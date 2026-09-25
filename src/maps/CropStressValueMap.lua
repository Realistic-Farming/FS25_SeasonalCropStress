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

CropStressValueMap = CropStressValueMap or {}
local CropStressValueMap_mt = Class(CropStressValueMap)

-- The single layer. Moisture is a 0..1 fraction, so unitsPerRaw is 1/254.
CropStressValueMap.LAYER_DEF = {
    key    = "moisture",
    file   = "csMoistureMap.grle",
    minVal = 0.0,
    maxVal = 1.0,
}

--- RSF-F244: THE NATIVE IMAGE LIVES IN ONE OF THREE ROTATING SLOT FILES.
--- PR188 named each generation's image csMoistureMap.g<N>.grle, so every save
--- left the previous image behind for good. A mod cannot clean those up: the mod
--- environment wraps deleteFile so it only reaches modSettings/<modName>
--- (decompiled mods.lua:708-733), and the savegame folder is outside it. So the
--- files are reused instead: the selected current, the selected previous and one
--- candidate. The generation stays in the envelope and is no longer in the name.
CropStressValueMap.SLOT_FILES = {
    "csMoistureMap.s1.grle",
    "csMoistureMap.s2.grle",
    "csMoistureMap.s3.grle",
}

function CropStressValueMap.isSlotFileName(name)
    for _, slot in ipairs(CropStressValueMap.SLOT_FILES) do
        if name == slot then return true end
    end
    return false
end

--- RSF-F244: the whole-string door check every native open passes. Accepts
--- exactly the legacy name, a PR188-era generation name with a positive N and no
--- leading zero (so g0 and g01 are refused), or one of the three slot names.
--- Anchored at both ends, so any separator, "..", prefix or suffix is refused.
--- This is a door check, not an identity check: the compact digest does not cover
--- the file name, so one legal name can still stand in for another (a named limit).
function CropStressValueMap.isAcceptedNativeName(name)
    if type(name) ~= "string" then return false end
    if name == CropStressValueMap.LAYER_DEF.file then return true end
    if CropStressValueMap.isSlotFileName(name) then return true end
    return name:match("^csMoistureMap%.g[1-9]%d*%.grle$") ~= nil
end

--- RSF-F244: the slot a save cut writes: the lowest slot named by neither the
--- selected current nor the selected previous retained record. At most two are
--- excluded, so one is always free. A pure function of those two names, so a
--- retried failed cut picks the same slot, and the legacy name is never returned.
---@param currentName string|nil  file named by the selected current record's envelope
---@param previousName string|nil file named by the selected previous record's envelope
---@return string
function CropStressValueMap.chooseSlotFileName(currentName, previousName)
    for _, slot in ipairs(CropStressValueMap.SLOT_FILES) do
        if slot ~= currentName and slot ~= previousName then return slot end
    end
    return CropStressValueMap.SLOT_FILES[1]
end

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
    -- RSF-F244: the resolution computed from the terrain, and the width the
    -- modifier and filter were last built at.
    self.computedResolution = 0
    self.toolWidth    = 0
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

--- Stand a FRESH map up. RSF-F244: THE PROBE OPENS NO FILE. It used to import
--- csMoistureMap.grle here, at field-ready and before the restore barrier had
--- read any envelope, so a stale legacy picture could sit in memory as current
--- truth and survive on the barrier's no-candidate path. Native images are now
--- opened only inside the barrier, through loadNativeFile.
function CropStressValueMap:initialize()
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
    self.computedResolution = self.resolution

    local ok, err = pcall(function()
        self.bvm = createBitVectorMap("CSMoistureMap")
        if self.bvm == nil or self.bvm == 0 then
            error("createBitVectorMap returned nothing")
        end

        loadBitVectorMapNew(self.bvm, self.resolution, self.resolution, NUM_CHANNELS, false)
        self.loadedFromSave = false
        self:_buildTools()
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
        "Moisture map: %dx%d at %.1f m/px [fresh; the restore barrier opens any saved image]",
        self.resolution, self.resolution, self:getGrainMetres()))
    return true
end

--- Build the modifier and filter against the map's CURRENT width and record that
--- width. Whether an engine modifier stays valid after a load changes the map's
--- size cannot be determined from Lua, so no painting or reading may use tools
--- built at another width. The base game builds these freely and never deletes
--- them, so replacing them needs no teardown.
function CropStressValueMap:_buildTools()
    self.modifier = DensityMapModifier.new(self.bvm, 0, NUM_CHANNELS, g_terrainNode)
    self.filter = nil
    if DensityMapFilter ~= nil and DensityMapFilter.new ~= nil then
        self.filter = DensityMapFilter.new(self.bvm, 0, NUM_CHANNELS)
    end
    self.toolWidth = self.resolution
    -- A parcel-union work set built at another width is stale: drop it, and it
    -- rebuilds lazily at this width (the SCS-041 parcel union below).
    self:_deleteUnionMask()
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
    self:_deleteUnionMask()
    self.available = false
end

--- SCS-039 SDS 3.7/3.8, RSF-F244: THE ONE NATIVE LOADER, called only from inside
--- the restore barrier. Opens the file the caller names (an envelope's recorded
--- filename, or the legacy name) and proves its shape. The name must pass the
--- whole-string door check, the file must exist, the engine load must return
--- literal true, and the persisted width must match when a width is expected.
--- A successful load that moved the width rebuilds the modifier and filter.
---
--- The second return says whether an engine load was ATTEMPTED. A refusal before
--- any load (a rejected name, a missing file, a nil directory) leaves the map as
--- it was. After an attempted load that failed, the map's state is not
--- determinable from Lua; what to do about that belongs to the caller (the
--- generation path declines the map, the legacy path resets it), not to this
--- loader on every false return.
---@param savegameDir string|nil
---@param filename string|nil
---@param expectedWidth number|nil
---@return boolean loaded
---@return boolean attempted
function CropStressValueMap:loadNativeFile(savegameDir, filename, expectedWidth)
    if not self.available or savegameDir == nil then return false, false end
    if self.bvm == nil or self.bvm == 0 then return false, false end
    if not CropStressValueMap.isAcceptedNativeName(filename) then
        csvmLog(string.format("Moisture map: refused native image name %s", tostring(filename)))
        return false, false
    end
    if fileExists == nil or loadBitVectorMapFromFile == nil then return false, false end
    local path = savegameDir .. "/" .. filename
    if fileExists(path) ~= true then
        csvmLog(string.format("Moisture map: native image %s is absent", path))
        return false, false
    end
    local ok, loaded = pcall(loadBitVectorMapFromFile, self.bvm, path, NUM_CHANNELS)
    if not ok or loaded ~= true then
        csvmLog(string.format("Moisture map: native image %s refused to load", path))
        return false, true
    end
    local width = nil
    if getBitVectorMapSize ~= nil then
        local okSize, w = pcall(getBitVectorMapSize, self.bvm)
        if okSize then width = w end
    end
    if expectedWidth ~= nil and (width == nil or width ~= expectedWidth) then
        csvmLog(string.format("Moisture map: native image %s has width %s, envelope expects %s",
            path, tostring(width), tostring(expectedWidth)))
        return false, true
    end
    if width ~= nil and width > 0 then self.resolution = width end
    if self.resolution ~= self.toolWidth then
        local okTools = pcall(function() self:_buildTools() end)
        if not okTools then
            csvmLog(string.format("Moisture map: tools could not be rebuilt at the loaded width %d", self.resolution))
            return false, true
        end
        csvmLog(string.format("Moisture map: tools rebuilt at the loaded width %d", self.resolution))
    end
    self.loadedFromSave = true
    csvmLog(string.format("Moisture map: native image %s adopted (%dx%d)", path, self.resolution, self.resolution))
    return true, true
end

--- RSF-F244: import the pre-generation csMoistureMap.grle, once, from the restore
--- barrier's legacy branch only. No expected width: the file is the authority for
--- data already on disk. A refusal or absence before any engine load leaves the
--- fresh map initialize stood up. An ATTEMPTED load that failed leaves the map
--- and its tools not determinable, so the map is reset fresh at the computed
--- resolution and the tools are rebuilt unconditionally, even when the width did
--- not change.
---@param savegameDir string|nil
---@return boolean imported
function CropStressValueMap:importLegacyFile(savegameDir)
    local loaded, attempted = self:loadNativeFile(savegameDir, CropStressValueMap.LAYER_DEF.file, nil)
    if loaded then return true end
    if attempted then self:_resetFresh() end
    return false
end

--- Reset the map to a fresh one at the computed resolution and rebuild its tools.
--- If even that fails, the map is released, and the soil system declines it.
function CropStressValueMap:_resetFresh()
    local ok, err = pcall(function()
        self.resolution = self.computedResolution
        loadBitVectorMapNew(self.bvm, self.resolution, self.resolution, NUM_CHANNELS, false)
        self.loadedFromSave = false
        self:_buildTools()
    end)
    if not ok then
        csvmLog(string.format("Moisture map: reset after a failed legacy load failed (%s); map released", tostring(err)))
        self:delete()
        return false
    end
    csvmLog(string.format("Moisture map: legacy image failed after an engine load; map reset fresh at %dx%d and tools rebuilt",
        self.resolution, self.resolution))
    return true
end

---@param savegameDir string|nil
---@param filename string  the slot name the save cut chose
---@return boolean
function CropStressValueMap:saveToSavegame(savegameDir, filename)
    if not self.available or savegameDir == nil then return false end
    if saveBitVectorMapToFile == nil then return false end
    -- RSF-F244: ONE NAME, END TO END. The save cut chooses the slot string once;
    -- this writes exactly that string, and nothing here derives a path from the
    -- generation. Only a slot name is writable: the legacy file and PR188-era
    -- g<N> names are never written again.
    if not CropStressValueMap.isSlotFileName(filename) then
        csvmLog(string.format("Moisture map: refused to write non-slot name %s", tostring(filename)))
        return false
    end
    local path = savegameDir .. "/" .. filename
    -- SCS-039 v2.1: a native mutator succeeds only when BOTH the outer pcall
    -- survived AND the engine returned literal true. A non-throwing false return
    -- was previously misread as a saved file, a silent data-loss report.
    local ok, nativeResult = pcall(saveBitVectorMapToFile, self.bvm, path)
    local success = ok and nativeResult == true
    if not success then
        csvmLog("Moisture map: native save failed; the StateLedger scalar degrade carries this save")
    end
    return success
end

-- ─────────────────────────────────────────────────────────
-- Point reads and writes
-- ─────────────────────────────────────────────────────────

--- Read moisture at a world position.
--- SCS-039 v2.1 (SDS 3.2/3.3): the third return is a TYPED outcome, so a caller
--- can tell a genuine native provider refusal (which fails the provider closed
--- for the mission) apart from a benign unwritten or out-of-range position;
--- neither of the latter is a refusal. Returns: value, grain, outcome.
---   "PROVIDER_REFUSAL" - the native provider did not answer
---   "OUT_OF_RANGE"     - the position maps outside the pixel grid
---   "EMPTY"            - a resolvable pixel that has never been written
---   "OK"               - a written pixel's decoded value
---@return number|nil value  0..1, nil when not answered or nothing written
---@return number|nil grain  metres per pixel (nil for refusal and out-of-range)
---@return string outcome     one of the typed outcomes above
function CropStressValueMap:readValueAtWorld(worldX, worldZ)
    if not self.available then return nil, nil, "PROVIDER_REFUSAL" end
    if getBitVectorMapPoint == nil then return nil, nil, "PROVIDER_REFUSAL" end
    local px, pz = self:worldToPixel(worldX, worldZ)
    if px == nil then return nil, nil, "OUT_OF_RANGE" end
    local ok, raw = pcall(getBitVectorMapPoint, self.bvm, px, pz, 0, NUM_CHANNELS)
    -- A nil raw answer is the provider not answering, never a written pixel: an
    -- unwritten pixel reads back the raw-0 no-data sentinel (a number), so nil
    -- here is treated as a refusal exactly as readAverageOfPolygon treats a nil
    -- executeGet accumulator.
    if not ok or raw == nil then return nil, nil, "PROVIDER_REFUSAL" end
    if raw <= 0 then return nil, self:getGrainMetres(), "EMPTY" end
    return decode(raw, CropStressValueMap.LAYER_DEF), self:getGrainMetres(), "OK"
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

--- [SCS-041] World-space centre of a pixel, the inverse of worldToPixel at the
--- pixel's midpoint. A positional absorption consumer samples soil at the
--- provider-cell centre rather than the request point, so competing callers in
--- one cell share one sample. Returns nil when the map is not carrying data.
function CropStressValueMap:pixelCentreWorld(px, pz)
    if not self.available or self.terrainSize <= 0 or self.resolution <= 0 then return nil, nil end
    local half = self.terrainSize * 0.5
    local wx = (px + 0.5) / self.resolution * self.terrainSize - half
    local wz = (pz + 0.5) / self.resolution * self.terrainSize - half
    return wx, wz
end

--- Write a value over a square region centred on a world position.
--- `radius` is in metres; it floors to one pixel so a point write is never a
--- no-op on a coarse map.
--- SCS-039 v2.1 (SDS 3.3/3.4): the second return is a TYPED outcome, so a caller
--- can tell a genuine native region-write refusal (the execute threw) from a
--- benign no-op (map not carrying the data). Only a refusal fails the provider
--- closed; NOOP leaves the carrier untouched. Returns: wrote, outcome.
---   "PROVIDER_REFUSAL" - the native region write threw
---   "NOOP"             - nothing attempted (map absent, no modifier)
---   "OK"               - the region write executed
---@return boolean wrote   true only when the native execute ran
---@return string outcome  one of the typed outcomes above
function CropStressValueMap:writeValueAtWorld(worldX, worldZ, value, radius)
    if not self.available then return false, "NOOP" end
    local grain = self:getGrainMetres() or 2
    local r = math.max(radius or 0, grain * 0.5)
    local raw = encode(value, CropStressValueMap.LAYER_DEF)
    return self:_setRegion(worldX - r, worldZ - r, worldX + r, worldZ + r, raw)
end

---@return boolean wrote, string outcome (see writeValueAtWorld)
function CropStressValueMap:_setRegion(x0, z0, x1, z1, raw)
    local m = self.modifier
    if m == nil then return false, "NOOP" end
    local ok = pcall(function()
        m:setParallelogramWorldCoords(x0, z0, x1, z0, x0, z1, DensityCoordType.POINT_POINT_POINT)
        m:executeSet(raw)
    end)
    if not ok then return false, "PROVIDER_REFUSAL" end
    return true, "OK"
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
    -- SCS-039 v2.1 (SDS 3.2/3.3): TYPED outcomes, so a caller can tell a genuine
    -- native provider refusal (which fails the provider closed for the mission)
    -- apart from a malformed polygon or a valid-but-empty one; neither of the
    -- latter is a refusal. Returns: outcome, mean, grain.
    --   "INVALID_FIELD_GEOMETRY" - malformed polygon; the caller rebuilds context
    --   "PROVIDER_REFUSAL"       - the native provider did not answer
    --   "EMPTY"                  - a valid polygon with zero written pixels
    --   "OK"                     - the mean over the written pixels
    if vx == nil or vz == nil or n == nil or n < 3 then
        return "INVALID_FIELD_GEOMETRY", nil, nil
    end
    if not self.available then return "PROVIDER_REFUSAL", nil, nil end
    local m = self.modifier
    if m == nil or m.executeGet == nil then return "PROVIDER_REFUSAL", nil, nil end
    if not self:_setPolygonRegion(vx, vz, n) then
        -- Geometry is already validated, so a bind failure here is the provider
        -- (polygon ops unavailable, or a native throw), not bad geometry.
        return "PROVIDER_REFUSAL", nil, nil
    end
    -- executeGet returns (accumulator, numPixels, totalArea), confirmed at the
    -- decompile: PrecisionFarming NitrogenMap.lua:1034 reads it as
    -- `local acc, numPixels, _ = modifierFruit:executeGet()`. The mean we want
    -- is over WRITTEN pixels, so numPixels is the divisor, never totalArea.
    local ok, acc, numPixels = pcall(function()
        return m:executeGet()
    end)
    if not ok or acc == nil or numPixels == nil then
        return "PROVIDER_REFUSAL", nil, nil
    end
    if numPixels == 0 then
        return "EMPTY", nil, self:getGrainMetres()
    end
    return "OK", decode(acc / numPixels, CropStressValueMap.LAYER_DEF), self:getGrainMetres()
end

-- ─────────────────────────────────────────────────────────
-- RSF-F247 item 1: the written-pixel probe and the unwritten-only fill.
-- Both bind the SAME modifier and filter the delta path uses. The delta path
-- changes the filter's compare values (applyDeltaToPolygon), so each helper sets
-- its own compare values on every call.
-- ─────────────────────────────────────────────────────────

--- Is anything written inside this polygon? Never averages and never writes.
--- The count is the filtered pixel count (raw BETWEEN RAW_MIN..RAW_MAX), the
--- second value of executeGet(filter) (FieldManager.lua:100), so the answer does
--- not depend on what the unfiltered count means (F250 item 3).
---@return string outcome  "INVALID_FIELD_GEOMETRY" | "PROVIDER_REFUSAL" | "UNPROVEN" | "PRESENT" | "NONE"
function CropStressValueMap:hasWrittenPixels(vx, vz, n)
    if vx == nil or vz == nil or n == nil or n < 3 then
        return "INVALID_FIELD_GEOMETRY"
    end
    if not self.available then return "PROVIDER_REFUSAL" end
    local m = self.modifier
    if m == nil or m.executeGet == nil then return "PROVIDER_REFUSAL" end
    local f = self.filter
    if f == nil then
        -- No filter class on this engine: the probe cannot prove anything, which
        -- is a refusal of the decision, not of the provider.
        if DensityMapFilter == nil or DensityMapFilter.new == nil then return "UNPROVEN" end
        return "PROVIDER_REFUSAL"
    end
    if not self:_setPolygonRegion(vx, vz, n) then return "PROVIDER_REFUSAL" end
    local ok, _, count = pcall(function()
        f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN, RAW_MAX)
        return m:executeGet(f)
    end)
    if not ok or type(count) ~= "number" then return "PROVIDER_REFUSAL" end
    if count > 0 then return "PRESENT" end
    return "NONE"
end

--- Paint only the unwritten (raw 0) pixels inside this polygon. Movement is proved
--- only by the filtered raw-0 count falling across the set; executeSet has no
--- receipt (StoneSystem.lua:253 ignores its return). Because the filter admits
--- only raw 0, a written pixel can never change.
---@return string outcome  "EMPTY_OUTLINE" | "OK" | "NOOP" | "PROVIDER_REFUSAL"
---@return boolean setRan  true when executeSet was called (a NOOP with setRan is
---  a set that proved no movement; the caller logs it once per field)
function CropStressValueMap:fillUnwrittenPolygon(vx, vz, n, value)
    if not self.available then return "NOOP", false end
    local m, f = self.modifier, self.filter
    if m == nil or f == nil or m.executeGet == nil or m.executeSet == nil then
        return "NOOP", false
    end
    if not self:_setPolygonRegion(vx, vz, n) then return "PROVIDER_REFUSAL", false end
    local raw = encode(value, CropStressValueMap.LAYER_DEF)
    local okBefore, _, before = pcall(function()
        f:setValueCompareParams(DensityValueCompareType.EQUAL, 0)
        return m:executeGet(f)
    end)
    if not okBefore or type(before) ~= "number" then return "PROVIDER_REFUSAL", false end
    if before == 0 then return "EMPTY_OUTLINE", false end
    local okSet = pcall(function() m:executeSet(raw, f) end)
    if not okSet then return "PROVIDER_REFUSAL", true end
    local okAfter, _, after = pcall(function()
        f:setValueCompareParams(DensityValueCompareType.EQUAL, 0)
        return m:executeGet(f)
    end)
    if not okAfter or type(after) ~= "number" then return "PROVIDER_REFUSAL", true end
    if after < before then return "OK", true end
    return "NOOP", true
end

-- ─────────────────────────────────────────────────────────
-- SCS-041 PARCEL UNION (Iris's Design return of 2026-09-09, section 2).
--
-- A parcel is every cultivated polygon sharing one farmland id. The region ops
-- above take ONE polygon and let the engine rasterise it. For a parcel of several
-- polygons the invariant is: each physical provider cell of the SET UNION is
-- written once and sampled once, however the polygons touch or overlap, and the
-- gaps between them are never covered. Looping the one-polygon ops would apply
-- an additive delta twice on an overlap and average polygon averages.
--
-- THE NATIVE TECHNIQUE: a work set on a second bit-vector map of the same width
-- (one channel). Each polygon is set to 1 on it with the engine's own polygon
-- rasterisation, the same coverage convention as the one-polygon ops, so the
-- mask holds the union. The moisture modifier is then bound to the union's
-- bounding box and every execute takes a filter on the mask (EQUAL 1). A filter
-- may sit on another map than the modifier: PrecisionFarming's CoverMap.lua:184
-- builds a modifier on the cover map and :189 a mask filter on
-- g_farmlandManager.localMap, and :196-197 stack that mask filter with others in
-- one executeGet. So one executeSet, executeAdd or executeGet touches each union
-- cell exactly once. The references bind a modifier by polygon points or by a
-- parallelogram, never one modifier switching between the two, so the polygon
-- points are cleared before every box bind here: the box is the only region
-- either way (the same assumption writeValueAtWorld has always made after a
-- polygon op; the TESTING row carries its in-game falsifier).
-- The mask is cleared over the box afterwards, and cleared again over the next
-- box before that union is painted, so a failed clear can never lend a stale
-- cell to another parcel. The mask is machinery: never saved, never synced,
-- never a truth grid.
--
-- A parcel of ONE polygon takes the one-polygon op unchanged (same bytes, same
-- read); the mask exists only for a real union.
-- ─────────────────────────────────────────────────────────
local MASK_CHANNELS = 1

--- The bounding box of a collection, or nil when any polygon is malformed.
local function collectionBox(polys)
    if type(polys) ~= "table" or #polys == 0 then return nil end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for pi = 1, #polys do
        local p = polys[pi]
        if type(p) ~= "table" or type(p.vx) ~= "table" or type(p.vz) ~= "table"
           or type(p.n) ~= "number" or p.n < 3 then
            return nil
        end
        for i = 1, p.n do
            local x, z = p.vx[i], p.vz[i]
            if type(x) ~= "number" or type(z) ~= "number" or x ~= x or z ~= z
               or math.abs(x) == math.huge or math.abs(z) == math.huge then
                return nil
            end
            if x < minX then minX = x end
            if x > maxX then maxX = x end
            if z < minZ then minZ = z end
            if z > maxZ then maxZ = z end
        end
    end
    return minX, minZ, maxX, maxZ
end

function CropStressValueMap:_deleteUnionMask()
    if self.maskBvm ~= nil and self.maskBvm ~= 0 and delete ~= nil then
        pcall(delete, self.maskBvm)
    end
    self.maskBvm, self.maskModifier, self.maskFilter, self.maskWidth = nil, nil, nil, 0
    self._unionBox = nil
end

--- The work-set map at the moisture map's current width, built on first use. A
--- failure is latched per width: the engine is asked once and the refusal logged
--- once, not on every union call; a new width asks again.
function CropStressValueMap:_ensureUnionMask()
    if self.maskBvm ~= nil and self.maskWidth == self.resolution then return true end
    if self.maskFailedWidth == self.resolution then return false end
    if not self.available or self.resolution <= 0 then return false end
    if createBitVectorMap == nil or loadBitVectorMapNew == nil
       or DensityMapModifier == nil or DensityMapModifier.new == nil
       or DensityMapFilter == nil or DensityMapFilter.new == nil then
        return false
    end
    self:_deleteUnionMask()
    local ok, err = pcall(function()
        local bvm = createBitVectorMap("CSMoistureUnionMask")
        if bvm == nil or bvm == 0 then error("createBitVectorMap returned nothing") end
        self.maskBvm = bvm
        loadBitVectorMapNew(bvm, self.resolution, self.resolution, MASK_CHANNELS, false)
        self.maskModifier = DensityMapModifier.new(bvm, 0, MASK_CHANNELS, g_terrainNode)
        self.maskFilter = DensityMapFilter.new(bvm, 0, MASK_CHANNELS)
        if self.maskModifier == nil or self.maskFilter == nil then error("mask tools unavailable") end
        self.maskWidth = self.resolution
    end)
    if not ok then
        csvmLog(string.format("Moisture map: parcel-union work set unavailable (%s); a multi-field parcel refuses",
            tostring(err)))
        self:_deleteUnionMask()
        self.maskFailedWidth = self.resolution
        return false
    end
    return true
end

--- Bind an axis-aligned world box to a modifier the way the engine binds a box
--- (DensityMapParallelogram:applyToModifier, densityMaps/DensityMapParallelogram.lua
--- :70-75): clear the polygon points, then the four corners in order, start, width,
--- the fourth corner (width + height - start) and height. Every region the union ops
--- set on these modifiers is then a polygon, so no bind has to replace another kind of
--- region (MAINTENANCE row 90: setParallelogramWorldCoords after clearPolygonPoints
--- left open whether the parallelogram replaces the points).
local function bindBox(mod, x0, z0, x1, z1)
    mod:clearPolygonPoints()
    mod:addPolygonPointWorldCoords(x0, z0)
    mod:addPolygonPointWorldCoords(x1, z0)
    mod:addPolygonPointWorldCoords(x1, z1)
    mod:addPolygonPointWorldCoords(x0, z1)
end

--- Bind the union of two or more polygons: paint the work set, bind the moisture
--- modifier to the union's box, arm the mask filter. Returns true, or false and
--- a typed reason ("INVALID_FIELD_GEOMETRY" | "PROVIDER_REFUSAL").
function CropStressValueMap:_bindUnion(polys)
    local x0, z0, x1, z1 = collectionBox(polys)
    if x0 == nil then return false, "INVALID_FIELD_GEOMETRY" end
    if self.modifier == nil or not self.hasPolygonOps then return false, "PROVIDER_REFUSAL" end
    if not self:_ensureUnionMask() then return false, "PROVIDER_REFUSAL" end
    -- One grain of margin: a cell whose centre sits on the box edge is inside it.
    local margin = self:getGrainMetres() or 2
    x0, z0, x1, z1 = x0 - margin, z0 - margin, x1 + margin, z1 + margin
    local mm = self.maskModifier
    self._unionBox = { x0, z0, x1, z1 }
    local ok = pcall(function()
        -- Clear the box first: nothing a failed release left behind joins this parcel.
        -- The box is bound as polygon points (bindBox), so it is the only region on
        -- either modifier.
        bindBox(mm, x0, z0, x1, z1)
        mm:executeSet(0)
        for pi = 1, #polys do
            local p = polys[pi]
            mm:clearPolygonPoints()
            for i = 1, p.n do
                mm:addPolygonPointWorldCoords(p.vx[i], p.vz[i])
            end
            mm:executeSet(1)
        end
        bindBox(self.modifier, x0, z0, x1, z1)
        self.maskFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
    end)
    if not ok then
        self:_releaseUnion()
        return false, "PROVIDER_REFUSAL"
    end
    return true
end

--- Clear the work set over the last union's box. Best effort: the next bind
--- clears its own box again before painting.
function CropStressValueMap:_releaseUnion()
    local box = self._unionBox
    self._unionBox = nil
    local mm = self.maskModifier
    if box == nil or mm == nil then return end
    pcall(function()
        bindBox(mm, box[1], box[2], box[3], box[4])
        mm:executeSet(0)
    end)
end

--- Paint every cell of the parcel union to one value, once per cell. One
--- polygon: paintPolygon, unchanged.
function CropStressValueMap:paintPolygons(polys, value)
    if type(polys) ~= "table" or #polys == 0 then return false end
    if #polys == 1 then
        local p = polys[1]
        return self:paintPolygon(p.vx, p.vz, p.n, value)
    end
    if not self.available then return false end
    if not self:_bindUnion(polys) then return false end
    local raw = encode(value, CropStressValueMap.LAYER_DEF)
    local ok = pcall(function() self.modifier:executeSet(raw, self.maskFilter) end)
    self:_releaseUnion()
    return ok
end

--- Shift every written cell of the parcel union by a whole number of raw steps,
--- once per cell however the polygons overlap. One polygon: applyDeltaToPolygon,
--- unchanged. The caller has quantised the delta through quantiseDelta().
---@return number applied  semantic amount actually applied (0 when nothing moved)
function CropStressValueMap:applyDeltaToPolygons(polys, delta)
    if type(polys) ~= "table" or #polys == 0 then return 0 end
    if #polys == 1 then
        local p = polys[1]
        return self:applyDeltaToPolygon(p.vx, p.vz, p.n, delta)
    end
    if not self.available or delta == nil or delta == 0 then return 0 end
    local def = CropStressValueMap.LAYER_DEF
    local upr = unitsPerRaw(def)
    local rawDelta = (delta >= 0) and math.floor(delta / upr + 0.5)
                                   or -math.floor(-delta / upr + 0.5)
    if rawDelta == 0 then return 0 end
    if not self.hasExecuteAdd then return 0 end
    -- The written-range guard is a filter; without the filter class there is no
    -- union add (the mask needs the same class), so nothing moves and nothing wraps.
    if self.filter == nil then return 0 end
    if not self:_bindUnion(polys) then return 0 end
    local m, f = self.modifier, self.filter
    local ok = pcall(function()
        if rawDelta > 0 then
            f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN, RAW_MAX - rawDelta)
        else
            f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN - rawDelta, RAW_MAX)
        end
        m:executeAdd(rawDelta, f, self.maskFilter)
    end)
    self:_releaseUnion()
    if not ok then
        csvmLog("Moisture map: executeAdd unavailable on the parcel union; disabling the add path")
        self.hasExecuteAdd = false
        return 0
    end
    return rawDelta * upr
end

--- The mean over the written cells of the parcel union: their native
--- accumulation over the unique cells divided by their count, never an average
--- of polygon averages. One polygon: readAverageOfPolygon, unchanged. Returns
--- outcome, mean, grain with readAverageOfPolygon's typed outcomes.
function CropStressValueMap:readAverageOfPolygons(polys)
    if type(polys) ~= "table" or #polys == 0 then return "INVALID_FIELD_GEOMETRY", nil, nil end
    if #polys == 1 then
        local p = polys[1]
        return self:readAverageOfPolygon(p.vx, p.vz, p.n)
    end
    if collectionBox(polys) == nil then return "INVALID_FIELD_GEOMETRY", nil, nil end
    if not self.available then return "PROVIDER_REFUSAL", nil, nil end
    local m, f = self.modifier, self.filter
    if m == nil or m.executeGet == nil or f == nil then return "PROVIDER_REFUSAL", nil, nil end
    if not self:_bindUnion(polys) then return "PROVIDER_REFUSAL", nil, nil end
    local ok, acc, numPixels = pcall(function()
        -- Written cells only, said explicitly: the unique written cells are the
        -- samples and their count is the divisor.
        f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN, RAW_MAX)
        return m:executeGet(f, self.maskFilter)
    end)
    self:_releaseUnion()
    if not ok or acc == nil or numPixels == nil then return "PROVIDER_REFUSAL", nil, nil end
    if numPixels == 0 then return "EMPTY", nil, self:getGrainMetres() end
    return "OK", decode(acc / numPixels, CropStressValueMap.LAYER_DEF), self:getGrainMetres()
end

-- ─────────────────────────────────────────────────────────
-- MULTIPLAYER DELIVERY (brief step 5, the six-layer precedent)
--
-- The server owns the moisture truth; a client allocates the same map and is
-- filled a ROW AT A TIME rather than in one payload, because a 2048x2048 map is
-- 4 MB of raw bytes and no single event carries that. Rows are raw values, so
-- nothing is re-quantised in flight and a client's pixels are bit-identical to
-- the server's.
-- ─────────────────────────────────────────────────────────

function CropStressValueMap:getSyncRowCount()
    if not self.available then return 0 end
    return self.resolution
end

--- Read one row of RAW values off the map. Returns nil when unavailable so the
--- caller can stop rather than send a row of zeros that would erase a client.
function CropStressValueMap:readSyncRow(gy)
    if not self.available then return nil end
    if getBitVectorMapPoint == nil then return nil end
    if gy == nil or gy < 0 or gy >= self.resolution then return nil end
    local row = {}
    for gx = 0, self.resolution - 1 do
        local ok, raw = pcall(getBitVectorMapPoint, self.bvm, gx, gy, 0, NUM_CHANNELS)
        row[gx + 1] = (ok and raw) or 0
    end
    return row
end

--- Apply one received row. Client side only in practice, but it is written as a
--- plain map operation so the bench can drive it without a network.
function CropStressValueMap:applySyncRow(gy, row)
    if not self.available or row == nil then return false end
    if setBitVectorMapPoint == nil then return false end
    if gy == nil or gy < 0 or gy >= self.resolution then return false end
    local limit = math.min(#row, self.resolution)
    for i = 1, limit do
        local raw = row[i] or 0
        pcall(setBitVectorMapPoint, self.bvm, i - 1, gy, 0, NUM_CHANNELS, raw)
    end
    return true
end

--- SCS-039 v2.1 (SDS 3.7): set ONE pixel from a semantic moisture value by its
--- composite pixel key (px*4096+pz). Absolute deltas that a snapshot publishes
--- land here after the raw rows are applied.
function CropStressValueMap:writePixelValue(pixelKey, value)
    if not self.available then return false end
    if setBitVectorMapPoint == nil then return false end
    local px = math.floor(pixelKey / 4096)
    local pz = pixelKey - px * 4096
    if px < 0 or pz < 0 or px >= self.resolution or pz >= self.resolution then return false end
    local raw = encode(value, CropStressValueMap.LAYER_DEF)
    local ok = pcall(setBitVectorMapPoint, self.bvm, px, pz, 0, NUM_CHANNELS, raw)
    return ok == true
end

--- Pack a raw row into a compact run-length form for the wire. Moisture maps are
--- overwhelmingly runs of one value (a field at a uniform level, and the whole
--- off-field remainder at the raw-0 sentinel), so this is the difference between
--- a sane join and a stall. Falls back to nothing clever when the row is noisy.
---@return table pairs  flat {count, value, count, value, ...}
function CropStressValueMap.packRow(row)
    local out = {}
    if row == nil or #row == 0 then return out end
    local runValue = row[1]
    local runLen   = 1
    for i = 2, #row do
        local v = row[i]
        if v == runValue and runLen < 65535 then
            runLen = runLen + 1
        else
            out[#out + 1] = runLen
            out[#out + 1] = runValue
            runValue = v
            runLen = 1
        end
    end
    out[#out + 1] = runLen
    out[#out + 1] = runValue
    return out
end

--- Inverse of packRow. Never trusts the payload: a malformed or hostile run
--- table cannot make this allocate past the map's own width.
function CropStressValueMap.unpackRow(packed, width)
    local row = {}
    if packed == nil then return row end
    local n = 0
    local i = 1
    while i < #packed do
        local count = packed[i] or 0
        local value = packed[i + 1] or 0
        i = i + 2
        for _ = 1, count do
            if width ~= nil and n >= width then return row end
            n = n + 1
            row[n] = value
        end
    end
    return row
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
