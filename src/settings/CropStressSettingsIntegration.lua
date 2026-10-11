CropStressSettingsIntegration = CropStressSettingsIntegration or {}

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
function CropStressSettingsIntegration.headerText()
    local base = "Seasonal Crop Stress"
    -- get() returns a localized status word when nothing is bound, so the old
    -- form read "(Unbound for full settings)". Only a live chord earns the
    -- parenthetical; every other kind leaves the bare section name.
    if CsLiveKeyLabel ~= nil and CsLiveKeyLabel.resolve ~= nil then
        local chord, kind = CsLiveKeyLabel.resolve("CS_OPEN_SETTINGS")
        if kind == "live" and type(chord) == "string" and chord ~= "" then
            return base .. "  (" .. chord .. " for full settings)"
        end
    end
    return base
end

-- The hint is injected once per frame open, and the global message centre lives
-- for the whole game session without deduping subscribers, so subscribing here
-- unconditionally added one closure over a dead text element per mission load.
-- At most one subscription is held: the previous is released before a new one
-- is taken, and teardown releases it.
local csHeaderUnsubscribe = nil

local function csReleaseHeaderSubscription()
    if csHeaderUnsubscribe ~= nil then
        pcall(csHeaderUnsubscribe)
        csHeaderUnsubscribe = nil
    end
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
        textElement:setText(CropStressSettingsIntegration.headerText())
        if CsLiveKeyLabel ~= nil and CsLiveKeyLabel.subscribe ~= nil then
            csReleaseHeaderSubscription()
            csHeaderUnsubscribe = CsLiveKeyLabel.subscribe(textElement, function()
                pcall(function() textElement:setText(CropStressSettingsIntegration.headerText()) end)
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

-- Release the binding-change subscription with the mission, so a second mission
-- in one session cannot inherit the first mission's text element.
if FSBaseMission ~= nil and Utils ~= nil and Utils.prependedFunction ~= nil then
    FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, function()
        csReleaseHeaderSubscription()
    end)
end
