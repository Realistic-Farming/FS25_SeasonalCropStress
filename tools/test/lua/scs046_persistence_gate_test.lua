-- scs046_persistence_gate_test.lua
-- SCS-046: fitted rain-key latch and dial persist through the StateLedger table
-- mirror (and the own-XML keys are written/read identically), and the rain-key
-- sensor freezes when SCS master or the rain_key_pause release row is off.
--!load: src/SoilMoistureSystem.lua, src/IrrigationManager.lua, src/SaveLoadHandler.lua

local function baseManager()
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.5, soilType = "loamy" }
  local irr = { systems = {}, activateSystem = function() end }
  irr.systems[10] = {
    id = 10, schedule = { startHour = 6, endHour = 10,
                          activeDays = { true, true, true, true, true, false, false } },
    isActive = false,
    rainKeyFitted = true, rainKeyTripMm = 5.0, rainKeyAccumulatedMm = 2.0,
    rainKeyDryElapsedMinutes = 3, rainKeyTripped = false,
    rainKeyStateRevision = 4, rainKeyInputState = "OK",
  }
  return {
    soilSystem = soil,
    stressModifier = { fieldStress = {}, getStress = function() return 0 end },
    irrigationManager = irr,
    npcIntegration = nil,
  }
end

-- 1. RAIN-KEY LATCH AND DIAL SURVIVE THE LEDGER TABLE ROUND TRIP.
do
  local mgr = baseManager()
  local sh = SaveLoadHandler.new(mgr)
  sh:initialize()
  local state = sh:buildStateTable()
  local entry = state.irrigation[10]
  T.eq('build.rkFitted', entry.rkFitted, true)
  T.near('build.rkTripMm', entry.rkTripMm, 5.0, 1e-9)
  T.near('build.rkAccMm', entry.rkAccMm, 2.0, 1e-9)
  T.near('build.rkDryMin', entry.rkDryMin, 3, 1e-9)
  T.eq('build.rkRev', entry.rkRev, 4)
  T.eq('build.rkInput', entry.rkInput, "OK")

  local mgr2 = baseManager()
  local target = mgr2.irrigationManager.systems[10]
  target.rainKeyFitted = nil
  target.rainKeyTripMm = 2.5
  target.rainKeyAccumulatedMm = 0
  local sh2 = SaveLoadHandler.new(mgr2)
  sh2:initialize()
  sh2:applyStateTable(state)
  T.eq('restore.fitted', target.rainKeyFitted, true)
  T.near('restore.tripMm', target.rainKeyTripMm, 5.0, 1e-9)
  T.near('restore.accMm', target.rainKeyAccumulatedMm, 2.0, 1e-9)
  T.near('restore.dryMin', target.rainKeyDryElapsedMinutes, 3, 1e-9)
  T.eq('restore.revision', target.rainKeyStateRevision, 4)
  T.eq('restore.input', target.rainKeyInputState, "OK")
end

-- 2. THE RAIN-KEY SENSOR FREEZES WHEN MASTER OR THE RELEASE ROW IS OFF.
do
  local function sensorMgr(enabled, releaseLive)
    local settings = { enabled = enabled }
    if releaseLive ~= nil then
      ReleaseGate = { isSystemLive = function() return releaseLive end }
    else
      ReleaseGate = nil
    end
    g_server = {}
    local mgr = IrrigationManager.new({ settings = settings, weatherIntegration = {
      getCurrentRainKey = function() return false end,
    } })
    mgr.systems = {
      [10] = { id = 10, rainKeyFitted = true, rainKeyTripped = false,
               rainKeyInputState = "OK", rainKeyAccumulatedMm = 0 },
    }
    return mgr
  end

  local disabled = sensorMgr(false, nil)
  T.eq('gate.masterDisabledFreezes', #disabled:updateRainKeySensor(16), 0)

  local locked = sensorMgr(true, false)
  T.eq('gate.releaseLockedFreezes', #locked:updateRainKeySensor(16), 0)
  T.eq('gate.releaseLockedNoAccum', locked.systems[10].rainKeyAccumulatedMm, 0)

  g_server = nil
  ReleaseGate = nil
end

T.summary()
