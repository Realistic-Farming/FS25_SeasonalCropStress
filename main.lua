-- ============================================================
-- FS25_SeasonalCropStress — main.lua
-- Entry point. Loads all modules via source() in strict dependency
-- order, then wires up FS25 lifecycle hooks.
--
-- Load order:
--   1. Weather bridge
--   2. Core simulation (soil, stress, irrigation)
--   3. Settings
--   4. Player-facing systems (HUD, consultant)
--   5. Optional mod bridges (activated at runtime if mods present)
--   6. Event bus
--   7. Persistence
--   8. GUI dialogs
--   9. Central coordinator (depends on everything above)
-- ============================================================

local modDir = g_currentModDirectory

-- Weather bridge
source(modDir .. "src/WeatherIntegration.lua")

-- Value-map substrate (SCS-039): loads BEFORE SoilMoistureSystem, which
-- delegates to it when the engine is capable and falls back to its own
-- cell store when it is not.
source(modDir .. "src/maps/CropStressValueMap.lua")

-- Core simulation
source(modDir .. "src/SoilMoistureSystem.lua")
source(modDir .. "src/CropStressModifier.lua")
source(modDir .. "src/IrrigationManager.lua")

-- Settings
source(modDir .. "src/ReleaseGate.lua")
source(modDir .. "src/settings/CropStressSettings.lua")
source(modDir .. "src/settings/CropStressSettingsPanel.lua")
source(modDir .. "src/settings/CropStressSettingsIntegration.lua")
source(modDir .. "src/settings/SettingsHubBridge.lua")

-- Player-facing systems
source(modDir .. "src/HUDOverlay.lua")
source(modDir .. "src/CropConsultant.lua")

-- Optional mod bridges
source(modDir .. "src/NPCIntegration.lua")
source(modDir .. "src/FinanceIntegration.lua")
source(modDir .. "src/UsedEquipmentMarketplace.lua")
source(modDir .. "src/SoilFertilizerIntegration.lua")
source(modDir .. "src/CoursePlayIntegration.lua")
source(modDir .. "src/AutoDriveIntegration.lua")
source(modDir .. "src/SprayerIntegration.lua")

-- Bedrock bridges (optional, delegate-when-present against the four core APIs)
source(modDir .. "src/integrations/CropStressStateLedgerBridge.lua")
source(modDir .. "src/integrations/CropStressNetworkSyncBridge.lua")
source(modDir .. "src/integrations/CropStressMasterHUDBridge.lua")

-- Event bus
source(modDir .. "src/events/CropStressSettingsSyncEvent.lua")
source(modDir .. "src/events/CropStressMoistureInitEvent.lua")
source(modDir .. "src/events/CropStressIrrigateNowEvent.lua")

-- Persistence
source(modDir .. "src/SaveLoadHandler.lua")

-- Map overlay & PDA screen (load before CropStressManager so hooks install in time)
source(modDir .. "src/ui/CsMoistureMapOverlay.lua")
source(modDir .. "src/ui/CsMapHooks.lua")
source(modDir .. "src/ui/CsPDAScreen.lua")
-- RF Esc greenfield (NO-HOST Option B): shared door + Crop Stress module.
-- Legacy CsPDAScreen Esc tab stands down when menuRealisticFarming is live.
-- CsMapHooks left on development path (Map overlay only; no Esc MapFrame rewrite).
source(modDir .. "src/ui/RfEscModules.lua")
source(modDir .. "src/ui/RfPdaMenuPage.lua")
source(modDir .. "src/ui/RfEscBootstrap.lua")
-- DEV: Esc UIDebugger (F6). Install no-ops if Soil (or another mod) already registered.
source(modDir .. "src/ui/RfEscUiDebugger.lua")
source(modDir .. "src/ui/CsRfPdaGuest.lua")
source(modDir .. "src/ui/CsHelpDialog.lua")

-- GUI dialog loader (must precede dialog scripts)
source(modDir .. "src/gui/CsDialogLoader.lua")

-- GUI dialogs
source(modDir .. "gui/FieldMoisturePanel.lua")
source(modDir .. "gui/IrrigationScheduleDialog.lua")
source(modDir .. "gui/CropConsultantDialog.lua")

-- Central coordinator (must load last — depends on all modules above)
source(modDir .. "src/CropStressManager.lua")

-- ============================================================
-- INPUT BINDING (NPCFavor pattern — confirmed working)
-- Hook PlayerInputComponent.registerActionEvents. This is the ONLY
-- correct point to register action events in FS25; calling
-- g_inputBinding:registerActionEvent directly in loadMission00Finished
-- is not inside the player input context and silently does nothing.
-- ============================================================
local function csToggleHUDCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    if g_cropStressManager ~= nil then g_cropStressManager:onToggleHUD() end
end

local function csOpenIrrigationCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    if g_cropStressManager ~= nil then g_cropStressManager:onOpenIrrigationDialog() end
end

local function csOpenConsultantCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    if g_cropStressManager ~= nil then g_cropStressManager:onOpenConsultantDialog() end
end

local function csEditHUDCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    if g_cropStressManager ~= nil and g_cropStressManager.hudOverlay ~= nil then
        local hud = g_cropStressManager.hudOverlay
        if hud.editMode then
            hud:exitEditMode()
        elseif hud.isVisible then
            hud:enterEditMode()
        end
    end
end

local function csOpenSettingsCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    if g_cropStressManager ~= nil then g_cropStressManager:onToggleSettings() end
end

do
    if PlayerInputComponent ~= nil and PlayerInputComponent.registerActionEvents ~= nil then
        local origFn = PlayerInputComponent.registerActionEvents
        PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
            origFn(inputComponent, ...)
            if inputComponent.player ~= nil and inputComponent.player.isOwner then
                g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                local function reg(actionId, callback, labelKey, labelFallback)
                    if actionId == nil then return end
                    local ok, eventId = g_inputBinding:registerActionEvent(
                        actionId, CropStressManager, callback,
                        false, true, false, false, nil, true
                    )
                    if ok and eventId ~= nil then
                        g_inputBinding:setActionEventActive(eventId, true)
                        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
                        local label = (g_i18n ~= nil and g_i18n:getText(labelKey)) or labelFallback
                        g_inputBinding:setActionEventText(eventId, label)
                    end
                end

                reg(InputAction.CS_TOGGLE_HUD,      csToggleHUDCallback,      "input_CS_TOGGLE_HUD",      "Toggle Moisture HUD")
                reg(InputAction.CS_OPEN_IRRIGATION, csOpenIrrigationCallback, "input_CS_OPEN_IRRIGATION", "Open Irrigation Manager")
                reg(InputAction.CS_OPEN_CONSULTANT, csOpenConsultantCallback, "input_CS_OPEN_CONSULTANT", "Open Crop Consultant")
                reg(InputAction.CS_EDIT_HUD,        csEditHUDCallback,        "input_CS_EDIT_HUD",        "Edit/Move Moisture HUD")
                reg(InputAction.CS_OPEN_SETTINGS,   csOpenSettingsCallback,   "input_CS_OPEN_SETTINGS",   "Open Crop Stress Settings")

                g_inputBinding:endActionEventsModification()
            end
        end
        print("[CropStress] PlayerInputComponent hook installed")
    else
        print("[CropStress] WARNING: PlayerInputComponent.registerActionEvents not available — keybinds will not work")
    end
end

-- ============================================================
-- VEHICLE INPUT HOOK
-- Register CS_TOGGLE_HUD and CS_EDIT_HUD in the vehicle input context so
-- Shift+M and Shift+H work while driving (PlayerInputComponent context is
-- on-foot only; vehicles require a separate registration via Vehicle).
-- ============================================================
do
    if Vehicle ~= nil and type(Vehicle.registerActionEvents) == "function" then
        Vehicle.registerActionEvents = Utils.appendedFunction(
            Vehicle.registerActionEvents,
            function(vehicle, isActiveForInput, isSelected)
                if not isActiveForInput then return end
                if not g_inputBinding then return end

                local function regV(actionId, callback)
                    if actionId == nil then return end
                    g_inputBinding:registerActionEvent(
                        actionId, CropStressManager, callback,
                        false, true, false, true
                    )
                end

                regV(InputAction.CS_TOGGLE_HUD,    csToggleHUDCallback)
                regV(InputAction.CS_EDIT_HUD,      csEditHUDCallback)
                regV(InputAction.CS_OPEN_SETTINGS, csOpenSettingsCallback)
            end
        )
        print("[CropStress] Vehicle action hook installed for in-vehicle HUD keys")
    else
        print("[CropStress] WARNING: Vehicle.registerActionEvents not available — in-vehicle keybinds disabled")
    end
end

-- ============================================================
-- Lifecycle reference -- set in Mission00.load, cleared in FSBaseMission.delete
-- ============================================================
local g_csManager = nil

-- 1. Mission load: create the manager
Mission00.load = Utils.appendedFunction(Mission00.load, function(self, ...)
    g_csManager = CropStressManager.new()
    getfenv(0)["g_cropStressManager"] = g_csManager
    -- Cross-mod bridge: g_currentMission is a shared C++ object visible to all mods.
    -- getfenv(0) is per-mod scoped in FS25; use mission property for reliable cross-mod detection.
    self.cropStressManager = g_csManager
    print("[CropStress] CropStressManager created (v1.2.0.0)")
end)

-- 2. Mission fully loaded: initialize all systems
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function(self, ...)
    if g_csManager == nil then return end

    g_csManager:initialize()

    -- Register with SettingsHub (if installed) so FarmTablet's System Settings
    -- app can list Seasonal Crop Stress' settings. No-ops safely if absent.
    SeasonalSettingsHubBridge.register(g_csManager)

    -- Register with StateLedger (if installed) so crop-stress state persists into
    -- the shared master save file. careerSavegame.xml stays the safety fallback.
    -- No-ops safely if absent.
    CropStressStateLedgerBridge.register(g_csManager)

    -- Register with NetworkSync (if installed) so the hourly moisture/stress
    -- broadcast batches through NetworkSync's 1Hz map. The join full-sync and the
    -- moisture event class stay as the fallback. No-ops safely if absent.
    CropStressNetworkSyncBridge.register(g_csManager)

    -- Register with MasterHUD (if installed) so the crop-stress HUD draws through
    -- its single suspend-aware loop; the FSBaseMission.draw hook stands down when
    -- active. No-ops safely if absent.
    CropStressMasterHUDBridge.register(g_csManager)

    -- Install field-ready updater immediately after initialize (NPCFavor pattern).
    -- The updater polls g_currentMission.isMissionStarted + g_fieldManager.fields
    -- each frame and self-removes once enumeration succeeds.
    g_csManager:installFieldReadyUpdater()

    -- Register dialogs with CsDialogLoader (NPCFavor confirmed pattern).
    -- Dialogs are lazily loaded on first CsDialogLoader.show() call:
    --   ensureLoaded() creates the instance + calls g_gui:loadGui()
    --   → g_gui:loadGui() calls onCreate() → superClass().onCreate() auto-wires elements
    --   show() calls the data setter BEFORE g_gui:showDialog() fires onOpen()
    -- No stored instance references needed on g_csManager.
    CsDialogLoader.init(modDir)
    CsDialogLoader.register("IrrigationScheduleDialog", IrrigationScheduleDialog, "gui/IrrigationScheduleDialog.xml")
    CsDialogLoader.register("CropConsultantDialog",     CropConsultantDialog,     "gui/CropConsultantDialog.xml")
    CsDialogLoader.register("CsHelpDialog",             CsHelpDialog,             "xml/gui/CsHelpDialog.xml")

    -- Register PDA screen with InGameMenu
    if CsPDAScreen ~= nil then
        CsPDAScreen.register(modDir)
    end

    -- Register console debug commands
    if addConsoleCommand ~= nil then
        addConsoleCommand("csHelp",        "List all CropStress debug commands",                           "consoleHelp",        g_csManager)
        addConsoleCommand("csStatus",      "Print full system status to log",                              "consoleStatus",      g_csManager)
        addConsoleCommand("csSetMoisture", "Set field moisture: csSetMoisture <fieldId> <0.0-1.0>",        "consoleSetMoisture", g_csManager)
        addConsoleCommand("csForceStress", "Force maximum stress: csForceStress <fieldId>",                "consoleForceStress", g_csManager)
        addConsoleCommand("csSimulateHeat","Simulate heat wave: csSimulateHeat <days>",                    "consoleSimulateHeat",g_csManager)
        addConsoleCommand("csDebug",       "Toggle verbose debug logging",                                 "consoleToggleDebug", g_csManager)
        addConsoleCommand("csConsultant",  "Open the Crop Consultant dialog",                              "consoleConsultant",  g_csManager)
        addConsoleCommand("csRelease",     "Release gate: show STABLE vs experimental-LOCKED systems",     "consoleRelease",     g_csManager)
    end
end)

-- 3. Per-frame update
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(self, dt)
    if g_csManager ~= nil then g_csManager:update(dt) end
    -- Retry PDA registration each frame until InGameMenu is ready
    if CsPDAScreen ~= nil then CsPDAScreen._attemptDeferredRegister(dt) end
    -- Harvest-hook liveness backstop (see the install block near the bottom of this
    -- file). Guarded on the specialization actually being present so a genuinely
    -- absent Cutter cannot spam its skip message once per frame; the flag makes this
    -- a single boolean test for the rest of the session once the hook lands.
    if CropStressModifier ~= nil and not CropStressModifier.harvestHookInstalled
       and Cutter ~= nil and type(Cutter.processCutterArea) == "function" then
        CropStressModifier.installHarvestHook()
    end
end)

-- 4. Draw hook (HUD rendering)
-- When FS25_MasterHUD is installed it owns our draw (its single suspend-aware loop
-- calls CropStressMasterHUDBridge.drawStack), so this hook stands down to avoid
-- double drawing. When MasterHUD is absent this hook runs the exact same body via
-- drawStack, so the two paths can never diverge.
FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(self)
    if CropStressMasterHUDBridge ~= nil and CropStressMasterHUDBridge.active then return end
    if CropStressMasterHUDBridge ~= nil then
        CropStressMasterHUDBridge.drawStack()
    elseif g_csManager ~= nil then
        g_csManager:draw()
    end
end)

-- 5. Cleanup on mission unload
FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, function(self)
    -- Reset dialog instances so the next mission load creates fresh ones.
    CsDialogLoader.cleanup()

    -- Retained deep page must not survive a mission unload.
    if CsPDAScreen ~= nil then
        CsPDAScreen._retainedDeepScreen = nil
    end

    if g_csManager ~= nil then
        g_csManager:delete()
        g_csManager = nil
        getfenv(0)["g_cropStressManager"] = nil
        if g_currentMission then g_currentMission.cropStressManager = nil end
        if removeConsoleCommand ~= nil then
            removeConsoleCommand("csHelp")
            removeConsoleCommand("csStatus")
            removeConsoleCommand("csSetMoisture")
            removeConsoleCommand("csForceStress")
            removeConsoleCommand("csSimulateHeat")
            removeConsoleCommand("csDebug")
            removeConsoleCommand("csConsultant")
            removeConsoleCommand("csRelease")
        end
    end
end)

-- 6. Save
-- 'self' here is the FSCareerMissionInfo object, which IS the missionInfo
-- (it has savegameDirectory, xmlFile, etc. — same object CropStressSettings:load() receives).
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function(self, xmlFile)
    if g_csManager == nil then return end
    -- Save field moisture / stress / irrigation schedules into careerSavegame.xml
    g_csManager:saveToXMLFile(xmlFile)
    -- Save settings into separate sidecar cropStressSettings.xml
    if g_csManager.settings ~= nil then
        g_csManager.settings:saveToXMLFile(self)
    end
end)

-- 7. Mission start: load settings, install field-ready updater (NPCFavor pattern),
--    load saved field data. Field enumeration itself happens inside the updater
--    once g_currentMission.isMissionStarted + g_fieldManager.fields are ready.
Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function(self, ...)
    if g_csManager == nil then return end

    -- FocusManager nil-node guard — installed here where FocusManager is guaranteed available
    if type(FocusManager) == "table" and type(FocusManager.loadSharedI3DFileFinished) == "function" then
        if not FocusManager._csNilNodeGuardInstalled then
            local origFn = FocusManager.loadSharedI3DFileFinished
            FocusManager.loadSharedI3DFileFinished = function(fm, i3dNode, failedReason, args)
                if i3dNode == nil then
                    print("[CropStress] FocusManager nil-node guard triggered — suppressed")
                    return
                end
                return origFn(fm, i3dNode, failedReason, args)
            end
            FocusManager._csNilNodeGuardInstalled = true
            print("[CropStress] FocusManager nil-node guard applied")
        end
    end

    -- Load settings first so subsystems get correct thresholds before fields init
    if self.missionInfo ~= nil then
        g_csManager.settings:load(self.missionInfo)
        g_csManager:applySettings()
    end

    -- Install the self-removing frame updater that waits for g_fieldManager.fields
    -- to be populated, then enumerates fields and builds the fieldId map exactly once.
    g_csManager:installFieldReadyUpdater()

    -- Load saved moisture/stress/irrigation state (fresh game = no-op)
    g_csManager:loadFromXMLFile()
end)

-- 8a. Install the harvest yield hook.
--
-- HISTORY, kept because the old comment here was confidently wrong and cost us a
-- shipped-but-dead feature. It claimed FSBaseMission.onAllVehiclesLoaded was "the
-- first guaranteed-safe hook point" and cited NPCFavor and CoursePlay as witnesses.
-- NEITHER MOD USES IT, it appears in no reference doc, and it never fires: a full
-- session log contains none of installHarvestHook's three outcome lines (success or
-- either skip). Cutter.processCutterArea was therefore never wrapped and the yield
-- penalty had never run on any save. Certified in-game 2026-07-30 by forcing stress
-- to 1.0 and measuring litres per area across the harvest: a flat 0.4 L/m2 before
-- and after, i.e. no reduction at all.
--
-- Mission00.onStartMission is the proven point. SoilFertilizer installs its own
-- vehicle-specialization hooks there (Combine.addCutterArea,
-- FillUnit.addFillUnitFillLevel, Mower.onStartWorkAreaProcessing) and all three
-- install successfully every session, so the Cutter specialization is registered by
-- then. Cutter:processCutterArea(workArea, dt) is confirmed in the Community LUADOC
-- (Cutter.md:1853, registered via SpecializationUtil.registerFunction).
--
-- The per-frame retry in FSBaseMission.update below is the liveness backstop: if the
-- specialization is somehow not ready at onStartMission, we keep trying instead of
-- silently doing nothing for the rest of the session. installHarvestHook() sets
-- harvestHookInstalled only on success, so the retry costs one boolean test per frame
-- once it lands, and a genuine "Cutter absent" case still logs its reason.
Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function(self, ...)
    if not CropStressModifier.harvestHookInstalled then
        CropStressModifier.installHarvestHook()
    end
end)

-- 8. Multiplayer: send initial state to new client
FSBaseMission.sendInitialClientState = Utils.appendedFunction(
    FSBaseMission.sendInitialClientState,
    function(self, connection, objectId, farmId)
        if g_csManager ~= nil then g_csManager:sendInitialClientState(connection) end
    end
)

-- 9. Mouse events — RMB repositions the HUD panel.
-- addModEventListener is the correct FS25 pattern for raw mouse input in mods.
-- FS25 button numbers: 1=left, 3=right, 2=middle (confirmed via FS25_NPCFavor).
--
-- Defensive stubs for the listener table. Per confirmed FS25_NPCFavor research, FS25 DOES
-- nil-check before calling keyEvent/update/draw/delete — ESC works correctly without stubs
-- (NPCFavor omits them and ESC functions fine). These stubs are kept as defensive practice
-- only; they do NOT prevent any crash.
addModEventListener({
    update   = function(self, dt) end,
    draw     = function(self) end,
    delete   = function(self) end,
    keyEvent = function(self, unicode, sym, modifier, isDown) end,
    mouseEvent = function(self, posX, posY, isDown, isUp, button)
        if g_csManager == nil then return end
        if g_gui ~= nil and g_gui:getIsGuiVisible() then return end
        -- Settings panel gets full mouse priority when open
        if g_csManager.settingsPanel ~= nil and g_csManager.settingsPanel:isOpen() then
            g_csManager.settingsPanel:onMouseEvent(posX, posY, isDown, isUp, button)
            return
        end
        if g_csManager.hudOverlay == nil then return end
        g_csManager.hudOverlay:onMouseEvent(posX, posY, isDown, isUp, button)
    end
})