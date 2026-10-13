-- ============================================================
-- AutoDriveIntegration.lua
-- Optional integration with AutoDrive for FS25.
--
-- Reads AutoDrive destination data to inform the player about
-- available water-hauling infrastructure when a critical drought
-- alert fires. When AutoDrive is detected and destinations are
-- configured, the Crop Consultant appends a one-line hint to
-- CRITICAL alerts suggesting the player set up a water route.
--
-- This integration is READ-ONLY. We never call StartDriving or
-- modify AutoDrive state in any way.
--
-- Detection global: AutoDrive (no g_ prefix — confirmed FS25 source)
-- NOTE: FS22 used g_autoDrive. FS25 uses AutoDrive (bare table).
--
-- API used (confirmed from ExternalInterface.lua):
--   AutoDrive:GetAvailableDestinations()
--     Returns: { [id] = { name, x, y, z, id }, ... }
--
-- Water destination heuristic: if a destination's name contains
-- any of the water-related keywords below, it is counted as a
-- possible water source for irrigation water hauling.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

AutoDriveIntegration = AutoDriveIntegration or {}
AutoDriveIntegration.__index = AutoDriveIntegration

-- Cache TTL in in-game hours; destinations rarely change mid-session
AutoDriveIntegration.CACHE_TTL_HOURS = 6

-- Lowercase substrings that suggest a destination is a water source.
-- Checked against the destination's `name` field (case-insensitive).
AutoDriveIntegration.WATER_KEYWORDS = {
    "water", "pump", "tank", "irrig", "pond", "lake",
    "river", "well", "cistern", "reservoir",
}

-- ============================================================
-- CONSTRUCTOR
-- ============================================================
function AutoDriveIntegration.new(manager)
    local self = setmetatable({}, AutoDriveIntegration)
    self.manager       = manager
    self.adActive      = false     -- set by CropStressManager:detectOptionalMods()
    self.isInitialized = false

    -- Cached counts (refreshed hourly)
    self.destinationCount      = 0
    self.waterDestinationCount = 0
    self.lastCacheHourKey      = -1

    return self
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function AutoDriveIntegration:initialize()
    self.isInitialized = true
    if not self.adActive then
        csLog("AutoDriveIntegration: AutoDrive not detected — running without AD context")
        return
    end
    -- Populate cache immediately so first-tick alerts have data
    self:refreshDestinationCache(-1)
    csLog(string.format(
        "AutoDriveIntegration: active — %d destinations (%d water-related)",
        self.destinationCount, self.waterDestinationCount))
end

-- ============================================================
-- ACTIVATION
-- Called by CropStressManager:detectOptionalMods().
-- ============================================================
function AutoDriveIntegration:enableAutoDriveMode()
    self.adActive = true
end

-- ============================================================
-- IS ACTIVE
-- ============================================================
function AutoDriveIntegration:isActive()
    return self.adActive and self.isInitialized
end

-- ============================================================
-- HOURLY REFRESH
-- Updates the destination cache if the TTL has elapsed.
-- Called from CropStressManager:onHourlyTick().
-- ============================================================
function AutoDriveIntegration:hourlyRefresh()
    if not self:isActive() then return end

    local env     = g_currentMission and g_currentMission.environment
    local hourKey = 0
    if env ~= nil then
        hourKey = (env.currentMonotonicDay or 0) * 24 + (env.currentHour or 0)
    end

    if (hourKey - self.lastCacheHourKey) < AutoDriveIntegration.CACHE_TTL_HOURS then
        return  -- Still fresh
    end

    self:refreshDestinationCache(hourKey)
end

-- ============================================================
-- REFRESH DESTINATION CACHE
-- Calls the confirmed AutoDrive public API and counts destinations.
-- ============================================================
function AutoDriveIntegration:refreshDestinationCache(hourKey)
    self.destinationCount      = 0
    self.waterDestinationCount = 0
    self.lastCacheHourKey      = hourKey

    -- Guard: AutoDrive table and GetAvailableDestinations must both exist
    if AutoDrive == nil then return end
    if type(AutoDrive.GetAvailableDestinations) ~= "function" then return end

    local ok, destinations = pcall(function()
        return AutoDrive:GetAvailableDestinations()
    end)
    if not ok or type(destinations) ~= "table" then return end

    for _, dest in pairs(destinations) do
        self.destinationCount = self.destinationCount + 1
        if dest ~= nil and self:isWaterDestination(dest) then
            self.waterDestinationCount = self.waterDestinationCount + 1
        end
    end

    if self.manager and self.manager.debugMode then
        csLog(string.format(
            "AutoDriveIntegration: cache refreshed — %d destinations (%d water)",
            self.destinationCount, self.waterDestinationCount))
    end
end

-- ============================================================
-- WATER DESTINATION HEURISTIC
-- Checks a destination's name for water-related keywords.
-- ============================================================
function AutoDriveIntegration:isWaterDestination(dest)
    local name = dest.name
    if name == nil then return false end
    local lower = string.lower(tostring(name))
    for _, keyword in ipairs(AutoDriveIntegration.WATER_KEYWORDS) do
        if lower:find(keyword, 1, true) then
            return true
        end
    end
    return false
end

-- ============================================================
-- PUBLIC ACCESSORS
-- ============================================================

function AutoDriveIntegration:getDestinationCount()
    return self.destinationCount
end

function AutoDriveIntegration:getWaterDestinationCount()
    return self.waterDestinationCount
end

-- Returns a short localised hint for CRITICAL stress alerts,
-- or nil if AutoDrive is inactive or has no destinations.
function AutoDriveIntegration:getCriticalAlertHint()
    if not self:isActive() then return nil end
    if self.destinationCount == 0 then return nil end

    -- getText() returns the key itself when a translation is missing — the standard FS25 pattern.
    -- Hardcoded English fallback ensures players never see a raw "cs_ad_..." key.
    local function getLocalised(key, ...)
        if g_i18n ~= nil then
            local t = g_i18n:getText(key)
            if t ~= nil and t ~= key then return string.format(t, ...) end
        end
        return nil
    end

    -- With identified water destinations: direct hint
    if self.waterDestinationCount > 0 then
        return getLocalised("cs_ad_water_hint", self.waterDestinationCount)
            or string.format(
                "AutoDrive: %d water destination(s) available — consider a hauling route",
                self.waterDestinationCount)
    end

    -- Destinations exist but none matched water keywords
    return getLocalised("cs_ad_destinations", self.destinationCount)
        or string.format("AutoDrive: %d destination(s) configured", self.destinationCount)
end

-- ============================================================
-- CLEANUP
-- ============================================================
function AutoDriveIntegration:delete()
    self.destinationCount      = 0
    self.waterDestinationCount = 0
    self.isInitialized         = false
end
