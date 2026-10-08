--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/events/CropStressSettingsSyncEvent.lua, src/SoilFertilizerIntegration.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE rows 247, 262 and 263: SCS's HUD shows Soil's field pressures in a game.
--
-- Row 247: HUDOverlay:rebuildDisplayRows read Soil through the bare global g_SoilFertilityManager
-- (src/HUDOverlay.lua:1520 at a6757f7). Soil writes that global into its own mod environment
-- (getfenv(0), SoilFertilizer main.lua:758), so the read was nil in a game and the HUD's Soil
-- strip never drew, while the block's own gate passed because SCS detects Soil through the mission
-- (src/SoilFertilizerIntegration.lua:114, :145-148). It now reads the mission first.
-- Row 262: the strip tested Soil's weed, pest and disease pressures with "> 0.15", but Soil's
-- pressures run 0 to 100 (SoilFertilizer src/integrations/SoilNetworkSyncBridge.lua:74), so with
-- the handle fixed it would light on nearly every field. The threshold is now 15 on that scale.
-- Row 263: D read the raw diseasePressure, so it would show an infection Soil has not revealed yet.
-- It now reads getFieldInfo's shownDiseasePressure, nil until the field is scouted
-- (SoilFertilitySystem.lua:8398-8399), as Soil's own HUD does (SoilHUD.lua:1036).
-- Bob's review of #228: Soil stops growing and reducing a pressure while its system is off, so a
-- switched-off system keeps its last value. The strip now honours Soil's on/off switches as Soil's
-- own HUD rows do (SoilHUD.lua:433-444): W, P and D only while that system is on, and nothing for
-- a field whose sim Soil has disabled (getFieldInfo's simDisabled).
--
-- THE ENTRY-POINT BAR IS GROUP E. main.lua itself runs (maint165_main_world.lua, the load list of
-- MAINTENANCE row 259's bench with src/SoilFertilizerIntegration.lua added, so the integration is
-- the real class, not the manager's no-op stand-in). Soil is modelled in its own mod environment,
-- built as dataS mods.lua:482-520 builds one (__index = _G, _G the env itself, getfenv(0) mapped to
-- it); its load puts the manager into that environment and onto the mission (main.lua:758, :761),
-- and its getFieldInfo returns the keys the strip reads from per-field state, on Soil's 0 to 100
-- scale, with shownDiseasePressure gated as SoilFertilitySystem.lua:8398-8399 gates it, and simDisabled;
-- the manager carries Soil's settings (weedPressure, pestPressure, diseasePressure), all on at start. The engine side is three fields in g_fieldManager.fields (farmlands 7, 8 and 9, the
-- ids SCS enumerates by) owned by farm 1, and the render primitives, with renderText recorded.
-- Mission00.load and loadMission00Finished build the manager, its HUD and its Soil integration;
-- the player's HUD key (CropStressManager:onToggleHUD) shows the HUD; FSBaseMission.update runs
-- the HUD's throttled rebuild; FSBaseMission.draw draws it. Nothing writes a row, a field record or
-- a Soil reading by hand.
--
--   E0  the world: SCS's environment has no g_SoilFertilityManager; Soil's has it
--   E1  main.lua built the manager, its HUD and an active Soil integration
--   E2  after main.lua's update, each field's HUD row carries Soil's reading for that field
--   E3  main.lua's draw shows "W P D" on field 7 (weeds 50, pests 30, scouted disease 20), none on field 8
--       (weeds 10, pests 5, disease 3: all under 15, each above the old 0.15, so each letter's
--       threshold is pinned by its own row), and no D on field 9 (disease 60, not yet scouted)
--   E4  once Soil reveals field 9's infection, the next rebuild and draw show its D
--   E5  Soil's switches: with weeds off field 7 shows "P D", with pests off "W D", with disease off
--       "W P" and field 9 no D (Soil then returns the raw value), and with field 7's sim disabled
--       field 7 shows nothing

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
Logging = Logging or { info = function() end, warning = function() end, error = function() end, devInfo = function() end }

local mission = g_currentMission

-- ── the engine: two fields owned by farm 1, and the render primitives ──────────
g_fieldManager = { fields = {
    { farmland = { id = 7 }, posX = 10, posZ = 10 },
    { farmland = { id = 8 }, posX = 90, posZ = 90 },
    { farmland = { id = 9 }, posX = 170, posZ = 170 },
} }
g_farmlandManager = { farmlandMapping = { [7] = 1, [8] = 1, [9] = 1 } }
mission.player = { farmId = 1 }

local TEXT = {}
function createImageOverlay() return 1 end
function setOverlayColor() end
function renderOverlay() end
function setTextColor() end
function setTextBold() end
function setTextAlignment() end
function getTextWidth(_size, text) return #tostring(text or "") * 0.005 end
function renderText(_x, _y, _size, text) TEXT[#TEXT + 1] = tostring(text) end
-- The engine's text alignment table (C-side; no Lua definition in dataS); the recorder ignores alignment.
RenderText = RenderText or { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
g_gui = g_gui or { getIsGuiVisible = function() return false end }

-- ── Soil, in its own mod environment (mods.lua:482-520) ─────────────────────────
local soilEnv = setmetatable({}, { __index = _G })
soilEnv._G = soilEnv
soilEnv.getfenv = function() return soilEnv end
local SOIL_LOAD = [==[
local mission = ...
-- Per-field state on Soil's own 0 to 100 scale (SoilNetworkSyncBridge.lua:74).
local FIELDS = {
    [7] = { weedPressure = 50, pestPressure = 30, diseasePressure = 20, diseaseDiscovered = true },
    [8] = { weedPressure = 10, pestPressure = 5, diseasePressure = 3,  diseaseDiscovered = true },
    [9] = { weedPressure = 0,  pestPressure = 0, diseasePressure = 60, diseaseDiscovered = false },
}
-- Soil's on/off switches (SoilHUD.lua:437-442 reads them as mgr.settings.*), all on at start.
local settings = { weedPressure = true, pestPressure = true, diseasePressure = true }
local sfm = { soilSystem = { calls = 0 }, settings = settings }
function sfm.soilSystem:getFieldInfo(fieldId)
    self.calls = self.calls + 1
    local f = FIELDS[fieldId]
    if f == nil then return nil end
    return { weedPressure = f.weedPressure, pestPressure = f.pestPressure,
             diseasePressure = f.diseasePressure, needsFertilization = false,
             simDisabled = f.simDisabled == true,
             -- SoilFertilitySystem.lua:8398-8399: nil until scouted while the disease system is on.
             shownDiseasePressure = (f.diseaseDiscovered or not settings.diseasePressure)
                 and f.diseasePressure or nil }
end
-- Soil's scouting reveal: the field's diseaseDiscovered flag turns on.
function sfm.reveal(fieldId) FIELDS[fieldId].diseaseDiscovered = true end
-- Soil's FieldSentry state for a field (getFieldInfo's simDisabled).
function sfm.setSimDisabled(fieldId, v) FIELDS[fieldId].simDisabled = v end
-- main.lua:758 and :761 at 437ca320.
getfenv(0)["g_SoilFertilityManager"] = sfm
mission.soilFertilityManager = sfm
return sfm
]==]
local sfm = assert(load(SOIL_LOAD, "=SoilFertilizer main.lua (model)", "t", soilEnv))(mission)

local function rowFor(hud, fieldId)
    for _, r in ipairs(hud.displayRows or {}) do
        if r.fieldId == fieldId then return r end
    end
    return nil
end

group("E0", function()
    T.eq("E0 SCS's environment has no g_SoilFertilityManager", g_SoilFertilityManager, nil)
    T.ok("E0 Soil's own environment has it, and the mission carries it",
        soilEnv.g_SoilFertilityManager == sfm and mission.soilFertilityManager == sfm)
end)

group("E1", function()
    quiet(function() Mission00.load(mission) end)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    local mgr = mission.cropStressManager
    T.ok("E1 [reached] main.lua built the manager and its HUD", mgr ~= nil and mgr.hudOverlay ~= nil)
    local sfi = mgr and mgr.soilFertilizerIntegration
    T.eq("E1 the Soil integration is the real class and active (Soil detected through the mission)",
        sfi ~= nil and getmetatable(sfi) ~= nil and sfi:isActive(), true)
end)

group("E2", function()
    local mgr = mission.cropStressManager
    local hud = mgr.hudOverlay
    quiet(function() mgr:onToggleHUD() end)
    T.eq("E2 [reached] the player's HUD key shows the HUD", hud.isVisible, true)
    quiet(function() FSBaseMission.update(mission, 1000) end)
    quiet(function() FSBaseMission.update(mission, 1000) end)
    local r7, r8 = rowFor(hud, 7), rowFor(hud, 8)
    T.ok("E2 [reached] main.lua's update rebuilt a row for each field", r7 ~= nil and r8 ~= nil)
    T.eq("E2 field 7's row carries Soil's weed reading", r7 and r7.sfInfo and r7.sfInfo.weedPressure, 50)
    T.eq("E2 field 8's row carries Soil's weed reading", r8 and r8.sfInfo and r8.sfInfo.weedPressure, 10)
end)

--- The Soil strips drawn, by field: drawFieldRow draws the row label ("F<id> · ...") and then the
--- strip, the letters W, P, D, F joined by spaces; a forecast cell ("D+1") carries other characters.
local function stripsByField()
    local by, n, current = {}, 0, nil
    for _, t in ipairs(TEXT) do
        local fid = t:match("^F(%d+) ")
        if fid ~= nil then current = tonumber(fid) end
        if t:match("^[WPDF][ WPDF]*$") then by[current or 0] = t; n = n + 1 end
    end
    return by, n
end

group("E3", function()
    TEXT = {}
    quiet(function() FSBaseMission.draw(mission) end)
    local by, n = stripsByField()
    T.eq("E3 main.lua's draw shows one Soil strip", n, 1)
    T.eq("E3 field 7 shows W (weeds 50), P (pests 30) and D (scouted disease 20)", by[7], "W P D")
    T.eq("E3 field 8 shows no letters (weeds 10, pests 5, disease 3: all under 15)", by[8], nil)
    T.eq("E3 field 9's unscouted disease 60 shows no D (Soil's reveal gate)", by[9], nil)
end)

group("E4", function()
    sfm.reveal(9)
    quiet(function() FSBaseMission.update(mission, 1000) end)
    quiet(function() FSBaseMission.update(mission, 1000) end)
    TEXT = {}
    quiet(function() FSBaseMission.draw(mission) end)
    local by = stripsByField()
    T.eq("E4 once Soil reveals field 9's infection, its row shows D", by[9], "D")
    T.eq("E4 field 7's strip is unchanged", by[7], "W P D")
end)

--- Rebuild and draw as production does after a change: two updates (the throttled rebuild), then the draw.
local function redraw()
    quiet(function() FSBaseMission.update(mission, 1000) end)
    quiet(function() FSBaseMission.update(mission, 1000) end)
    TEXT = {}
    quiet(function() FSBaseMission.draw(mission) end)
    return stripsByField()
end

group("E5", function()
    local s = sfm.settings
    s.weedPressure = false
    local by = redraw()
    T.eq("E5 weeds switched off: field 7 shows P and D, not its last weed value", by[7], "P D")
    s.weedPressure = true
    s.pestPressure = false
    by = redraw()
    T.eq("E5 pests switched off: field 7 shows W and D", by[7], "W D")
    s.pestPressure = true
    s.diseasePressure = false
    by = redraw()
    T.eq("E5 disease switched off: field 7 shows W and P, no D", by[7], "W P")
    T.eq("E5 disease switched off: field 9 shows no D (Soil returns the raw value then)", by[9], nil)
    s.diseasePressure = true
    sfm.setSimDisabled(7, true)
    by = redraw()
    T.eq("E5 field 7's sim disabled by Soil: no strip on field 7", by[7], nil)
    T.eq("E5 and field 9's revealed D still shows", by[9], "D")
    sfm.setSimDisabled(7, false)
    by = redraw()
    T.eq("E5 every switch back on: field 7 shows W P D again", by[7], "W P D")
end)
