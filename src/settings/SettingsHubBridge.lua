-- =========================================================
-- FS25 Seasonal Crop Stress - SettingsHub bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_SettingsHub. Safe if SettingsHub is not
-- installed (register() just no-ops). Purpose: let the FarmTablet
-- System Settings app list Seasonal Crop Stress' settings.
--
-- g_cropStressManager.settings (a CropStressSettings object with its own
-- load/save path) stays the source of truth. This mirrors current values
-- into SettingsHub for display; the tablet app is read-only for now, so
-- applyChange sets the value back and revalidates. HUD panel X/Y drag
-- coordinates are intentionally not exposed.
-- =========================================================

SeasonalSettingsHubBridge = SeasonalSettingsHubBridge or {}

local function applyChange(key, value)
    local mgr = g_cropStressManager
    if mgr == nil or mgr.settings == nil then return end
    mgr.settings[key] = value
    if type(mgr.settings.validateSettings) == "function" then
        mgr.settings:validateSettings()
    end
end

function SeasonalSettingsHubBridge.register(mgr)
    -- The reliable cross-mod handle is g_currentMission.settingsHub (the same one
    -- FarmTablet reads). The bare g_settingsHub global is only visible inside
    -- SettingsHub's own mod environment, so it reads back nil from here.
    local hub = (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
    if hub == nil then return end
    if mgr == nil or mgr.settings == nil then return end
    local s = mgr.settings

    local defs = {
        { id = "enabled",            type = "bool",  default = s.enabled,            adminOnly = true,  label = "Seasonal Crop Stress Enabled" },
        { id = "difficulty",         type = "enum",  default = s.difficulty,         adminOnly = true,  values = { "easy", "normal", "hard" }, label = "Difficulty (easy/normal/hard)" },
        { id = "evapotranspiration", type = "enum",  default = s.evapotranspiration, adminOnly = true,  values = { "slow", "normal", "fast" }, label = "Evapotranspiration Rate" },
        { id = "maxYieldLoss",       type = "float", default = s.maxYieldLoss,       adminOnly = true,  min = 0.30, max = 0.75, label = "Max Yield Loss" },
        { id = "criticalThreshold",  type = "float", default = s.criticalThreshold,  adminOnly = true,  min = 0.15, max = 0.35, label = "Critical Moisture Threshold" },
        { id = "irrigationCosts",    type = "bool",  default = s.irrigationCosts,    adminOnly = true,  label = "Irrigation Costs" },
        { id = "hudVisible",         type = "bool",  default = s.hudVisible,         adminOnly = false, label = "Show Moisture HUD" },
        { id = "alertsEnabled",      type = "bool",  default = s.alertsEnabled,      adminOnly = false, label = "Stress Alerts" },
        { id = "alertCooldown",      type = "int",   default = s.alertCooldown,      adminOnly = false, min = 4, max = 24, label = "Alert Cooldown (hours)" },
        { id = "debugMode",          type = "bool",  default = s.debugMode,          adminOnly = false, label = "Debug Mode" },
        { id = "finiteWater",        type = "bool",  default = s.finiteWater,        adminOnly = true,  label = "Finite Irrigation Water" },
        { id = "experimentalSystems", type = "bool", default = s.experimentalSystems, adminOnly = true, label = "Experimental Systems" },
    }

    local ok, err = pcall(function()
        hub:registerModule("SeasonalCropStress", {
            adminSettings = defs,
            onChange      = function(key, value, playerId) applyChange(key, value) end,
        })
    end)

    if ok then
        Logging.info("Seasonal Crop Stress: Registered with SettingsHub (%d setting(s))", #defs)
    else
        Logging.warning("Seasonal Crop Stress: SettingsHub registration failed: %s", tostring(err))
    end
end
