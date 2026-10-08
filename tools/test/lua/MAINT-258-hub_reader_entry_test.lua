--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/events/CropStressSettingsSyncEvent.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 258 (SCS's half): SCS passes SettingsHub a reader, so a change made in SCS's own settings
-- panel shows in the hub, the Tablet and the hub's broadcast.
--
-- WHY. SCS registers with SettingsHub as selfPersisted (src/settings/SettingsHubBridge.lua:58-68), so the hub
-- mirrors the values SCS registered with. SCS's own settings panel (CropStressSettingsPanel:requestChange)
-- writes its settings through the settings owner, or straight onto the settings for a client-local key, and
-- never tells the hub, so the Tablet showed the stale value. SettingsHub's row 258 PR lets a selfPersisted
-- companion pass read(key); this passes one, reading the object the hub's own onChange (applyChange) routes
-- through.
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs (maint165_main_world.lua): Mission00.load creates the
-- manager, loadMission00Finished runs initialize() (which builds the panel) and registers the bridge with
-- SettingsHub, reachable only as the mission's handle; the hub records the spec registerModule receives (the
-- hub's own behaviour is SettingsHub's bench). The change enters where a player makes it: SCS's own panel,
-- requestChange, on the host.
--
--   E0  [reached] the registration is selfPersisted and carries a reader
--   E1  after the panel changes difficulty and switches irrigation costs off (admin keys, through the owner),
--       the reader answers them, while the values SCS registered are still the old ones
--   E2  after the panel hides the HUD (a client-local key, straight onto the settings), the reader answers false
--   E3  for every registered key the reader answers SCS's own value; an unknown key answers nil

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
Permission = Permission or { MASTER_USER = 1 }

local mission = g_currentMission
local SPEC = nil
g_settingsHub = nil
mission.settingsHub = { registerModule = function(_, modId, spec) if modId == "SeasonalCropStress" then SPEC = spec end return true end }
mission.missionDynamicInfo = { isMultiplayer = false }

group("E", function()
    g_server, g_client = { broadcastEvent = function() end }, nil
    quiet(function() Mission00.load(mission) end)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    local mgr = mission.cropStressManager
    T.ok("E0 [reached] main.lua built the manager and its panel and registered the bridge as selfPersisted, with a reader",
        mgr ~= nil and mgr.settingsPanel ~= nil and SPEC ~= nil and SPEC.selfPersisted == true and type(SPEC.read) == "function")

    local registered = {}
    for _, def in ipairs(SPEC.adminSettings) do registered[def.id] = def.default end
    local s = mgr.settings
    local oldDifficulty, oldCosts = s.difficulty, s.irrigationCosts
    local newDifficulty = (oldDifficulty == "easy") and "hard" or "easy"

    quiet(function() mgr.settingsPanel:requestChange("difficulty", newDifficulty) end)
    quiet(function() mgr.settingsPanel:requestChange("irrigationCosts", false) end)
    -- Typed, not through tostring: a string "false" would pass a tostring compare, and the hub would refuse it.
    T.ok("E1 [entry point] NAMED (row 258): after SCS's own panel changed difficulty and switched irrigation costs off, the reader answers both, typed",
        SPEC.read("difficulty") == newDifficulty and SPEC.read("irrigationCosts") == false,
        tostring(SPEC.read("difficulty")) .. "/" .. tostring(SPEC.read("irrigationCosts")) .. " (" .. type(SPEC.read("irrigationCosts")) .. ")")
    T.eq("E1 while the values SCS registered are still the old ones (what the hub showed before)",
        tostring(registered.difficulty) .. "/" .. tostring(registered.irrigationCosts), tostring(oldDifficulty) .. "/" .. tostring(oldCosts))

    quiet(function() mgr.settingsPanel:requestChange("hudVisible", false) end)
    T.ok("E2 after the panel hides the HUD (a client-local key), the reader answers false, a boolean",
        SPEC.read("hudVisible") == false, tostring(SPEC.read("hudVisible")) .. " (" .. type(SPEC.read("hudVisible")) .. ")")

    local all, mismatch = 0, {}
    for _, def in ipairs(SPEC.adminSettings) do
        all = all + 1
        if SPEC.read(def.id) ~= s[def.id] then mismatch[#mismatch + 1] = def.id end
    end
    T.eq("E3 for every registered key the reader answers SCS's own value; an unknown key answers nil",
        all .. " " .. table.concat(mismatch, ",") .. " " .. tostring(SPEC.read("noSuchKey")), "12  nil")
end)

g_server, g_client = nil, nil
