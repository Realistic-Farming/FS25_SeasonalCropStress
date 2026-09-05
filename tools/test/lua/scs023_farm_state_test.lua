-- scs023_farm_state_test.lua
-- SCS-023 / F200 (SDS 8): the public/private irrigation row split, the
-- travelled source keys, and the farm-private state event. getIrrigationSystems
-- (nil) omits private fields; the positive-farm server getter is current
-- immediately; a pure client returns nil until that farm's complete private
-- snapshot event applied, then mutation-safe copies.
--!load: src/IrrigationManager.lua, src/CropStressManager.lua, src/events/CropStressIrrigationStateEvent.lua

local function buildManager()
  local mgr = IrrigationManager.new({})
  mgr.waterSources = {
    [1] = { id = 1, farmId = 2, finite = true, capacity = 48, waterRemaining = 40, hasWater = true },
    [3] = { id = 3, farmId = 7, finite = false, waterRemaining = nil, hasWater = true },
  }
  mgr.systems = {
    [10] = { id = 10, type = "pivot", isActive = false, ownerFarmId = 2, waterSourceId = 1,
             coveredFields = { 5 }, schedule = {}, flowRatePerHour = 0.018, operationalCostPerHour = 15 },
    [20] = { id = 20, type = "pivot", isActive = true, ownerFarmId = 7, waterSourceId = 3,
             coveredFields = { 6 }, schedule = {}, flowRatePerHour = 0.02, operationalCostPerHour = 20 },
  }
  mgr.getSystemStopReason = function(_self, system)
    local source = mgr.waterSources[system.waterSourceId]
    if source == nil then return "no_source" end
    return nil
  end
  return mgr
end

local function fakeManager(irr)
  return setmetatable({ irrigationManager = irr }, { __index = CropStressManager })
end

-- 1. PUBLIC (nil) ROWS OMIT PRIVATE FIELDS; POSITIVE FARM ROWS CARRY THEM.
do
  local mgr = buildManager()
  local all = mgr:getIrrigationSystemsRows(nil)
  T.eq('rows.publicCount', #all, 2)
  T.eq('rows.publicOmitsOwner', all[1].ownerFarmId, nil)
  T.eq('rows.publicOmitsSource', all[1].waterSourceId, nil)

  local farm2 = mgr:getIrrigationSystemsRows(2)
  T.eq('rows.farmFiltered', #farm2, 1)
  T.eq('rows.privateOwner', farm2[1].ownerFarmId, 2)
  T.eq('rows.privateSource', farm2[1].waterSourceId, 1)
end

-- 2. TRAVELLED SOURCE KEYS (waterCapacity / isUnlimited / connectedSystemIds)
--    with legacy aliases retained.
do
  g_i18n.hasText = function() return true end
  local mgr = buildManager()
  local sources = mgr:getIrrigationWaterSources(2)
  T.eq('sources.filtered', #sources, 1)
  T.eq('sources.waterCapacity', sources[1].waterCapacity, 48)
  T.eq('sources.isUnlimited', sources[1].isUnlimited, false)
  T.eq('sources.connectedSystemIds', sources[1].connectedSystemIds[1], 10)
  T.eq('sources.legacyAliases', sources[1].capacity, 48)
  T.eq('sources.legacyUnlimitedAlias', sources[1].unlimited, false)
  T.eq('sources.legacyConnectedAlias', sources[1].connectedSystems[1], 10)
end

-- 3. SERVER FACADE IS CURRENT IMMEDIATELY; INVALID FARM IS NIL.
do
  g_server = {}
  local cm = fakeManager(buildManager())
  local farm2 = cm:getIrrigationSystems(2)
  T.eq('facade.serverFarmFiltered', #farm2, 1)
  T.eq('facade.serverOwner', farm2[1].ownerFarmId, 2)
  T.eq('facade.invalidFarmNil', cm:getIrrigationSystems(0), nil)
  T.eq('facade.nilFarmNotNil', cm:getIrrigationSystems(nil) ~= nil, true)
  T.eq('facade.sourcesServerImmediate', #cm:getIrrigationWaterSources(2), 1)
  g_server = nil
end

-- 4. PURE CLIENT: nil until the farm's complete private event applied, then
--    mutation-safe copies; a different farm stays nil.
do
  local irr = buildManager()
  local cm = fakeManager(irr)
  T.eq('client.beforeEventNil', cm:getIrrigationSystems(2), nil)
  T.eq('client.beforeSourcesNil', cm:getIrrigationWaterSources(2), nil)

  g_cropStressManager = cm
  local snap = irr:buildFarmPrivateSnapshot(2)
  local s = _sfMockStream()
  local ev = CropStressIrrigationStateEvent.new(2, snap.systemRows, snap.sourceRows)
  ev:writeStream(s)
  local got = CropStressIrrigationStateEvent.emptyNew()
  got:readStream(s)
  T.eq('client.eventStreamClean', s.typeErrors + s.underflows, 0)

  local rows = cm:getIrrigationSystems(2)
  T.eq('client.afterEventCurrent', #rows, 1)
  T.eq('client.afterEventOwner', rows[1].ownerFarmId, 2)
  local sources = cm:getIrrigationWaterSources(2)
  T.eq('client.afterEventSource', sources[1].waterCapacity, 48)
  T.eq('client.otherFarmStillNil', cm:getIrrigationSystems(7), nil)
  g_cropStressManager = nil
end

T.summary()
