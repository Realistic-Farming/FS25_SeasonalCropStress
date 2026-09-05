-- scs046_join_push_test.lua
-- SCS-046 A / SDS 8: on a pure client join the server pushes that connection's
-- farm's COMPLETE private snapshot (CropStressIrrigationStateEvent) so the
-- client _clientFarmCurrent flag becomes current for exactly that farm.
--!load: src/IrrigationManager.lua, src/events/CropStressIrrigationStateEvent.lua

local function farmManager()
  g_i18n.hasText = function() return true end
  local mgr = IrrigationManager.new({})
  mgr.waterSources = {
    [1] = { id = 1, farmId = 2, finite = true, capacity = 48, waterRemaining = 40, hasWater = true },
  }
  mgr.systems = {
    [10] = { id = 10, type = "pivot", isActive = false, ownerFarmId = 2, waterSourceId = 1,
             coveredFields = { 5 }, schedule = {}, flowRatePerHour = 0.018, operationalCostPerHour = 15 },
  }
  return mgr
end

do
  g_server = {}
  local mgr = farmManager()
  g_currentMission.getFarmId = function(_m, connection)
    return connection ~= nil and connection.farmId or nil
  end
  local received = {}
  local conn = {
    farmId = 2,
    sendEvent = function(_c, ev)
      received[#received + 1] = ev
    end,
  }
  local ok = mgr:sendFarmPrivateState(conn)
  T.eq('push.sent', ok, true)
  T.eq('push.oneEvent', #received, 1)
  T.eq('push.farmId', received[1].farmId, 2)
  T.eq('push.systemRowCount', #received[1].systemRows, 1)
  T.eq('push.systemOwner', received[1].systemRows[1].ownerFarmId, 2)
  T.eq('push.sourceRowCount', #received[1].sourceRows, 1)

  -- An unresolved connection farm pushes nothing.
  local noFarm = { sendEvent = function() end }
  g_currentMission.getFarmId = function() return nil end
  T.eq('push.unresolvedNone', mgr:sendFarmPrivateState(noFarm), false)
  T.eq('push.unresolvedNoEvent', #received, 1)

  g_currentMission.getFarmId = nil
  g_server = nil
end

T.summary()
