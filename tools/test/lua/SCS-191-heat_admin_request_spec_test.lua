--!load: src/SoilMoistureSystem.lua, src/events/CropStressMoistureInitEvent.lua, src/CropStressManager.lua, src/settings/CropStressSettingsPanel.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua
-- SCS #191 follow-up (Design d3c0626, Bob intake 82af751): a client admin's Simulate
-- Heat Wave sends CropStressHeatRequestEvent; the server re-checks master-user rights
-- itself, validates days, runs the host simulation, pushes the result to clients and
-- answers the requesting connection with CropStressHeatResultEvent. Every event is
-- delivered through a stream round trip (writeStream -> readStream), because the
-- engine never calls run for an incoming event (Server.lua:435-437).
-- Groups: S server receipt, C client console and panel, E end to end, H hourly push,
-- A isAdmin().

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server, g_client, g_cropStressManager = nil, nil, nil
end

local function heatManager()
    local mgr = setmetatable({}, { __index = CropStressManager })
    local soil = SoilMoistureSystem.new(mgr)
    soil.isInitialized = true
    soil.providerMode = "ZONE"
    soil.fieldData[1] = { fieldId = 1, moisture = 0.6, soilType = "loamy", cells = {}, cellSum = 0, cellCount = 0 }
    local counts = { soil = 0, stress = 0, broadcasts = 0 }
    local realHourly = soil.hourlyUpdate
    soil.hourlyUpdate = function(self, ...) counts.soil = counts.soil + 1; return realHourly(self, ...) end
    mgr.soilSystem = soil
    mgr.stressModifier = { fieldStress = {}, hourlyUpdate = function() counts.stress = counts.stress + 1 end }
    mgr.weatherIntegration = {
        currentTemp = 20.0, hourlyRainAmount = 0.2,
        getHourlyEvapMultiplier = function(self) return self.currentTemp > 30 and 2.0 or 1.0 end,
        getHourlyRainAmount = function(self) return self.hourlyRainAmount end,
    }
    local popups = {}
    mgr.settingsPanel = setmetatable({}, { __index = CropStressSettingsPanel })
    mgr.settingsPanel.showPopup = function(_, msg) popups[#popups + 1] = msg end
    g_cropStressManager = mgr
    return mgr, soil, counts, popups
end

local function serverSide(counts)
    g_client = nil
    g_server = { broadcastEvent = function() counts.broadcasts = counts.broadcasts + 1 end }
end

--- A connection as the server sees the sender (or as a client sees the server).
local function connection(opts)
    local c = { sent = {}, isServer = opts.isServer == true, isLocal = opts.isLocal == true, master = opts.master == true }
    function c:getIsServer() return self.isServer end
    function c:getIsLocal() return self.isLocal end
    function c:sendEvent(ev) self.sent[#self.sent + 1] = ev end
    return c
end
g_currentMission.userManager = { getIsConnectionMasterUser = function(_, c) return c.master == true end }

--- Deliver an event object through a mock stream: writeStream, then a fresh instance's readStream.
local function deliver(event, class, conn)
    local s = _sfMockStream()
    event:writeStream(s, conn)
    local rx = class.emptyNew()
    rx:readStream(s, conn)
    return s
end

local function withPrint(fn)
    local lines, realPrint = {}, print
    print = function(msg) lines[#lines + 1] = tostring(msg) end
    local ok, err = pcall(fn)
    print = realPrint
    if not ok then error(err) end
    return lines
end

-- =====================================================================
-- S: the server's receipt of a request
-- =====================================================================
group("S server", function()
    local mgr, soil, counts = heatManager()
    serverSide(counts)
    local master = connection({ master = true })
    local s = deliver(CropStressHeatRequestEvent.new(2), CropStressHeatRequestEvent, master)
    T.eq("S1a [reached: the request read cleanly off the stream]", tostring(s.typeErrors) .. ":" .. tostring(s.underflows), "0:0")
    T.eq("S1b NAMED: a master user's request runs 24 x days soil hourly updates", counts.soil, 48)
    T.eq("S1c and 24 x days stress hourly updates", counts.stress, 48)
    local reply = master.sent[1]
    T.eq("S1d and replies accepted to that connection", reply and (tostring(reply.accepted) .. ":" .. reply.code .. ":" .. reply.days), "true:OK:2")
    T.eq("S1e NAMED: the result is pushed to clients once", counts.broadcasts, 1)
    T.ok("S1f the host field dried", soil.fieldData[1].moisture < 0.6)

    mgr, soil, counts = heatManager()
    serverSide(counts)
    local player = connection({ master = false })
    deliver(CropStressHeatRequestEvent.new(3), CropStressHeatRequestEvent, player)
    T.eq("S2a NAMED: a non-master user's request runs no hourly update", counts.soil + counts.stress, 0)
    T.eq("S2b and replies NOT_ADMIN", player.sent[1] and (tostring(player.sent[1].accepted) .. ":" .. player.sent[1].code), "false:NOT_ADMIN")
    T.eq("S2c and pushes nothing", counts.broadcasts, 0)

    mgr, soil, counts = heatManager()
    serverSide(counts)
    local localConn = connection({ isLocal = true })
    deliver(CropStressHeatRequestEvent.new(1), CropStressHeatRequestEvent, localConn)
    T.eq("S3 a local connection is accepted", tostring(counts.soil) .. ":" .. localConn.sent[1].code, "24:OK")

    mgr, soil, counts = heatManager()
    serverSide(counts)
    local fromServer = connection({ isServer = true, master = true })
    deliver(CropStressHeatRequestEvent.new(1), CropStressHeatRequestEvent, fromServer)
    T.eq("S4 a request arriving over a server connection is refused", tostring(counts.soil) .. ":" .. fromServer.sent[1].code, "0:NOT_ADMIN")

    for _, forged in ipairs({ 0, 31, 255 }) do
        mgr, soil, counts = heatManager()
        serverSide(counts)
        local m = connection({ master = true })
        deliver(CropStressHeatRequestEvent.new(forged), CropStressHeatRequestEvent, m)
        T.eq("S5 NAMED: a forged day count " .. forged .. " runs nothing and is refused BAD_DAYS",
            tostring(counts.soil) .. ":" .. tostring(m.sent[1] and m.sent[1].code), "0:BAD_DAYS")
    end
    mgr, soil, counts = heatManager()
    serverSide(counts)
    local p2 = connection({ master = false })
    deliver(CropStressHeatRequestEvent.new(0), CropStressHeatRequestEvent, p2)
    T.eq("S6 a non-master with a forged count still gets NOT_ADMIN", p2.sent[1].code, "NOT_ADMIN")
end)

-- =====================================================================
-- C: a pure client's console and panel
-- =====================================================================
group("C client", function()
    local mgr, soil, counts, popups = heatManager()
    local toServer = connection({ isServer = true })
    g_server = nil
    g_client = { getServerConnection = function() return toServer end }

    local status
    local printed = withPrint(function() status = mgr:consoleSimulateHeat("3") end)
    T.eq("C1a NAMED: the client console sends exactly one request", #toServer.sent, 1)
    T.eq("C1b for 3 days", toServer.sent[1] and toServer.sent[1].days, 3)
    T.eq("C1c and says only that it was sent", printed[#printed], "Heat wave request sent to the server.")
    T.eq("C1d status SENT, no local simulation", tostring(status) .. ":" .. (counts.soil + counts.stress), "SENT:0")

    toServer.sent = {}
    local panel = mgr.settingsPanel
    panel:handleClick("admin_action_admin_heat", { actionId = "admin_heat" })
    T.eq("C2a NAMED: the client panel sends exactly one request", #toServer.sent, 1)
    T.eq("C2b NAMED: and never claims success before the reply", popups[#popups], "Heat wave request sent to the server.")

    local fromServer = connection({ isServer = true })
    deliver(CropStressHeatResultEvent.new(true, "OK", 3), CropStressHeatResultEvent, fromServer)
    T.eq("C3 NAMED: the server's accepted answer, off the stream, shows in the panel",
        popups[#popups], "Simulated 3-day heat wave. Check field moisture: stress may have increased.")

    panel:handleClick("admin_action_admin_heat", { actionId = "admin_heat" })
    deliver(CropStressHeatResultEvent.new(false, "NOT_ADMIN", 0), CropStressHeatResultEvent, fromServer)
    T.eq("C4 NAMED: a refusal shows the truth", popups[#popups], "Only a server admin can run the heat wave simulation.")

    withPrint(function() mgr:consoleSimulateHeat("2") end)
    local consoleLines = withPrint(function()
        deliver(CropStressHeatResultEvent.new(true, "OK", 2), CropStressHeatResultEvent, fromServer)
    end)
    T.eq("C5 a console request's answer prints to the console", consoleLines[#consoleLines],
        "Simulated 2-day heat wave. Check field moisture: stress may have increased.")

    g_client = nil
    toServer.sent = {}
    local st, text = mgr:requestHeatWave("3", "panel")
    T.eq("C6 with no server connection nothing is sent and the player is told", tostring(st) .. ":" .. text .. ":" .. #toServer.sent,
        "REFUSED:Heat wave request could not be sent to the server.:0")
end)

-- =====================================================================
-- E: end to end, a client admin's click to the server and back
-- =====================================================================
group("E end to end", function()
    local mgr, soil, counts, popups = heatManager()
    local toServer = connection({ isServer = true })
    g_server = nil
    g_client = { getServerConnection = function() return toServer end }
    mgr.settingsPanel:handleClick("admin_action_admin_heat", { actionId = "admin_heat" })
    local request = toServer.sent[1]

    serverSide(counts)
    local adminAtServer = connection({ master = true })
    deliver(request, CropStressHeatRequestEvent, adminAtServer)
    T.eq("E1a [reached: the server ran the request]", counts.soil, 72)

    g_server = nil
    deliver(adminAtServer.sent[1], CropStressHeatResultEvent, connection({ isServer = true }))
    T.eq("E1b NAMED: a client admin's click runs the host simulation and then shows it", popups[#popups],
        "Simulated 3-day heat wave. Check field moisture: stress may have increased.")
end)

-- =====================================================================
-- H: the hourly act pushes to clients through the shared helper (Bob #199 MAJOR)
-- =====================================================================
--- A manager whose hourly act runs to the end on the server, counting the
--- moisture push the act makes. Every integration the act touches is a no-op,
--- so the only thing these rows can observe is the push itself.
local function hourlyManager()
    local counts = { soilHourly = 0, stressHourly = 0, refresh = 0, broadcasts = 0, initEvents = 0, dirty = 0 }
    local mgr = setmetatable({}, { __index = CropStressManager })
    local noop = function() end
    mgr.settings = { enabled = true }
    mgr.lastFieldMapDay = 1
    mgr.weatherIntegration = { update = noop }
    mgr.soilFertilizerIntegration = { hourlyRefresh = noop }
    mgr.coursePlayIntegration = { hourlyRefresh = noop }
    mgr.autoDriveIntegration = { hourlyRefresh = noop }
    mgr.irrigationManager = { systems = {}, hourlyScheduleCheck = noop }
    mgr.soilSystem = {
        fieldData = {},
        hourlyUpdate = function() counts.soilHourly = counts.soilHourly + 1 end,
        refreshForPublication = function() counts.refresh = counts.refresh + 1 end,
    }
    mgr.getSkipRainHours = function() return nil end
    mgr.stressModifier = { fieldStress = {}, hourlyUpdate = function() counts.stressHourly = counts.stressHourly + 1 end }
    mgr.financeIntegration = { chargeHourlyCosts = noop }
    mgr.consultant = { hourlyEvaluate = noop }
    mgr.debugMode = false
    g_server = { broadcastEvent = function(_, ev)
        counts.broadcasts = counts.broadcasts + 1
        if getmetatable(ev) == CropStressMoistureInitEvent_mt then counts.initEvents = counts.initEvents + 1 end
    end }
    g_currentMission.isMissionStarted = true
    g_currentMission.environment = { currentDay = 1 }
    return mgr, counts
end

group("H hourly push", function()
    local savedBridge = CropStressNetworkSyncBridge
    CropStressNetworkSyncBridge = nil
    local mgr, counts = hourlyManager()
    mgr:onHourlyTick(1)
    T.eq("H1a [reached: the hourly body ran on the server]", tostring(counts.soilHourly) .. ":" .. counts.stressHourly, "1:1")
    T.eq("H1b NAMED: with no active NetworkSync bridge the hourly act broadcasts exactly one CropStressMoistureInitEvent",
        tostring(counts.initEvents) .. ":" .. counts.broadcasts, "1:1")
    T.eq("H1c after refreshing the slots once", counts.refresh, 1)

    mgr, counts = hourlyManager()
    CropStressNetworkSyncBridge = { active = true, markFieldDirty = function() counts.dirty = counts.dirty + 1 end }
    mgr:onHourlyTick(1)
    T.eq("H2a [reached: the hourly body ran on the server]", tostring(counts.soilHourly) .. ":" .. counts.stressHourly, "1:1")
    T.eq("H2b NAMED: with the NetworkSync bridge active the hourly act marks it dirty exactly once", counts.dirty, 1)
    T.eq("H2c and broadcasts nothing directly", counts.broadcasts, 0)
    CropStressNetworkSyncBridge = savedBridge
    g_currentMission.isMissionStarted = nil
end)

-- =====================================================================
-- A: the panel's admin display in multiplayer
-- =====================================================================
group("A isAdmin", function()
    local panel = setmetatable({}, { __index = CropStressSettingsPanel })
    local savedInfo, savedUsers, savedMaster = g_currentMission.missionDynamicInfo, g_currentMission.userManager, g_currentMission.isMasterUser
    g_currentMission.missionDynamicInfo = { isMultiplayer = true }
    g_currentMission.userManager = { getUserByUserId = function() return { getIsMasterUser = function() return true end } end }
    g_currentMission.isMasterUser = true
    local ok, result = pcall(function() return panel:isAdmin() end)
    T.eq("A1 NAMED: isAdmin() in multiplayer reads isMasterUser without error", tostring(ok) .. ":" .. tostring(result), "true:true")
    g_currentMission.isMasterUser = false
    ok, result = pcall(function() return panel:isAdmin() end)
    T.eq("A2 and is false for a player who is not the master user", tostring(ok) .. ":" .. tostring(result), "true:false")
    g_currentMission.missionDynamicInfo, g_currentMission.userManager, g_currentMission.isMasterUser = savedInfo, savedUsers, savedMaster
end)
