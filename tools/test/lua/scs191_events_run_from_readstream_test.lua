-- scs191_events_run_from_readstream_test.lua
-- SCS #191: the five events that never ran for a remote client.
--
-- The engine's incoming dispatch reads the event id, calls
-- readStream(streamId, connection) and then deletes the event
-- (network/Server.lua:435-437, network/Client.lua:418-419). It NEVER calls run.
-- A LOCAL connection short-circuits before any of that and calls
-- event:run(self.localConnection) directly (network/Connection.lua:71-74), which
-- is why singleplayer and a listen host always worked and only a remote client's
-- event was lost.
--
-- Every row below delivers through a real writeStream -> readStream round trip
-- and asserts the run body's EFFECT. No row calls run to produce the effect it
-- measures; the CONTROL rows call run directly on the same fixture for the one
-- purpose of proving the fixture can reach that effect at all, so a failing row
-- is failing on the readStream wiring and not on a dead fixture.
--
-- The refusal rows carry a witness for the same reason in the other direction:
-- "nothing happened" is also what a dead event looks like, so each refusal is
-- preceded by an owned delivery on the SAME fixture that must visibly apply.
--!load: src/IrrigationManager.lua, src/events/CropStressIrrigateNowEvent.lua, src/events/CropStressIrrigateNowResultEvent.lua, src/events/CropStressPivotRemoteEvent.lua, src/events/CropStressScheduleSyncEvent.lua, src/events/CropStressRainKeyCommandEvent.lua, src/events/CropStressRainKeyResultEvent.lua

-- ── engine delivery models ─────────────────────────────────

--- A remote connection: it records what the server sends back and never runs it.
local function remoteConn()
  local c = { sent = {} }
  c.getIsServer = function(_self) return false end
  c.sendEvent = function(self, ev) self.sent[#self.sent + 1] = ev end
  return c
end

--- network/Connection.lua:71-74. A LOCAL connection never serialises: sendEvent
--- calls run directly with the local connection, so readStream is never reached.
local function localConn()
  local c = { sent = {} }
  c.localConnection = c
  c.getIsServer = function(_self) return false end
  c.sendEvent = function(self, ev)
    self.sent[#self.sent + 1] = ev
    ev:run(self.localConnection)
  end
  return c
end

--- The remote path exactly as the dispatcher performs it: write, read, delete.
--- run is deliberately absent here. Returns the received event and the stream so
--- a wire fault cannot be mistaken for a wiring fault.
local function deliverRemote(cls, event, connection)
  local s = _sfMockStream()
  event:writeStream(s, connection)
  local rx = cls.emptyNew()
  rx:readStream(s, connection)
  return rx, s
end

local function countByClass(list, className)
  local n = 0
  for _, ev in ipairs(list) do
    if ev.className == className then n = n + 1 end
  end
  return n
end

--- Field read that survives a missing row, so a dead event fails its named row
--- with a value mismatch instead of crashing the file and taking every later
--- row with it.
local function field(t, key)
  if t == nil then return nil end
  return t[key]
end

local function resetGlobals()
  g_server = nil
  g_client = nil
  g_logManager = nil
  g_cropStressManager = nil
  g_currentMission.getFarmId = nil
  g_currentMission.getPlayerByConnection = nil
  g_currentMission.placeableSystem = nil
  g_currentMission.player = nil
end

-- ============================================================
-- 1. CropStressIrrigateNowEvent  (client -> server request)
-- ============================================================
-- Effect: the transaction is applied for the requester's farm and a result event
-- goes back on the same connection.

local function irrigateFixture()
  local mgr = IrrigationManager.new({ settings = { enabled = true } })
  mgr.manager = { settings = { enabled = true } }
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 5, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, ownerFarmId = 2, type = "pivot",
             coveredFields = { 5 }, x = 0, z = 0, radius = 200,
             flowRatePerHour = 0.018, pressureMultiplier = 1.0 },
  }
  mgr.isFiniteWaterActive = function() return false end
  mgr._fieldsForId = function(_self, _fid) return { { polygonPoints = { 1 } } } end
  mgr.getFieldPolygonWorld = function(_self, _f) return { -10, 10, 10 }, { -10, -10, 10 }, 3 end
  mgr._cellsInPolygon = function() return { { wx = 0, wz = 0 } } end
  mgr.manager.soilSystem = {
    fieldData = { [5] = { moisture = 0.5 } },
    getCellSize = function() return 2 end,
    applyWaterAtCell = function() return true end,
  }

  resetGlobals()
  g_server = { broadcastEvent = function() end }
  g_currentMission.getFarmId = function(_m, _c) return 2 end
  g_cropStressManager = { irrigationManager = mgr, isMissionWaterReady = function() return true end }
  return mgr
end

do
  -- CONTROL: this fixture reaches the effect when run is called.
  local mgr = irrigateFixture()
  local conn = remoteConn()
  CropStressIrrigateNowEvent.new(10, -1):run(conn)
  T.eq('irrigate.control.applied', mgr.lastIrrigateNowResultByFarm[2] ~= nil, true)
  T.eq('irrigate.control.replied', #conn.sent, 1)
end

do
  -- ROW: the same effect must follow a wire delivery, with no call to run.
  local mgr = irrigateFixture()
  local conn = remoteConn()
  local _, s = deliverRemote(CropStressIrrigateNowEvent, CropStressIrrigateNowEvent.new(10, -1), conn)
  local stored = mgr.lastIrrigateNowResultByFarm[2]
  T.eq('irrigate.wireClean', s.typeErrors + s.underflows, 0)
  T.eq('irrigate.remoteApplied', stored ~= nil, true)
  T.eq('irrigate.remoteResultCode', field(stored, "resultCode"), "success")
  T.eq('irrigate.remoteSystemId', field(stored, "systemId"), 10)
  T.eq('irrigate.remoteReplied', countByClass(conn.sent, "CropStressIrrigateNowResultEvent"), 1)
end

-- ============================================================
-- 2. CropStressPivotRemoteEvent  (client -> server command)
-- ============================================================
-- Effect: AUTO_MANUAL_TOGGLE flips manualMode on the owned SCS row, and a row
-- owned by another farm is refused with no mutation. System 10 belongs to the
-- requester's farm, system 11 does not.

local function pivotFixture()
  local irr = IrrigationManager.new({ settings = { enabled = true } })
  irr.manager = { settings = { enabled = true } }
  irr.systems = {
    [10] = { id = 10, ownerFarmId = 2, type = "pivot", manualMode = false,
             coveredFields = { 5 }, flowRatePerHour = 0.018, pressureMultiplier = 1.0,
             schedule = { startHour = 6, endHour = 10, activeDays = {} } },
    [11] = { id = 11, ownerFarmId = 7, type = "pivot", manualMode = false,
             coveredFields = { 6 }, flowRatePerHour = 0.018, pressureMultiplier = 1.0,
             schedule = { startHour = 6, endHour = 10, activeDays = {} } },
  }
  irr.applyScheduleNow = function() end

  resetGlobals()
  g_server = { broadcastEvent = function() end }
  g_cropStressManager = { irrigationManager = irr }
  g_currentMission.placeableSystem = {
    placeables = {
      { id = 10, getOwnerFarmId = function() return 2 end },
      { id = 11, getOwnerFarmId = function() return 7 end },
    },
  }
  g_currentMission.getPlayerByConnection = function(_m, _c) return { farmId = 2 } end
  return irr
end

local PIVOT_AUTO_MANUAL = CropStressPivotRemoteEvent.ACTION.AUTO_MANUAL_TOGGLE

do
  -- CONTROL: this fixture reaches the effect when run is called.
  local irr = pivotFixture()
  CropStressPivotRemoteEvent.new(10, PIVOT_AUTO_MANUAL):run(remoteConn())
  T.eq('pivot.control.toggled', irr.systems[10].manualMode, true)
end

do
  -- ROW: the same effect must follow a wire delivery, with no call to run.
  local irr = pivotFixture()
  local _, s = deliverRemote(CropStressPivotRemoteEvent,
    CropStressPivotRemoteEvent.new(10, PIVOT_AUTO_MANUAL), remoteConn())
  T.eq('pivot.wireClean', s.typeErrors + s.underflows, 0)
  T.eq('pivot.remoteToggled', irr.systems[10].manualMode, true)
end

do
  -- ROW: ownership refuses over the wire without mutating. The owned delivery
  -- first is the witness: without it, a dead event would read as a refusal.
  local irr = pivotFixture()
  local conn = remoteConn()
  deliverRemote(CropStressPivotRemoteEvent,
    CropStressPivotRemoteEvent.new(10, PIVOT_AUTO_MANUAL), conn)
  T.eq('pivot.refusalWitnessArrived', irr.systems[10].manualMode, true)
  deliverRemote(CropStressPivotRemoteEvent,
    CropStressPivotRemoteEvent.new(11, PIVOT_AUTO_MANUAL), conn)
  T.eq('pivot.remoteRefusedOnOwnership', irr.systems[11].manualMode, false)
end

-- ============================================================
-- 3. CropStressScheduleSyncEvent  (both directions)
-- ============================================================
-- Effect on the server: the owner's row is written and the canonical row is
-- broadcast. Effect on a client: the server's row is written locally.

local function scheduleFixture(isServer)
  local irr = IrrigationManager.new({ settings = { enabled = true } })
  irr.manager = { settings = { enabled = true } }
  irr.systems = {
    [10] = { id = 10, ownerFarmId = 2, type = "pivot", manualMode = false,
             coveredFields = { 5 },
             schedule = { startHour = 6, endHour = 10, activeDays = {} } },
    [11] = { id = 11, ownerFarmId = 7, type = "pivot", manualMode = false,
             coveredFields = { 6 },
             schedule = { startHour = 6, endHour = 10, activeDays = {} } },
  }
  local seen = { scheduleApplied = 0, broadcasts = {} }
  irr.applyScheduleNow = function() seen.scheduleApplied = seen.scheduleApplied + 1 end

  resetGlobals()
  if isServer then
    g_server = { broadcastEvent = function(_s, ev) seen.broadcasts[#seen.broadcasts + 1] = ev end }
  end
  g_cropStressManager = { irrigationManager = irr }
  g_currentMission.getPlayerByConnection = function(_m, _c) return { farmId = 2 } end
  return irr, seen
end

local function scheduleRow(systemId)
  return CropStressScheduleSyncEvent.new(systemId, true, 4, 9,
    { true, false, true, false, false, false, false })
end

do
  -- CONTROL: this fixture reaches the effect when run is called.
  local irr, seen = scheduleFixture(true)
  scheduleRow(10):run(remoteConn())
  T.eq('schedule.control.startHour', irr.systems[10].schedule.startHour, 4)
  T.eq('schedule.control.broadcast', #seen.broadcasts, 1)
end

do
  -- ROW (server direction): the owner's row lands and the canonical row goes out.
  local irr, seen = scheduleFixture(true)
  local _, s = deliverRemote(CropStressScheduleSyncEvent, scheduleRow(10), remoteConn())
  T.eq('schedule.wireClean', s.typeErrors + s.underflows, 0)
  T.eq('schedule.serverStartHour', irr.systems[10].schedule.startHour, 4)
  T.eq('schedule.serverEndHour', irr.systems[10].schedule.endHour, 9)
  T.eq('schedule.serverManualMode', irr.systems[10].manualMode, true)
  T.eq('schedule.serverDay3', irr.systems[10].schedule.activeDays[3], true)
  T.eq('schedule.serverAppliedNow', seen.scheduleApplied, 1)
  T.eq('schedule.serverBroadcast', #seen.broadcasts, 1)
  T.eq('schedule.serverBroadcastRow', field(seen.broadcasts[1], "startHour"), 4)
end

do
  -- ROW (client direction): the server's row lands on the client copy.
  local irr = scheduleFixture(false)
  local _, s = deliverRemote(CropStressScheduleSyncEvent, scheduleRow(10), remoteConn())
  T.eq('schedule.clientWireClean', s.typeErrors + s.underflows, 0)
  T.eq('schedule.clientStartHour', irr.systems[10].schedule.startHour, 4)
  T.eq('schedule.clientManualMode', irr.systems[10].manualMode, true)
end

do
  -- ROW (server direction): a row for another farm is refused without mutating.
  -- The owned delivery first is the witness against a dead event reading as a
  -- refusal.
  local irr, seen = scheduleFixture(true)
  deliverRemote(CropStressScheduleSyncEvent, scheduleRow(10), remoteConn())
  T.eq('schedule.refusalWitnessArrived', irr.systems[10].schedule.startHour, 4)
  deliverRemote(CropStressScheduleSyncEvent, scheduleRow(11), remoteConn())
  T.eq('schedule.serverRefusedOnOwnership', irr.systems[11].schedule.startHour, 6)
  T.eq('schedule.serverRefusedNoExtraBroadcast', #seen.broadcasts, 1)
end

-- ============================================================
-- 4. CropStressRainKeyCommandEvent  (client -> server command)
-- ============================================================
-- Effect: the command is applied and the requester gets a result event carrying
-- the code and the new revision.

local function rainKeyFixture(requesterFarmId)
  local irr = IrrigationManager.new({ settings = { enabled = true } })
  irr.manager = { settings = { enabled = true } }
  irr.systems = {
    [1] = { id = 1, type = "pivot", ownerFarmId = 2, isActive = true,
            coveredFields = { 5 }, flowRatePerHour = 0.018, pressureMultiplier = 1.0,
            activeGameHoursSinceSettle = 0 },
  }

  resetGlobals()
  g_server = { broadcastEvent = function() end }
  g_currentMission.getFarmId = function(_m, _c) return requesterFarmId end
  g_cropStressManager = { irrigationManager = irr }
  return irr
end

do
  -- CONTROL: this fixture reaches the effect when run is called.
  local irr = rainKeyFixture(2)
  local conn = remoteConn()
  CropStressRainKeyCommandEvent.new(1, "FIT", nil, 0):run(conn)
  T.eq('rainKeyCmd.control.applied', irr.systems[1].rainKeyFitted, true)
  T.eq('rainKeyCmd.control.replied', #conn.sent, 1)
end

do
  -- ROW: the same effect must follow a wire delivery, with no call to run.
  local irr = rainKeyFixture(2)
  local conn = remoteConn()
  local _, s = deliverRemote(CropStressRainKeyCommandEvent,
    CropStressRainKeyCommandEvent.new(1, "FIT", nil, 0), conn)
  T.eq('rainKeyCmd.wireClean', s.typeErrors + s.underflows, 0)
  T.eq('rainKeyCmd.remoteApplied', irr.systems[1].rainKeyFitted, true)
  T.eq('rainKeyCmd.remoteRevision', irr.systems[1].rainKeyStateRevision, 1)
  T.eq('rainKeyCmd.remoteReplied', countByClass(conn.sent, "CropStressRainKeyResultEvent"), 1)
  T.eq('rainKeyCmd.remoteReplyCode', field(conn.sent[1], "resultCode"), "OK")
  T.eq('rainKeyCmd.remoteReplyRevision', field(conn.sent[1], "stateRevision"), 1)
end

do
  -- ROW: an unauthorized requester is refused over the wire, with no mutation.
  -- The refusal itself is a reply, so this row cannot be satisfied by silence.
  local irr = rainKeyFixture(9)
  local conn = remoteConn()
  deliverRemote(CropStressRainKeyCommandEvent,
    CropStressRainKeyCommandEvent.new(1, "FIT", nil, 0), conn)
  T.eq('rainKeyCmd.remoteRefusalReplied', countByClass(conn.sent, "CropStressRainKeyResultEvent"), 1)
  T.eq('rainKeyCmd.remoteNotAuthorized', field(conn.sent[1], "resultCode"), "NOT_AUTHORIZED")
  T.eq('rainKeyCmd.remoteNoMutation', irr.systems[1].rainKeyFitted, nil)
end

-- ============================================================
-- 5. CropStressRainKeyResultEvent  (server -> requesting client)
-- ============================================================
-- The run body only logs today (the result never reaches the UI; that gap is
-- named in the PR body and is not fixed here). The log line is therefore the
-- whole observable effect, so that is what the row asserts.

local function rainKeyResultFixture()
  resetGlobals()
  local lines = {}
  g_logManager = { devInfo = function(_self, _prefix, msg) lines[#lines + 1] = msg end }
  return lines
end

do
  -- CONTROL: this fixture reaches the effect when run is called.
  local lines = rainKeyResultFixture()
  CropStressRainKeyResultEvent.new(1, true, "OK", "FIT", 4):run(remoteConn())
  T.eq('rainKeyResult.control.logged', #lines, 1)
end

do
  -- ROW: the same effect must follow a wire delivery, with no call to run.
  local lines = rainKeyResultFixture()
  local _, s = deliverRemote(CropStressRainKeyResultEvent,
    CropStressRainKeyResultEvent.new(1, true, "OK", "FIT", 4), remoteConn())
  T.eq('rainKeyResult.wireClean', s.typeErrors + s.underflows, 0)
  T.eq('rainKeyResult.remoteLogged', #lines, 1)
  T.ok('rainKeyResult.remoteLineNamesAction',
    lines[1] ~= nil and string.find(lines[1], "action=FIT", 1, true) ~= nil,
    "log line did not carry the delivered action: " .. tostring(lines[1]))
  T.ok('rainKeyResult.remoteLineNamesRevision',
    lines[1] ~= nil and string.find(lines[1], "rev=4", 1, true) ~= nil,
    "log line did not carry the delivered revision: " .. tostring(lines[1]))
end

-- ============================================================
-- 6. RUNS EXACTLY ONCE, on both paths
-- ============================================================
-- The fix cannot double-run: the LOCAL path never calls readStream, and the
-- remote path never calls run on its own. These two rows pin that in both
-- directions, so a later "helpful" run added to a dispatcher would fail here.

do
  -- LOCAL path (network/Connection.lua:71-74): the host's own send runs the
  -- event directly, exactly once, and readStream is never reached.
  local mgr = irrigateFixture()
  local host = localConn()
  host:sendEvent(CropStressIrrigateNowEvent.new(10, -1))
  T.eq('once.localRequests', countByClass(host.sent, "CropStressIrrigateNowEvent"), 1)
  T.eq('once.localResults', countByClass(host.sent, "CropStressIrrigateNowResultEvent"), 1)
  T.eq('once.localApplied', mgr.lastIrrigateNowResultByFarm[2] ~= nil, true)
end

do
  -- REMOTE path: one wire delivery produces exactly one run, so exactly one
  -- result goes back to the requester.
  local mgr = irrigateFixture()
  local conn = remoteConn()
  deliverRemote(CropStressIrrigateNowEvent, CropStressIrrigateNowEvent.new(10, -1), conn)
  T.eq('once.remoteResults', countByClass(conn.sent, "CropStressIrrigateNowResultEvent"), 1)
  T.eq('once.remoteApplied', mgr.lastIrrigateNowResultByFarm[2] ~= nil, true)
end

resetGlobals()
T.summary()
