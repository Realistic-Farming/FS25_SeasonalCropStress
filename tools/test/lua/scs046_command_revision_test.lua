-- scs046_command_revision_test.lua
-- SCS-046 B (F200): rain-key command idempotence. The request stream carries an
-- expectedRevision; a stale revision is rejected before any mutation; FIT and
-- SET require the rain_key_pause release row live; REMOVE settles the
-- already-run interval first. Ownership in the event resolves only through the
-- shared engine farm resolver.
--!load: src/IrrigationManager.lua, src/events/CropStressRainKeyCommandEvent.lua, src/events/CropStressRainKeyResultEvent.lua

local function fittedManager()
  local mgr = IrrigationManager.new({ settings = { enabled = true } })
  local water = { calls = 0 }
  mgr.manager = { settings = { enabled = true } }
  mgr.systems = {
    [1] = { id = 1, type = "pivot", ownerFarmId = 2, isActive = true,
            coveredFields = { 5 }, flowRatePerHour = 0.018, pressureMultiplier = 1.0,
            activeGameHoursSinceSettle = 2 },
  }
  return mgr
end

-- 1. FIT APPLIES AND ADVANCES; A STALE EXPECTED REVISION IS REJECTED.
do
  local mgr = fittedManager()
  local ok, err = mgr:applyRainKeyCommand(1, "FIT", nil, 0)
  T.eq('fit.accepted', ok, true)
  T.eq('fit.fitted', mgr.systems[1].rainKeyFitted, true)
  T.eq('fit.revisionAdvanced', mgr.systems[1].rainKeyStateRevision, 1)

  mgr.systems[1].rainKeyStateRevision = 3
  local stale, staleErr = mgr:applyRainKeyCommand(1, "FIT", nil, 1)
  T.eq('stale.rejected', stale, false)
  T.eq('stale.code', staleErr, "STALE_CONFIRMATION")
end

-- 2. FIT / SET REQUIRE THE RELEASE ROW LIVE.
do
  ReleaseGate = { isSystemLive = function() return false end }
  local mgr = fittedManager()
  local ok, err = mgr:applyRainKeyCommand(1, "FIT", nil, 0)
  T.eq('release.fitsLocked', ok, false)
  T.eq('release.code', err, "RELEASE_LOCKED")
  T.eq('release.noMutation', mgr.systems[1].rainKeyFitted, nil)
  ReleaseGate = nil
end

-- 3. REMOVE SETTLES THE ALREADY-RUN INTERVAL FIRST.
do
  local mgr = fittedManager()
  mgr:applyRainKeyCommand(1, "FIT", nil, 0)
  mgr.systems[1].isActive = true
  mgr.systems[1].activeGameHoursSinceSettle = 2
  local water = { calls = 0, gain = 0 }
  mgr.manager.soilSystem = {
    fieldData = { [5] = { centerX = 0, centerZ = 0 } },
    applyWaterAtCell = function(_s, _fid, _x, _z, gain)
      water.calls = water.calls + 1
      water.gain = water.gain + gain
      return true
    end,
  }
  local charged = { amount = 0, farmId = 0 }
  mgr.manager.financeIntegration = {
    deductFundsVanilla = function(_fi, amount, farmId) charged.amount = amount; charged.farmId = farmId end,
  }
  mgr.getEffectiveCostPerHour = function(_self, _s) return 15 end
  local revBefore = mgr.systems[1].rainKeyStateRevision
  local ok, err = mgr:applyRainKeyCommand(1, "REMOVE", nil, revBefore)
  T.eq('remove.ok', ok, true)
  T.eq('remove.settledWater', water.calls, 1)
  T.near('remove.settledGain', water.gain, 0.036, 1e-6)   -- 0.018 * 1.0 * 2h
  T.near('remove.settledCost', charged.amount, 30, 1e-6)  -- 15 * 2h
  T.eq('remove.farm', charged.farmId, 2)
  T.eq('remove.clearedHours', mgr.systems[1].activeGameHoursSinceSettle, 0)
  T.eq('remove.unfitted', mgr.systems[1].rainKeyFitted, false)
end

-- 4. COMMAND EVENT WIRE CARRIES THE EXPECTED REVISION.
do
  local s = _sfMockStream()
  local cmd = CropStressRainKeyCommandEvent.new(1, "SET_TRIP_MM", 5.0, 4)
  cmd:writeStream(s)
  local got = CropStressRainKeyCommandEvent.emptyNew()
  got:readStream(s)
  T.eq('wire.systemId', got.systemId, 1)
  T.eq('wire.action', got.action, "SET_TRIP_MM")
  T.near('wire.value', got.value, 5.0, 1e-9)
  T.eq('wire.expectedRevision', got.expectedRevision, 4)
  T.eq('wire.streamClean', s.typeErrors + s.underflows, 0)
end

-- 5. RESULT EVENT WIRE CARRIES ACTION + STATE REVISION (F200 shape).
do
  local s = _sfMockStream()
  local res = CropStressRainKeyResultEvent.new(1, true, "OK", "FIT", 4)
  res:writeStream(s)
  local got = CropStressRainKeyResultEvent.emptyNew()
  got:readStream(s)
  T.eq('res.systemId', got.systemId, 1)
  T.eq('res.action', got.action, "FIT")
  T.eq('res.accepted', got.accepted, true)
  T.eq('res.resultCode', got.resultCode, "OK")
  T.eq('res.stateRevision', got.stateRevision, 4)
  T.eq('res.streamClean', s.typeErrors + s.underflows, 0)
end

T.summary()
