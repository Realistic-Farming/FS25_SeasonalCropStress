-- ============================================================
-- CropStressSettingsIntegration.lua
-- Injects "Seasonal Crop Stress" section into the ESC > Settings
-- > Game Settings page.
--
-- Pattern: mirrors NPCSettingsIntegration.lua from FS25_NPCFavor
--   - Uses actual FS25 element classes: TextElement, BitmapElement,
--     BinaryOptionElement, MultiTextOptionElement
--   - Loads built-in FS25 profiles via g_gui:getProfile()
--   - Stores element references as frame.cropstress_* (per-instance guard)
--   - Hooks both onFrameOpen (inject once) and updateGameSettings (refresh)
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
-- CLASS DEFINITION
-- ============================================================
CropStressSettingsIntegration = {}
CropStressSettingsIntegration_mt = Class(CropStressSettingsIntegration)

-- Multi-text option value tables (index → value, index → display text)
CropStressSettingsIntegration.difficultyValues = { "easy", "normal", "hard" }
CropStressSettingsIntegration.difficultyTexts  = { "Easy", "Normal", "Hard" }

CropStressSettingsIntegration.evapValues = { "slow", "normal", "fast" }
CropStressSettingsIntegration.evapTexts  = { "Slow", "Normal", "Fast" }

CropStressSettingsIntegration.maxYieldLossValues = { 0.30, 0.45, 0.60, 0.75 }
CropStressSettingsIntegration.maxYieldLossTexts  = { "30%", "45%", "60%", "75%" }

CropStressSettingsIntegration.criticalThresholdValues = { 0.15, 0.25, 0.35 }
CropStressSettingsIntegration.criticalThresholdTexts  = { "15%", "25%", "35%" }

CropStressSettingsIntegration.alertCooldownValues = { 4, 8, 12, 24 }
CropStressSettingsIntegration.alertCooldownTexts  = { "4h", "8h", "12h", "24h" }

-- ============================================================
-- FRAME OPEN HOOK
-- 'self' is the InGameMenuSettingsFrame instance (appended fn)
-- ============================================================
function CropStressSettingsIntegration:onFrameOpen()
    -- Guard: inject only once per frame instance, but ALWAYS refresh values on open.
    -- cropstress_initDone is stored ON the frame, so a new session's
    -- new frame instance automatically starts without it.
    if self.cropstress_initDone then
        -- BUG FIX: previously returned here without refreshing — controls showed
        -- stale/default values every time the settings page was reopened.
        CropStressSettingsIntegration:updateSettingsUI(self)
        return
    end

    -- Support both property names used by different FS25 versions/mods.
    -- RealisticHarvesting accesses the layout via generalSettingsLayout;
    -- vanilla FS25 exposes it as gameSettingsLayout.  If RH ran its instance
    -- hook before us it may have only populated generalSettingsLayout on the
    -- live page object, leaving gameSettingsLayout nil.  Alias it here so the
    -- rest of this file works unchanged regardless of load order.
    if self.gameSettingsLayout == nil and self.generalSettingsLayout ~= nil then
        self.gameSettingsLayout = self.generalSettingsLayout
    end

    -- Guard: gameSettingsLayout must exist on this frame.
    -- If nil, skip injection silently so InGameMenu still opens.
    if self.gameSettingsLayout == nil then
        csLog("WARNING: gameSettingsLayout is nil on InGameMenuSettingsFrame — settings injection skipped")
        self.cropstress_initDone = true
        return
    end

    -- Wrap in pcall so ANY crash in our injection code cannot abort
    -- InGameMenu opening. FS25 does not pcall-wrap frame opens —
    -- an unprotected crash here prevents ESC from working entirely.
    local ok, err = pcall(function()
        CropStressSettingsIntegration:addSettingsElements(self)

        -- Refresh the layout so our new elements are sized/positioned
        self.gameSettingsLayout:invalidateLayout()
        if self.updateAlternatingElements then
            self:updateAlternatingElements(self.gameSettingsLayout)
        end
        if self.updateGeneralSettings then
            self:updateGeneralSettings(self.gameSettingsLayout)
        end

        -- Populate controls with current settings.
        -- BUG FIX: cropstress_initDone must be set TRUE before calling updateSettingsUI,
        -- because updateSettingsUI guards on `if not frame.cropstress_initDone then return end`.
        -- Previously it was set AFTER the pcall, so updateSettingsUI always returned early
        -- on the first open — elements were built but never populated, making all settings
        -- appear as off/default.
        self.cropstress_initDone = true
        CropStressSettingsIntegration:updateSettingsUI(self)
    end)

    -- Mark done if not already set inside pcall (e.g. pcall errored before reaching it)
    self.cropstress_initDone = true

    if not ok then
        csLog("WARNING: Settings frame injection failed: " .. tostring(err))
    else
        csLog("ESC menu: Seasonal Crop Stress section added successfully")
    end
end

-- ============================================================
-- UPDATE GAME SETTINGS HOOK
-- Called whenever the settings page refreshes its values.
-- 'self' is the InGameMenuSettingsFrame instance.
-- ============================================================
function CropStressSettingsIntegration:updateGameSettings()
    CropStressSettingsIntegration:updateSettingsUI(self)
end

-- ============================================================
-- ADD ALL SETTINGS ELEMENTS
-- ============================================================
function CropStressSettingsIntegration:addSettingsElements(frame)
    -- Section header
    CropStressSettingsIntegration:addSectionHeader(frame,
        (g_i18n and g_i18n:getText("cs_settings_section")) or "Seasonal Crop Stress"
    )

    -- Enable Mod
    frame.cropstress_enabled = CropStressSettingsIntegration:addBinaryOption(
        frame, "onEnabledChanged",
        (g_i18n and g_i18n:getText("cs_settings_enabled_short")) or "Enable Mod",
        (g_i18n and g_i18n:getText("cs_settings_enabled_long")) or "Enable or disable the crop stress simulation"
    )

    -- Difficulty
    frame.cropstress_difficulty = CropStressSettingsIntegration:addMultiTextOption(
        frame, "onDifficultyChanged",
        CropStressSettingsIntegration.difficultyTexts,
        (g_i18n and g_i18n:getText("cs_settings_difficulty_short")) or "Difficulty",
        (g_i18n and g_i18n:getText("cs_settings_difficulty_long")) or "How aggressively crops accumulate water stress"
    )

    -- HUD Visible
    frame.cropstress_hudVisible = CropStressSettingsIntegration:addBinaryOption(
        frame, "onHudVisibleChanged",
        (g_i18n and g_i18n:getText("cs_settings_hud_short")) or "Show Moisture HUD",
        (g_i18n and g_i18n:getText("cs_settings_hud_long")) or "Show the soil moisture overlay"
    )

    -- Evapotranspiration rate
    frame.cropstress_evapotranspiration = CropStressSettingsIntegration:addMultiTextOption(
        frame, "onEvapotranspirationChanged",
        CropStressSettingsIntegration.evapTexts,
        (g_i18n and g_i18n:getText("cs_settings_evap_short")) or "Evaporation Rate",
        (g_i18n and g_i18n:getText("cs_settings_evap_long")) or "How quickly soil moisture evaporates"
    )

    -- Max Yield Loss
    frame.cropstress_maxYieldLoss = CropStressSettingsIntegration:addMultiTextOption(
        frame, "onMaxYieldLossChanged",
        CropStressSettingsIntegration.maxYieldLossTexts,
        (g_i18n and g_i18n:getText("cs_settings_yield_loss_short")) or "Max Yield Loss",
        (g_i18n and g_i18n:getText("cs_settings_yield_loss_long")) or "Maximum harvest reduction from crop stress"
    )

    -- Critical Threshold
    frame.cropstress_criticalThreshold = CropStressSettingsIntegration:addMultiTextOption(
        frame, "onCriticalThresholdChanged",
        CropStressSettingsIntegration.criticalThresholdTexts,
        (g_i18n and g_i18n:getText("cs_settings_threshold_short")) or "Critical Threshold",
        (g_i18n and g_i18n:getText("cs_settings_threshold_long")) or "Moisture level that triggers stress accumulation"
    )

    -- Irrigation Costs
    frame.cropstress_irrigationCosts = CropStressSettingsIntegration:addBinaryOption(
        frame, "onIrrigationCostsChanged",
        (g_i18n and g_i18n:getText("cs_settings_irr_costs_short")) or "Irrigation Costs",
        (g_i18n and g_i18n:getText("cs_settings_irr_costs_long")) or "Charge running costs for active irrigation systems"
    )

    -- Alerts Enabled
    frame.cropstress_alertsEnabled = CropStressSettingsIntegration:addBinaryOption(
        frame, "onAlertsEnabledChanged",
        (g_i18n and g_i18n:getText("cs_settings_alerts_short")) or "Crop Alerts",
        (g_i18n and g_i18n:getText("cs_settings_alerts_long")) or "Show alerts when fields reach critical moisture"
    )

    -- Alert Cooldown
    frame.cropstress_alertCooldown = CropStressSettingsIntegration:addMultiTextOption(
        frame, "onAlertCooldownChanged",
        CropStressSettingsIntegration.alertCooldownTexts,
        (g_i18n and g_i18n:getText("cs_settings_cooldown_short")) or "Alert Cooldown",
        (g_i18n and g_i18n:getText("cs_settings_cooldown_long")) or "Minimum time between repeated alerts for the same field"
    )

    -- Debug Mode
    frame.cropstress_debugMode = CropStressSettingsIntegration:addBinaryOption(
        frame, "onDebugModeChanged",
        (g_i18n and g_i18n:getText("cs_settings_debug_short")) or "Debug Mode",
        (g_i18n and g_i18n:getText("cs_settings_debug_long")) or "Print verbose simulation info to the log"
    )
end

-- ============================================================
-- GUI ELEMENT BUILDERS
-- Uses actual FS25 element classes + built-in profile names.
-- Confirmed working via NPCSettingsIntegration.lua (NPCFavor).
-- ============================================================

function CropStressSettingsIntegration:addSectionHeader(frame, text)
    local textElement = TextElement.new()
    local profile = g_gui:getProfile("fs25_settingsSectionHeader")
    textElement.name = "sectionHeader"
    textElement:loadProfile(profile, true)
    textElement:setText(text)
    frame.gameSettingsLayout:addElement(textElement)
    textElement:onGuiSetupFinished()
end

function CropStressSettingsIntegration:addBinaryOption(frame, callbackName, title, tooltip)
    local bitMap = BitmapElement.new()
    local bitMapProfile = g_gui:getProfile("fs25_multiTextOptionContainer")
    bitMap:loadProfile(bitMapProfile, true)

    local binaryOption = BinaryOptionElement.new()
    binaryOption.useYesNoTexts = true
    local binaryOptionProfile = g_gui:getProfile("fs25_settingsBinaryOption")
    binaryOption:loadProfile(binaryOptionProfile, true)
    binaryOption.target = CropStressSettingsIntegration
    binaryOption:setCallback("onClickCallback", callbackName)

    local titleElement = TextElement.new()
    local titleProfile = g_gui:getProfile("fs25_settingsMultiTextOptionTitle")
    titleElement:loadProfile(titleProfile, true)
    titleElement:setText(title)

    local tooltipElement = TextElement.new()
    local tooltipProfile = g_gui:getProfile("fs25_multiTextOptionTooltip")
    tooltipElement.name = "ignore"
    tooltipElement:loadProfile(tooltipProfile, true)
    tooltipElement:setText(tooltip)

    binaryOption:addElement(tooltipElement)
    bitMap:addElement(binaryOption)
    bitMap:addElement(titleElement)

    binaryOption:onGuiSetupFinished()
    titleElement:onGuiSetupFinished()
    tooltipElement:onGuiSetupFinished()

    frame.gameSettingsLayout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    return binaryOption
end

function CropStressSettingsIntegration:addMultiTextOption(frame, callbackName, texts, title, tooltip)
    local bitMap = BitmapElement.new()
    local bitMapProfile = g_gui:getProfile("fs25_multiTextOptionContainer")
    bitMap:loadProfile(bitMapProfile, true)

    local multiTextOption = MultiTextOptionElement.new()
    local multiTextOptionProfile = g_gui:getProfile("fs25_settingsMultiTextOption")
    multiTextOption:loadProfile(multiTextOptionProfile, true)
    multiTextOption.target = CropStressSettingsIntegration
    multiTextOption:setCallback("onClickCallback", callbackName)
    multiTextOption:setTexts(texts)

    local titleElement = TextElement.new()
    local titleProfile = g_gui:getProfile("fs25_settingsMultiTextOptionTitle")
    titleElement:loadProfile(titleProfile, true)
    titleElement:setText(title)

    local tooltipElement = TextElement.new()
    local tooltipProfile = g_gui:getProfile("fs25_multiTextOptionTooltip")
    tooltipElement.name = "ignore"
    tooltipElement:loadProfile(tooltipProfile, true)
    tooltipElement:setText(tooltip)

    multiTextOption:addElement(tooltipElement)
    bitMap:addElement(multiTextOption)
    bitMap:addElement(titleElement)

    multiTextOption:onGuiSetupFinished()
    titleElement:onGuiSetupFinished()
    tooltipElement:onGuiSetupFinished()

    frame.gameSettingsLayout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    return multiTextOption
end

-- ============================================================
-- UPDATE UI FROM CURRENT SETTINGS
-- 'frame' is the InGameMenuSettingsFrame instance.
-- ============================================================

-- Returns the 1-based index of 'target' in 'values', or 1 if not found.
local function findIndex(values, target)
    for i, v in ipairs(values) do
        if v == target then return i end
    end
    return 1
end

function CropStressSettingsIntegration:updateSettingsUI(frame)
    if not frame.cropstress_initDone then return end

    local settings = g_cropStressManager and g_cropStressManager.settings
    if settings == nil then return end

    -- Binary options: setIsChecked(bool, animateChange, sendCallback)
    if frame.cropstress_enabled then
        frame.cropstress_enabled:setIsChecked(settings.enabled == true, false, false)
    end
    if frame.cropstress_hudVisible then
        frame.cropstress_hudVisible:setIsChecked(settings.hudVisible == true, false, false)
    end
    if frame.cropstress_irrigationCosts then
        frame.cropstress_irrigationCosts:setIsChecked(settings.irrigationCosts == true, false, false)
    end
    if frame.cropstress_alertsEnabled then
        frame.cropstress_alertsEnabled:setIsChecked(settings.alertsEnabled == true, false, false)
    end
    if frame.cropstress_debugMode then
        frame.cropstress_debugMode:setIsChecked(settings.debugMode == true, false, false)
    end

    -- Multi-text options: setState(1-based index)
    if frame.cropstress_difficulty then
        frame.cropstress_difficulty:setState(
            findIndex(CropStressSettingsIntegration.difficultyValues, settings.difficulty)
        )
    end
    if frame.cropstress_evapotranspiration then
        frame.cropstress_evapotranspiration:setState(
            findIndex(CropStressSettingsIntegration.evapValues, settings.evapotranspiration)
        )
    end
    if frame.cropstress_maxYieldLoss then
        frame.cropstress_maxYieldLoss:setState(
            findIndex(CropStressSettingsIntegration.maxYieldLossValues, settings.maxYieldLoss)
        )
    end
    if frame.cropstress_criticalThreshold then
        frame.cropstress_criticalThreshold:setState(
            findIndex(CropStressSettingsIntegration.criticalThresholdValues, settings.criticalThreshold)
        )
    end
    if frame.cropstress_alertCooldown then
        frame.cropstress_alertCooldown:setState(
            findIndex(CropStressSettingsIntegration.alertCooldownValues, settings.alertCooldown)
        )
    end
end

-- ============================================================
-- SETTING APPLICATION HELPER
-- Server/SP: apply + validate + push to subsystems + broadcast.
-- Client: send to server (server validates and re-broadcasts).
-- ============================================================
local function applySetting(key, value)
    if g_cropStressManager == nil or g_cropStressManager.settings == nil then return end

    if g_server ~= nil then
        g_cropStressManager.settings[key] = value
        g_cropStressManager.settings:validateSettings()
        g_cropStressManager:applySettings()
        if CropStressSettingsSyncEvent ~= nil then
            g_server:broadcastEvent(CropStressSettingsSyncEvent.newSingle(key, value), false)
        end
    else
        if CropStressSettingsSyncEvent ~= nil then
            CropStressSettingsSyncEvent.sendSingleToServer(key, value)
        end
    end
end

-- ============================================================
-- CALLBACK HANDLERS
-- 'self' = CropStressSettingsIntegration (set as binaryOption.target)
-- Binary: state == BinaryOptionElement.STATE_RIGHT → true
-- Multi-text: state is a 1-based index
-- ============================================================

function CropStressSettingsIntegration:onEnabledChanged(state)
    applySetting("enabled", state == BinaryOptionElement.STATE_RIGHT)
end

function CropStressSettingsIntegration:onHudVisibleChanged(state)
    applySetting("hudVisible", state == BinaryOptionElement.STATE_RIGHT)
end

function CropStressSettingsIntegration:onIrrigationCostsChanged(state)
    applySetting("irrigationCosts", state == BinaryOptionElement.STATE_RIGHT)
end

function CropStressSettingsIntegration:onAlertsEnabledChanged(state)
    applySetting("alertsEnabled", state == BinaryOptionElement.STATE_RIGHT)
end

function CropStressSettingsIntegration:onDebugModeChanged(state)
    applySetting("debugMode", state == BinaryOptionElement.STATE_RIGHT)
end

function CropStressSettingsIntegration:onDifficultyChanged(state)
    applySetting("difficulty", CropStressSettingsIntegration.difficultyValues[state] or "normal")
end

function CropStressSettingsIntegration:onEvapotranspirationChanged(state)
    applySetting("evapotranspiration", CropStressSettingsIntegration.evapValues[state] or "normal")
end

function CropStressSettingsIntegration:onMaxYieldLossChanged(state)
    applySetting("maxYieldLoss", CropStressSettingsIntegration.maxYieldLossValues[state] or 0.60)
end

function CropStressSettingsIntegration:onCriticalThresholdChanged(state)
    applySetting("criticalThreshold", CropStressSettingsIntegration.criticalThresholdValues[state] or 0.25)
end

function CropStressSettingsIntegration:onAlertCooldownChanged(state)
    applySetting("alertCooldown", CropStressSettingsIntegration.alertCooldownValues[state] or 12)
end

-- ============================================================
-- HOOK INSTALLATION
-- Deferred via Mission00.loadMission00Finished to guarantee
-- InGameMenuSettingsFrame is fully initialised before we patch it.
-- Installing at source() time risks a nil-class error on some
-- FS25 build orders where the GUI classes load after mod scripts.
-- ============================================================
local function initHooks()
    -- ----------------------------------------------------------------
    -- INSTANCE-LEVEL hook (not class-level).
    --
    -- Some mods (e.g. FS25_RealisticHarvesting) hook onFrameOpen on the
    -- LIVE PAGE INSTANCE via Utils.appendedFunction at loadMission00Finished
    -- time.  An instance property shadows the class method, so any
    -- subsequent class-level patch (InGameMenuSettingsFrame.onFrameOpen = …)
    -- is never reached when the instance already owns that key.
    --
    -- We therefore hook the instance directly, exactly as RH does, so
    -- both mods' hooks coexist on the same instance chain regardless of
    -- which mod loads first.
    -- ----------------------------------------------------------------
    local settingsPage = g_gui
        and g_gui.screenControllers
        and g_gui.screenControllers[InGameMenu]
        and g_gui.screenControllers[InGameMenu].pageSettings

    if not settingsPage then
        -- Fallback: if the live page isn't available yet, patch the class.
        -- This covers bare FS25 without conflicting mods.
        if not InGameMenuSettingsFrame then
            csLog("WARNING: InGameMenuSettingsFrame not available — ESC menu integration skipped")
            return
        end
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen,
            CropStressSettingsIntegration.onFrameOpen
        )
        if InGameMenuSettingsFrame.updateGameSettings then
            InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
                InGameMenuSettingsFrame.updateGameSettings,
                CropStressSettingsIntegration.updateGameSettings
            )
        end
        csLog("ESC menu hook installed (class-level fallback)")
        return
    end

    -- Primary path: hook the instance directly.
    settingsPage.onFrameOpen = Utils.appendedFunction(
        settingsPage.onFrameOpen,
        CropStressSettingsIntegration.onFrameOpen
    )

    if settingsPage.updateGameSettings then
        settingsPage.updateGameSettings = Utils.appendedFunction(
            settingsPage.updateGameSettings,
            CropStressSettingsIntegration.updateGameSettings
        )
    end

    csLog("ESC menu hook installed")
end

-- Register hook installation for when the mission is fully loaded
-- (safe to call multiple times — Mission00.loadMission00Finished appended fn guards against double-init).
Mission00.loadMission00Finished = Utils.appendedFunction(
    Mission00.loadMission00Finished,
    function(self, ...)
        initHooks()
    end
)