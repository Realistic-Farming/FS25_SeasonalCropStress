-- ============================================================
-- CropStressSettingsIntegration.lua
-- Injects a minimal hint into ESC > Settings > Game Settings.
-- Full settings live in the custom panel, opened by the Open Crop Stress
-- Settings action. The chord is never hardcoded here; it is read live.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

-- ── Frame open hook ───────────────────────────────────────────
-- The settings hint is injected once per frame (cropstress_hintDone), so the
-- label has to be rebuilt when a binding changes rather than cached. Returns the
-- header with the live chord, or the bare name when no chord can be resolved:
-- a factory default is never presented as if it were the live binding.
local function csHeaderText()
    local base = "Seasonal Crop Stress"
    if CsLiveKeyLabel ~= nil and CsLiveKeyLabel.get ~= nil then
        local chord = CsLiveKeyLabel.get("CS_OPEN_SETTINGS")
        if type(chord) == "string" and chord ~= "" then
            return base .. "  (" .. chord .. " for full settings)"
        end
    end
    return base
end

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
        textElement:setText(csHeaderText())
        if CsLiveKeyLabel ~= nil and CsLiveKeyLabel.subscribe ~= nil then
            CsLiveKeyLabel.subscribe(textElement, function()
                pcall(function() textElement:setText(csHeaderText()) end)
            end)
        end
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
        csLog("ESC menu: Seasonal Crop Stress hint injected")
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
