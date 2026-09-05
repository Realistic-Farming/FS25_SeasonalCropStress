-- scs039_geometry_rekey_test.lua
-- SCS-039 / GRID-1 (SDS 3.4 tail, slice 9): on a farmland ownership/geometry
-- change every pending positional leaf is revalidated against CURRENT field
-- geometry. Accepted water is never lost and never moves by identifier
-- accident: a leaf re-keys only when exactly one current field owns its world
-- position; ambiguous or missing membership stays an UNRESOLVED leaf.
--
-- The pure contract is modelled by the bar: Group H (unique resolution rekeys,
-- ambiguous stays unresolved, amount preserved) and Group I (ordered polygon
-- fingerprint change detection). These live tests drive the real re-key seam.
--!load: src/SoilMoistureSystem.lua

local function newSystem()
  local sys = SoilMoistureSystem.new({})
  sys._mapWaterPending = {}
  sys._fieldVerts = {}
  sys.fieldData = {}
  return sys
end

local function addField(sys, fid, minX, maxX, minZ, maxZ)
  sys.fieldData[fid] = { fieldId = fid }
  sys._fieldVerts[fid] = {
    vx = { minX, maxX, maxX, minX },
    vz = { minZ, minZ, maxZ, maxZ },
    n  = 4,
  }
end

local function worldLeaf(worldX, worldZ, grain, amount)
  return { status = "UNRESOLVED", worldX = worldX, worldZ = worldZ,
           sourceWidth = grain, amount = amount }
end

local function pendingTotal(sys)
  local total = 0
  for _, acc in pairs(sys._mapWaterPending) do
    for key, value in pairs(acc) do
      if type(key) == "number" then total = total + value
      else total = total + (value.amount or 0) end
    end
  end
  return total
end

-- Locate an unresolved leaf by world coordinates. Key text is intentionally not
-- matched: numeric-to-string rendering of a computed world centre can differ
-- across Lua runtimes (an integer-valued double prints "150" under Lua 5.1 but
-- "150.0" under fengari's number subtype), so the canonical test is the leaf's
-- own stored worldX/worldZ, never a literal key guess.
local function findWorldLeaf(sys, fieldId, worldX, worldZ)
  local acc = sys._mapWaterPending[fieldId]
  if acc == nil then return nil end
  for key, leaf in pairs(acc) do
    if type(key) == "string" and type(leaf) == "table"
       and leaf.worldX == worldX and leaf.worldZ == worldZ then
      return leaf
    end
  end
  return nil
end

-- 1. UNIQUE RE-KEY: a leaf now uniquely owned by another field moves to that
--    field with its amount, status and source width intact (Group H H4/H6).
do
  local sys = newSystem()
  addField(sys, 3, 0, 100, 0, 100)
  addField(sys, 7, 150, 250, 150, 250)
  sys._mapWaterPending[3] = {
    ["WORLD:10,20"]   = worldLeaf(10, 20, 2, 0.01),
    ["WORLD:180,200"] = worldLeaf(180, 200, 2, 0.02),
  }
  local totalBefore = pendingTotal(sys)
  local moved = sys:rekeyPositionalWaterForOwnership()
  T.eq("rekey.movedToUniqueOwner", moved, 1)
  T.near("rekey.staysInOwnField", sys._mapWaterPending[3]["WORLD:10,20"].amount, 0.01, 1e-12)
  T.eq("rekey.missingFromOldField", sys._mapWaterPending[3]["WORLD:180,200"], nil)
  local leaf = sys._mapWaterPending[7] and sys._mapWaterPending[7]["WORLD:180,200"]
  T.eq("rekey.arrivesAtNewField", leaf ~= nil, true)
  T.eq("rekey.keepsUnresolvedStatus", leaf and leaf.status or nil, "UNRESOLVED")
  T.eq("rekey.keepsWorldCoords", leaf and leaf.worldX or nil, 180)
  T.eq("rekey.keepsSourceWidth", leaf and leaf.sourceWidth or nil, 2)
  T.near("rekey.keepsAmount", leaf and leaf.amount or -1, 0.02, 1e-12)
  T.near("rekey.totalConserved", pendingTotal(sys), totalBefore, 1e-12)
end

-- 2. AMBIGUOUS MEMBERSHIP stays unresolved in its stored field and is never
--    moved to another field (Group H H5/H6).
do
  local sys = newSystem()
  addField(sys, 3, 0, 100, 0, 100)
  addField(sys, 5, 50, 150, 50, 150)
  sys._mapWaterPending[3] = {
    ["WORLD:75,75"] = worldLeaf(75, 75, 2, 0.004),
  }
  local totalBefore = pendingTotal(sys)
  local moved = sys:rekeyPositionalWaterForOwnership()
  T.eq("ambiguous.noMove", moved, 0)
  T.eq("ambiguous.noOtherField", sys._mapWaterPending[5], nil)
  local leaf = sys._mapWaterPending[3]["WORLD:75,75"]
  T.eq("ambiguous.staysResolved", leaf ~= nil and leaf.status or nil, "UNRESOLVED")
  T.near("ambiguous.amountKept", leaf and leaf.amount or -1, 0.004, 1e-12)
  T.near("ambiguous.totalConserved", pendingTotal(sys), totalBefore, 1e-12)
end

-- 3. MISSING MEMBERSHIP (the point now belongs to no current field) stays
--    unresolved in the stored field, water never dropped.
do
  local sys = newSystem()
  addField(sys, 3, 0, 100, 0, 100)
  sys._mapWaterPending[3] = {
    ["WORLD:1000,1000"] = worldLeaf(1000, 1000, 2, 0.02),
  }
  local moved = sys:rekeyPositionalWaterForOwnership()
  T.eq("missing.noMove", moved, 0)
  local leaf = sys._mapWaterPending[3]["WORLD:1000,1000"]
  T.near("missing.amountKept", leaf and leaf.amount or -1, 0.02, 1e-12)
end

-- 4. RESOLVED pixel remainder re-keys by its reconstructed world centre when
--    the pixel map is present. res=4 over terrainSize=400 gives 100 m pixels
--    centred at x = 100*(px+0.5) - 200: px 2 -> (50,50), px 3 -> (150,150).
do
  local sys = newSystem()
  addField(sys, 3, 0, 100, 0, 100)
  addField(sys, 7, 120, 220, 120, 220)
  sys.valueMap = { available = true, resolution = 4, terrainSize = 400 }
  sys._mapWaterPending[3] = {
    [8194]  = 0.001,   -- px2,pz2 centre (50,50)  -> stays field 3
    [12291] = 0.002,   -- px3,pz3 centre (150,150) -> moves to field 7
  }
  local totalBefore = pendingTotal(sys)
  local moved = sys:rekeyPositionalWaterForOwnership()
  T.eq("resolved.movedToOwner", moved, 1)
  T.near("resolved.staysNumeric", sys._mapWaterPending[3][8194], 0.001, 1e-12)
  T.eq("resolved.leftOldField", sys._mapWaterPending[3][12291], nil)
  T.near("resolved.arrivesAtNewField", sys._mapWaterPending[7][12291], 0.002, 1e-12)
  T.eq("resolved.arrivesResolved", type(sys._mapWaterPending[7][12291]), "number")
  T.near("resolved.totalConserved", pendingTotal(sys), totalBefore, 1e-12)
end

-- 5. A RESOLVED remainder whose world centre is now inside two fields is
--    demoted to an UNRESOLVED world leaf in its stored field, never applied to
--    the wrong one and never lost.
do
  local sys = newSystem()
  addField(sys, 3, 0, 200, 0, 200)
  addField(sys, 5, 100, 300, 100, 300)
  sys.valueMap = { available = true, resolution = 4, terrainSize = 400 }
  sys._mapWaterPending[3] = { [12291] = 0.0015 }   -- centre (150,150) in both
  local totalBefore = pendingTotal(sys)
  local moved = sys:rekeyPositionalWaterForOwnership()
  T.eq("demote.moved", moved, 1)
  T.eq("demote.clearedResolved", sys._mapWaterPending[3][12291], nil)
  local leaf = findWorldLeaf(sys, 3, 150, 150)
  T.eq("demote.isUnresolvedLeaf", leaf ~= nil and leaf.status or nil, "UNRESOLVED")
  T.near("demote.amountKept", leaf and leaf.amount or -1, 0.0015, 1e-12)
  T.eq("demote.recordsGrain", leaf and leaf.sourceWidth or nil, 100)
  T.near("demote.totalConserved", pendingTotal(sys), totalBefore, 1e-12)
end

-- 6. A RESOLVED remainder without a pixel map cannot be reconstructed, so it
--    stays exactly where it is rather than being guessed to a field.
do
  local sys = newSystem()
  addField(sys, 3, 0, 100, 0, 100)
  addField(sys, 7, 150, 250, 150, 250)
  sys.valueMap = nil
  sys._mapWaterPending[3] = { [8194] = 0.001 }
  local moved = sys:rekeyPositionalWaterForOwnership()
  T.eq("noMap.noMove", moved, 0)
  T.near("noMap.staysNumeric", sys._mapWaterPending[3][8194], 0.001, 1e-12)
end

-- 7. ORDERED POLYGON FINGERPRINT is stable for equal geometry and changes when
--    the polygon moves (Group I I13/I14).
do
  local sys = newSystem()
  addField(sys, 1, 0, 100, 0, 100)
  local fp1 = sys:fieldGeometryFingerprint(1)
  local fp2 = sys:fieldGeometryFingerprint(1)
  T.eq("fingerprint.stable", fp1 == fp2, true)
  T.ok("fingerprint.nonNil", fp1 ~= nil)
  sys._fieldVerts[1].vx = { 5, 105, 105, 5 }
  local fp3 = sys:fieldGeometryFingerprint(1)
  T.eq("fingerprint.changesOnGeometry", fp1 ~= fp3, true)
end

-- 8. The handler (server) invalidates the cached vertices and never crashes;
--    a load-time replay only invalidates and returns without re-keying.
do
  g_server = {}
  local sys = newSystem()
  addField(sys, 3, 0, 100, 0, 100)
  sys._mapWaterPending[3] = { ["WORLD:10,20"] = worldLeaf(10, 20, 2, 0.01) }
  sys:onFarmlandOwnerChanged(3, 1, true)
  T.eq("handler.loadReplayInvalidates", sys._fieldVerts[3], nil)
  T.eq("handler.loadReplayKeepsPending", sys._mapWaterPending[3]["WORLD:10,20"] ~= nil, true)
  addField(sys, 3, 0, 100, 0, 100)
  sys._fieldVerts[3] = { vx = { 0, 100, 100, 0 }, vz = { 0, 0, 100, 100 }, n = 4 }
  sys:onFarmlandOwnerChanged(3, 2, false)
  -- The square verts are dropped; the revalidation may re-cache a refusal marker
  -- (no scene here) but must never keep the stale pre-change square.
  local cached = sys._fieldVerts[3]
  T.eq("handler.vertsDropped", cached == nil or cached.n ~= 4, true)
  T.near("handler.keepsWater", pendingTotal(sys), 0.01, 1e-12)
  g_server = nil
end

T.summary()
