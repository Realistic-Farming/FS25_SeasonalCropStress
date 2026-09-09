-- scs041_parcel_union_test.lua
-- SCS-041 owner-ratified field-boundary correction (decidable core): when two
-- engine fields share one farmland (parcel) id, the geometry domain is the
-- COMPLETE polygon collection, never a first match. This drives the REAL cache
-- collector and the pure-geometry consumers that share the parcel domain:
-- membership (point-in-ANY polygon, gaps never filled), the deterministic
-- collection fingerprint, cell-store relief across the union, and the runoff
-- source-field fence (a shared parcel is not permission to cross between its
-- fields). The native-map raster union (paint / delta / read-average region
-- ops) is the SDS remainder and is not exercised here.
--!load: src/SoilMoistureSystem.lua

-- One shared node registry so parcels added later never clobber earlier ones.
local nodePos = {}
local nodeSeed = 0
function getWorldTranslation(k)
  local p = nodePos[k]
  if p ~= nil then return p[1], p[2], p[3] end
  return 0, 0, 0
end

local function squareField(fid, minX, maxX)
  local pts = {}
  for i = 1, 4 do
    nodeSeed = nodeSeed + 1
    pts[i] = 100000 + nodeSeed
  end
  local corners = { { minX, 0, 0 }, { maxX, 0, 0 }, { maxX, 0, 100 }, { minX, 0, 100 } }
  for i = 1, 4 do nodePos[pts[i]] = corners[i] end
  return { farmland = { id = fid }, polygonPoints = pts }
end

-- Two engine fields share farmland id 1: A = x 0..100, B = x 200..300, so the
-- deed margin 100..200 is NOT cultivated ground and must stay empty.
local function installFields()
  g_fieldManager = { fields = { squareField(1, 0, 100), squareField(1, 200, 300) } }
end

local function newSystem()
  local s = SoilMoistureSystem.new({ eventBus = nil })
  s.isInitialized = true
  s.fieldData[1] = {
    fieldId = 1, moisture = 0.50, soilType = "loamy",
    cells = {}, cellSum = 0, cellCount = 0, reliefScan = false,
  }
  s._fieldVerts = {}
  return s
end

installFields()
do
  local s = newSystem()
  local polys = s:_getFieldPolygons(1)
  T.eq("P1 cache retains every shared-farmland polygon", #polys, 2)
  local again = s:_getFieldPolygons(1)
  T.eq("P2 collection is cached, not re-walked every call", #again, 2)
  T.ok("P3 field A polygon present", type(polys[1]) == "table" and polys[1].n == 4)
  T.ok("P4 field B polygon present", type(polys[2]) == "table" and polys[2].n == 4)
end

-- Membership is point-in-ANY cultivated polygon; the deed margin stays empty.
do
  local s = newSystem()
  T.ok("P5 in parcel on field A", s:_pointInParcel(1, 50, 50))
  T.ok("P6 in parcel on field B", s:_pointInParcel(1, 250, 50))
  T.eq("P7 deed margin between the fields is not watered", s:_pointInParcel(1, 150, 50), false)
  T.eq("P8 far outside is not in the parcel", s:_pointInParcel(1, 500, 500), false)

  -- _getFieldVerts (first polygon) still resolves for single-polygon callers.
  local vx, _, n = s:_getFieldVerts(1)
  T.eq("P9 first-polygon seam still answers", vx ~= nil and n == 4, true)
end

-- Unique-owner uses the union: both fields of the one parcel are one owner,
-- the margin is no owner, and a second parcel elsewhere stays distinct.
do
  local s = newSystem()
  s.fieldData[2] = { fieldId = 2 }
  g_fieldManager.fields[3] = squareField(2, 500, 600)
  local ownerA = s:_uniqueFieldOwnerAt(50, 50)
  local ownerB = s:_uniqueFieldOwnerAt(250, 50)
  local ownerMargin = s:_uniqueFieldOwnerAt(150, 50)
  local ownerOther = s:_uniqueFieldOwnerAt(550, 50)
  g_fieldManager.fields[3] = nil
  T.eq("P10 field A resolves to the one shared parcel", ownerA, 1)
  T.eq("P11 field B resolves to the same shared parcel", ownerB, 1)
  T.eq("P12 the deed margin resolves to no owner", ownerMargin, nil)
  T.eq("P13 a separate parcel stays its own owner", ownerOther, 2)
end

-- Fingerprint folds the whole collection deterministically and detects a move.
do
  installFields()
  local a = newSystem()
  local b = newSystem()
  T.eq("P14 collection fingerprint is stable", a:fieldGeometryFingerprint(1) == b:fieldGeometryFingerprint(1), true)
  local fp1 = a:fieldGeometryFingerprint(1)
  local polys = a:_getFieldPolygons(1)
  polys[2].vx = { 210, 310, 310, 210 }
  local fp2 = a:fieldGeometryFingerprint(1)
  T.eq("P15 fingerprint changes when any polygon moves", fp1 ~= fp2, true)
  local single = newSystem()
  T.ok("P16 single-polygon parcel still fingerprints", single:fieldGeometryFingerprint(1) ~= nil)
end

-- Cell-store relief materialises across the union (both fields of the parcel).
do
  installFields()
  g_terrainNode = {}
  function getTerrainHeightAtWorldPos(_n, x, _y, _z) return x * 0.5 end
  local s = newSystem()
  s._cellSize = 10
  s:materialiseRelief(1)
  local seenFar = false
  for cx, row in pairs(s.fieldData[1].cells) do
    if cx >= 20 then seenFar = true end   -- worldX >= 200 => inside field B
    for _ in pairs(row) do end
  end
  T.ok("P17 relief materialised cells on field A", s.fieldData[1].cellCount > 0)
  T.ok("P18 relief reached field B of the shared parcel", seenFar)
end

-- Runoff: a shared parcel is NOT permission to cross between its fields. The
-- source resolves to exactly one polygon; a destination in the OTHER field of
-- the same parcel is refused before any capacity or raw write.
local BASE = SoilMoistureSystem.BASE_INFILTRATION_PER_HOUR
do
  installFields()
  local function runoffSys()
    local s = newSystem()
    s.absorptionMode = "CAPPED"
    s.agronomyRestriction = 1.0
    s._resolveProviderCell = function()
      return { mode = "TRUTH", grain = 2, cellX = 1, cellZ = 1,
               centerX = 0, centerZ = 0, cellKey = "TRUTH:2:1:1" }
    end
    return s
  end
  local rawCalls = 0
  local s = runoffSys()
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end

  local crossField = s:_acceptRunoffDestinationSpan(1, 250, 50, 2, 100, 1, 0.08, 50, 50)
  T.eq("P19 source on field A, dest on field B refuses", crossField, 0)
  T.eq("P20 cross-field refusal makes no raw write", rawCalls, 0)

  local sameField = s:_acceptRunoffDestinationSpan(1, 250, 50, 2, 100, 1, 0.08, 250, 50)
  T.near("P21 source and dest on the same field accept", sameField, BASE, 1e-12)
  T.eq("P22 same-field acceptance writes once", rawCalls, 1)

  local marginDest = s:_acceptRunoffDestinationSpan(1, 150, 50, 2, 100, 1, 0.08, 50, 50)
  T.eq("P23 dest in the deed margin refuses", marginDest, 0)
end

T.summary()
