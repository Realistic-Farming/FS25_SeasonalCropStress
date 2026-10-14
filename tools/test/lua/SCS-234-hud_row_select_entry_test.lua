--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, tools/test/lua/scs234_listener_world.lua, main.lua
-- Issue #234 (joeynuggetz, on 1.2.6.0): a field row in the moisture HUD could not be
-- selected, so the 5-day forecast never filled.
--   A. Edit mode: the press on the fields pane started a drag at once, so every
--      release ended a drag and never reached row select.
--   B. In a cab, outside edit mode: isPlayerInVehicle read fields the 1.24 engine never
--      sets, so the cab's click path never armed.
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs: its Mission00.load creates the
-- manager through the real CropStressManager.new() and its loadMission00Finished runs
-- the real initialize(). Every click goes in through the mouse listener main.lua
-- registers with addModEventListener (main.lua:523-539), kept by
-- scs234_listener_world.lua, and is delivered as the engine delivers it. Set by hand:
-- the HUD's visibility and its rows (data the manager's update would fill), and the
-- player. The player follows the 1.24 engine: g_localPlayer stays set while seated and
-- answers getCurrentVehicle() (Player.lua:979; nil on foot,
-- PlayerOnFootStateMachine.lua:67; the vehicle when driving, PlayerStateDriving.lua:83).
--
-- Groups: E the wiring, A edit mode, B outside edit mode, V the vehicle check and what
-- it wakes.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
end

local function quiet(fn)
    local realPrint = print
    print = function() end
    local ok, err = pcall(fn)
    print = realPrint
    if not ok then error(err, 0) end
end

-- The player, as the 1.24 engine shows it to a mod.
local VEHICLE = { id = "tractor" }
local seated = false
g_localPlayer = { getCurrentVehicle = function(_self) if seated then return VEHICLE end return nil end }

-- Camera spy: enterEditMode reads the free-roam camera only on foot.
local camReads = 0
function getCamera() return 1 end
function getRotation(_cam) camReads = camReads + 1; return 0.1, 0.2, 0.3 end
function setRotation() end

g_inputBinding = g_inputBinding or {}
g_inputBinding.setShowMouseCursor = function() end

local mission = g_currentMission
local listener, hud, homeX, homeY

local LMB, RMB = 1, 3
local function mouse(x, y, isDown, isUp, button)
    listener.mouseEvent(listener, x, y, isDown, isUp, button)
end
local function press(x, y, b)   mouse(x, y, true, false, b or LMB) end
local function release(x, y, b) mouse(x, y, false, true, b or LMB) end
local function move(x, y)       mouse(x, y, false, false, 0) end

-- The point at the middle of row i, from the geometry the draw path paints rows with
-- (HUDOverlay.lua: rowY = py + panelH - headerH - i * rowH), a third of the way in.
local function rowPoint(i)
    local s = hud.scale
    local rowH, headerH = HUDOverlay.ROW_H * s, HUDOverlay.HEADER_H * s
    local panelH = hud:calcPanelHeight(math.min(#hud.displayRows, HUDOverlay.MAX_FIELDS))
    local rowY = hud.panelY + panelH - headerH - i * rowH
    return hud.panelX + hud:getPanelW() / 3, rowY + rowH / 2
end
local function headerPoint()
    local s = hud.scale
    local headerH = HUDOverlay.HEADER_H * s
    local panelH = hud:calcPanelHeight(math.min(#hud.displayRows, HUDOverlay.MAX_FIELDS))
    return hud.panelX + hud:getPanelW() / 3, hud.panelY + panelH - headerH / 2
end

local function fresh()
    if hud.editMode then hud:exitEditMode() end
    hud.selectedFieldId, hud.forecastCache, hud.forecastDirty = nil, nil, false
    hud.panelX, hud.panelY = homeX, homeY
    seated, camReads = false, 0
end

-- Edit mode on foot the way a player enters it: right-click the HUD's header.
local function editOnFoot()
    local x, y = headerPoint()
    press(x, y, RMB)
end

group("E wiring", function()
    quiet(function() Mission00.load(mission) end)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    local mgr = mission.cropStressManager
    T.ok("E1 [reached: main.lua's Mission00.load created the manager]", mgr ~= nil)
    hud = mgr and mgr.hudOverlay
    T.ok("E2 [reached: initialize() built the real HUDOverlay]", hud ~= nil and getmetatable(hud) ~= nil)
    local n = 0
    for _, l in ipairs(SCS234Listeners) do
        if l.mouseEvent ~= nil then listener = l; n = n + 1 end
    end
    T.eq("E3 [reached: main.lua registered exactly one mouse listener]", n, 1)
    hud.isVisible = true
    hud.displayRows = { { fieldId = 5 }, { fieldId = 36 }, { fieldId = 12 } }
    homeX, homeY = hud.panelX, hud.panelY
    fresh()
    editOnFoot()
    T.ok("E4 [reached: a right-click on the header enters edit mode on foot]", hud.editMode == true)
    T.eq("E5 [reached: and selects no row]", hud.selectedFieldId, nil)
end)

group("A edit mode", function()
    fresh(); editOnFoot()
    local x, y = rowPoint(2)
    press(x, y); release(x, y)
    T.eq("A1 NAMED: in edit mode a left press and release in place on row 2 selects its field", hud.selectedFieldId, 36)
    T.ok("A2 and asks for the forecast", hud.forecastDirty == true)
    T.eq("A3 the pane stays where it was (x)", hud.panelX, homeX)
    T.eq("A4 the pane stays where it was (y)", hud.panelY, homeY)

    press(x, y); release(x, y)
    T.eq("A5 a second click on the same row clears the selection, as before", hud.selectedFieldId, nil)

    fresh(); editOnFoot()
    x, y = rowPoint(1)
    press(x, y); move(x + 0.002, y - 0.001); release(x + 0.002, y - 0.001)
    T.eq("A6 NAMED: a press that wobbles inside the click slop is still a click on row 1", hud.selectedFieldId, 5)
    T.eq("A7 NAMED: and the pane goes back exactly to where the press found it (x)", hud.panelX, homeX)
    T.eq("A8 and (y)", hud.panelY, homeY)

    fresh(); editOnFoot()
    x, y = rowPoint(1)
    press(x, y); move(x + 0.05, y); release(x + 0.05, y)
    T.eq("A9 NAMED: a real drag selects nothing", hud.selectedFieldId, nil)
    T.near("A10 and moves the pane by the drag", hud.panelX, homeX + 0.05, 1e-9)
    T.near("A11 and saves where it went", mission.cropStressManager.settings.hudPanelX, homeX + 0.05, 1e-9)

    fresh(); editOnFoot()
    x, y = rowPoint(1)
    press(x, y); move(x + 0.05, y); move(x, y); release(x, y)
    T.eq("A12 NAMED: a drag that comes back to where it started is still a drag, not a click", hud.selectedFieldId, nil)

    fresh(); editOnFoot()
    local fx, fy, fw, fh = hud:getForecastRect()
    press(fx + fw / 2, fy + fh / 2); release(fx + fw / 2, fy + fh / 2)
    T.eq("A13 a press and release in place on the forecast pane selects nothing", hud.selectedFieldId, nil)
end)

group("B outside edit mode", function()
    fresh(); seated = true
    local x, y = rowPoint(3)
    press(x, y); release(x, y)
    T.eq("B1 NAMED: in a cab, outside edit mode, a left click on row 3 selects its field", hud.selectedFieldId, 12)
    T.ok("B2 and asks for the forecast", hud.forecastDirty == true)

    fresh(); seated = false
    x, y = rowPoint(3)
    press(x, y); release(x, y)
    T.eq("B3 on foot, outside edit mode, a left click still does nothing, as before", hud.selectedFieldId, nil)
    T.ok("B4 and does not enter edit mode", hud.editMode == false)
end)

group("V the vehicle check", function()
    fresh(); seated = true
    T.ok("V1 NAMED: isPlayerInVehicle is true while getCurrentVehicle() returns the vehicle", hud:isPlayerInVehicle() == true)
    seated = false
    T.ok("V2 and false on foot", hud:isPlayerInVehicle() == false)

    fresh(); seated = true
    local x, y = headerPoint()
    press(x, y, RMB)
    T.ok("V3 NAMED: in a cab a right-click on the HUD does not enter edit mode (HUDOverlay.lua's RMB rule)", hud.editMode == false)

    fresh(); seated = false
    hud:enterEditMode()
    T.eq("V4 on foot, entering edit mode reads the free-roam camera once", camReads, 1)
    fresh(); seated = true
    hud:enterEditMode()
    T.eq("V5 NAMED: in a cab, entering edit mode (the CS_EDIT_HUD key, main.lua:186) leaves the vehicle camera alone", camReads, 0)
end)
