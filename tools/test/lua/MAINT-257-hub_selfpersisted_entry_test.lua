--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 257: SeasonalCropStress registers with SettingsHub as selfPersisted.
--
-- WHY. The bridge's header states the hub's selfPersisted contract (src/settings/SettingsHubBridge.lua:
-- 10-12: CropStressSettings, with its own load and save, "stays the source of truth. This mirrors current
-- values into SettingsHub for display"), and SCS-023 v2.3 SDS 4 says clients apply display state only
-- through SCS's settings event (src/CropStressManager.lua:515-520). It registered without the flag. Dead
-- while SettingsHub never bound its bedrock mods; once SettingsHub's row 241 binds them, an unflagged
-- module has the hub's stored copy replayed over its own loaded values on every load, and its onChange
-- called on every client (Bob's R-15 on row 241).
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs (maint165_main_world.lua): its Mission00.load hook
-- creates the manager through CropStressManager.new(), and its loadMission00Finished hook runs
-- initialize() and calls SeasonalSettingsHubBridge.register (main.lua:297). SettingsHub is reachable only
-- as the mission's handle (mission.settingsHub, SettingsHub main.lua:58), a stand-in that records what is
-- registered with it. Nothing registers by hand.

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

-- The engine's Logging, which the bridge reports its registration through (SettingsHubBridge.lua:72-74);
-- the main world does not model it because, without a hub on the mission, the bridge returned before it.
Logging = Logging or { info = function() end, warning = function() end, error = function() end, devInfo = function() end }

local mission = g_currentMission
local REG = {}
-- The hub as a companion reaches it: on the mission only (no g_settingsHub in another mod's environment).
g_settingsHub = nil
mission.settingsHub = { registerModule = function(_, modId, spec) REG[modId] = spec return true end }

group("E entry", function()
    quiet(function() Mission00.load(mission) end)
    T.ok("E0 [reached] main.lua's Mission00.load created the manager", mission.cropStressManager ~= nil)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    local spec = REG["SeasonalCropStress"]
    T.ok("E1 [entry point] main.lua's loadMission00Finished registered SeasonalCropStress with the mission's SettingsHub", spec ~= nil)
    T.eq("E2 NAMED: the registration carries selfPersisted = true (the bridge's own contract, SettingsHubBridge.lua:10-12)",
        tostring(spec and spec.selfPersisted), "true")
    local admin = 0
    for _, d in ipairs(spec and spec.adminSettings or {}) do if d.adminOnly then admin = admin + 1 end end
    -- [MAINTENANCE row 289] Nine since debugMode became a server setting in the hub, as SCS's panel has it.
    T.eq("E3 and it is otherwise the registration it was: its nine admin settings and its onChange", admin .. "/" .. type(spec and spec.onChange), "9/function")
end)
