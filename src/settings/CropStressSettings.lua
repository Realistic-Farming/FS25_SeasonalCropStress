-- ============================================================
-- CropStressSettings.lua
-- Data model and persistence for mod settings.
-- Follows NPCFavor pattern: data model → ESC menu → multiplayer sync.
-- Settings live in a sidecar XML file per savegame.
-- ============================================================

-- ============================================================
-- LOGGING HELPER
-- ============================================================
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ============================================================
-- CROP STRESS SETTINGS CLASS
-- ============================================================
-- Wizard hot-reload law Part 1: reuse the existing class table on reload so
-- updated methods land on the table live metatables already reference.
CropStressSettings = CropStressSettings or {}
CropStressSettings.__index = CropStressSettings

-- Default values matching the current hardcoded constants
local DEFAULTS = {
    enabled = true,
    difficulty = "normal",
    hudVisible = true,
    evapotranspiration = "normal",
    maxYieldLoss = 0.30,   -- gentle end of the clamp; Arissani ruling 2026-07-30
    criticalThreshold = 0.25,
    irrigationCosts = true,
    alertsEnabled = true,
    alertCooldown = 12,
    debugMode = false,
    -- Release-gate opt-in (default false), orthogonal to difficulty. See ReleaseGate.lua.
    experimentalSystems = false,
    -- Wizard 2026-08-21: factory home is the suite layout Wizard arranged
    -- in-game (must match HUDOverlay.PANEL_X/Y). A saved XML still wins on load.
    hudPanelX = 0.012604,
    hudPanelY = 0.236481,
    -- Forecast pane home (Wizard 2026-08-21: strip is independently movable).
    -- -1 = docked to the fields panel's right edge; the factory home is the
    -- absolute spot Wizard placed it (just above the fields pane).
    hudForecastX = 0.136500,
    hudForecastY = 0.135556,
    -- Wizard 2026-08-21 width wave: corner-scale and per-pane width multipliers
    -- (NPCFavor/Workplace pattern) persist too. hudScale was written by the HUD
    -- since the resize feature shipped but never saved - fixed here. Values are
    -- the factory suite layout.
    hudScale         = 1.118898,
    hudWidthMult     = 1.098438,
    hudForecastWMult = 1.187500
}

-- Difficulty multipliers
local DIFFICULTY_MULTIPLIERS = {
    easy = { stress = 0.5, evap = 0.7 },
    normal = { stress = 1.0, evap = 1.0 },
    hard = { stress = 1.5, evap = 1.4 }
}

-- The pre-2026-07-30 default cap. Retained solely so a save still carrying it can be
-- migrated to the current default on load (see the migration note in load()). Do not
-- reuse this for anything else, and do not change it: it is a historical marker, not
-- a tunable.
local LEGACY_MAX_YIELD_LOSS = 0.60

--- One-time default migration for the yield cap (Arissani ruling 2026-07-30).
---
--- The harvest hook never installed before this version, so NO stored maxYieldLoss was
--- ever actually experienced. Changing DEFAULTS alone does not reach existing saves
--- (they persist the value and the XML read wins), which would leave exactly the
--- players the ruling protects sitting on the old cap the moment the penalty went live.
---
--- A save still carrying the OLD DEFAULT moves to the new one. A player who
--- deliberately chose anything else keeps it, because an intentional 0.60 is
--- indistinguishable from an untouched one and "equal to the old default" is the
--- conservative read of "never configured".
---
--- COMPARED WITH A TOLERANCE, NOT WITH ==. The stored value round-trips through XML
--- text and 0.6 has no exact binary representation, so getFloat's result is not
--- bit-identical to the Lua literal. The first in-game test proved it: savegame14 held
--- 0.600000 and an exact compare silently did nothing. The window is far tighter than
--- the settings UI's step, so it cannot swallow a deliberate neighbouring choice.
---
--- Extracted as a named function precisely because the exact-compare version failed
--- SILENTLY. A no-op bug needs a test that can see it.
---@param stored number|nil  the value read from the savegame
---@return number value      the value to use
---@return boolean migrated  true when the legacy default was replaced
function CropStressSettings.migrateLegacyYieldCap(stored)
    if type(stored) ~= "number" then return DEFAULTS.maxYieldLoss, false end
    if math.abs(stored - LEGACY_MAX_YIELD_LOSS) < 0.001 then
        return DEFAULTS.maxYieldLoss, true
    end
    return stored, false
end

-- Validation ranges
local VALIDATION = {
    maxYieldLoss = { min = 0.30, max = 0.75 },
    criticalThreshold = { min = 0.15, max = 0.35 },
    alertCooldown = { min = 4, max = 24 },
    hudPanelX = { min = 0.0,  max = 0.95 },
    hudPanelY = { min = 0.05, max = 0.95 },
    -- Forecast pane: same screen clamp, but -1 (docked sentinel) passes through
    -- validate() untouched - see the explicit branch there.
    hudForecastX = { min = 0.0, max = 0.95 },
    hudForecastY = { min = 0.0, max = 0.95 },
    -- Mirror HUDOverlay.MIN/MAX_SCALE and MIN/MAX_WIDTH_MULT
    hudScale         = { min = 0.6,  max = 1.6 },
    hudWidthMult     = { min = 0.75, max = 2.0 },
    hudForecastWMult = { min = 0.75, max = 2.0 }
}

function CropStressSettings.new()
    local self = setmetatable({}, CropStressSettings)
    
    -- Initialize with defaults
    self:resetToDefaults()
    
    return self
end

-- Reset all settings to defaults
function CropStressSettings:resetToDefaults()
    for key, value in pairs(DEFAULTS) do
        self[key] = value
    end
end

-- Safe boolean reader: preserves explicitly-saved false values.
-- The Lua pattern `getBool(key) or default` is WRONG for booleans:
-- if the saved value is false, `false or default` evaluates to default,
-- silently reverting the user's choice. Use this helper instead.
local function readBool(xmlFile, key, default)
    local v = xmlFile:getBool(key)
    if v == nil then return default end
    return v
end

-- Load settings from savegame XML file
function CropStressSettings:load(missionInfo)
    if missionInfo == nil then
        csLog("WARNING: missionInfo is nil, using defaults")
        return
    end

    local savegameDir = missionInfo.savegameDirectory
    if savegameDir == nil then
        csLog("WARNING: savegameDirectory is nil, using defaults")
        return
    end

    local xmlPath = savegameDir .. "/cropStressSettings.xml"

    -- Check if file exists
    if not fileExists(xmlPath) then
        csLog("Settings file not found, using defaults")
        return
    end

    local xmlFile = XMLFile.load("CropStressSettings", xmlPath)
    if xmlFile == nil then
        csLog("WARNING: Failed to load settings XML, using defaults")
        return
    end

    -- Read all settings.  Booleans use readBool() — not the 'or' pattern —
    -- to correctly restore false values (see helper comment above).
    self.enabled            = readBool(xmlFile, "cropStressSettings.enabled",           DEFAULTS.enabled)
    self.difficulty         = xmlFile:getString("cropStressSettings.difficulty")         or DEFAULTS.difficulty
    self.hudVisible         = readBool(xmlFile, "cropStressSettings.hudVisible",         DEFAULTS.hudVisible)
    self.evapotranspiration = xmlFile:getString("cropStressSettings.evapotranspiration") or DEFAULTS.evapotranspiration
    self.maxYieldLoss       = xmlFile:getFloat("cropStressSettings.maxYieldLoss")        or DEFAULTS.maxYieldLoss
    self.criticalThreshold  = xmlFile:getFloat("cropStressSettings.criticalThreshold")   or DEFAULTS.criticalThreshold
    self.irrigationCosts    = readBool(xmlFile, "cropStressSettings.irrigationCosts",    DEFAULTS.irrigationCosts)
    self.alertsEnabled      = readBool(xmlFile, "cropStressSettings.alertsEnabled",      DEFAULTS.alertsEnabled)
    self.alertCooldown      = xmlFile:getInt("cropStressSettings.alertCooldown")         or DEFAULTS.alertCooldown
    self.debugMode          = readBool(xmlFile, "cropStressSettings.debugMode",          DEFAULTS.debugMode)
    self.experimentalSystems = readBool(xmlFile, "cropStressSettings.experimentalSystems", DEFAULTS.experimentalSystems)
    self.hudPanelX          = xmlFile:getFloat("cropStressSettings.hudPanelX")           or DEFAULTS.hudPanelX
    self.hudPanelY          = xmlFile:getFloat("cropStressSettings.hudPanelY")           or DEFAULTS.hudPanelY
    self.hudForecastX       = xmlFile:getFloat("cropStressSettings.hudForecastX")        or DEFAULTS.hudForecastX
    self.hudForecastY       = xmlFile:getFloat("cropStressSettings.hudForecastY")        or DEFAULTS.hudForecastY
    self.hudScale           = xmlFile:getFloat("cropStressSettings.hudScale")            or DEFAULTS.hudScale
    self.hudWidthMult       = xmlFile:getFloat("cropStressSettings.hudWidthMult")        or DEFAULTS.hudWidthMult
    self.hudForecastWMult   = xmlFile:getFloat("cropStressSettings.hudForecastWMult")    or DEFAULTS.hudForecastWMult

    -- One-time default migration for the yield cap (Arissani ruling 2026-07-30).
    --
    -- The harvest hook never installed before this version, so NO stored maxYieldLoss
    -- was ever actually experienced by any player. Changing DEFAULTS alone would not
    -- reach existing saves (they persist the value and the read above wins), which
    -- would leave the exact population the ruling protects still on 0.60 the moment
    -- the penalty goes live. That is the surprise tax the ruling exists to prevent.
    --
    -- So: a save still carrying the OLD DEFAULT is moved to the new one. A player who
    -- deliberately moved the slider to anything else keeps their choice untouched,
    -- because we cannot tell an intentional 0.60 from an untouched one and the
    -- conservative read of a value equal to the old default is "never configured".
    local migrated, didMigrate = CropStressSettings.migrateLegacyYieldCap(self.maxYieldLoss)
    self.maxYieldLoss = migrated
    if didMigrate then
        csLog(string.format(
            "maxYieldLoss migrated from the pre-fix default %.2f to %.2f (harvest hook now live; see ruling 2026-07-30)",
            LEGACY_MAX_YIELD_LOSS, DEFAULTS.maxYieldLoss))
    end

    xmlFile:delete()

    -- Validate and clamp values
    self:validateSettings()

    csLog("Settings loaded from " .. xmlPath)
end

-- Convert settings to a plain table (used for bulk network sync).
-- NOTE: local named 't', not 'table' — shadowing the builtin is a footgun.
-- NOTE: hudPanelX and hudPanelY ARE included in the output but are intentionally
-- excluded from CropStressSettingsSyncEvent — they are client-local display
-- preferences and must not be overwritten by a server-pushed sync.
function CropStressSettings:toTable()
    local t = {}
    for key, value in pairs(self) do
        if type(value) ~= "function" and key ~= "__index" then
            t[key] = value
        end
    end
    return t
end

-- Save settings to savegame XML file
function CropStressSettings:saveToXMLFile(missionInfo)
    if missionInfo == nil then
        csLog("WARNING: missionInfo is nil, cannot save settings")
        return
    end
    
    local savegameDir = missionInfo.savegameDirectory
    if savegameDir == nil then
        csLog("WARNING: savegameDirectory is nil, cannot save settings")
        return
    end
    
    local xmlPath = savegameDir .. "/cropStressSettings.xml"
    
    -- Create new XML file
    local xmlFile = XMLFile.create("CropStressSettings", xmlPath, "cropStressSettings")
    if xmlFile == nil then
        csLog("WARNING: Failed to create settings XML file")
        return
    end
    
    -- Write all settings with type-appropriate setters
    xmlFile:setBool("cropStressSettings.enabled", self.enabled)
    xmlFile:setString("cropStressSettings.difficulty", self.difficulty)
    xmlFile:setBool("cropStressSettings.hudVisible", self.hudVisible)
    xmlFile:setString("cropStressSettings.evapotranspiration", self.evapotranspiration)
    xmlFile:setFloat("cropStressSettings.maxYieldLoss", self.maxYieldLoss)
    xmlFile:setFloat("cropStressSettings.criticalThreshold", self.criticalThreshold)
    xmlFile:setBool("cropStressSettings.irrigationCosts", self.irrigationCosts)
    xmlFile:setBool("cropStressSettings.alertsEnabled", self.alertsEnabled)
    xmlFile:setInt("cropStressSettings.alertCooldown", self.alertCooldown)
    xmlFile:setBool("cropStressSettings.debugMode", self.debugMode)
    xmlFile:setBool("cropStressSettings.experimentalSystems", self.experimentalSystems)
    xmlFile:setFloat("cropStressSettings.hudPanelX", self.hudPanelX)
    xmlFile:setFloat("cropStressSettings.hudPanelY", self.hudPanelY)
    xmlFile:setFloat("cropStressSettings.hudForecastX", self.hudForecastX or -1)
    xmlFile:setFloat("cropStressSettings.hudForecastY", self.hudForecastY or -1)
    xmlFile:setFloat("cropStressSettings.hudScale", self.hudScale or 1.0)
    xmlFile:setFloat("cropStressSettings.hudWidthMult", self.hudWidthMult or 1.0)
    xmlFile:setFloat("cropStressSettings.hudForecastWMult", self.hudForecastWMult or 1.0)

    xmlFile:save()
    xmlFile:delete()
    
    csLog("Settings saved to " .. xmlPath)
end

-- Validate and clamp settings to valid ranges
function CropStressSettings:validateSettings()
    -- Validate difficulty
    if self.difficulty ~= "easy" and self.difficulty ~= "normal" and self.difficulty ~= "hard" then
        self.difficulty = DEFAULTS.difficulty
        csLog("Invalid difficulty, reset to 'normal'")
    end
    
    -- Validate evapotranspiration
    if self.evapotranspiration ~= "slow" and self.evapotranspiration ~= "normal" and self.evapotranspiration ~= "fast" then
        self.evapotranspiration = DEFAULTS.evapotranspiration
        csLog("Invalid evapotranspiration, reset to 'normal'")
    end
    
    -- Clamp maxYieldLoss
    if self.maxYieldLoss < VALIDATION.maxYieldLoss.min then
        self.maxYieldLoss = VALIDATION.maxYieldLoss.min
        csLog("maxYieldLoss too low, clamped to " .. self.maxYieldLoss)
    elseif self.maxYieldLoss > VALIDATION.maxYieldLoss.max then
        self.maxYieldLoss = VALIDATION.maxYieldLoss.max
        csLog("maxYieldLoss too high, clamped to " .. self.maxYieldLoss)
    end
    
    -- Clamp criticalThreshold
    if self.criticalThreshold < VALIDATION.criticalThreshold.min then
        self.criticalThreshold = VALIDATION.criticalThreshold.min
        csLog("criticalThreshold too low, clamped to " .. self.criticalThreshold)
    elseif self.criticalThreshold > VALIDATION.criticalThreshold.max then
        self.criticalThreshold = VALIDATION.criticalThreshold.max
        csLog("criticalThreshold too high, clamped to " .. self.criticalThreshold)
    end
    
    -- Clamp alertCooldown
    if self.alertCooldown < VALIDATION.alertCooldown.min then
        self.alertCooldown = VALIDATION.alertCooldown.min
        csLog("alertCooldown too low, clamped to " .. self.alertCooldown)
    elseif self.alertCooldown > VALIDATION.alertCooldown.max then
        self.alertCooldown = VALIDATION.alertCooldown.max
        csLog("alertCooldown too high, clamped to " .. self.alertCooldown)
    end
    
    -- Clamp HUD panel position
    self.hudPanelX = math.max(VALIDATION.hudPanelX.min, math.min(VALIDATION.hudPanelX.max, self.hudPanelX or DEFAULTS.hudPanelX))
    self.hudPanelY = math.max(VALIDATION.hudPanelY.min, math.min(VALIDATION.hudPanelY.max, self.hudPanelY or DEFAULTS.hudPanelY))
    -- Forecast pane: -1 is the docked sentinel and passes through untouched;
    -- anything else clamps on-screen like the main panel.
    local fx = self.hudForecastX or DEFAULTS.hudForecastX
    local fy = self.hudForecastY or DEFAULTS.hudForecastY
    if fx >= 0 then fx = math.max(VALIDATION.hudForecastX.min, math.min(VALIDATION.hudForecastX.max, fx)) else fx = -1 end
    if fy >= 0 then fy = math.max(VALIDATION.hudForecastY.min, math.min(VALIDATION.hudForecastY.max, fy)) else fy = -1 end
    self.hudForecastX = fx
    self.hudForecastY = fy
    self.hudScale         = math.max(VALIDATION.hudScale.min,         math.min(VALIDATION.hudScale.max,         self.hudScale or DEFAULTS.hudScale))
    self.hudWidthMult     = math.max(VALIDATION.hudWidthMult.min,     math.min(VALIDATION.hudWidthMult.max,     self.hudWidthMult or DEFAULTS.hudWidthMult))
    self.hudForecastWMult = math.max(VALIDATION.hudForecastWMult.min, math.min(VALIDATION.hudForecastWMult.max, self.hudForecastWMult or DEFAULTS.hudForecastWMult))

    -- Ensure boolean values are actually booleans
    self.enabled = not not self.enabled
    self.hudVisible = not not self.hudVisible
    self.irrigationCosts = not not self.irrigationCosts
    self.alertsEnabled = not not self.alertsEnabled
    self.debugMode = not not self.debugMode
    self.experimentalSystems = not not self.experimentalSystems
end

--- Release-gate opt-in. True when the player has explicitly enabled experimental
--- (LOCKED) systems. Orthogonal to difficulty: the two locks stack, see ReleaseGate.lua.
---@return boolean
function CropStressSettings:allowsExperimentalSystems()
    return self.experimentalSystems == true
end

-- Get stress rate multiplier based on difficulty
function CropStressSettings:getDifficultyStressMultiplier()
    local mult = DIFFICULTY_MULTIPLIERS[self.difficulty]
    return mult and mult.stress or 1.0
end

-- Get evapotranspiration multiplier based on difficulty
function CropStressSettings:getDifficultyEvapMultiplier()
    local mult = DIFFICULTY_MULTIPLIERS[self.difficulty]
    return mult and mult.evap or 1.0
end

-- Get evapotranspiration base multiplier based on setting
function CropStressSettings:getEvapBaseMultiplier()
    if self.evapotranspiration == "slow" then
        return 0.7
    elseif self.evapotranspiration == "fast" then
        return 1.4
    else
        return 1.0  -- normal
    end
end

-- Get combined evapotranspiration multiplier (base * difficulty)
function CropStressSettings:getTotalEvapMultiplier()
    return self:getEvapBaseMultiplier() * self:getDifficultyEvapMultiplier()
end

-- Debug: print current settings
function CropStressSettings:debugPrint()
    csLog("=== CropStress Settings ===")
    csLog("enabled: " .. tostring(self.enabled))
    csLog("difficulty: " .. self.difficulty)
    csLog("hudVisible: " .. tostring(self.hudVisible))
    csLog("evapotranspiration: " .. self.evapotranspiration)
    csLog("maxYieldLoss: " .. tostring(self.maxYieldLoss))
    csLog("criticalThreshold: " .. tostring(self.criticalThreshold))
    csLog("irrigationCosts: " .. tostring(self.irrigationCosts))
    csLog("alertsEnabled: " .. tostring(self.alertsEnabled))
    csLog("alertCooldown: " .. tostring(self.alertCooldown))
    csLog("debugMode: " .. tostring(self.debugMode))
    csLog("stressMultiplier: " .. tostring(self:getDifficultyStressMultiplier()))
    csLog("evapMultiplier: " .. tostring(self:getTotalEvapMultiplier()))
    csLog("hudPanelX: " .. tostring(self.hudPanelX))
    csLog("hudPanelY: " .. tostring(self.hudPanelY))
    csLog("=========================")
end
-- =========================================================
-- Wizard hot-reload law Part 2: force-patch the live settings instance after a
-- reload so the new save()/validate() (hudForecastX/Y persistence) apply
-- mid-session. The instance lives at manager.settings; fields the new code
-- reads that the old instance lacks are nil-safe (save writes "or -1").
local __hrMgr = g_cropStressManager or (g_currentMission ~= nil and g_currentMission.cropStressManager or nil)
if __hrMgr ~= nil and __hrMgr.settings ~= nil then
    local inst = __hrMgr.settings
    for k, v in pairs(CropStressSettings) do
        if type(v) == "function" then
            inst[k] = v
        end
    end
    -- Delivery proof in log.txt (Wizard 2026-08-21).
    print("[CropStress] CropStressSettings hot-patched onto live instance")
end
