--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/events/CropStressSettingsSyncEvent.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 259: SCS's settings owner broadcasts once on the server, for every origin.
--
-- WHY. SCS-023 v2.3 build brief :117: the one owner (CropStressManager:applyAuthoritativeSettingChange)
-- "validates, applies, persists ... refreshes finite mode and broadcasts once on the server ... Panel,
-- settings event and SettingsHub use that owner". The owner never broadcast: the panel and the settings
-- event broadcast after calling it, and the SettingsHub bridge did not, so a change through SettingsHub on
-- the server reached no SCS client until it rejoined (Bob's R-15 on row 257). The owner now broadcasts the
-- validated value once; the panel's and the event's own broadcasts go (each keeps one only where there is
-- no owner).
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs (maint165_main_world.lua, its load list with the settings
-- event added): Mission00.load creates the manager, loadMission00Finished runs initialize() (which builds
-- the panel) and registers the bridge with SettingsHub, reachable only as the mission's handle. Each change
-- then enters where production enters it: the hub calling the registered onChange on the server, the
-- engine running a client's settings event on the server, the panel's own requestChange. The server's
-- broadcastEvent is recorded; a recorded event is then run as the engine runs it on a client.

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

-- The engine's Logging (the bridge reports its registration through it) and the user permission the
-- settings event checks a sender against (Permission.MASTER_USER, User:hasPermission).
Logging = Logging or { info = function() end, warning = function() end, error = function() end, devInfo = function() end }
Permission = Permission or { MASTER_USER = 1 }

local mission = g_currentMission
local REG = {}
g_settingsHub = nil
mission.settingsHub = { registerModule = function(_, modId, spec) REG[modId] = spec return true end }

-- The server's broadcast, as Server:broadcastEvent(event, sendLocal) takes it (Server.lua:542).
local SENT = {}
local SERVER = { broadcastEvent = function(_, ev, sendLocal) SENT[#SENT + 1] = { ev = ev, sendLocal = sendLocal } end }
--- What was broadcast since n, as "key=value/sendLocal", comma separated.
local function sentSince(n)
    local out = {}
    for i = n + 1, #SENT do
        local e = SENT[i]
        out[#out + 1] = tostring(e.ev and e.ev.key) .. "=" .. tostring(e.ev and e.ev.value) .. "/" .. tostring(e.sendLocal)
    end
    return table.concat(out, ",")
end

group("E entry", function()
    quiet(function() Mission00.load(mission) end)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    local mgr = mission.cropStressManager
    T.ok("E0 [reached] main.lua created the manager and its panel and registered the bridge with the mission's SettingsHub",
        mgr ~= nil and mgr.settingsPanel ~= nil and REG["SeasonalCropStress"] ~= nil)
end)

group("H hub path", function()
    g_server, g_client = SERVER, nil
    local mgr = mission.cropStressManager
    local n0 = #SENT
    -- SettingsHub's update calls a registrant's onChange(key, value, playerId) on the server.
    quiet(function() REG["SeasonalCropStress"].onChange("maxYieldLoss", 0.9, nil) end)
    T.eq("H1 [entry point] NAMED (SCS-023 :117): a change through SettingsHub on the server is broadcast once, to clients only, carrying the owner's validated value (0.9 clamps to 0.75)",
        sentSince(n0), "maxYieldLoss=0.75/false")
    local ev = SENT[n0 + 1] and SENT[n0 + 1].ev
    -- On a client: its copy before the event, then the event as the engine runs it there.
    mgr.settings.maxYieldLoss = 0.30
    g_server, g_client = nil, {}
    quiet(function() ev:run(nil) end)
    T.eq("H2 the event applies on a client: its SCS settings take the server's value", tostring(mgr.settings.maxYieldLoss), "0.75")
end)

group("V event path", function()
    g_server, g_client = SERVER, nil
    g_userManager = { getUserByConnection = function(_, c) return c.user end }
    local conn = { user = { hasPermission = function(_, p) return p == Permission.MASTER_USER end } }
    local n0 = #SENT
    local ev = CropStressSettingsSyncEvent.newSingle("difficulty", "hard")
    quiet(function() ev:run(conn) end)
    T.eq("V1 a master client's change through SCS's own settings event is applied and broadcast once (the owner's; the event's own is gone)",
        tostring(mission.cropStressManager.settings.difficulty) .. "|" .. sentSince(n0), "hard|difficulty=hard/false")
end)

group("P panel path", function()
    g_server, g_client = SERVER, nil
    mission.missionDynamicInfo = { isMultiplayer = false }
    local n0 = #SENT
    quiet(function() mission.cropStressManager.settingsPanel:requestChange("difficulty", "easy") end)
    T.eq("P1 a host's change in SCS's own panel is applied and broadcast once (the owner's; the panel's own is gone)",
        tostring(mission.cropStressManager.settings.difficulty) .. "|" .. sentSince(n0), "easy|difficulty=easy/false")
end)
