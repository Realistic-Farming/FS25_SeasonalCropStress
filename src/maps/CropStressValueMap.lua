-- ============================================================
-- CropStressValueMap.lua  (SCS-039 / GRID-1)
--
-- THE VENDORED MOISTURE VALUE MAP: one 8-bit layer at engine grain
-- (2 m/px on 2048-4096 m maps, 4 m at 16x), so soil moisture is measured
-- by the same ruler as the rest of the ground instead of the 10-40 m Lua
-- cell store.
--
-- HOSTING IS VENDORED BY RULING (TysonK): SeasonalCropStress carries its
-- own value-map machinery rather than registering a layer inside
-- SoilFertilizer. SF has no layer-registration door (its LAYER_DEFS is a
-- static table), and cross-mod writes would breach the firewall. SCS is
-- the SOLE writer of this map; SF's own layers are never touched.
--
-- ENGINE-ABSENT IS TODAY, EXACTLY. When the bit-vector API or the terrain
-- node is missing, `available` stays false, every method is inert, and the
-- shipped sparse-cell store in SoilMoistureSystem carries on bit for bit.
--
-- THE QUANTISATION FLOOR, and it is the reason this file exists in this
-- shape: moisture spans 0..1 across 254 raw steps, so ONE RAW STEP IS
-- ~0.0039 MOISTURE. An hourly rain or evaporation delta is routinely
-- smaller than that, and a naive per-hour write floors to zero every time:
-- twenty four of them move the map by NOTHING. Callers MUST accumulate
-- sub-step deltas through quantiseDelta() and apply only whole raw steps.
-- That is a correctness law, not an optimisation.
-- ============================================================

CropStressValueMap = {}
local CropStressValueMap_mt = Class(CropStressValueMap)

-- The single layer. Moisture is a 0..1 fraction, so unitsPerRaw is 1/254.
CropStressValueMap.LAYER_DEF = {
    key    = "moisture",
    file   = "csMoistureMap.grle",
    minVal = 0.0,
    maxVal = 1.0,
}

local NUM_CHANNELS = 8      -- bits per pixel
local RAW_MIN      = 1      -- raw 0 is reserved as "no data" / off-field
local RAW_MAX      = 255
local RAW_SPAN     = RAW_MAX - RAW_MIN   -- 254 usable steps

CropStressValueMap.RAW_MIN  = RAW_MIN
CropStressValueMap.RAW_MAX  = RAW_MAX
CropStressValueMap.RAW_SPAN = RAW_SPAN

-- Map resolution: half the terrain size, so 2 m/px on a 2048-4096 m map and
-- 4 m/px once a 16x map is capped. This is the SAME formula SoilFertilizer's
-- engine uses, which is the whole point of the concordance: one ruler.
local MIN_RESOLUTION = 1024
local MAX_RESOLUTION = 4096

local function csvmLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ─────────────────────────────────────────────────────────
-- Encode / decode. Pure, and exposed as test seams.
-- ─────────────────────────────────────────────────────────

local function encode(value, def)
    local clamped  = math.max(def.minVal, math.min(def.maxVal, value or def.minVal))
    local fraction = (clamped - def.minVal) / (def.maxVal - def.minVal)
    return RAW_MIN + math.floor(fraction * RAW_SPAN + 0.5)
end

local function decode(raw, def)
    if raw == nil or raw <= 0 then return nil end   -- raw 0 is "no data"
    local fraction = (raw - RAW_MIN) / RAW_SPAN
    return def.minVal + fraction * (def.maxVal - def.minVal)
end

local function unitsPerRaw(def)
    return (def.maxVal - def.minVal) / RAW_SPAN
end

CropStressValueMap._encode      = encode
CropStressValueMap._decode      = decode
CropStressValueMap._unitsPerRaw = unitsPerRaw

--- THE QUANTISATION LAW (SCS-039, the moisture brief's first answered blocker).
--- Split an accumulated semantic delta into the part that can actually move the
--- map (a whole number of raw steps) and the sub-step remainder that must be
--- carried forward.
---
--- Callers keep the returned remainder and hand it back next tick. Without this
--- every hourly write smaller than one raw step is silently discarded by the
--- floor, and a whole day of light rain lands as nothing at all.
---
--- Truncates toward zero in BOTH directions on purpose: a positive remainder
--- must not become a negative applied step, and vice versa, or a field would
--- oscillate around a value it never reaches.
---@param pending number  accumulated semantic delta, including this tick's
---@return number applied    semantic amount that maps to whole raw steps (may be 0)
---@return number remainder  sub-step amount to carry into the next tick
function CropStressValueMap.quantiseDelta(pending)
    pending = pending or 0
    local upr = unitsPerRaw(CropStressValueMap.LAYER_DEF)
    local rawSteps
    if pending >= 0 then
        rawSteps = math.floor(pending / upr)
    else
        rawSteps = -math.floor(-pending / upr)
    end
    if rawSteps == 0 then return 0, pending end
    local applied = rawSteps * upr
    return applied, pending - applied
end

-- ─────────────────────────────────────────────────────────
-- Construction and engine detection
-- ─────────────────────────────────────────────────────────

function CropStressValueMap.new()
    local self = setmetatable({}, CropStressValueMap_mt)
    self.initialized  = false
    self.available    = false
    self.bvm          = nil
    self.modifier     = nil
    self.filter       = nil
    self.resolution   = 0
    self.terrainSize  = 0
    self.loadedFromSave = false
    self.hasExecuteAdd  = true
    self.hasPolygonOps  = true
    return self
end

--- True when every engine entry point this map needs actually exists.
--- Checked as capability rather than as a mod-presence test, so the map works
--- on any install where the engine offers the API.
local function engineCapable()
    return createBitVectorMap ~= nil
       and loadBitVectorMapNew ~= nil
       and DensityMapModifier ~= nil
       and DensityMapModifier.new ~= nil
       and g_terrainNode ~= nil
       and g_terrainNode ~= 0
end

function CropStressValueMap:initialize(savegameDir)
    if self.initialized then return self.available end
    self.initialized = true

    if not engineCapable() then
        csvmLog("Moisture map: bit-vector API or terrain node unavailable; using the cell-store fallback")
        return false
    end

    self.terrainSize = getTerrainSize(g_terrainNode) or 0
    if self.terrainSize <= 0 then
        csvmLog("Moisture map: getTerrainSize returned 0; using the cell-store fallback")
        return false
    end

    self.resolution = math.max(MIN_RESOLUTION,
                      math.min(MAX_RESOLUTION, math.floor(self.terrainSize / 2)))

    local ok, err = pcall(function()
        self.bvm = createBitVectorMap("CSMoistureMap")
        if self.bvm == nil or self.bvm == 0 then
            error("createBitVectorMap returned nothing")
        end

        local loaded = false
        if savegameDir ~= nil and fileExists ~= nil then
            local path = savegameDir .. "/" .. CropStressValueMap.LAYER_DEF.file
            if fileExists(path) and loadBitVectorMapFromFile ~= nil then
                loaded = loadBitVectorMapFromFile(self.bvm, path, NUM_CHANNELS) and true or false
                if loaded and getBitVectorMapSize ~= nil then
                    -- Adopt the persisted resolution: it may differ from the one
                    -- computed above if the cap changed between versions, and the
                    -- file is the authority for data already on disk.
                    local w = getBitVectorMapSize(self.bvm)
                    if w ~= nil and w > 0 then self.resolution = w end
                end
            end
        end
        if not loaded then
            loadBitVectorMapNew(self.bvm, self.resolution, self.resolution, NUM_CHANNELS, false)
        end
        self.loadedFromSave = loaded

        self.modifier = DensityMapModifier.new(self.bvm, 0, NUM_CHANNELS, g_terrainNode)
        if DensityMapFilter ~= nil and DensityMapFilter.new ~= nil then
            self.filter = DensityMapFilter.new(self.bvm, 0, NUM_CHANNELS)
        end
    end)

    if not ok then
        csvmLog(string.format("Moisture map: init failed (%s); using the cell-store fallback", tostring(err)))
        if self.bvm ~= nil and self.bvm ~= 0 and delete ~= nil then
            pcall(delete, self.bvm)
        end
        self.bvm = nil
        self.modifier = nil
        self.filter = nil
        return false
    end

    self.available = true
    csvmLog(string.format(
        "Moisture map: %dx%d at %.1f m/px%s",
        self.resolution, self.resolution, self:getGrainMetres(),
        self.loadedFromSave and " [restored from savegame]" or " [fresh]"))
    return true
end

--- THE CONCORDANCE'S TEETH: the grain, in metres, that any value read off this
--- map was measured at. Every cross-grid read reports it alongside the value so
--- a consumer can never silently mistake a 2 m reading for a 40 m one, or the
--- reverse. Returns nil when the map is not carrying the data.
function CropStressValueMap:getGrainMetres()
    if not self.available or self.resolution <= 0 then return nil end
    return self.terrainSize / self.resolution
end

function CropStressValueMap:delete()
    if self.bvm ~= nil and self.bvm ~= 0 and delete ~= nil then
        pcall(delete, self.bvm)
    end
    self.bvm = nil
    self.modifier = nil
    self.filter = nil
    self.available = false
end

function CropStressValueMap:saveToSavegame(savegameDir)
    if not self.available or savegameDir == nil then return false end
    if saveBitVectorMapToFile == nil then return false end
    local path = savegameDir .. "/" .. CropStressValueMap.LAYER_DEF.file
    local ok = pcall(saveBitVectorMapToFile, self.bvm, path)
    if not ok then
        csvmLog("Moisture map: native save failed; the StateLedger scalar degrade carries this save")
    end
    return ok
end

-- ─────────────────────────────────────────────────────────
-- Point reads and writes
-- ─────────────────────────────────────────────────────────

--- Read moisture at a world position.
---@return number|nil value  0..1, or nil where nothing has been written
---@return number|nil grain  metres per pixel of the reading (the concordance)
function CropStressValueMap:readValueAtWorld(worldX, worldZ)
    if not self.available then return nil, nil end
    if getBitVectorMapPoint == nil then return nil, nil end
    local px, pz = self:worldToPixel(worldX, worldZ)
    if px == nil then return nil, nil end
    local ok, raw = pcall(getBitVectorMapPoint, self.bvm, px, pz, 0, NUM_CHANNELS)
    if not ok or raw == nil then return nil, nil end
    return decode(raw, CropStressValueMap.LAYER_DEF), self:getGrainMetres()
end

--- World position to map pixel. Terrain is centred on the origin, so the
--- half-size offset is what puts negative world coordinates in range.
function CropStressValueMap:worldToPixel(worldX, worldZ)
    if not self.available or self.terrainSize <= 0 then return nil, nil end
    local half = self.terrainSize * 0.5
    local px = math.floor((worldX + half) / self.terrainSize * self.resolution)
    local pz = math.floor((worldZ + half) / self.terrainSize * self.resolution)
    if px < 0 or pz < 0 or px >= self.resolution or pz >= self.resolution then
        return nil, nil
    end
    return px, pz
end

--- Write a value over a square region centred on a world position.
--- `radius` is in metres; it floors to one pixel so a point write is never a
--- no-op on a coarse map.
function CropStressValueMap:writeValueAtWorld(worldX, worldZ, value, radius)
    if not self.available then return false end
    local grain = self:getGrainMetres() or 2
    local r = math.max(radius or 0, grain * 0.5)
    local raw = encode(value, CropStressValueMap.LAYER_DEF)
    return self:_setRegion(worldX - r, worldZ - r, worldX + r, worldZ + r, raw)
end

function CropStressValueMap:_setRegion(x0, z0, x1, z1, raw)
    local m = self.modifier
    if m == nil then return false end
    local ok = pcall(function()
        m:setParallelogramWorldCoords(x0, z0, x1, z0, x0, z1, DensityCoordType.POINT_POINT_POINT)
        m:executeSet(raw)
    end)
    return ok
end

-- ─────────────────────────────────────────────────────────
-- Polygon operations (the region ops the drainage and rain paths use)
-- ─────────────────────────────────────────────────────────

--- Bind the modifier to a field polygon. Returns false when engine polygon ops
--- are unavailable or the polygon is malformed, so callers can fall back.
function CropStressValueMap:_setPolygonRegion(vx, vz, n)
    local m = self.modifier
    if m == nil or not self.hasPolygonOps then return false end
    if vx == nil or n == nil or n < 3 then return false end
    if m.clearPolygonPoints == nil or m.addPolygonPointWorldCoords == nil then
        self.hasPolygonOps = false
        return false
    end
    local ok = pcall(function()
        m:clearPolygonPoints()
        for i = 1, n do
            m:addPolygonPointWorldCoords(vx[i], vz[i])
        end
    end)
    if not ok then
        self.hasPolygonOps = false
        return false
    end
    return true
end

--- Paint a whole field polygon to one value. Used by the one-time migration
--- and by the flat-field seed.
function CropStressValueMap:paintPolygon(vx, vz, n, value)
    if not self.available then return false end
    if not self:_setPolygonRegion(vx, vz, n) then return false end
    local raw = encode(value, CropStressValueMap.LAYER_DEF)
    return pcall(function() self.modifier:executeSet(raw) end)
end

--- Shift every written pixel of a field polygon by a WHOLE number of raw steps.
--- The caller is responsible for having quantised the delta through
--- quantiseDelta() first; a sub-step delta arriving here would floor to nothing.
---@return number applied  semantic amount actually applied (0 when nothing moved)
function CropStressValueMap:applyDeltaToPolygon(vx, vz, n, delta)
    if not self.available or delta == nil or delta == 0 then return 0 end
    local def = CropStressValueMap.LAYER_DEF
    local upr = unitsPerRaw(def)
    local rawDelta = (delta >= 0) and math.floor(delta / upr + 0.5)
                                   or -math.floor(-delta / upr + 0.5)
    if rawDelta == 0 then return 0 end
    if not self.hasExecuteAdd then return 0 end
    if not self:_setPolygonRegion(vx, vz, n) then return 0 end

    local m = self.modifier
    local f = self.filter
    local ok = pcall(function()
        if f ~= nil then
            -- Only touch written pixels, and never push one past the raw range
            -- (which would wrap into the raw-0 no-data sentinel and read as a
            -- hole in the field rather than as wet or dry ground).
            if rawDelta > 0 then
                f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN, RAW_MAX - rawDelta)
            else
                f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN - rawDelta, RAW_MAX)
            end
            m:executeAdd(rawDelta, f)
        else
            m:executeAdd(rawDelta)
        end
    end)
    if not ok then
        csvmLog("Moisture map: executeAdd unavailable; disabling the add path")
        self.hasExecuteAdd = false
        return 0
    end
    return rawDelta * upr
end

--- The derived field aggregate: the mean of the written pixels inside a field
--- polygon. This is what the field scalar becomes once the map is carrying the
--- truth (the compaction precedent), rather than a separately maintained number
--- that can drift from the ground it describes.
---@return number|nil mean   0..1, nil when nothing is written in the polygon
---@return number|nil grain  metres per pixel (the concordance)
function CropStressValueMap:readAverageOfPolygon(vx, vz, n)
    if not self.available then return nil, nil end
    if getDensityMapModifierStats == nil then return nil, nil end
    if not self:_setPolygonRegion(vx, vz, n) then return nil, nil end
    local ok, total, area = pcall(function()
        return self.modifier:executeGet()
    end)
    if not ok or area == nil or area == 0 then return nil, nil end
    local meanRaw = total / area
    return decode(meanRaw, CropStressValueMap.LAYER_DEF), self:getGrainMetres()
end

function CropStressValueMap:getDebugStats()
    return {
        available   = self.available,
        resolution  = self.resolution,
        terrainSize = self.terrainSize,
        grainMetres = self:getGrainMetres(),
        fromSave    = self.loadedFromSave,
        executeAdd  = self.hasExecuteAdd,
        polygonOps  = self.hasPolygonOps,
        unitsPerRaw = unitsPerRaw(CropStressValueMap.LAYER_DEF),
    }
end
