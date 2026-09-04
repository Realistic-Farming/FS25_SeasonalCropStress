-- scs039_delegation_test.lua
-- SCS-039 / GRID-1: the delegate-when-present seam.
--
-- THE INVARIANT THIS EXISTS FOR: engine-absent must be TODAY, EXACTLY. Every
-- branch SCS-039 adds is gated on mapActive(), and when that is false the
-- shipped sparse-cell store must behave bit for bit as it did before the map
-- was written. A regression here is invisible on any machine where the map
-- works, which is most of them, so it gets its own bench.
--
-- The map-present half is driven through a stub value map: the engine calls
-- themselves are not testable off a running game, but the DELEGATION (what gets
-- called, with what, and what is skipped) is, and that is where the bugs live.
--!load: src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua

-- A stub standing in for the engine-backed map. Records what it was asked to do.
local function stubMap(grain)
  local m = {
    available = true,
    grain     = grain or 2,
    painted   = {},
    writes    = {},
    deltas    = {},
    pixels    = {},          -- "x:z" -> value, so reads see prior writes
    meanToReturn = nil,
  }
  function m:getGrainMetres() return self.grain end
  -- worldToPixel is part of the sanctioned map interface (the SCS-039 authority
  -- bar's stub provides it too); the positional water path keys pending by pixel.
  function m:worldToPixel(x, z) return math.floor(x), math.floor(z) end
  function m:paintPolygon(_vx, _vz, _n, value)
    self.painted[#self.painted + 1] = value
    return true
  end
  function m:writeValueAtWorld(x, z, value, _r)
    self.writes[#self.writes + 1] = { x = x, z = z, v = value }
    self.pixels[string.format("%d:%d", math.floor(x), math.floor(z))] = value
    return true
  end
  function m:readValueAtWorld(x, z)
    return self.pixels[string.format("%d:%d", math.floor(x), math.floor(z))], self.grain
  end
  function m:applyDeltaToPolygon(_vx, _vz, _n, delta)
    self.deltas[#self.deltas + 1] = delta
    return delta            -- pretend the engine applied it in full
  end
  function m:readAverageOfPolygon(_vx, _vz, _n)
    return self.meanToReturn, self.grain
  end
  return m
end

local function newSystem()
  local sys = SoilMoistureSystem.new({ eventBus = nil })
  sys.isInitialized = true
  sys.fieldData[1] = {
    fieldId = 1, moisture = 0.50, soilType = "loamy", irrigationGain = 0.0,
    centerX = 0, centerZ = 0, cells = {}, cellSum = 0, cellCount = 0, reliefScan = false,
  }
  -- A square field polygon, pre-cached so no scene walk is needed.
  sys._fieldVerts[1] = { vx = {0, 100, 100, 0}, vz = {0, 0, 100, 100}, n = 4 }
  return sys
end

-- 1. NO MAP = NOT ACTIVE, and every new branch stays out of the way.
do
  local sys = newSystem()
  T.eq("absent.mapNotActive", sys:mapActive(), false)
  T.eq("absent.migrateRefuses", sys:migrateFieldToMap(1), false)

  -- The positional getter falls back to the cell path and reports CELL grain.
  local v, grain = sys:getMoisture(1, 10, 10)
  T.near("absent.readsAggregate", v, 0.50, 1e-9)
  T.eq("absent.reportsCellGrain", grain, sys:getCellSize())

  -- Field-level read is unchanged and reports no grain.
  local fv, fgrain = sys:getMoisture(1)
  T.near("absent.fieldRead", fv, 0.50, 1e-9)
  T.eq("absent.fieldGrainNil", fgrain, nil)
end

-- 2. ENGINE-ABSENT CELL BEHAVIOUR IS UNCHANGED: applyWaterAtCell still
--    materialises a cell and still moves the aggregate, exactly as SCS-018.
do
  local sys = newSystem()
  sys:applyWaterAtCell(1, 10, 10, 0.20)
  local d = sys.fieldData[1]
  T.eq("absent.cellMaterialised", d.cellCount, 1)
  T.ok("absent.cellHoldsWater", d.cellSum > 0.5)
  local v = sys:getMoisture(1, 10, 10)
  T.near("absent.cellReadsBack", v, 0.70, 1e-6)
end

-- 3. MAP PRESENT: the getter delegates and reports MAP grain, not cell grain.
do
  local sys = newSystem()
  sys.valueMap = stubMap(2)
  T.eq("present.mapActive", sys:mapActive(), true)

  sys:applyWaterAtCell(1, 10, 10, 0.20)
  local d = sys.fieldData[1]
  -- The cell store must NOT be touched once the map carries the truth,
  -- or two stores drift apart and nobody knows which one is the ground.
  T.eq("present.noCellMaterialised", d.cellCount, 0)
  T.ok("present.mapWasWritten", #sys.valueMap.writes > 0)

  local v, grain = sys:getMoisture(1, 10, 10)
  -- SCS-039 quantisation law: a positional write lands on whole raw steps, so the
  -- read-back is the semantic amount floored to the nearest raw step (a 0.20 gain
  -- becomes 50 of the 254 steps), always within one raw step of 0.70.
  T.near("present.readsMapValue", v, 0.70, 1 / CropStressValueMap.RAW_SPAN)
  T.eq("present.reportsMapGrain", grain, 2)
end

-- 4. MIGRATION runs ONCE and paints the base coat before stamping cells.
do
  local sys = newSystem()
  -- Give the field two materialised cells first (an old save being upgraded).
  sys:applyWaterAtCell(1, 10, 10, 0.20)
  sys:applyWaterAtCell(1, 50, 50, 0.10)
  local before = sys:getMoisture(1)

  sys.valueMap = stubMap(2)
  T.eq("migrate.firstCallSeeds", sys:migrateFieldToMap(1), true)
  T.eq("migrate.baseCoatPainted", #sys.valueMap.painted, 1)
  T.near("migrate.baseCoatIsAggregate", sys.valueMap.painted[1], before, 1e-9)
  T.eq("migrate.cellsStamped", #sys.valueMap.writes, 2)

  -- Second call is a no-op: re-seeding would wipe live map data with stale cells.
  local paintedBefore = #sys.valueMap.painted
  T.eq("migrate.secondCallNoOp", sys:migrateFieldToMap(1), true)
  T.eq("migrate.noReseed", #sys.valueMap.painted, paintedBefore)
end

-- 5. THE DAILY SETTLE RE-DERIVES the scalar from the map instead of trusting it.
do
  local sys = newSystem()
  sys.valueMap = stubMap(2)
  sys.fieldData[1].moisture = 0.50
  sys.valueMap.meanToReturn = 0.42
  sys:settleDaily(1)
  T.near("settle.scalarReDerived", sys.fieldData[1].moisture, 0.42, 1e-9)

  -- A map that cannot answer must leave the scalar alone rather than zero it.
  sys.valueMap.meanToReturn = nil
  sys:settleDaily(1)
  T.near("settle.nilMeanLeavesScalar", sys.fieldData[1].moisture, 0.42, 1e-9)
end

-- 6. THE DAILY SETTLE ON THE FALLBACK still runs the conserving drainage and
--    still conserves. Guards the branch split above from eating SCS-018.
do
  local sys = newSystem()
  sys:applyWaterAtCell(1, 10, 10, 0.30)
  sys:applyWaterAtCell(1, 50, 50, 0.00001)
  local d = sys.fieldData[1]
  local totalBefore = d.cellSum
  sys:settleDaily(1)
  T.near("fallback.drainageConserves", d.cellSum, totalBefore, 1e-6)
  T.ok("fallback.stillHasCells", d.cellCount == 2)
end

-- 7. THE POLYGON CACHE remembers a refusal, so a field with no usable polygon
--    does not re-walk the field list every single hour.
do
  local sys = newSystem()
  sys._fieldVerts = {}
  local vx = sys:_getFieldVerts(999)          -- no such field, no g_fieldManager
  T.eq("cache.refusalReturnsNil", vx, nil)
  T.ok("cache.refusalRemembered", sys._fieldVerts[999] ~= nil)
  T.eq("cache.refusalIsZeroN", sys._fieldVerts[999].n, 0)
  T.eq("cache.secondCallStillNil", (sys:_getFieldVerts(999)), nil)
end


-- 8. A FIELD-LEVEL SET REACHES THE MAP, or the daily re-derive silently
--    reverts it. Regression guard for csSetMoisture and the sprayer path.
do
  local sys = newSystem()
  sys.valueMap = stubMap(2)
  sys.fieldData[1].mapPending = 0.002        -- stale sub-step carry

  T.eq("set.accepted", sys:setMoisture(1, 0.80), true)
  T.ok("set.mapPainted", #sys.valueMap.painted > 0)
  T.near("set.paintedValue", sys.valueMap.painted[#sys.valueMap.painted], 0.80, 1e-9)
  T.near("set.scalarFollows", sys.fieldData[1].moisture, 0.80, 1e-9)
  -- The carried delta was accumulated against ground that no longer exists.
  T.near("set.pendingCleared", sys.fieldData[1].mapPending, 0, 1e-12)

  -- And it survives the daily re-derive, because the map now agrees.
  sys.valueMap.meanToReturn = 0.80
  sys:settleDaily(1)
  T.near("set.survivesSettle", sys.fieldData[1].moisture, 0.80, 1e-9)
end


-- 9. MAP DRAINAGE: conserved by construction, and it runs downhill.
--    Water must MOVE between places without the field total changing, and it
--    must arrive at the hollow rather than the ridge.
do
  local drain = SoilMoistureSystem.computeDrainageAdditions

  local function sum(t)
    local s = 0
    for i = 1, #t do s = s + t[i] end
    return s
  end

  -- A slope with uniform water: relief alone decides the direction.
  local h, m = {}, {}
  for i = 1, 20 do h[i] = 100 + i * 1.0; m[i] = 0.50 end
  local add = drain(h, m, 0.05)
  T.near("drain.slopeConserves", sum(add), 0, 1e-9)
  T.ok("drain.lowGroundGains", add[1] > 0)
  T.ok("drain.highGroundGives", add[20] < 0)

  -- A flat field with uneven water: the water term alone levels it, and still
  -- conserves. This is the case that must match the cell store's behaviour.
  local fh, fm = {}, {}
  for i = 1, 20 do fh[i] = 88.0; fm[i] = 0.30 + (i % 4) * 0.1 end
  local fadd = drain(fh, fm, 0.05)
  T.near("drain.flatConserves", sum(fadd), 0, 1e-9)
  local wettest, driest = 1, 1
  for i = 2, 20 do
    if fm[i] > fm[wettest] then wettest = i end
    if fm[i] < fm[driest] then driest = i end
  end
  T.ok("drain.wettestGives", fadd[wettest] < 0)
  T.ok("drain.driestGains", fadd[driest] > 0)

  -- A hollow: one low block among many, the shape that must not leak.
  local hh, hm = {}, {}
  for i = 1, 30 do hh[i] = 120.0; hm[i] = 0.45 end
  hh[15] = 112.0
  local hadd = drain(hh, hm, 0.05)
  T.near("drain.hollowConserves", sum(hadd), 0, 1e-9)
  T.ok("drain.hollowGains", hadd[15] > 0)
  T.ok("drain.surroundGives", hadd[1] < 0)

  -- Degenerate inputs refuse rather than divide by zero.
  T.eq("drain.singleBlockRefuses", drain({1}, {0.5}, 0.05), nil)
  T.eq("drain.emptyRefuses", drain({}, {}, 0.05), nil)
  T.eq("drain.mismatchedRefuses", drain({1, 2}, {0.5}, 0.05), nil)
end

T.summary()
