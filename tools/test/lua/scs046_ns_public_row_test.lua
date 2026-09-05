-- scs046_ns_public_row_test.lua
-- SCS-046 A (F200): the seven-field public irrigation animation row appended to
-- the NetworkSync moisture payload. systemId, isActive01, tripped01,
-- activityStateCode, pauseReasonCode, nextWakeKindCode, stateRevision. No owner,
-- source, schedule, coverage, rate, cost or rain total enters the public row.
-- An older payload without the block reads as neutral absent.
--!load: src/SoilMoistureSystem.lua, src/integrations/CropStressNetworkSyncBridge.lua

local function managerWithSystems()
  local irr = { systems = {
    [10] = { id = 10, isActive = true, rainKeyFitted = true, rainKeyTripped = false,
             rainKeyInputState = "OK", rainKeyStateRevision = 3 },
    [20] = { id = 20, isActive = false, rainKeyFitted = true, rainKeyTripped = true,
             rainKeyInputState = "OK", rainKeyStateRevision = 7 },
    [30] = { id = 30, isActive = false },
  } }
  return { irrigationManager = irr }
end

-- 1. SERIALIZE / DESERIALIZE ROUND TRIP keeps all seven public fields.
do
  local arr = CropStressNetworkSyncBridge.serializeIrrigation(managerWithSystems())
  T.eq('ns.marker', arr[1], CropStressNetworkSyncBridge.IRR_MARKER)
  T.eq('ns.count', arr[2], 3)

  local _fd, _fs, rows = CropStressNetworkSyncBridge.deserializeFields(
    { 0, CropStressNetworkSyncBridge.IRR_MARKER, 3,
      10, 1, 0, 1, 0, 0, 3,
      20, 0, 1, 2, 1, 1, 7,
      30, 0, 0, 0, 0, 0, 0 })
  T.eq('ns.rowCount', #rows, 3)
  T.eq('ns.sortedBySystem', rows[1].systemId, 10)
  T.eq('ns.runningActive', rows[1].isActive, true)
  T.eq('ns.runningActivity', rows[1].activityStateCode, 1)
  T.eq('ns.runningRevision', rows[1].stateRevision, 3)
  T.eq('ns.trippedRow', rows[2].tripped, true)
  T.eq('ns.trippedActivity', rows[2].activityStateCode, 2)
  T.eq('ns.trippedPause', rows[2].pauseReasonCode, 1)
  T.eq('ns.trippedNextWake', rows[2].nextWakeKindCode, 1)
  T.eq('ns.offActivity', rows[3].activityStateCode, 0)
  T.eq('ns.noPrivateOwner', rows[1].ownerFarmId, nil)
end

-- 2. AN OLD PAYLOAD WITHOUT THE BLOCK READS AS NEUTRAL ABSENT.
do
  local _fd, _fs, rows = CropStressNetworkSyncBridge.deserializeFields({ 1, 5, 0.6, 0.1 })
  T.eq('ns.oldPayloadAbsent', rows, nil)
end

-- 3. _onReadState STORES PUBLIC ROWS EVEN WHEN THE FINE MAP IS CURRENT.
do
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[5] = { moisture = 0.5 }
  soil.providerMode = "TRUTH"
  soil.valueMap = { available = true }
  local mgr = managerWithSystems()
  mgr.soilSystem = soil
  mgr.stressModifier = { fieldStress = {} }
  g_currentMission.cropStressManager = mgr

  local arr = CropStressNetworkSyncBridge.serializeFields({ [5] = { moisture = 0.9 } }, { [5] = 0.2 })
  local block = CropStressNetworkSyncBridge.serializeIrrigation(mgr)
  for i = 1, #block do arr[#arr + 1] = block[i] end
  CropStressNetworkSyncBridge._onReadState(arr)
  T.eq('read.storedRows', #mgr.irrigationManager._publicAnimationStates, 3)
  T.eq('read.rowRevision', mgr.irrigationManager._publicAnimationStates[1].stateRevision, 3)
  T.eq('read.moistureStillCurrentGround', soil.fieldData[5].moisture, 0.5)
  g_currentMission.cropStressManager = nil
end

T.summary()
