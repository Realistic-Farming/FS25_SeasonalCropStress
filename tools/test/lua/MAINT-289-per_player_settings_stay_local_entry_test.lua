--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/events/CropStressSettingsSyncEvent.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 289: SCS's per-player settings stay per player (Tyson, 2026-10-08: hudVisible, alertsEnabled and
-- alertCooldown are each player's own; debugMode stays a server setting, as SCS's panel has it).
--
-- WHY. Three paths carried a host's per-player choices to every client:
--   1. The Tablet: SettingsHub applies a player-local key on the host and calls SCS's onChange; the bridge's
--      applyChange sent every key through the settings owner, which broadcasts (CropStressManager.lua:539). A
--      regression from #226.
--   2. SCS's own panel: it marked only hudVisible localOnly, so alertsEnabled and alertCooldown went through the
--      owner and were broadcast too.
--   3. The join: the bulk settings event wrote all three (CropStressSettingsSyncEvent.lua writeStream) and a client
--      applied every key it received (applyBulkSettings), at join and after a rejected change.
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs (maint165_main_world.lua): Mission00.load creates the manager,
-- loadMission00Finished runs initialize() (which builds the panel) and registers the bridge with SettingsHub,
-- reachable only as the mission's handle. A Tablet change enters as the hub's onChange on the host; a panel change
-- as the panel's requestChange; the join as the server's sendAllToConnection, its event written to a stream and read
-- back where a client reads it (readStream, then run). The server's broadcastEvent is recorded.
--
--   E0  [reached] the bridge registered with the mission's SettingsHub
--   R1  hudVisible, alertsEnabled and alertCooldown are player-local in the hub; debugMode is a server setting
--   T1  a host's Tablet change to each per-player key applies on the host and broadcasts nothing (hudVisible also
--       hides the host's HUD)
--   P1  SCS's own panel: a host's change to alertsEnabled or alertCooldown applies and broadcasts nothing
--   A1  an admin key from the Tablet (debugMode) still goes through the owner and broadcasts once
--   J0  the bulk event the host writes carries none of the three per-player keys (9 settings)
--   J1  a join: the client takes the host's server settings and keeps each of its own per-player choices
--   J2  a bulk table that does carry them (any sender) still leaves a client's own choices alone
--   S1  a single settings event carrying a per-player key leaves a client's own choice alone; an admin key
--       in the same kind of event still applies

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
local REG = {}
g_settingsHub = nil
mission.settingsHub = { registerModule = function(_, modId, spec) REG[modId] = spec return true end }
local SENT = {}
local SERVER = { broadcastEvent = function(_, ev, sendLocal) SENT[#SENT + 1] = { ev = ev, sendLocal = sendLocal } end }

local mgr
local PER_PLAYER = { "hudVisible", "alertsEnabled", "alertCooldown" }

group("E", function()
    g_server, g_client = SERVER, nil
    quiet(function() Mission00.load(mission) end)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    mgr = mission.cropStressManager
    T.ok("E0 [reached] main.lua built the manager and its panel and registered the bridge with the mission's SettingsHub",
        mgr ~= nil and mgr.settingsPanel ~= nil and REG["SeasonalCropStress"] ~= nil)
    local scope = {}
    for _, def in ipairs(REG["SeasonalCropStress"].adminSettings) do scope[def.id] = def.adminOnly end
    T.eq("R1 hudVisible, alertsEnabled and alertCooldown are player-local in the hub; debugMode is a server setting",
        tostring(scope.hudVisible) .. "/" .. tostring(scope.alertsEnabled) .. "/" .. tostring(scope.alertCooldown) .. "/" .. tostring(scope.debugMode),
        "false/false/false/true")
end)

group("T", function()
    g_server, g_client = SERVER, nil
    quiet(function() mgr.settings.hudVisible = true; mgr.settings.alertsEnabled = true; mgr.settings.alertCooldown = 12; mgr:applySettings() end)
    local n0 = #SENT
    quiet(function() REG["SeasonalCropStress"].onChange("hudVisible", false, nil) end)
    quiet(function() REG["SeasonalCropStress"].onChange("alertsEnabled", false, nil) end)
    quiet(function() REG["SeasonalCropStress"].onChange("alertCooldown", 4, nil) end)
    T.ok("T1 [entry point] NAMED (row 289): a host's Tablet change to each per-player key applies on the host and broadcasts nothing; the host's HUD hides",
        mgr.settings.hudVisible == false and mgr.settings.alertsEnabled == false and mgr.settings.alertCooldown == 4
        and mgr.hudOverlay.isVisible == false and #SENT == n0,
        tostring(mgr.settings.hudVisible) .. "/" .. tostring(mgr.settings.alertsEnabled) .. "/" .. tostring(mgr.settings.alertCooldown)
        .. " hud " .. tostring(mgr.hudOverlay.isVisible) .. ", broadcasts " .. (#SENT - n0))
end)

group("P", function()
    g_server, g_client = SERVER, nil
    mission.missionDynamicInfo = { isMultiplayer = false }
    local n0 = #SENT
    quiet(function() mgr.settingsPanel:requestChange("alertsEnabled", true) end)
    quiet(function() mgr.settingsPanel:requestChange("alertCooldown", 24) end)
    T.ok("P1 SCS's own panel: a host's change to alertsEnabled and alertCooldown applies and broadcasts nothing",
        mgr.settings.alertsEnabled == true and mgr.settings.alertCooldown == 24 and #SENT == n0,
        tostring(mgr.settings.alertsEnabled) .. "/" .. tostring(mgr.settings.alertCooldown) .. ", broadcasts " .. (#SENT - n0))
end)

group("A", function()
    g_server, g_client = SERVER, nil
    local n1 = #SENT
    quiet(function() REG["SeasonalCropStress"].onChange("debugMode", true, nil) end)
    local ev = SENT[n1 + 1] and SENT[n1 + 1].ev
    T.eq("A1 an admin key from the Tablet (debugMode) still goes through the owner and broadcasts once",
        (#SENT - n1) .. " " .. tostring(ev and ev.key) .. "=" .. tostring(ev and ev.value), "1 debugMode=true")
end)

group("J", function()
    -- The host: its own per-player choices, and difficulty easy.
    g_server, g_client = SERVER, nil
    quiet(function()
        mgr.settings.hudVisible = false; mgr.settings.alertsEnabled = false; mgr.settings.alertCooldown = 4
        mgr.settings.difficulty = "easy"
    end)
    local captured = nil
    local conn = { sendEvent = function(_, e) captured = e end }
    quiet(function() CropStressSettingsSyncEvent.sendAllToConnection(conn) end)
    local s = _sfMockStream()
    quiet(function() captured:writeStream(s, nil) end)
    local carried, count = {}, nil
    for i, e in ipairs(s.q) do
        if e.t == "str" then carried[e.v] = true end
        if i == 2 then count = e.v end
    end
    T.ok("J0 the bulk event the host writes carries none of the three per-player keys, and 9 settings",
        not carried.hudVisible and not carried.alertsEnabled and not carried.alertCooldown and count == 9 and carried.difficulty == true,
        "count " .. tostring(count))
    -- The client: its own choices, and a stale difficulty; the event read where a client reads it.
    g_server, g_client = nil, {}
    quiet(function()
        mgr.settings.hudVisible = true; mgr.settings.alertsEnabled = true; mgr.settings.alertCooldown = 24
        mgr.settings.difficulty = "normal"
    end)
    quiet(function() CropStressSettingsSyncEvent.emptyNew():readStream(s, nil) end)
    T.eq("J1 a join: the client takes the host's difficulty and keeps its own HUD, alerts and cooldown",
        tostring(mgr.settings.difficulty) .. "/" .. tostring(mgr.settings.hudVisible) .. "/" .. tostring(mgr.settings.alertsEnabled)
        .. "/" .. tostring(mgr.settings.alertCooldown), "easy/true/true/24")
end)

group("J2", function()
    g_server, g_client = nil, {}
    quiet(function() mgr.settings.hudVisible = true; mgr.settings.alertsEnabled = true; mgr.settings.alertCooldown = 24 end)
    local ev = CropStressSettingsSyncEvent.emptyNew()
    ev.eventType = CropStressSettingsSyncEvent.TYPE_BULK
    ev.settings = { hudVisible = false, alertsEnabled = false, alertCooldown = 4, difficulty = "hard" }
    quiet(function() ev:run(nil) end)
    T.eq("J2 a bulk table that carries the per-player keys still leaves a client's own (and applies the rest)",
        tostring(mgr.settings.hudVisible) .. "/" .. tostring(mgr.settings.alertsEnabled) .. "/" .. tostring(mgr.settings.alertCooldown)
        .. "/" .. tostring(mgr.settings.difficulty), "true/true/24/hard")
end)


group("S", function()
    g_server, g_client = nil, {}
    quiet(function() mgr.settings.alertCooldown = 24; mgr.settings.difficulty = "normal" end)
    local function deliver(key, value)
        local s1 = _sfMockStream()
        quiet(function() CropStressSettingsSyncEvent.newSingle(key, value):writeStream(s1, nil) end)
        quiet(function() CropStressSettingsSyncEvent.emptyNew():readStream(s1, nil) end)
    end
    deliver("alertCooldown", 4)
    deliver("difficulty", "hard")
    T.eq("S1 a single event with a per-player key leaves the client's own (24); an admin key still applies (hard)",
        tostring(mgr.settings.alertCooldown) .. "/" .. tostring(mgr.settings.difficulty), "24/hard")
end)

g_server, g_client = nil, nil
