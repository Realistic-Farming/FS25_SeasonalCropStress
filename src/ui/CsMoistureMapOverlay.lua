-- =========================================================
-- CsMoistureMapOverlay
-- Map -> Crop Moisture as a Soil-style polygon heat sheet.
-- =========================================================
-- BUILD 22:29: this used to draw ONE dot per field, at the field centroid, coloured from
-- the field-average moisture. That cannot show what a player actually wants to see, which
-- is the wet patch where the irrigator has just been: a sub-area read is invisible when the
-- whole field is one dot.
--
-- 2026-08-18: the primary render path is now the engine density-map visualization (DMV)
-- overlay, the same pipeline Soil's PDA uses: a dedicated 4-bit display bitvector is
-- band-painted per field polygon and rendered as a crisp per-pixel overlay. The sampled
-- tile grid below is the engine-absent fallback and is kept bit for bit.
--
-- The display map is SEPARATE from CropStressValueMap on purpose: the sim map encodes
-- moisture linearly over 254 raw steps, where the driest pixels land in DMV state 0 (the
-- off-field transparent band). Band-painting a dedicated map floors every field at band 1
-- so a bone-dry field stays visible, and it never touches the persisted sim data.
--
-- The helpers are PORTED, not required: SCS must not depend on
-- FS25_SoilFertilizer being installed, so the polygon walk and the point-in-polygon test
-- live here in full rather than being reached across a mod boundary.
--
-- ONE ramp function feeds the tiles, the DMV bands and the legend swatch. That is
-- deliberate: a legend drawn from a second colour table is a legend that can quietly stop
-- describing the map, which is exactly the kind of drift this suite keeps paying for.
--
-- Read only. Nothing here writes a densmap, and the HUD alert thresholds are untouched:
-- this is a display ramp, not a change to what counts as dry.
-- =========================================================

CsMoistureMapOverlay = CsMoistureMapOverlay or {}
local CsMoistureMapOverlay_mt = Class(CsMoistureMapOverlay)

-- Ramp anchors. These are the hairlines the legend labels, NOT the HUD alert thresholds,
-- which stay where they are in HUDOverlay.
CsMoistureMapOverlay.HAIR_DRY_GOOD = 0.40
CsMoistureMapOverlay.HAIR_GOOD_WET = 0.70
CsMoistureMapOverlay.ALPHA         = 0.72

-- Deep red at bone dry, through amber, to grass green at the Good edge; green holds across
-- the plateau; green to light blue as it goes past field capacity.
CsMoistureMapOverlay.C_DRY   = {0.72, 0.09, 0.09}
CsMoistureMapOverlay.C_AMBER = {0.90, 0.62, 0.15}
CsMoistureMapOverlay.C_GOOD  = {0.35, 0.72, 0.30}
CsMoistureMapOverlay.C_WET   = {0.55, 0.80, 0.95}
-- BUILD 23:03: cyan chrome is OFF. The only accent on the panel is the wet end of the
-- ramp, so the chrome cannot drift away from the sheet it describes. Charcoal and
-- border tone match the Soil Layers panel.
CsMoistureMapOverlay.C_CHARCOAL = {0.07, 0.07, 0.13}
CsMoistureMapOverlay.C_BORDER   = {0.30, 0.32, 0.36}

-- Sampling. Step is the world grid spacing; tiles are drawn slightly larger than a cell so
-- the sheet reads solid instead of showing seams between samples.
CsMoistureMapOverlay.SAMPLE_INTERVAL_MS   = 2000
CsMoistureMapOverlay.POLYGON_STEP         = 10
CsMoistureMapOverlay.TILE_OVERSIZE        = 1.15
CsMoistureMapOverlay.EXPANSION_MARGIN_CELLS = 8
CsMoistureMapOverlay.MAX_SCAN_CELLS       = 12000
-- Base budgets for a 2048 m map, scaled by map area at runtime so a 4x map gets the same
-- visual density rather than running out of points half way down the field list.
CsMoistureMapOverlay.DENSITY_POINTS       = {8000, 20000, 40000}
-- BUILD 23:03. 22:29 moved only the point budget, so Low and High drew more or fewer
-- tiles of the SAME size and the field edges never got finer. The step is what the eye
-- actually reads, so each level carries its own.
CsMoistureMapOverlay.DENSITY_STEPS        = {13, 10, 6}
CsMoistureMapOverlay.DENSITY_DEFAULT      = 2

-- DMV (density-map visualization) primary path. Rebuild cadence while the page is open,
-- and the number of discrete colour bands the display map paints (state 0 stays
-- transparent for off-field, bands 1..15 carry the moisture ramp).
CsMoistureMapOverlay.PDA_DMV_REBUILD_MS = 3000
CsMoistureMapOverlay.PDA_DMV_BANDS      = 15

local CS_MAP_MOD_NAME = (SeasonalCropStressModName or g_currentModName)

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[CS_MAP_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            -- Reject unresolved keys the engine can hand back: the raw key, the
            -- $l10n_ literal, or "MISSING ..." variants. A missing key must fall
            -- back to the English default, never render as a raw string.
            local lower = text:lower()
            if lower ~= tostring(key):lower()
               and text ~= ("$l10n_" .. key)
               and not lower:find("^missing%s")
               and not lower:find("^missing_") then
                return text
            end
        end
    end
    return fallback or key
end

local function clamp01(v)
    if type(v) ~= "number" then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

--- Even-odd point in polygon. Ported from the Soil overlay rather than required across the
--- mod boundary, so Crop Stress keeps working with Soil absent.
local function isPointInPoly(px, pz, verts)
    local n = #verts
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local xi, zi = verts[i].x, verts[i].z
        local xj, zj = verts[j].x, verts[j].z
        if ((zi > pz) ~= (zj > pz)) and
           (px < (xj - xi) * (pz - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- ── The one ramp ──────────────────────────────────────────

--- Moisture 0..1 to colour. THE single source for both the tiles and the legend swatch.
--- Continuous below the Dry|Good hair, flat across the Good plateau, continuous again into
--- Wet, so the legend bar can be drawn by feeding it the same 0..1 sweep.
---@param m number|nil
---@return number, number, number
function CsMoistureMapOverlay.rampColor(m)
    local v = clamp01(m)
    if v == nil then
        local c = CsMoistureMapOverlay.C_GOOD
        return c[1], c[2], c[3]
    end
    local function mix(a, b, t)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        return a[1] + (b[1] - a[1]) * t,
               a[2] + (b[2] - a[2]) * t,
               a[3] + (b[3] - a[3]) * t
    end
    local dryGood = CsMoistureMapOverlay.HAIR_DRY_GOOD
    local goodWet = CsMoistureMapOverlay.HAIR_GOOD_WET
    if v <= dryGood then
        local mid = dryGood * 0.5
        if v <= mid then
            return mix(CsMoistureMapOverlay.C_DRY, CsMoistureMapOverlay.C_AMBER, v / mid)
        end
        return mix(CsMoistureMapOverlay.C_AMBER, CsMoistureMapOverlay.C_GOOD, (v - mid) / mid)
    end
    if v <= goodWet then
        local c = CsMoistureMapOverlay.C_GOOD
        return c[1], c[2], c[3]
    end
    return mix(CsMoistureMapOverlay.C_GOOD, CsMoistureMapOverlay.C_WET,
               (v - goodWet) / (1.0 - goodWet))
end

--- Which band a moisture figure sits in. ONE owner for the two hairs, shared by the
--- status row counts and the average card verdict, so a row can never disagree with
--- the card it sits above.
---@return string|nil  "dry" | "good" | "wet", nil when there is no reading
function CsMoistureMapOverlay.classifyMoisture(m)
    if type(m) ~= "number" then return nil end
    if m < CsMoistureMapOverlay.HAIR_DRY_GOOD then return "dry" end
    if m > CsMoistureMapOverlay.HAIR_GOOD_WET then return "wet" end
    return "good"
end

-- ── Constructor ───────────────────────────────────────────

function CsMoistureMapOverlay.new(manager)
    local self = setmetatable({}, CsMoistureMapOverlay_mt)
    self.manager        = manager
    self.samplePoints   = {}
    self.nextSampleTime = 0
    self.buttonRects    = {}
    self.ingameMapRef   = nil
    self.fieldPolyCache = {}
    -- Session local on purpose: a map view knob is not worth a savegame key.
    self.density        = CsMoistureMapOverlay.DENSITY_DEFAULT
    self.sampleStep     = CsMoistureMapOverlay.DENSITY_STEPS[CsMoistureMapOverlay.DENSITY_DEFAULT]
    self.stats          = {dry = 0, good = 0, wet = 0, avg = nil, fields = 0}

    -- PDA DMV double-buffer overlay (async density-map visualization, Soil pattern).
    self._pdaDMVAvailable  = false
    self._pdaOverlays      = {nil, nil}
    self._pdaShowIdx       = 1
    self._pdaBuildIdx      = 2
    self._pdaBuildInFlight = false
    self._pdaBuildHandle   = nil
    self._pdaHasShownOnce  = false
    self._pdaUsingDMV      = false
    self._pdaNextBuildMs   = 0
    self._pdaDataSig       = nil   -- fingerprint of last painted field state
    self._pdaDisplayMap    = nil   -- dedicated 4-bit display bitvector
    self._pdaDisplayMod    = nil   -- its terrain-bound modifier
    return self
end

function CsMoistureMapOverlay:initialize()
    if createImageOverlay then
        self.mapDotOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    self:_pdaCreateOverlays()
    print("[CropStress] CsMoistureMapOverlay initialized (DMV heatmap, tile fallback)")
end

--- Create the double-buffer DMV overlays and the band-paint display map. Mirror of the
--- Soil PDA overlay creation; engine-absent stays available=false so onDraw keeps tiles.
function CsMoistureMapOverlay:_pdaCreateOverlays()
    if createDensityMapVisualizationOverlay == nil or g_dedicatedServer then return end
    if createBitVectorMap == nil or loadBitVectorMapNew == nil then return end
    if DensityMapModifier == nil or DensityMapModifier.new == nil then return end

    local resX, resY = 1024, 1024
    local mog = g_currentMission and g_currentMission.mapOverlayGenerator
    if mog and MapOverlayGenerator and MapOverlayGenerator.OVERLAY_RESOLUTION then
        local fsRes = MapOverlayGenerator.OVERLAY_RESOLUTION.FOLIAGE_STATE
        if fsRes and fsRes[1] and fsRes[2] then resX, resY = fsRes[1], fsRes[2] end
    end

    local ok, err = pcall(function()
        self._pdaOverlays[1] = createDensityMapVisualizationOverlay("CS_PDAHeatmapA", resX, resY)
        self._pdaOverlays[2] = createDensityMapVisualizationOverlay("CS_PDAHeatmapB", resX, resY)
    end)
    if not ok or self._pdaOverlays[1] == nil or self._pdaOverlays[2] == nil then
        self._pdaOverlays = {nil, nil}
        return
    end
    self._pdaDMVAvailable = true

    ok, err = pcall(function()
        -- 8-channel map, same shape Soil's value maps use; the DMV reads the low 4 bits
        -- (firstChannel=0, numChannels=4), so band 1..15 lands in states 1..15.
        self._pdaDisplayMap = createBitVectorMap("CS_PDA_MoistureDisplay")
        loadBitVectorMapNew(self._pdaDisplayMap, resX, resY, 8, false)
        self._pdaDisplayMod = DensityMapModifier.new(self._pdaDisplayMap, 0, 8, g_terrainNode)
    end)
    if not ok or self._pdaDisplayMap == nil or self._pdaDisplayMap == 0 or self._pdaDisplayMod == nil then
        self._pdaDisplayMap = nil
        self._pdaDisplayMod = nil
        self._pdaDMVAvailable = false
        self._pdaOverlays = {nil, nil}
        return
    end
end

function CsMoistureMapOverlay:delete()
    if self.mapDotOverlay then
        delete(self.mapDotOverlay)
        self.mapDotOverlay = nil
    end
    if self._pdaDisplayMap and self._pdaDisplayMap ~= 0 and delete then
        pcall(delete, self._pdaDisplayMap)
    end
    self._pdaDisplayMap    = nil
    self._pdaDisplayMod    = nil
    self._pdaOverlays      = {nil, nil}
    self._pdaBuildInFlight = false
    self._pdaBuildHandle   = nil
    self.samplePoints = {}
    self.fieldPolyCache = {}
end

function CsMoistureMapOverlay:getDisplayValues()       return {} end
function CsMoistureMapOverlay:getDefaultFilterState()  return {} end

function CsMoistureMapOverlay:requestRefresh()
    self.nextSampleTime = 0
    self._pdaNextBuildMs = 0
    self._pdaDataSig     = nil   -- force a repaint on the next build
end

--- Kept for callers that still ask for a banded colour; it now answers from the ramp so a
--- second palette cannot drift away from the sheet.
function CsMoistureMapOverlay:getMoistureColor(moisture)
    return CsMoistureMapOverlay.rampColor(moisture)
end

-- ── PDA DMV overlay (density-map visualization) ───────────

--- Poll the async overlay build. When the engine reports the back buffer ready, swap the
--- buffers so the freshly generated frame becomes the one that draws (Soil pattern).
function CsMoistureMapOverlay:_pdaPollBuildFinished()
    if not self._pdaBuildInFlight or not self._pdaBuildHandle then return end
    if getIsDensityMapVisualizationOverlayReady == nil then return end
    if getIsDensityMapVisualizationOverlayReady(self._pdaBuildHandle) then
        self._pdaShowIdx, self._pdaBuildIdx = self._pdaBuildIdx, self._pdaShowIdx
        self._pdaBuildInFlight = false
        self._pdaBuildHandle   = nil
        self._pdaHasShownOnce  = true
    end
end

--- Every field polygon (not farmland patch) with its farmland's moisture, for the band
--- paint. One farmland may own several fields; the moisture scalar is per farmland, so it
--- is cached per fid and every polygon of that farmland gets the same band.
function CsMoistureMapOverlay:_pdaCollectFieldPolygons()
    local out = {}
    if g_fieldManager == nil or g_fieldManager.fields == nil then return out end
    local mgr = self.manager
    local soilSystem = mgr and mgr.soilSystem
    if soilSystem == nil or soilSystem.fieldData == nil then return out end

    local moistCache = {}
    for _, f in ipairs(g_fieldManager.fields) do
        if f and f.farmland and f.farmland.id and f.farmland.id > 0 then
            local fid = f.farmland.id
            if moistCache[fid] == nil then
                local entry = soilSystem.fieldData[fid]
                moistCache[fid] = (entry and entry.moisture) or -1   -- -1 = no sim data yet
            end
            local moisture = moistCache[fid]
            if moisture >= 0 then
                local vx, vz = {}, {}
                if f.polygonPoints then
                    for i = 1, #f.polygonPoints do
                        local nodeId = f.polygonPoints[i]
                        if nodeId and nodeId ~= 0 then
                            local okW, wx, _, wz = pcall(getWorldTranslation, nodeId)
                            if okW and wx then
                                vx[#vx + 1] = wx
                                vz[#vz + 1] = wz
                            end
                        end
                    end
                end
                if #vx >= 3 then
                    out[#out + 1] = { fid = fid, vx = vx, vz = vz, moisture = moisture }
                end
            end
        end
    end
    return out
end

--- Cheap fingerprint of the field moisture state. Repainting the display map is skipped
--- while this is unchanged, so the open map idles without churning the bitvector.
function CsMoistureMapOverlay:_pdaBuildDataSignature(polys)
    local sig = 0
    for _, p in ipairs(polys) do
        sig = sig + math.floor(p.moisture * 1000) * 31 + p.fid * 7
    end
    return sig
end

--- Band counts for the sidebar legend, computed from the DMV polygon pass so the status
--- rows stay live when the DMV path (not updateSamplePoints) drives the page.
function CsMoistureMapOverlay:_pdaComputeStats(polys)
    local stats = {dry = 0, good = 0, wet = 0, avg = nil, fields = 0}
    local sum = 0
    local seenFarms = {}
    for _, p in ipairs(polys) do
        if not seenFarms[p.fid] then
            seenFarms[p.fid] = true
            local band = CsMoistureMapOverlay.classifyMoisture(p.moisture)
            if band ~= nil then
                stats[band] = stats[band] + 1
                stats.fields = stats.fields + 1
                sum = sum + p.moisture
            end
        end
    end
    if stats.fields > 0 then stats.avg = sum / stats.fields end
    self.stats = stats
end

--- Repaint the dedicated display map: clear everything, then band-paint every field
--- polygon. Band 0 stays for off-field (DMV state 0 = transparent); each field lands on
--- band 1..15 so even a bone-dry field is visible.
function CsMoistureMapOverlay:_pdaPaintDisplayMap(polys)
    local m = self._pdaDisplayMod
    if m == nil then return false end
    local half = ((g_currentMission and g_currentMission.terrainSize) or 2048) * 0.5

    local okClear = pcall(function()
        m:setParallelogramWorldCoords(-half, -half, half, -half, -half, half,
                                      DensityCoordType.POINT_POINT_POINT)
        m:executeSet(0)
    end)
    if not okClear then return false end

    for _, p in ipairs(polys) do
        local band = math.max(1, math.min(CsMoistureMapOverlay.PDA_DMV_BANDS,
                                          math.ceil(p.moisture * CsMoistureMapOverlay.PDA_DMV_BANDS)))
        local okP = pcall(function()
            m:clearPolygonPoints()
            for i = 1, #p.vx do
                m:addPolygonPointWorldCoords(p.vx[i], p.vz[i])
            end
        end)
        if okP then
            pcall(function() m:executeSet(band) end)
        end
    end
    return true
end

--- Kick an async DMV build. Repaints the display map only when the moisture state moved;
--- the state colours are a fixed ramp so the regenerate alone would not change anything.
--- Engine-absent or value-map-absent leaves _pdaUsingDMV false so onDraw keeps tiles.
function CsMoistureMapOverlay:_pdaKickBuild()
    local ov = self._pdaOverlays[self._pdaBuildIdx]
    if not ov then return end
    self._pdaUsingDMV = false

    local polys = self:_pdaCollectFieldPolygons()
    local sig   = self:_pdaBuildDataSignature(polys)
    if sig ~= (self._pdaDataSig or -1) then
        self:_pdaComputeStats(polys)
        if self:_pdaPaintDisplayMap(polys) then
            self._pdaDataSig = sig
        end
    end

    local map = self._pdaDisplayMap
    if map == nil then return end

    if resetDensityMapVisualizationOverlay then
        resetDensityMapVisualizationOverlay(ov)
    end
    -- State 0 (off-field band 0) stays transparent; states 1..15 follow the ramp.
    setDensityMapVisualizationOverlayStateColor(ov, map, 0, 0, 0, 4, 0, 0, 0, 0, 0)
    for i = 1, CsMoistureMapOverlay.PDA_DMV_BANDS do
        local r, g, b = CsMoistureMapOverlay.rampColor(i / CsMoistureMapOverlay.PDA_DMV_BANDS)
        setDensityMapVisualizationOverlayStateColor(ov, map, 0, 0, 0, 4, i, r, g, b, 1.0)
    end
    self._pdaUsingDMV = true
    generateDensityMapVisualizationOverlay(ov)
    self._pdaBuildHandle   = ov
    self._pdaBuildInFlight = true
end

--- Draw the engine DMV overlay stretched over the map rect. Returns true when the DMV
--- overlay was drawn, so the caller skips the sampled tiles entirely.
function CsMoistureMapOverlay:_pdaDrawDMV(ingameMap, mapX, mapY, mapWidth, mapHeight)
    if not self._pdaDMVAvailable then return false end

    local now = (g_currentMission and g_currentMission.time) or g_time or 0
    self:_pdaPollBuildFinished()

    local wantBuild = not self._pdaBuildInFlight
        and (not self._pdaHasShownOnce or now >= self._pdaNextBuildMs)
    if wantBuild then
        self:_pdaKickBuild()
        self._pdaNextBuildMs = now + CsMoistureMapOverlay.PDA_DMV_REBUILD_MS
    end

    if not self._pdaUsingDMV then return false end
    if not self._pdaHasShownOnce then return false end   -- tiles until the first build lands

    local ov = self._pdaOverlays[self._pdaShowIdx]
    if not ov then return false end

    -- Terrain rect in screen space via the shared world→screen projection.
    local half = ((g_currentMission and g_currentMission.terrainSize) or 2048) * 0.5
    local ax, ay = self:worldToScreenPosition(ingameMap, -half, -half)
    local bx, by = self:worldToScreenPosition(ingameMap, half, half)
    if not ax or not bx then return false end

    local x1, x2 = math.min(ax, bx), math.max(ax, bx)
    local y1, y2 = math.min(ay, by), math.max(ay, by)
    if x1 == x2 or y1 == y2 then return false end

    -- Clip to the visible map area and pick the matching UV slice.
    local rx1 = math.max(x1, mapX);          local ry1 = math.max(y1, mapY)
    local rx2 = math.min(x2, mapX + mapWidth);   local ry2 = math.min(y2, mapY + mapHeight)
    if (rx2 - rx1) <= 0 or (ry2 - ry1) <= 0 then return false end

    local uL = (rx1 - x1) / (x2 - x1); local vT = (ry1 - y1) / (y2 - y1)
    local uR = (rx2 - x1) / (x2 - x1); local vB = (ry2 - y1) / (y2 - y1)

    setOverlayUVs(ov, uL, vT, uL, vB, uR, vT, uR, vB)
    setOverlayColor(ov, 1, 1, 1, CsMoistureMapOverlay.ALPHA)
    renderOverlay(ov, rx1, ry1, rx2 - rx1, ry2 - ry1)

    if Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
        setOverlayUVs(ov, unpack(Overlay.DEFAULT_UVS))
    end
    return true
end

-- ── Farmland fill points (ported from the Soil overlay) ───

--- Every sample point inside one farmland, on a `step` grid.
---
--- Field.polygonPoints is static and never grows when a player plows a field bigger, so the
--- polygon alone misses the new ground. The scan widens the polygon AABB, unions the
--- farmland bounding box when the engine exposes one, and accepts off-polygon cells that the
--- engine reports as live field ground on this same farmland.
function CsMoistureMapOverlay:getFarmlandFillPoints(farmlandId, step)
    step = step or CsMoistureMapOverlay.POLYGON_STEP
    local cacheKey = tostring(farmlandId) .. "@" .. tostring(step)
    if self.fieldPolyCache[cacheKey] then
        return self.fieldPolyCache[cacheKey]
    end

    local pts = {}
    local polys = {}
    local fallbackX, fallbackZ
    local pMinX, pMaxX, pMinZ, pMaxZ
    local fields = g_fieldManager and g_fieldManager.fields
    if fields then
        for _, f in ipairs(fields) do
            if f and f.farmland and f.farmland.id == farmlandId then
                local polyNodes = f.polygonPoints
                local verts = {}
                if polyNodes and #polyNodes > 0 then
                    for i = 1, #polyNodes do
                        local nodeId = polyNodes[i]
                        if nodeId and nodeId ~= 0 then
                            local ok, wx, _, wz = pcall(getWorldTranslation, nodeId)
                            if ok and wx then
                                verts[#verts + 1] = {x = wx, z = wz}
                                if not pMinX or wx < pMinX then pMinX = wx end
                                if not pMaxX or wx > pMaxX then pMaxX = wx end
                                if not pMinZ or wz < pMinZ then pMinZ = wz end
                                if not pMaxZ or wz > pMaxZ then pMaxZ = wz end
                            end
                        end
                    end
                end
                if #verts >= 3 then polys[#polys + 1] = verts end
                if not fallbackX and f.posX then fallbackX, fallbackZ = f.posX, f.posZ end
            end
        end
    end

    local minX, maxX, minZ, maxZ = pMinX, pMaxX, pMinZ, pMaxZ
    if minX then
        local margin = CsMoistureMapOverlay.EXPANSION_MARGIN_CELLS * step
        minX, maxX = minX - margin, maxX + margin
        minZ, maxZ = minZ - margin, maxZ + margin
    end

    local farmland = g_farmlandManager and g_farmlandManager.getFarmlandById
        and g_farmlandManager:getFarmlandById(farmlandId)
    local bb = farmland and farmland.boundingBox
    if type(bb) == "table" and type(bb.minX) == "number" and type(bb.maxX) == "number"
       and type(bb.minZ) == "number" and type(bb.maxZ) == "number"
       and bb.maxX > bb.minX and bb.maxZ > bb.minZ then
        minX = minX and math.min(minX, bb.minX) or bb.minX
        maxX = maxX and math.max(maxX, bb.maxX) or bb.maxX
        minZ = minZ and math.min(minZ, bb.minZ) or bb.minZ
        maxZ = maxZ and math.max(maxZ, bb.maxZ) or bb.maxZ
    end

    if not minX then
        if fallbackX then pts[1] = {x = fallbackX, z = fallbackZ} end
        self.fieldPolyCache[cacheKey] = pts
        return pts
    end

    local half = ((g_currentMission and g_currentMission.terrainSize) or 2048) * 0.5
    minX = math.max(minX, -half); maxX = math.min(maxX, half)
    minZ = math.max(minZ, -half); maxZ = math.min(maxZ, half)

    -- A bogus bounding box must not turn into a giant scan and a frame hitch.
    local nx = math.floor((maxX - minX) / step) + 1
    local nz = math.floor((maxZ - minZ) / step) + 1
    if nx * nz > CsMoistureMapOverlay.MAX_SCAN_CELLS then
        if pMinX then
            minX, maxX, minZ, maxZ = pMinX, pMaxX, pMinZ, pMaxZ
        else
            if fallbackX then pts[1] = {x = fallbackX, z = fallbackZ} end
            self.fieldPolyCache[cacheKey] = pts
            return pts
        end
    end

    local hasFieldGroundApi = (FSDensityMapUtil ~= nil
        and FSDensityMapUtil.getFieldDataAtWorldPosition ~= nil)
    local x = minX + step * 0.5
    while x <= maxX do
        local z = minZ + step * 0.5
        while z <= maxZ do
            local inField = false
            for pi = 1, #polys do
                if isPointInPoly(x, z, polys[pi]) then inField = true; break end
            end
            if not inField and hasFieldGroundApi then
                local ok, onField = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, x, 0, z)
                if ok and onField then
                    local fid = g_farmlandManager and g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
                    if type(fid) == "table" then fid = fid.id end
                    if fid == farmlandId then inField = true end
                end
            end
            if inField then pts[#pts + 1] = {x = x, z = z} end
            z = z + step
        end
        x = x + step
    end

    if #pts == 0 and fallbackX then
        pts[1] = {x = fallbackX, z = fallbackZ}
    end
    self.fieldPolyCache[cacheKey] = pts
    return pts
end

-- ── Sample the sheet ──────────────────────────────────────

function CsMoistureMapOverlay:updateSamplePoints(force)
    local now = (g_currentMission and g_currentMission.time) or 0
    if not force and now < self.nextSampleTime then return end
    self.nextSampleTime = now + CsMoistureMapOverlay.SAMPLE_INTERVAL_MS

    self.samplePoints = {}

    if g_currentMission == nil or g_fieldManager == nil then return end
    local fields = g_fieldManager.fields
    if fields == nil then return end

    local mgr = self.manager
    local soilSystem = mgr and mgr.soilSystem
    if soilSystem == nil then return end

    local terrainSize = (g_currentMission and g_currentMission.terrainSize) or 2048
    local mapScale    = math.max(1.0, terrainSize / 2048.0)
    local level       = self.density or CsMoistureMapOverlay.DENSITY_DEFAULT
    local basePoints  = CsMoistureMapOverlay.DENSITY_POINTS[level]
        or CsMoistureMapOverlay.DENSITY_POINTS[CsMoistureMapOverlay.DENSITY_DEFAULT]
    local maxPoints   = math.floor(basePoints * mapScale * mapScale)
    local step        = self.sampleStep or CsMoistureMapOverlay.POLYGON_STEP

    -- The per-spot read. nil means this map has no moisture value map, which is a real
    -- state and not an error: the field then paints one honest colour rather than vanishing.
    local canSpotRead = mgr ~= nil and type(mgr.getMoisture) == "function"

    local stats = {dry = 0, good = 0, wet = 0, avg = nil, fields = 0}
    local sum = 0

    local total = 0
    local seen = {}
    for _, field in ipairs(fields) do
        if total >= maxPoints then break end
        if field and field.farmland then
            local fid = field.farmland.id
            if fid and fid > 0 and not seen[fid] then
                seen[fid] = true
                local entry = soilSystem.fieldData and soilSystem.fieldData[fid]
                local fieldAvg = entry and entry.moisture or nil
                -- Field-level tally for the panel. Counted per farmland rather than per
                -- tile, so a big field cannot outvote a small one in the band counts.
                local band = CsMoistureMapOverlay.classifyMoisture(fieldAvg)
                if band ~= nil then
                    stats[band] = stats[band] + 1
                    stats.fields = stats.fields + 1
                    sum = sum + fieldAvg
                end

                local pts = self:getFarmlandFillPoints(fid, step)
                for _, p in ipairs(pts) do
                    if total >= maxPoints then break end
                    local m = nil
                    if canSpotRead then
                        local ok, v = pcall(function() return mgr:getMoisture(fid, p.x, p.z) end)
                        if ok and type(v) == "number" then m = v end
                    end
                    -- No value map: every tile on this field takes the field figure, so the
                    -- sheet is flat but present. Never hide the overlay.
                    if m == nil then m = fieldAvg end
                    local r, g, b = CsMoistureMapOverlay.rampColor(m)
                    total = total + 1
                    self.samplePoints[total] = {
                        x = p.x, z = p.z, r = r, g = g, b = b, moisture = m, fieldId = fid,
                    }
                end
            end
        end
    end
    if stats.fields > 0 then stats.avg = sum / stats.fields end
    self.stats = stats
end

-- ── Map bounds and projection ─────────────────────────────

function CsMoistureMapOverlay:getMapRenderBounds(frame, ingameMap)
    local layout = nil
    if frame ~= nil and frame.ingameMapBase ~= nil and frame.ingameMapBase.fullScreenLayout ~= nil then
        layout = frame.ingameMapBase.fullScreenLayout
    elseif ingameMap ~= nil and ingameMap.fullScreenLayout ~= nil then
        layout = ingameMap.fullScreenLayout
    end
    if layout == nil or layout.getMapSize == nil or layout.getMapPosition == nil then
        return nil, nil, nil, nil
    end
    local mapX, mapY = layout:getMapPosition()
    local mapW, mapH = layout:getMapSize()
    return mapX, mapY, mapW, mapH
end

function CsMoistureMapOverlay:worldToScreenPosition(ingameMap, worldX, worldZ)
    if ingameMap == nil then return nil, nil end
    local layout = ingameMap.fullScreenLayout or ingameMap.layout
    if layout == nil or layout.getMapObjectPosition == nil then return nil, nil end

    local worldSizeX = ingameMap.worldSizeX or (g_currentMission and g_currentMission.terrainSize) or 2048
    local worldSizeZ = ingameMap.worldSizeZ or (g_currentMission and g_currentMission.terrainSize) or 2048
    if worldSizeX == 0 or worldSizeZ == 0 then return nil, nil end

    local objectX = (worldX + (ingameMap.worldCenterOffsetX or 0)) / worldSizeX
    local objectZ = (worldZ + (ingameMap.worldCenterOffsetZ or 0)) / worldSizeZ
    objectX = objectX * (ingameMap.mapExtensionScaleFactor or 1) + (ingameMap.mapExtensionOffsetX or 0)
    objectZ = objectZ * (ingameMap.mapExtensionScaleFactor or 1) + (ingameMap.mapExtensionOffsetZ or 0)
    return layout:getMapObjectPosition(objectX, objectZ, 0, 0)
end

-- ── Draw the sheet ────────────────────────────────────────

function CsMoistureMapOverlay:onDraw(frame, mapElement, ingameMap, pageIndex)
    local mapX, mapY, mapWidth, mapHeight = self:getMapRenderBounds(frame, ingameMap)
    if mapX == nil then return end

    -- REFINED primary path: engine density-map visualization overlay. When it is
    -- driving this page, never fall through to the sampled tiles (the "old grid
    -- flashes before the map appears" artifact).
    if self:_pdaDrawDMV(ingameMap, mapX, mapY, mapWidth, mapHeight) then
        return
    end
    if self._pdaUsingDMV then
        return
    end

    -- Legacy fallback: the sampled tile grid. Only reachable when the engine has no
    -- DMV support or the value-map backing is absent.
    self:updateSamplePoints(false)
    if #self.samplePoints == 0 then return end
    local mapMaxX = mapX + mapWidth
    local mapMaxY = mapY + mapHeight

    -- One affine basis for the whole sheet: three projected probes give the screen vectors
    -- for a world step, so each tile is two multiplies rather than a projection call.
    local step   = self.sampleStep or CsMoistureMapOverlay.POLYGON_STEP
    local ax, ay = self:worldToScreenPosition(ingameMap, 0, 0)
    local bx, by = self:worldToScreenPosition(ingameMap, step, 0)
    local cx, cy = self:worldToScreenPosition(ingameMap, 0, step)

    local sizeX, sizeY
    if ax and bx and cx then
        sizeX = math.max(math.abs(bx - ax) * CsMoistureMapOverlay.TILE_OVERSIZE, 0.0015)
        sizeY = math.max(math.abs(cy - ay) * CsMoistureMapOverlay.TILE_OVERSIZE, 0.0015)
    else
        sizeX, sizeY = getNormalizedScreenValues(6, 6)
    end
    local halfX, halfY = sizeX * 0.5, sizeY * 0.5

    local scaleXX = ax and ((bx - ax) / step) or 0
    local scaleYX = ax and ((by - ay) / step) or 0
    local scaleXZ = ax and ((cx - ax) / step) or 0
    local scaleYZ = ax and ((cy - ay) / step) or 0

    local alpha = CsMoistureMapOverlay.ALPHA
    for _, pt in ipairs(self.samplePoints) do
        local screenX, screenY
        if ax then
            screenX = ax + pt.x * scaleXX + pt.z * scaleXZ
            screenY = ay + pt.x * scaleYX + pt.z * scaleYZ
        else
            screenX, screenY = self:worldToScreenPosition(ingameMap, pt.x, pt.z)
        end
        if screenX and screenX >= mapX and screenX <= mapMaxX
           and screenY and screenY >= mapY and screenY <= mapMaxY then
            drawFilledRect(screenX - halfX, screenY - halfY, sizeX, sizeY,
                           pt.r, pt.g, pt.b, alpha)
        end
    end
end

-- ── Sidebar: legend strip and density ─────────────────────

function CsMoistureMapOverlay:onDrawHud(frame)
    self.buttonRects = {}

    local panelX, panelWidth
    if frame.filterList and frame.filterList.absPosition then
        panelX     = frame.filterList.absPosition[1]
        panelWidth = frame.filterList.absSize[1]
    else
        local safeX, _ = getNormalizedScreenValues(14, 0)
        local minW, _  = getNormalizedScreenValues(210, 0)
        panelX     = safeX
        panelWidth = minW
    end

    local topY = 0.80
    if frame.mapOverviewSelector and frame.mapOverviewSelector.absPosition then
        local _, extraM = getNormalizedScreenValues(0, 52)
        topY = frame.mapOverviewSelector.absPosition[2] - extraM
    end

    local _, rowH    = getNormalizedScreenValues(0, 26)
    local _, statusH = getNormalizedScreenValues(0, 38)
    local _, cardH   = getNormalizedScreenValues(0, 74)
    local _, btnH    = getNormalizedScreenValues(0, 30)
    local _, barH    = getNormalizedScreenValues(0, 24)
    local _, gap     = getNormalizedScreenValues(0, 4)
    -- Breathing room between the panel blocks (legend, average card, info box) so the
    -- stack reads as separate cards rather than one packed column.
    local _, cardGap = getNormalizedScreenValues(0, 18)
    local _, txtSz   = getNormalizedScreenValues(0, 14)
    local _, tickSz  = getNormalizedScreenValues(0, 11)
    local _, bigSz   = getNormalizedScreenValues(0, 22)
    local _, titleSz = getNormalizedScreenValues(0, 15)
    local padX, _    = getNormalizedScreenValues(10, 0)
    local acW, _     = getNormalizedScreenValues(3, 0)
    local bW, _      = getNormalizedScreenValues(1, 0)
    local _, bH      = getNormalizedScreenValues(0, 1)

    local CH = CsMoistureMapOverlay.C_CHARCOAL
    local BD = CsMoistureMapOverlay.C_BORDER

    --- Charcoal plate with a ramp-coloured accent rail and a thin border. This is the one
    --- place the panel's chrome is described, so every block below looks like the same
    --- family rather than each growing its own colours.
    local function plate(y, h, accent)
        drawFilledRect(panelX, y, panelWidth, h, CH[1], CH[2], CH[3], 0.92)
        drawFilledRect(panelX, y, panelWidth, bH, BD[1], BD[2], BD[3], 0.55)
        drawFilledRect(panelX, y + h - bH, panelWidth, bH, BD[1], BD[2], BD[3], 0.55)
        drawFilledRect(panelX, y, bW, h, BD[1], BD[2], BD[3], 0.55)
        drawFilledRect(panelX + panelWidth - bW, y, bW, h, BD[1], BD[2], BD[3], 0.55)
        if accent ~= nil then
            drawFilledRect(panelX, y, acW, h, accent[1], accent[2], accent[3], 1.0)
        end
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(true)
    local wet = CsMoistureMapOverlay.C_WET
    setTextColor(wet[1], wet[2], wet[3], 1.0)
    renderText(panelX + padX, topY - rowH, titleSz,
               tr("cs_map_sidebar_title", "CROP MOISTURE"):upper())
    setTextBold(false)

    local y = topY - rowH * 2 - gap
    local stats = self.stats or {dry = 0, good = 0, wet = 0, avg = nil, fields = 0}

    -- ── Status rows: how many fields sit in each band ──────
    local rows = {
        {key = "cs_map_status_dry",  fb = "Dry fields",  n = stats.dry,  anchor = 0.20},
        {key = "cs_map_status_good", fb = "Good fields", n = stats.good, anchor = 0.55},
        {key = "cs_map_status_wet",  fb = "Wet fields",  n = stats.wet,  anchor = 0.85},
    }
    for _, row in ipairs(rows) do
        local r, g, b = CsMoistureMapOverlay.rampColor(row.anchor)
        plate(y, statusH, {r, g, b})
        setTextColor(0.88, 0.88, 0.88, 1.0)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(panelX + padX + acW, y + statusH * 0.32, txtSz, tr(row.key, row.fb))
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextBold(true)
        setTextColor(r, g, b, 1.0)
        renderText(panelX + panelWidth - padX, y + statusH * 0.30, txtSz, tostring(row.n or 0))
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
        y = y - statusH - gap
    end

    y = y - gap
    drawFilledRect(panelX, y, panelWidth, bH, BD[1], BD[2], BD[3], 0.45)
    y = y - bH - gap * 2

    -- ── Actions: Detail cycle above Open Crop PDA ──────────
    local names = {
        tr("cs_map_density_low", "Low"),
        tr("cs_map_density_med", "Medium"),
        tr("cs_map_density_high", "High"),
    }
    local level = self.density or CsMoistureMapOverlay.DENSITY_DEFAULT
    plate(y, btnH, wet)
    setTextColor(0.86, 0.90, 0.94, 1.0)
    renderText(panelX + padX + acW, y + btnH * 0.28, txtSz,
               string.format("%s: %s", tr("cs_map_density", "Detail"),
                             names[level] or names[2]))
    table.insert(self.buttonRects, {
        x1 = panelX, y1 = y, x2 = panelX + panelWidth, y2 = y + btnH,
        action = "cycleDensity",
    })
    y = y - btnH - gap

    plate(y, btnH, wet)
    setTextColor(0.86, 0.90, 0.94, 1.0)
    renderText(panelX + padX + acW, y + btnH * 0.28, txtSz,
               tr("cs_map_btn_open_pda", "Open Crop PDA"))
    table.insert(self.buttonRects, {
        x1 = panelX, y1 = y, x2 = panelX + panelWidth, y2 = y + btnH,
        action = "openPDA",
    })
    y = y - btnH - cardGap

    -- ── Legend slot, at the BOTTOM of the stack ───────────
    -- Swept from rampColor, the same function the tiles use, so the bar cannot describe a
    -- scheme the sheet is not drawing.
    local barX = panelX + padX
    local barW = panelWidth - padX * 2
    local slices = 48
    local sliceW = barW / slices
    for i = 0, slices - 1 do
        local v = (i + 0.5) / slices
        local r, g, b = CsMoistureMapOverlay.rampColor(v)
        drawFilledRect(barX + i * sliceW, y, sliceW + 0.0004, barH, r, g, b, 0.95)
    end
    for _, hair in ipairs({CsMoistureMapOverlay.HAIR_DRY_GOOD, CsMoistureMapOverlay.HAIR_GOOD_WET}) do
        drawFilledRect(barX + barW * hair, y, bW, barH, 0.08, 0.08, 0.08, 0.85)
    end
    y = y - barH - gap

    setTextColor(0.90, 0.90, 0.90, 1.0)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(barX, y, txtSz, tr("cs_map_legend_dry", "Dry"))
    setTextAlignment(RenderText.ALIGN_CENTER)
    renderText(barX + barW * 0.55, y, txtSz, tr("cs_map_legend_good", "Good"))
    setTextAlignment(RenderText.ALIGN_RIGHT)
    renderText(barX + barW, y, txtSz, tr("cs_map_legend_wet", "Wet"))
    setTextAlignment(RenderText.ALIGN_LEFT)
    y = y - rowH * 0.72

    setTextColor(0.62, 0.62, 0.62, 1.0)
    setTextAlignment(RenderText.ALIGN_CENTER)
    renderText(barX + barW * CsMoistureMapOverlay.HAIR_DRY_GOOD, y, tickSz,
               string.format("%d%%", math.floor(CsMoistureMapOverlay.HAIR_DRY_GOOD * 100 + 0.5)))
    renderText(barX + barW * CsMoistureMapOverlay.HAIR_GOOD_WET, y, tickSz,
               string.format("%d%%", math.floor(CsMoistureMapOverlay.HAIR_GOOD_WET * 100 + 0.5)))
    setTextAlignment(RenderText.ALIGN_LEFT)
    y = y - rowH * 0.80 - cardGap

    -- ── Average field moisture card ───────────────────────
    local avg = stats.avg
    local avgR, avgG, avgB = CsMoistureMapOverlay.rampColor(avg)
    plate(y, cardH, {avgR, avgG, avgB})
    setTextColor(0.72, 0.74, 0.78, 1.0)
    renderText(panelX + padX + acW, y + cardH - rowH * 0.85, tickSz,
               tr("cs_map_avg_title", "Average Field Moisture"))
    setTextBold(true)
    setTextColor(avgR, avgG, avgB, 1.0)
    renderText(panelX + padX + acW, y + cardH * 0.34, bigSz,
               avg ~= nil and string.format("%d%%", math.floor(avg * 100 + 0.5)) or "--")
    setTextBold(false)
    local verdictKey, verdictFb = "cs_map_avg_ok", "OK"
    local band = CsMoistureMapOverlay.classifyMoisture(avg)
    if band == "dry" then
        verdictKey, verdictFb = "cs_map_avg_irrigate", "Irrigate"
    elseif band == "wet" then
        verdictKey, verdictFb = "cs_map_avg_toowet", "Too wet"
    end
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(0.86, 0.88, 0.90, 1.0)
    renderText(panelX + panelWidth - padX, y + cardH * 0.36, txtSz,
               avg ~= nil and tr(verdictKey, verdictFb) or "")
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Marker on the same ramp, so the card and the legend agree by construction.
    local mkX = panelX + padX + acW
    local mkW = panelWidth - padX * 2 - acW
    local _, mkH = getNormalizedScreenValues(0, 5)
    for i = 0, 23 do
        local v = (i + 0.5) / 24
        local r, g, b = CsMoistureMapOverlay.rampColor(v)
        drawFilledRect(mkX + i * (mkW / 24), y + gap, mkW / 24 + 0.0004, mkH, r, g, b, 0.9)
    end
    if avg ~= nil then
        drawFilledRect(mkX + mkW * math.min(math.max(avg, 0), 1) - bW, y + gap, bW * 2, mkH,
                       0.98, 0.98, 0.98, 1.0)
    end
    y = y - cardH - cardGap

    -- ── Info box ──────────────────────────────────────────
    local _, infoH = getNormalizedScreenValues(0, 56)
    drawFilledRect(panelX, y, panelWidth, infoH, 0, 0, 0, 0.35)
    drawFilledRect(panelX, y, panelWidth, bH, BD[1], BD[2], BD[3], 0.55)
    drawFilledRect(panelX, y + infoH - bH, panelWidth, bH, BD[1], BD[2], BD[3], 0.55)
    drawFilledRect(panelX, y, bW, infoH, BD[1], BD[2], BD[3], 0.55)
    drawFilledRect(panelX + panelWidth - bW, y, bW, infoH, BD[1], BD[2], BD[3], 0.55)
    setTextBold(true)
    setTextColor(0.82, 0.86, 0.90, 1.0)
    renderText(panelX + padX, y + infoH - rowH * 0.85, txtSz,
               tr("cs_map_info_title", "Crop Moisture"))
    setTextBold(false)
    setTextColor(0.68, 0.70, 0.72, 1.0)
    renderText(panelX + padX, y + infoH * 0.22, tickSz,
               tr("cs_map_info_line", "Spot readings, not field averages. Detail sets the sample step."))
end

function CsMoistureMapOverlay:onSideBarClick(posX, posY)
    for _, rect in ipairs(self.buttonRects) do
        if posX >= rect.x1 and posX <= rect.x2
           and posY >= rect.y1 and posY <= rect.y2 then
            if rect.action == "openPDA" then
                if CsPDAScreen ~= nil then
                    CsPDAScreen.toggle()
                end
            elseif rect.action == "cycleDensity" then
                local level = (self.density or CsMoistureMapOverlay.DENSITY_DEFAULT) + 1
                if level > #CsMoistureMapOverlay.DENSITY_POINTS then level = 1 end
                self.density = level
                -- The STEP moves with the level, not just the budget, which is what makes
                -- High visibly finer at a field edge. The polygon cache is keyed by step,
                -- so it is dropped rather than left to grow a second full set of points.
                self.sampleStep = CsMoistureMapOverlay.DENSITY_STEPS[level]
                    or CsMoistureMapOverlay.POLYGON_STEP
                self.fieldPolyCache = {}
                self:requestRefresh()
            end
            return true
        end
    end
    return false
end
