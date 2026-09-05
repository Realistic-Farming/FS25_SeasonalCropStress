-- scs039_iris_review_fixes_test.lua
-- Discriminating tests for the seven contract gaps from Iris's combined Design
-- read on PR #172. Each fix keeps the behaviour the brief actually requires:
-- fail-closed never promotes retained ZONE data, a refused whole-field
-- replacement conserves pending and revision, positional reads validate and
-- report nil grain on absent zone cells, readable hourly mutations advance the
-- provider revision, the compact digest binds full leaf identity, save capture
-- refreshes dirty aggregates, and PENDING_ONLY binds the retained COMPLETE base.
--!load: src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua, src/maps/CropStressValueMap.lua

local UPR = 1 / CropStressValueMap.RAW_SPAN

local function newSysWithCell()
  local s = SoilMoistureSystem.new({})
  s.isInitialized = true
  s.fieldData[1] = {
    fieldId = 1, moisture = 0.5, soilType = "loamy", mapPending = 0,
    cells = { [0] = { [0] = { moisture = 0.9 } } }, cellSum = 0.9, cellCount = 1,
  }
  return s
end

-- FIX 1: a native failure never promotes retained ZONE data as current ground.
do
  local s = newSysWithCell()
  s.valueMap = { available = true, readValueAtWorld = function() return nil, nil, "PROVIDER_REFUSAL" end }
  s.providerMode = "TRUTH"
  local v, grain = s:getMoisture(1, 10, 10)
  T.eq('fix1.modeUnavailable', s.providerMode, "UNAVAILABLE_PENDING_RELOAD")
  T.eq('fix1.readNil', v, nil)
  T.eq('fix1.readNilGrain', grain, nil)

  -- A subsequent water call must not mutate the retained zone cell.
  local accepted = s:applyWaterAtCell(1, 10, 10, 0.05)
  T.eq('fix1.waterAcceptedIntoPending', accepted, true)
  T.near('fix1.zoneCellUnchanged', s.fieldData[1].cells[0][0].moisture, 0.9, 1e-12)
  T.near('fix1.fieldPendingGrew', s.fieldData[1].mapPending, 0.05, 1e-12)
  -- The failed provider never answers the retained cell again.
  v = s:getMoisture(1, 10, 10)
  T.eq('fix1.neverPromoted', v, nil)
end

-- FIX 2: a refused whole-field replacement conserves pending and revision.
do
  local s = newSysWithCell()
  s._mapWaterPending[1] = { [5] = 0.01 }
  s.fieldData[1].mapPending = 0.002
  s.fieldData[1].moisture = 0.6
  s._mapSeeded[1] = true
  s._fieldVerts[1] = { vx = { 0, 100, 100, 0 }, vz = { 0, 0, 100, 100 }, n = 4 }
  s.providerMode = "TRUTH"
  s.moistureRevision = 5
  s.valueMap = { available = true, paintPolygon = function() return false end }
  local ok = s:setMoisture(1, 0.8)
  T.eq('fix2.receiptFalse', ok, false)
  T.near('fix2.scalarKept', s.fieldData[1].moisture, 0.6, 1e-12)
  T.near('fix2.fieldPendingKept', s.fieldData[1].mapPending, 0.002, 1e-12)
  T.near('fix2.positionalKept', s._mapWaterPending[1][5], 0.01, 1e-12)
  T.eq('fix2.revisionKept', s.moistureRevision, 5)
end

-- FIX 3: mixed nil coordinates and non-finite input are rejected; an absent
-- zone cell reports the aggregate at nil grain.
do
  local s = SoilMoistureSystem.new({})
  s.isInitialized = true
  s.fieldData[1] = { fieldId = 1, moisture = 0.5, soilType = "loamy", cells = {} }
  local v, grain = s:getMoisture(1, 10, nil)
  T.eq('fix3.mixedNilValue', v, nil)
  T.eq('fix3.mixedNilGrain', grain, nil)
  v = s:getMoisture(1, math.huge, 10)
  T.eq('fix3.nonFiniteValue', v, nil)
  local nv, ng = s:getMoisture(1, 10, 10)
  T.near('fix3.absentZoneAggregate', nv, 0.5, 1e-12)
  T.eq('fix3.absentZoneNilGrain', ng, nil)
end

-- FIX 4: a readable hourly mutation advances the revision once; a pending-only
-- sub-step remainder does not.
do
  local function fakeWeather(irrigate)
    return {
      getHourlyEvapMultiplier = function() return 0 end,
      getHourlyRainAmount = function() return 0 end,
    }
  end
  local read = SoilMoistureSystem.new({})
  read.isInitialized = true
  read.fieldData[1] = { fieldId = 1, moisture = 0.5, soilType = "loamy" }
  read.irrigationGains[1] = 0.1
  local revBefore = read.moistureRevision
  read:hourlyUpdate(fakeWeather(), 1, 0, false, nil)
  T.near('fix4.readableMoistureMoved', read.fieldData[1].moisture, 0.6, 1e-9)
  T.eq('fix4.revisionAdvancedOnce', read.moistureRevision, revBefore + 1)

  local sub = SoilMoistureSystem.new({})
  sub.isInitialized = true
  sub.fieldData[1] = { fieldId = 1, moisture = 0.5, soilType = "loamy", mapPending = UPR * 0.5 }
  sub._mapSeeded[1] = true
  sub._fieldVerts[1] = { vx = { 0, 100, 100, 0 }, vz = { 0, 0, 100, 100 }, n = 4 }
  sub.providerMode = "TRUTH"
  sub.valueMap = { available = true }
  local revBefore2 = sub.moistureRevision
  sub:hourlyUpdate(fakeWeather(), 1, 0, false, nil)
  T.eq('fix4.subStepNoRevision', sub.moistureRevision, revBefore2)
end

-- FIX 5: the compact digest distinguishes equal-count/equal-total payloads with
-- different positions.
do
  local sh = SaveLoadHandler.new({})
  local function env(rows)
    return {
      schema = 2, payloadKind = "COMPLETE", generation = 1,
      moistureRevision = 7, lastSettledMonotonicDay = 20,
      aggregates = {}, fieldPending = {}, positionalRows = rows,
    }
  end
  local a = sh:compactDigest(env({
    { fieldId = 1, status = "RESOLVED", pixelKey = 5, amount = 0.01 },
    { fieldId = 2, status = "RESOLVED", pixelKey = 9, amount = 0.01 },
  }))
  local b = sh:compactDigest(env({
    { fieldId = 1, status = "RESOLVED", pixelKey = 9, amount = 0.01 },
    { fieldId = 2, status = "RESOLVED", pixelKey = 5, amount = 0.01 },
  }))
  T.eq('fix5.equalTotalsDifferentPositions', a ~= b, true)
  local c = sh:compactDigest(env({
    { fieldId = 1, status = "UNRESOLVED", worldX = 10, worldZ = 10, sourceWidth = 2, amount = 0.01 },
    { fieldId = 2, status = "UNRESOLVED", worldX = 20, worldZ = 20, sourceWidth = 2, amount = 0.01 },
  }))
  T.eq('fix5.resolvedVsUnresolvedDistinct', a ~= c, true)
end

-- FIX 6: save capture refreshes a dirty aggregate before freezing it.
do
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.5, aggregateDirty = true, mapPending = 0 }
  soil._refreshFieldAggregate = function(_self, _fieldId, d)
    d.moisture = 0.7
    d.aggregateDirty = false
  end
  soil.packMapWaterPending = function() return {} end
  soil.valueMap = { available = true }
  local sh = SaveLoadHandler.new({ soilSystem = soil })
  local env = sh:captureMoistureEnvelope()
  T.near('fix6.capturedFreshAggregate', env.aggregates[1], 0.7, 1e-12)
end

-- FIX 7: PENDING_ONLY binds the retained COMPLETE base, not current RAM.
do
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.5 }
  soil.packMapWaterPending = function() return {} end
  local sh = SaveLoadHandler.new({ soilSystem = soil })
  soil.moistureRevision = 7
  soil._lastSettledDay = 20
  local env1 = sh:captureMoistureEnvelope()
  T.eq('fix7.firstCompletes', sh:commitMoistureEnvelope(env1, true, true), "COMPLETE")

  soil.moistureRevision = 8
  soil._lastSettledDay = 21
  local env2 = sh:captureMoistureEnvelope()
  T.eq('fix7.nativeFails', sh:commitMoistureEnvelope(env2, false, true), "PENDING_ONLY")
  T.eq('fix7.baseGeneration', sh._pendingOnly.baseGeneration, 1)
  T.eq('fix7.baseRevisionRetained', sh._pendingOnly.baseRevision, 7)
  T.eq('fix7.baseCursorRetained', sh._pendingOnly.baseLastSettledMonotonicDay, 20)
end

T.summary()
