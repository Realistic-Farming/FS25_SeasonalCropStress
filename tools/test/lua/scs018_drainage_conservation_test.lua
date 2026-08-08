-- scs018_drainage_conservation_test.lua
-- SCS-018 per-cell moisture store: the daily settle conserves the field total.
-- Drainage only moves water between cells; it must not create or destroy
-- moisture. We drive the real settleDaily against a synthetic cell store and
-- assert the aggregate is conserved to float tolerance.
--!load: src/SoilMoistureSystem.lua

local function newSystem()
  local m = { eventBus = { subscribe = function() end, publish = function() end } }
  local s = SoilMoistureSystem.new(m)
  s._cellSize = 10
  return s
end

-- Build a field with a spread of cell moistures (some wet hollows, dry knolls).
local function seededField(s, fieldId, values)
  local d = { fieldId = fieldId, moisture = 0.5, cells = {}, cellSum = 0, cellCount = 0, reliefScan = true }
  s.fieldData[fieldId] = d
  for cx = 0, 9 do
    for cz = 0, 9 do
      local idx = (cx * 10 + cz) % #values + 1
      d.cells[cx] = d.cells[cx] or {}
      d.cells[cx][cz] = { moisture = values[idx] }
      d.cellCount = d.cellCount + 1
      d.cellSum = d.cellSum + values[idx]
    end
  end
  return d
end

-- Conservation over one and many settle days.
do
  local s = newSystem()
  local values = { 0.1, 0.3, 0.5, 0.7, 0.9, 0.2, 0.4, 0.6, 0.8, 0.35 }
  local d = seededField(s, 1, values)
  local before = d.cellSum
  s:settleDaily(1)
  T.near("oneDay.conservesSum", d.cellSum, before, 1e-6)
  s:settleDaily(7)
  T.near("sevenDays.conservesSum", d.cellSum, before, 1e-6)
  T.eq("aggregateIsMean", s:getFieldAggregate(d), d.cellSum / d.cellCount)
end

-- A single wet cell drains toward the mean: it must not go below the clamp.
do
  local s = newSystem()
  local d = seededField(s, 2, { 0.9 })
  local before = s:getFieldAggregate(d)
  s:settleDaily(10)
  local after = s:getFieldAggregate(d)
  T.ok("wetCell.staysClamped", after >= 0 and after <= 1, "aggregate out of range")
  T.near("wetCell.conserves", d.cellSum, before * d.cellCount, 1e-6)
end

T.summary()
