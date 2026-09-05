-- scs023_irrigate_now_chain_test.lua
-- SCS-023 / F200 (SDS 6): ONE Irrigate Now chain,
-- CropStressIrrigateNowEvent -> applyIrrigateNowTransaction ->
-- CropStressIrrigateNowResultEvent. Every finite, Unlimited and mode-off entry
-- goes through the transaction wrapper; requester farm resolves only through
-- g_currentMission:getFarmId(connection); authorized results are stored per
-- farm, wrong_farm results are returned only and never stored. Request and
-- result event wire round trips carry the F200 streams.
--!load: src/IrrigationManager.lua, src/events/CropStressIrrigateNowEvent.lua, src/events/CropStressIrrigateNowResultEvent.lua

local function chainManager(finiteActive, sourceFinite)
  local mgr = IrrigationManager.new({ settings = { enabled = true } })
  mgr.waterSources = {}
  if sourceFinite ~= false then
    mgr.waterSources[1] = { id = 1, finite = true, capacity = 48, waterRemaining = 5, hasWater = true }
  else
    mgr.waterSources[1] = { id = 1, finite = false, waterRemaining = nil, hasWater = true }
  end
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, ownerFarmId = 2, type = "pivot",
             coveredFields = { 5 }, x = 0, z = 0, radius = 200,
             flowRatePerHour = 0.018, pressureMultiplier = 1.0 },
  }
  mgr.isFiniteWaterActive = function() return finiteActive end
  mgr.manager = { settings = { enabled = true } }
  mgr._fieldsForId = function(_self, _fid) return { { polygonPoints = { 1 } } } end
  mgr.getFieldPolygonWorld = function(_self, _f) return { -10, 10, 10 }, { -10, -10, 10 }, 3 end
  mgr._cellsInPolygon = function(_self, _vx, _vz, _n, _cs)
    return { { wx = 0, wz = 0 } }
  end
  mgr.manager.soilSystem = {
    fieldData = { [5] = { moisture = 0.5 } },
    getCellSize = function() return 2 end,
    applyWaterAtCell = function() return true end,
  }
  return mgr
end

-- 1. GATES: wrong farm, master disabled, stale fitted confirmation.
do
  local mgr = chainManager(true, true)
  local r = mgr:applyIrrigateNowTransaction(10, 9, -1)
  T.eq('chain.wrongFarm', r.resultCode, "wrong_farm")
  T.eq('chain.wrongFarmNotAccepted', r.accepted, false)

  mgr.manager.settings.enabled = false
  r = mgr:applyIrrigateNowTransaction(10, 2, -1)
  T.eq('chain.masterDisabled', r.resultCode, "master_disabled")
  mgr.manager.settings.enabled = true

  mgr.systems[10].StateRevision = 7
  r = mgr:applyIrrigateNowTransaction(10, 2, 3)
  T.eq('chain.staleConfirmation', r.resultCode, "stale_confirmation")
  T.eq('chain.staleNoMutation', mgr.waterSources[1].waterRemaining, 5)
  r = mgr:applyIrrigateNowTransaction(10, 2, 7)
  T.ok('chain.matchingRevisionProceeds', r.accepted == true or r.resultCode == "no_ground")
end

-- 2. MODE OFF / UNLIMITED full service, no remainder write.
do
  local mgr = chainManager(false, true)
  local r = mgr:applyIrrigateNowTransaction(10, 2, -1)
  T.eq('chain.modeOffCode', r.resultCode, "success")
  T.near('chain.modeOffFraction', r.servedFraction, 1, 1e-9)
  T.eq('chain.modeOffCommittedZero', r.committedHours, 0)
  T.near('chain.modeOffRemainderUntouched', mgr.waterSources[1].waterRemaining, 5, 1e-9)
end

-- 3. DISPATCH stores only authorized results for the farm.
do
  local mgr = chainManager(false, false)
  local farmId = 2
  local okResult = { accepted = true, resultCode = "success", servedFraction = 1,
    acceptedTargetCount = 3, committedHours = 0, stateRevision = 0 }
  mgr:dispatchIrrigateNowResult(10, okResult, nil, farmId)
  T.eq('dispatch.stored', mgr.lastIrrigateNowResultByFarm[2] ~= nil, true)
  T.eq('dispatch.storedCode', mgr.lastIrrigateNowResultByFarm[2].resultCode, "success")

  local wrong = { accepted = false, resultCode = "wrong_farm", servedFraction = 0,
    acceptedTargetCount = 0, committedHours = 0, stateRevision = 0 }
  mgr:dispatchIrrigateNowResult(10, wrong, nil, 99)
  T.eq('dispatch.wrongNotStored', mgr.lastIrrigateNowResultByFarm[99], nil)
end

-- 4. FARM RESOLVER uses the engine getFarmId only.
do
  local mgr = chainManager(false, false)
  g_currentMission.getFarmId = function(_m, _connection) return 2 end
  T.eq('resolve.engineFarm', mgr:resolveRequesterFarmId({}), 2)
  g_currentMission.getFarmId = function() return 0 end
  T.eq('resolve.rejectsNonOrdinary', mgr:resolveRequesterFarmId({}), nil)
  g_currentMission.getFarmId = nil
end

-- 5. EVENT WIRE ROUND TRIPS.
do
  local s = _sfMockStream()
  local req = CropStressIrrigateNowEvent.new(10, 7)
  req:writeStream(s)
  local got = CropStressIrrigateNowEvent.emptyNew()
  got:readStream(s)
  T.eq('req.systemId', got.systemId, 10)
  T.eq('req.expectedRevision', got.expectedRainKeyRevision, 7)
  T.eq('req.streamClean', s.typeErrors + s.underflows, 0)

  s = _sfMockStream()
  local res = CropStressIrrigateNowResultEvent.new(10, {
    accepted = true, resultCode = "partial", servedFraction = 0.4,
    acceptedTargetCount = 2, committedHours = 0.4, stateRevision = 7 })
  res:writeStream(s)
  local gotRes = CropStressIrrigateNowResultEvent.emptyNew()
  gotRes:readStream(s)
  T.eq('res.systemId', gotRes.systemId, 10)
  T.eq('res.accepted', gotRes.accepted, true)
  T.eq('res.resultCode', gotRes.resultCode, "partial")
  T.near('res.servedFraction', gotRes.servedFraction, 0.4, 1e-9)
  T.eq('res.acceptedTargetCount', gotRes.acceptedTargetCount, 2)
  T.near('res.committedHours', gotRes.committedHours, 0.4, 1e-9)
  T.eq('res.stateRevision', gotRes.stateRevision, 7)
  T.eq('res.streamClean', s.typeErrors + s.underflows, 0)
end

T.summary()
