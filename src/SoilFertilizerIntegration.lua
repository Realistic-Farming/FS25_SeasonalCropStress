-- ============================================================
-- SoilFertilizerIntegration.lua
-- Optional integration with FS25_SoilFertilizer (sibling mod).
--
-- Reads per-field soil chemistry (pH, organic matter) from the
-- sibling mod and translates it into modifiers that affect our
-- moisture simulation:
--
--   organicMatter → evaporation modifier
--     High OM (>5%) improves water retention → lower evap rate
--     Low  OM (<2%) reduces water retention  → higher evap rate
--
--   soil pH → stress threshold modifier
--     Optimal pH (6.0-7.5): no effect
--     Acidic  (<6.0):  +0.03 to criticalMoisture (crops stress earlier)
--     Alkaline (>7.5): +0.02 to criticalMoisture
--
-- Detection global: g_SoilFertilityManager
-- API used:
--   g_SoilFertilityManager.soilSystem:getFieldInfo(fieldId)
--   Returns: { pH, organicMatter, nitrogen, phosphorus, potassium, ... }
--
-- All reads are pcall-wrapped and nil-guarded. If the API differs
-- or SoilFertilizer is absent, all modifiers silently return neutral
-- values (evapMod=1.0, stressMod=0.0) and the simulation is unaffected.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

SoilFertilizerIntegration = {}
SoilFertilizerIntegration.__index = SoilFertilizerIntegration

-- Organic matter bands → evaporation multiplier
-- Values sourced from soil science: humus content > 4% substantially
-- improves water-holding capacity; depleted soils drain fast.
SoilFertilizerIntegration.OM_EVAP_HIGH  = 0.85  -- OM > 5%:  good retention
SoilFertilizerIntegration.OM_EVAP_MID   = 0.92  -- OM 3-5%:  above average
SoilFertilizerIntegration.OM_EVAP_LOW   = 1.10  -- OM 1-3%:  below average
SoilFertilizerIntegration.OM_EVAP_POOR  = 1.18  -- OM < 1%:  poor retention

-- pH bands → additive critical-moisture modifier (fraction, not %)
SoilFertilizerIntegration.PH_STRESS_ACID  = 0.04  -- pH < 6.0: +4% threshold
SoilFertilizerIntegration.PH_STRESS_ALK   = 0.02  -- pH > 7.5: +2% threshold

-- Compaction bands → additive critical-moisture modifier (Arrow-2's compaction
-- half). High compaction reduces the soil's moisture buffer, so a compacted
-- field's crop stresses and alerts hit earlier on a drying swing. SF's field
-- compaction is a 0..100 score (MAX_COMPACTION = 100); the bands and magnitudes
-- are balance-pass numbers.
SoilFertilizerIntegration.COMPACT_STRESS_HIGH   = 0.05   -- compaction >= 80
SoilFertilizerIntegration.COMPACT_STRESS_MID    = 0.02   -- compaction >= 50
SoilFertilizerIntegration.COMPACT_THRESHOLD_HIGH = 80
SoilFertilizerIntegration.COMPACT_THRESHOLD_MID  = 50

-- Cache TTL: refresh field modifiers every 4 in-game hours at most
-- (soil chemistry changes slowly; per-hour polling is excessive)
SoilFertilizerIntegration.CACHE_TTL_HOURS = 4

-- ============================================================
-- CONSTRUCTOR
-- ============================================================
function SoilFertilizerIntegration.new(manager)
    local self = setmetatable({}, SoilFertilizerIntegration)
    self.manager       = manager
    self.sfActive      = false      -- set by CropStressManager:detectOptionalMods()
    self.isInitialized = false

    -- Per-field cache: fieldId → { evapMod, stressMod, lastHourKey }
    self.fieldCache = {}

    return self
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function SoilFertilizerIntegration:initialize()
    self.isInitialized = true
    if not self.sfActive then
        csLog("SoilFertilizerIntegration: FS25_SoilFertilizer not detected — running without soil chemistry")
        return
    end
    csLog("SoilFertilizerIntegration: active — pH and organic matter will affect moisture simulation")
end

-- ============================================================
-- ACTIVATION
-- Called by CropStressManager:detectOptionalMods() when
-- g_SoilFertilityManager is present.
-- ============================================================
function SoilFertilizerIntegration:enableSoilFertilizerMode()
    self.sfActive = true
end

-- ============================================================
-- IS ACTIVE
-- ============================================================
function SoilFertilizerIntegration:isActive()
    return self.sfActive and self.isInitialized
end

-- ============================================================
-- HOURLY REFRESH
-- Called by CropStressManager:onHourlyTick() so the cache stays
-- current without querying the SoilFertilizer API every frame.
-- Only rebuilds entries that have exceeded the cache TTL.
-- ============================================================
function SoilFertilizerIntegration:hourlyRefresh()
    -- Late detection: SoilFertilizer may finish initializing after our detectOptionalMods() runs.
    -- On the first hourly tick it will always be ready, so we retry here if still inactive.
    if not self.sfActive and g_currentMission ~= nil and g_currentMission.soilFertilityManager ~= nil then
        self:enableSoilFertilizerMode()
        csLog("SoilFertilizerIntegration: late-detected FS25_SoilFertilizer — soil chemistry now active")
    end
    if not self:isActive() then return end
    if g_currentMission == nil or g_currentMission.soilFertilityManager == nil then return end

    local env     = g_currentMission and g_currentMission.environment
    local hourKey = 0
    if env ~= nil then
        hourKey = (env.currentMonotonicDay or 0) * 24 + (env.currentHour or 0)
    end

    -- Iterate CropStress-tracked fields and query SoilFertilizer for each
    local csSystem = self.manager and self.manager.soilSystem
    if csSystem == nil or csSystem.fieldData == nil then return end

    for fieldId, _ in pairs(csSystem.fieldData) do
        local cached = self.fieldCache[fieldId]
        if cached == nil or (hourKey - (cached.lastHourKey or 0)) >= SoilFertilizerIntegration.CACHE_TTL_HOURS then
            self:refreshField(fieldId, hourKey)
        end
    end
end

-- ============================================================
-- REFRESH SINGLE FIELD
-- Queries SoilFertilizer for a field and updates cache entry.
-- ============================================================
function SoilFertilizerIntegration:refreshField(fieldId, hourKey)
    -- getFieldInfo is the confirmed public method on SoilFertilitySystem
    -- Use mission bridge — g_SoilFertilityManager is per-mod scoped, not cross-mod accessible
    local sfSystem = g_currentMission
        and g_currentMission.soilFertilityManager
        and g_currentMission.soilFertilityManager.soilSystem
    if sfSystem == nil then
        self.fieldCache[fieldId] = { evapMod = 1.0, stressMod = 0.0, lastHourKey = hourKey or 0 }
        return
    end

    local ok, info = pcall(function()
        return sfSystem:getFieldInfo(fieldId)
    end)

    if not ok or info == nil then
        self.fieldCache[fieldId] = { evapMod = 1.0, stressMod = 0.0, lastHourKey = hourKey or 0 }
        return
    end

    local evapMod  = self:computeEvapMod(info.organicMatter)
    local stressMod = self:computeStressMod(info.pH)
    local compactMod = self:computeCompactMod(info.compaction)

    self.fieldCache[fieldId] = {
        evapMod     = evapMod,
        stressMod   = stressMod,
        compactMod  = compactMod,
        lastHourKey = hourKey or 0,
    }
end

-- ============================================================
-- COMPUTE EVAP MODIFIER FROM ORGANIC MATTER
-- organicMatter is a float in SoilFertilizer's range (0.0–10.0+).
-- ============================================================
function SoilFertilizerIntegration:computeEvapMod(om)
    if om == nil then return 1.0 end
    if om >= 5.0 then return SoilFertilizerIntegration.OM_EVAP_HIGH  end
    if om >= 3.0 then return SoilFertilizerIntegration.OM_EVAP_MID   end
    if om >= 1.0 then return SoilFertilizerIntegration.OM_EVAP_LOW   end
    return SoilFertilizerIntegration.OM_EVAP_POOR
end

-- ============================================================
-- COMPUTE STRESS THRESHOLD MODIFIER FROM PH
-- Returns an additive offset applied to criticalMoisture per field.
-- ============================================================
function SoilFertilizerIntegration:computeStressMod(pH)
    if pH == nil then return 0.0 end
    if pH < 6.0 then return SoilFertilizerIntegration.PH_STRESS_ACID end
    if pH > 7.5 then return SoilFertilizerIntegration.PH_STRESS_ALK  end
    return 0.0
end

-- ============================================================
-- COMPUTE COMPACTION MODIFIER
-- SF field compaction is a 0..100 score. High compaction sharpens the wet/dry
-- swing (additive to criticalMoisture, so stress and alerts fire earlier on a
-- drying pass); low compaction is neutral. Nil/unknown degrades to 0.0.
-- ============================================================
function SoilFertilizerIntegration:computeCompactMod(compaction)
    if compaction == nil then return 0.0 end
    if compaction >= SoilFertilizerIntegration.COMPACT_THRESHOLD_HIGH then
        return SoilFertilizerIntegration.COMPACT_STRESS_HIGH
    end
    if compaction >= SoilFertilizerIntegration.COMPACT_THRESHOLD_MID then
        return SoilFertilizerIntegration.COMPACT_STRESS_MID
    end
    return 0.0
end

-- ============================================================
-- PUBLIC ACCESSORS
-- Return cached values; neutral defaults if cache is empty.
-- ============================================================
function SoilFertilizerIntegration:getFieldEvapMod(fieldId)
    if not self:isActive() then return 1.0 end
    local cached = self.fieldCache[fieldId]
    return (cached ~= nil) and cached.evapMod or 1.0
end

function SoilFertilizerIntegration:getFieldStressMod(fieldId)
    if not self:isActive() then return 0.0 end
    local cached = self.fieldCache[fieldId]
    return (cached ~= nil) and cached.stressMod or 0.0
end

function SoilFertilizerIntegration:getFieldCompactMod(fieldId)
    if not self:isActive() then return 0.0 end
    local cached = self.fieldCache[fieldId]
    return (cached ~= nil) and cached.compactMod or 0.0
end

-- Returns a human-readable summary for the consultant dialog.
-- Shows how many fields have chemistry outside the optimal range.
function SoilFertilizerIntegration:getSummary()
    if not self:isActive() then return nil end

    local highEvap, poorPH = 0, 0
    for _, cached in pairs(self.fieldCache) do
        if cached.evapMod > 1.0 then highEvap = highEvap + 1 end
        if cached.stressMod > 0.0 then poorPH  = poorPH  + 1 end
    end

    return {
        highEvapFields = highEvap,
        poorPHFields   = poorPH,
    }
end

-- ============================================================
-- CLEANUP
-- ============================================================
function SoilFertilizerIntegration:delete()
    self.fieldCache    = {}
    self.isInitialized = false
end
