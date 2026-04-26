-- ============================================================
-- CropStressSettingsIntegration.lua
-- Injects a minimal hint into ESC > Settings > Game Settings.
-- Full settings live in the custom panel (SHIFT+S).
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

-- ── Frame open hook ───────────────────────────────────────────
local function onFrameOpen(frame)
    if frame.cropstress_hintDone then return end

    -- Support both layout property names (vanilla vs some mods)
    if frame.gameSettingsLayout == nil and frame.generalSettingsLayout ~= nil then
        frame.gameSettingsLayout = frame.generalSettingsLayout
    end
    if frame.gameSettingsLayout == nil then
        frame.cropstress_hintDone = true
        return
    end

    local ok, err = pcall(function()
        local textElement = TextElement.new()
        local profile = g_gui:getProfile("fs25_settingsSectionHeader")
        textElement.name = "sectionHeader"
        textElement:loadProfile(profile, true)
        textElement:setText("Seasonal Crop Stress  (SHIFT+S for full settings)")
        frame.gameSettingsLayout:addElement(textElement)
        textElement:onGuiSetupFinished()

        frame.gameSettingsLayout:invalidateLayout()
        if frame.updateAlternatingElements then
            frame:updateAlternatingElements(frame.gameSettingsLayout)
        end
    end)

    frame.cropstress_hintDone = true

    if not ok then
        csLog("WARNING: ESC settings hint injection failed: " .. tostring(err))
    else
        csLog("ESC menu: Seasonal Crop Stress hint injected (SHIFT+S)")
    end
end

-- ── Hook installation ─────────────────────────────────────────
local function initHooks()
    local settingsPage = g_gui
        and g_gui.screenControllers
        and g_gui.screenControllers[InGameMenu]
        and g_gui.screenControllers[InGameMenu].pageSettings

    if settingsPage then
        settingsPage.onFrameOpen = Utils.appendedFunction(
            settingsPage.onFrameOpen, onFrameOpen)
        csLog("ESC menu hook installed (instance-level)")
    elseif InGameMenuSettingsFrame then
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen, onFrameOpen)
        csLog("ESC menu hook installed (class-level fallback)")
    else
        csLog("WARNING: InGameMenuSettingsFrame not available — ESC menu hint skipped")
    end
end

Mission00.loadMission00Finished = Utils.appendedFunction(
    Mission00.loadMission00Finished,
    function(self, ...)
        initHooks()
    end
)
