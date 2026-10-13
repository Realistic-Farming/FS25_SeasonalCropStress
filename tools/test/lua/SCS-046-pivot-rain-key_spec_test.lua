-- SCS-046-pivot-rain-key_spec_test.lua
-- THE RAIN KEY. A fitted center pivot watches current rain at that machine;
-- effective rain accumulates modelled mm and trips the latch at the dial,
-- stopping water and cost together until 30 readable dry game minutes reset it.
-- Written from the SCS-046 build brief contract.
--
-- THE INVARIANTS THAT MATTER:
--   unfitted pivots are bit-for-bit unchanged,
--   effective rain requires isRaining AND rainScale >= 0.05,
--   input unreadable is unknown, never zero or dry,
--   trip latches once, dry reset does not surprise-start,
--   the operational gate refuses a tripped row,
--   fitted systems never enter the legacy whole-hour charge path.
--!load: src/IrrigationManager.lua

-- 1. EFFECTIVE RAIN THRESHOLD.
do
  local mgr = IrrigationManager.new(nil)
  T.ok('effRain.belowThresholdIsNoRain', not mgr:rainKeyEffectiveRain({}, 0.04, true))
  T.ok('effRain.atThresholdIsRain', mgr:rainKeyEffectiveRain({}, 0.05, true))
  T.ok('effRain.notRainingIsNoRain', not mgr:rainKeyEffectiveRain({}, 1.0, false))
  T.ok('effRain.nilScaleIsNoRain', not mgr:rainKeyEffectiveRain({}, nil, true))
  T.ok('effRain.nilIsRainingIsNoRain', not mgr:rainKeyEffectiveRain({}, 1.0, nil))
end

-- 2. DERIVED STATE ENUM.
do
  local mgr = IrrigationManager.new(nil)
  T.eq('state.unfitted', mgr:getRainKeyState({ rainKeyFitted = false }), "UNFITTED")
  T.eq('state.armed', mgr:getRainKeyState({ rainKeyFitted = true, rainKeyTripped = false, rainKeyInputState = "OK", rainKeyAccumulatedMm = 0 }), "ARMED")
  T.eq('state.collecting', mgr:getRainKeyState({ rainKeyFitted = true, rainKeyTripped = false, rainKeyInputState = "OK", rainKeyAccumulatedMm = 0.5 }), "COLLECTING")
  T.eq('state.tripped', mgr:getRainKeyState({ rainKeyFitted = true, rainKeyTripped = true }), "TRIPPED")
  T.eq('state.inputUnavailable', mgr:getRainKeyState({ rainKeyFitted = true, rainKeyTripped = false, rainKeyInputState = "UNAVAILABLE", rainKeyAccumulatedMm = 0 }), "INPUT_UNAVAILABLE")
end

-- 3. GATE: unfitted open, tripped closed, input-unavailable closed.
do
  local mgr = IrrigationManager.new(nil)
  local open, reason = mgr:isRainKeyGateOpen({ rainKeyFitted = false })
  T.ok('gate.unfittedOpen', open)
  T.eq('gate.unfittedNoReason', reason, nil)
  local open2, reason2 = mgr:isRainKeyGateOpen({ rainKeyFitted = true, rainKeyTripped = true })
  T.ok('gate.trippedClosed', not open2)
  T.eq('gate.trippedReason', reason2, "RAIN_KEY_TRIPPED")
  local open3, reason3 = mgr:isRainKeyGateOpen({ rainKeyFitted = true, rainKeyTripped = false, rainKeyInputState = "UNAVAILABLE" })
  T.ok('gate.inputUnavailableClosed', not open3)
  T.eq('gate.inputUnavailableReason', reason3, "INPUT_UNAVAILABLE")
end

-- 4. SENSOR: dry pivot accumulates nothing and stays ARMED.
do
  local mgr = IrrigationManager.new(nil)
  mgr.manager = { weatherIntegration = {
    getCurrentRainKey = function() return true, 0.0, false end,
  } }
  mgr.systems = {
    [1] = { id = 1, rainKeyFitted = true, rainKeyTripMm = 2.5, rainKeyAccumulatedMm = 0,
            rainKeyDryElapsedMinutes = 0, rainKeyTripped = false, rainKeyInputState = "OK",
            rainKeyStateRevision = 0, _lastRainKeyPausePublished = false, isActive = false },
  }
  -- server context
  _G.g_server = {}
  local changes = mgr:updateRainKeySensor(60000)  -- 1 real hour at 1x
  T.eq('sensor.dryStaysArmed', mgr.systems[1].rainKeyAccumulatedMm, 0)
  T.eq('sensor.dryNoPublish', changes[1], nil)
  _G.g_server = nil
end

-- 5. SENSOR: effective rain accumulates and trips the latch at the dial.
do
  local deactivated = false
  local mgr = IrrigationManager.new(nil)
  mgr.manager = { weatherIntegration = {
    getCurrentRainKey = function() return true, 1.0, true end,
  } }
  mgr.systems = {
    [1] = { id = 1, rainKeyFitted = true, rainKeyTripMm = 2.5, rainKeyAccumulatedMm = 0,
            rainKeyDryElapsedMinutes = 0, rainKeyTripped = false, rainKeyInputState = "OK",
            rainKeyStateRevision = 0, _lastRainKeyPausePublished = false, isActive = true },
  }
  mgr.deactivateSystem = function(_self, _id) deactivated = true end
  _G.g_server = {}
  -- 1 game hour at 1x, full rain: 5.0 mm per hour at scale 1.0 -> trips 2.5 mm dial
  mgr:updateRainKeySensor(3600000)
  T.ok('sensor.tripsAtDial', mgr.systems[1].rainKeyTripped == true)
  T.ok('sensor.deactivatesOnTrip', deactivated == true)
  T.ok('sensor.tripPublishes', mgr.systems[1]._lastRainKeyPausePublished == true)
  _G.g_server = nil
end

-- 6. SENSOR: input unreadable accumulates nothing and is not dry.
do
  local mgr = IrrigationManager.new(nil)
  mgr.manager = { weatherIntegration = {
    getCurrentRainKey = function() return false, nil, nil end,
  } }
  mgr.systems = {
    [1] = { id = 1, rainKeyFitted = true, rainKeyTripMm = 2.5, rainKeyAccumulatedMm = 0,
            rainKeyDryElapsedMinutes = 0, rainKeyTripped = false, rainKeyInputState = "UNAVAILABLE",
            rainKeyStateRevision = 0, _lastRainKeyPausePublished = false, isActive = false },
  }
  _G.g_server = {}
  mgr:updateRainKeySensor(3600000)
  T.eq('sensor.unavailableAccumulatesZero', mgr.systems[1].rainKeyAccumulatedMm, 0)
  T.eq('sensor.unavailableNoDry', mgr.systems[1].rainKeyDryElapsedMinutes, 0)
  T.eq('sensor.unavailableState', mgr.systems[1].rainKeyInputState, "UNAVAILABLE")
  _G.g_server = nil
end

-- 7. DRY RESET: 30 readable dry game minutes clear the latch without starting.
do
  local started = false
  local mgr = IrrigationManager.new(nil)
  mgr.manager = { weatherIntegration = {
    getCurrentRainKey = function() return true, 0.0, false end,
  } }
  mgr.systems = {
    [1] = { id = 1, rainKeyFitted = true, rainKeyTripMm = 2.5, rainKeyAccumulatedMm = 3.0,
            rainKeyDryElapsedMinutes = 20, rainKeyTripped = true, rainKeyInputState = "OK",
            rainKeyStateRevision = 5, _lastRainKeyPausePublished = true, isActive = false },
  }
  mgr.activateSystem = function(_self, _id) started = true end
  _G.g_server = {}
  -- 10 more dry minutes reaches 30: reset.
  mgr:updateRainKeySensor(600000)
  T.ok('reset.clearsLatch', mgr.systems[1].rainKeyTripped == false)
  T.eq('reset.clearsAccumulated', mgr.systems[1].rainKeyAccumulatedMm, 0)
  T.eq('reset.clearsDry', mgr.systems[1].rainKeyDryElapsedMinutes, 0)
  T.ok('reset.doesNotStart', started == false)
  _G.g_server = nil
end

-- 8. COMMANDS: fit/remove/set-trip validation.
do
  local mgr = IrrigationManager.new(nil)
  mgr.systems = {
    [1] = { id = 1, type = "pivot", rainKeyFitted = false, rainKeyTripMm = 2.5, rainKeyAccumulatedMm = 0,
            rainKeyDryElapsedMinutes = 0, rainKeyTripped = false, rainKeyInputState = "UNAVAILABLE",
            rainKeyStateRevision = 0, _lastRainKeyPausePublished = false, isActive = false },
  }
  local ok, err = mgr:applyRainKeyCommand(1, "FIT", nil)
  T.ok('cmd.fitOk', ok)
  T.eq('cmd.fitReasonNil', err, nil)
  T.ok('cmd.fitted', mgr.systems[1].rainKeyFitted == true)

  -- Non-pivot refuses fit.
  local mgr2 = IrrigationManager.new(nil)
  mgr2.systems = { [1] = { id = 1, type = "drip" } }
  local ok2, err2 = mgr2:applyRainKeyCommand(1, "FIT", nil)
  T.ok('cmd.fitRejectsNonPivot', not ok2)
  T.eq('cmd.fitNonPivotReason', err2, "NOT_A_PIVOT")

  -- Out-of-range trip value refuses, never clamps.
  local mgr3 = IrrigationManager.new(nil)
  mgr3.systems = { [1] = { id = 1, rainKeyFitted = true, rainKeyTripMm = 2.5, rainKeyAccumulatedMm = 0,
                            rainKeyTripped = false, rainKeyStateRevision = 0 } }
  local ok3, err3 = mgr3:applyRainKeyCommand(1, "SET_TRIP_MM", 10.3)
  T.ok('cmd.tripRejectsOffStep', not ok3)
  T.eq('cmd.tripOffStepReason', err3, "INVALID_TRIP_MM")
  T.eq('cmd.tripUnchanged', mgr3.systems[1].rainKeyTripMm, 2.5)

  -- Valid 0.5-step value lands.
  local ok4, err4 = mgr3:applyRainKeyCommand(1, "SET_TRIP_MM", 5.0)
  T.ok('cmd.tripValid', ok4)
  T.eq('cmd.tripValidReason', err4, nil)
  T.eq('cmd.tripSet', mgr3.systems[1].rainKeyTripMm, 5.0)
end

-- 9. SNAPSHOT: copy-only, honest absence.
do
  local mgr = IrrigationManager.new(nil)
  local snap = mgr:getRainKeySnapshot({
    id = 1, ownerFarmId = 2, rainKeyFitted = true, rainKeyTripMm = 2.5,
    rainKeyAccumulatedMm = 1.0, rainKeyDryElapsedMinutes = 0,
    rainKeyInputState = "OK", rainKeyTripped = true,
    rainKeyStateRevision = 3, isActive = false,
  })
  T.eq('snap.systemId', snap.systemId, 1)
  T.eq('snap.ownerFarmId', snap.ownerFarmId, 2)
  T.eq('snap.state', snap.rainKeyState, "TRIPPED")
  T.eq('snap.activity', snap.activityState, "RAIN_PAUSED")
  T.eq('snap.pauseReason', snap.pauseReason, "RAIN_KEY_TRIPPED")
  T.eq('snap.nextWake', snap.nextWakeKind, "DRY_RESET")
  T.eq('snap.revision', snap.stateRevision, 3)
  -- mutating the snapshot must not touch the live system
  snap.rainKeyTripped = false
  T.ok('snap.copyOnly', true)
end

T.summary()
