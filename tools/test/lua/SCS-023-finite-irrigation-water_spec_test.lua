-- SCS-023-finite-irrigation-water_spec_test.lua
-- FINITE IRRIGATION WATER. A pump carries a finite store in irrigation-hours;
-- scheduled systems and Irrigate Now consume it, rain refills it, and a dry
-- source stops its systems and says why. Written from the SCS-023 build brief.
--
-- THE INVARIANTS THAT MATTER:
--   capacity <= 0 is Unlimited (no remainder write or draw),
--   draw per scheduled system-hour = pressureMultiplier * finiteWaterDrawScale,
--   source draw and served hours are per system-hour, never multiplied by area,
--   dry source derives stopReason, farm-filtered rows only,
--   Irrigate Now is a fixed 1.0 requestedDraw transaction with servedFraction,
--   the 0.4-remaining partial case is the exact numeric contract.
--!load: src/IrrigationManager.lua

-- 1. SOURCE STATE: finite vs unlimited, remainder and hasWater.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = {}
  mgr:registerWaterSource({
    id = 1, x = 0, y = 0, z = 0, waterFlowCapacity = 1000,
    waterUnitsCapacity = 48.0, waterRemaining = 48.0, ownerFarmId = 1,
    waterUnitsRefillPerRainHour = 2.0,
  })
  T.ok('source.finiteRegistered', mgr.waterSources[1].finite == true)
  T.eq('source.finiteCapacity', mgr.waterSources[1].capacity, 48.0)
  T.ok('source.finiteHasWater', mgr.waterSources[1].hasWater == true)
  T.eq('source.retainsAuthoredRefill', mgr.waterSources[1].waterUnitsRefillPerRainHour, 2.0)
end

-- 2. UNLIMITED: capacity <= 0 means no remainder ever.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = {}
  mgr:registerWaterSource({
    id = 2, x = 0, y = 0, z = 0, waterFlowCapacity = 1000,
    waterUnitsCapacity = 0, ownerFarmId = 1,
  })
  T.ok('source.unlimitedFlag', mgr.waterSources[2].finite == false)
  T.eq('source.unlimitedRemainderNil', mgr.waterSources[2].waterRemaining, nil)
end

-- 3. SET REMAINDER clamps and derives hasWater.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 48, hasWater = true } }
  mgr:setSourceWaterRemaining(1, 0.5, false)
  T.eq('set.remainder', mgr.waterSources[1].waterRemaining, 0.5)
  T.ok('set.stillWet', mgr.waterSources[1].hasWater == true)
  mgr:setSourceWaterRemaining(1, -5, false)
  T.eq('set.clampToZero', mgr.waterSources[1].waterRemaining, 0)
  T.ok('set.dryAtZero', mgr.waterSources[1].hasWater == false)
end

-- 4. SCHEDULED HOUR detection (F160-safe day/hour).
do
  local mgr = IrrigationManager.new(nil)
  local sys = { schedule = { startHour = 6, endHour = 10, activeDays = {true,true,true,true,true,false,false} } }
  -- hourKey for day 1 hour 7 = 31
  T.ok('sched.inWindow', mgr:isScheduledAtHour(sys, 1 * 24 + 7))
  T.ok('sched.notInWindow', not mgr:isScheduledAtHour(sys, 1 * 24 + 11))
  -- weekend off (day 6 = Saturday, dow 6 -> activeDays[6] false)
  T.ok('sched.weekendOff', not mgr:isScheduledAtHour(sys, 6 * 24 + 7))
end

-- 5. COLLECT SCHEDULED HOURS (inactive mode, fraction 1.0, no mutation).
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 48, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  local served = mgr:collectScheduledHours(6, 1 * 24 + 6)
  T.eq('collect.servedHours', served[10], 6)
  T.eq('collect.noRemainderMutation', mgr.waterSources[1].waterRemaining, 48)
end

-- 6. FINITE PLANNER (PURE) + COMMIT: six ordinary hours serve the draw, the
--    plan writes nothing, and commitFiniteWaterPlan debits exactly once.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 6.0, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr.setSourceWaterRemaining = function(_self, sid, v)
    local src = mgr.waterSources[sid]
    src.waterRemaining = v
    src.hasWater = v > 0
  end
  -- 6 scheduled hours at draw scale 1.0 x pressure 1.0 = 6 irrigation-hours.
  local plan = mgr:planFiniteWater(6, 1 * 24 + 6, 0.0, false)
  T.eq('planner.served', plan.servedHoursBySystem[10], 6)
  T.eq('planner.pureNoWrite', mgr.waterSources[1].waterRemaining, 6)
  T.ok('planner.pureStillWet', mgr.waterSources[1].hasWater == true)
  T.eq('planner.planCarriesAfter', plan.sourceRows[1].after, 0)
  mgr:commitFiniteWaterPlan(plan)
  T.eq('planner.remainderAfterCommit', mgr.waterSources[1].waterRemaining, 0)
  T.ok('planner.nowDry', mgr.waterSources[1].hasWater == false)
end

-- 6b. CAPACITY CLAMP: rain refill never pushes a finite store past capacity.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 5, waterRemaining = 4.5, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr.setSourceWaterRemaining = function(_self, sid, v)
    local src = mgr.waterSources[sid]
    src.waterRemaining = v
    src.hasWater = v > 0
  end
  -- refill 2.0 on 4.5 would reach 6.5; capacity 5 clamps it, then the one
  -- scheduled hour draws 1.0, so the plan carries 4.0 (not 5.5 uncapped).
  local plan = mgr:planFiniteWater(1, 1 * 24 + 6, 1.0, true)
  T.near('clamp.afterCapped', plan.sourceRows[1].after, 4.0, 1e-9)
end

-- 7. FINITE PLANNER (PURE) + COMMIT: rain refill is added when isRaining, and
--    the authored refill rate rides the plan.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 1.0, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr.setSourceWaterRemaining = function(_self, sid, v)
    local src = mgr.waterSources[sid]
    src.waterRemaining = v
    src.hasWater = v > 0
  end
  -- rainScale 1.0 for 1 hour: refill 2.0, then 1.0 consumed by the scheduled hour.
  local plan = mgr:planFiniteWater(1, 1 * 24 + 6, 1.0, true)
  T.eq('planner.refillServed', plan.servedHoursBySystem[10], 1)
  T.near('planner.planAfterRefill', plan.sourceRows[1].after, 2.0, 1e-9)
  T.near('planner.remainderUnchangedWhilePure', mgr.waterSources[1].waterRemaining, 1.0, 1e-9)
  mgr:commitFiniteWaterPlan(plan)
  T.near('planner.remainderAfterCommitRefill', mgr.waterSources[1].waterRemaining, 2.0, 1e-9)
end

-- 8. STOP REASON derives from the bound source.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, hasWater = false } }
  mgr.systems = { [10] = { id = 10, waterSourceId = 1 } }
  T.eq('reason.drySource', mgr:getSystemStopReason(mgr.systems[10]), "dry_source")
  local mgr2 = IrrigationManager.new(nil)
  mgr2.waterSources = {}
  mgr2.systems = { [10] = { id = 10, waterSourceId = 999 } }
  T.eq('reason.noSource', mgr2:getSystemStopReason(mgr2.systems[10]), "no_source")
end

-- 9. FARM-FILTERED READ ROWS carry owner + reason; unfiltered does not.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, hasWater = false, farmId = 2 } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, ownerFarmId = 2, type = "pivot", isActive = false, coveredFields = {}, flowRatePerHour = 0.018, operationalCostPerHour = 15 },
  }
  local rows = mgr:getIrrigationSystemsRows(2)
  T.eq('rows.ownerFarm', rows[1].ownerFarmId, 2)
  T.eq('rows.stopReason', rows[1].stopReason, "dry_source")
end

-- 10. IRRIGATE NOW TRANSACTION: the fixed partial case (remaining 0.4 vs 1.0).
do
  local mgr = IrrigationManager.new(nil)
  mgr.manager = { soilSystem = {
    fieldData = { [5] = { centerX = 0, centerZ = 0 } },
    getCellSize = function() return 2 end,
    applyWaterAtCell = function(_self, fid, x, z, gain) return true end,
  } }
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 0.4, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, ownerFarmId = 2, type = "pivot", isActive = false,
             coveredFields = { 5 }, x = 0, z = 0, radius = 200,
             flowRatePerHour = 0.018, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr.setSourceWaterRemaining = function(_self, sid, v)
    local src = mgr.waterSources[sid]
    src.waterRemaining = v
    src.hasWater = v > 0
  end
  mgr._fieldsForId = function(_self, _fid) return { { polygonPoints = { 1, 2, 3 } } } end
  mgr.getFieldPolygonWorld = function(_self, _f) return { -10, 10, 10 }, { -10, -10, 10 }, 3 end
  mgr.isFiniteWaterActive = function() return true end
  local r = mgr:applyIrrigateNowTransaction(10, 2)
  T.ok('txn.partialAccepted', r.accepted == true)
  T.eq('txn.partialCode', r.resultCode, "partial")
  T.near('txn.partialFraction', r.servedFraction, 0.4, 1e-9)
  T.near('txn.partialCommitted', r.committedHours, 0.4, 1e-9)
  T.ok('txn.partialCountPositive', r.acceptedTargetCount > 0)
  T.near('txn.partialRemainder', mgr.waterSources[1].waterRemaining, 0, 1e-9)
end

-- 11. IRRIGATE NOW: wrong farm refuses.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 5, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, ownerFarmId = 2, type = "pivot", isActive = false,
             coveredFields = { 5 }, flowRatePerHour = 0.018, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr.isFiniteWaterActive = function() return true end
  local r = mgr:applyIrrigateNowTransaction(10, 9)
  T.ok('txn.wrongFarmRejects', r.accepted == false)
  T.eq('txn.wrongFarmCode', r.resultCode, "wrong_farm")
end

-- 12. UNLIMITED Irrigate Now never mutates remainder, commits 0.
do
  local mgr = IrrigationManager.new(nil)
  mgr.manager = { soilSystem = {
    fieldData = { [5] = { centerX = 0, centerZ = 0 } },
    getCellSize = function() return 2 end,
    applyWaterAtCell = function(_self, fid, x, z, gain) return true end,
  } }
  mgr.waterSources = { [1] = { id = 1, finite = false, capacity = nil, waterRemaining = nil, hasWater = true } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, ownerFarmId = 2, type = "pivot", isActive = false,
             coveredFields = { 5 }, x = 0, z = 0, radius = 200,
             flowRatePerHour = 0.018, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr._fieldsForId = function(_self, _fid) return { { polygonPoints = { 1, 2, 3 } } } end
  mgr.getFieldPolygonWorld = function(_self, _f) return { -10, 10, 10 }, { -10, -10, 10 }, 3 end
  mgr.isFiniteWaterActive = function() return true end
  local r = mgr:applyIrrigateNowTransaction(10, 2)
  T.ok('txn.unlimitedAccepted', r.accepted == true)
  T.eq('txn.unlimitedCommitted', r.committedHours, 0)
  T.eq('txn.unlimitedRemainderUnchanged', mgr.waterSources[1].waterRemaining, nil)
end

-- 13. COVER FIELD EVIDENCE (SDS 5.2): ownership gate + literal-true receipts.
do
  local function coverMgr(receiptValue)
    local mgr = IrrigationManager.new(nil)
    local calls = { water = 0 }
    mgr.manager = { soilSystem = {
      fieldData = { [5] = { moisture = 0.5 } },
      getCellSize = function() return 2 end,
      applyWaterAtCell = function(_self, _fid, _x, _z, _g)
        calls.water = calls.water + 1
        return receiptValue
      end,
    } }
    mgr._fieldsForId = function(_self, _fid) return { { polygonPoints = { 1 } } } end
    mgr.getFieldPolygonWorld = function(_self, _f) return { -10, 10, 10 }, { -10, -10, 10 }, 3 end
    mgr._cellsInPolygon = function(_self, _vx, _vz, _n, _cs)
      return { { wx = 0, wz = 0 }, { wx = 1, wz = 1 } }
    end
    mgr._calls = calls
    return mgr
  end

  g_farmlandManager = { farmlandMapping = { [5] = 2 } }

  local owned = coverMgr(true)
  owned.systems = { [10] = { id = 10, ownerFarmId = 2, type = "pivot",
    coveredFields = { 5 }, x = 0, z = 0, radius = 200, pressureMultiplier = 1.0 } }
  local ev = owned:applyGainToSystemCoverage(owned.systems[10], 0.018)
  T.eq('cover.ownedAccepted', ev.fields[5], "ACCEPTED")
  T.eq('cover.wroteOwnedField', owned._calls.water, 2)
  T.eq('cover.notLegacy', ev.wholeActLegacy, false)

  local refusedFarm = coverMgr(true)
  refusedFarm.systems = { [10] = { id = 10, ownerFarmId = 2, type = "pivot",
    coveredFields = { 5 }, x = 0, z = 0, radius = 200, pressureMultiplier = 1.0 } }
  g_farmlandManager.farmlandMapping[5] = 7
  ev = refusedFarm:applyGainToSystemCoverage(refusedFarm.systems[10], 0.018)
  T.eq('cover.otherFarmRefused', ev.fields[5], "REFUSED")
  T.eq('cover.refusedWritesNothing', refusedFarm._calls.water, 0)

  local missingMap = coverMgr(true)
  missingMap.systems = { [10] = { id = 10, ownerFarmId = 2, type = "pivot",
    coveredFields = { 5 }, x = 0, z = 0, radius = 200, pressureMultiplier = 1.0 } }
  g_farmlandManager.farmlandMapping[5] = nil
  ev = missingMap:applyGainToSystemCoverage(missingMap.systems[10], 0.018)
  T.eq('cover.missingMappingRefused', ev.fields[5], "REFUSED")
  T.eq('cover.missingMappingWritesNothing', missingMap._calls.water, 0)

  local refusedReceipt = coverMgr(false)
  refusedReceipt.systems = { [10] = { id = 10, ownerFarmId = 2, type = "pivot",
    coveredFields = { 5 }, x = 0, z = 0, radius = 200, pressureMultiplier = 1.0 } }
  g_farmlandManager.farmlandMapping[5] = 2
  ev = refusedReceipt:applyGainToSystemCoverage(refusedReceipt.systems[10], 0.018)
  T.eq('cover.falseReceiptRefused', ev.fields[5], "REFUSED")

  local legacy = IrrigationManager.new(nil)
  legacy.systems = { [10] = { id = 10, ownerFarmId = 2, type = "pivot",
    coveredFields = { 5 }, x = 0, z = 0, radius = 200 } }
  ev = legacy:applyGainToSystemCoverage(legacy.systems[10], 0.018)
  T.eq('cover.legacyWholeAct', ev.wholeActLegacy, true)

  g_farmlandManager = nil
end

T.summary()
