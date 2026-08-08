-- scs018_relief_sparsity_test.lua
-- SCS-018 per-cell moisture store: relief materialisation contract.
--   * a flat field materialises no cells (the store stays scalar; the field
--     number is identical everywhere),
--   * a steep field materialises a bounded share of its cells,
--   * the backstop cap bounds materialised cells per field.
-- No engine: we stub a field polygon + terrain heights and drive the real
-- SoilMoistureSystem:materialiseRelief directly.
--!load: src/SoilMoistureSystem.lua

-- Terrain heights by (worldX, worldZ); flat by default.
local function makeTerrain(heightFn)
  g_terrainNode = {}
  function getTerrainHeightAtWorldPos(_node, x, _y, z)
    return heightFn(x, z)
  end
end

-- Field polygon: polygonPoints are node ids; getWorldTranslation resolves them.
local function makeField(fid, corners)
  local nodes = {}
  for i = 1, #corners do nodes[i] = 100000 + fid * 100 + i end
  local field = {
    farmland = { id = fid },
    posX = 0, posZ = 0,
    polygonPoints = nodes,
  }
  -- getWorldTranslation(node) -> the corner's world position
  local nodePos = {}
  for i = 1, #corners do nodePos[nodes[i]] = { corners[i][1], 0, corners[i][2] } end
  function getWorldTranslation(node)
    local p = nodePos[node]
    if p ~= nil then return p[1], p[2], p[3] end
    return 0, 0, 0
  end
  return field
end

local function newSystem()
  local m = { eventBus = { subscribe = function() end, publish = function() end } }
  local s = SoilMoistureSystem.new(m)
  s._cellSize = 10
  return s
end

-- Flat field: no relief, no cells.
do
  local s = newSystem()
  makeTerrain(function() return 20.0 end)
  g_fieldManager = { fields = { makeField(1, { {0,0},{100,0},{100,100},{0,100} }) } }
  s.fieldData[1] = { fieldId = 1, moisture = 0.5, cells = {}, cellSum = 0, cellCount = 0, reliefScan = false }
  s:materialiseRelief(1)
  T.eq("flat.fieldHasNoCells", s.fieldData[1].cellCount, 0)
  T.eq("flat.aggregateIsScalar", s:getFieldAggregate(s.fieldData[1]), 0.5)
  T.eq("flat.positionalReadsAggregate", s:getMoisture(1, 15, 15), 0.5)
end

-- Steep field (a ridge: height rises 30m across the field): cells materialise,
-- bounded well below 100% by the threshold, and never above the backstop cap.
do
  local s = newSystem()
  makeTerrain(function(x, _z) return x * 0.5 end)  -- 0..50m across a 100m field
  g_fieldManager = { fields = { makeField(2, { {0,0},{100,0},{100,100},{0,100} }) } }
  s.fieldData[2] = { fieldId = 2, moisture = 0.5, cells = {}, cellSum = 0, cellCount = 0, reliefScan = false }
  s:materialiseRelief(2)
  local count = s.fieldData[2].cellCount
  T.ok("steep.materialised", count > 0, "expected some cells, got 0")
  T.ok("steep.notAll", count < 100, "expected <100% materialised, got " .. count)
  -- Aggregate stays sane (mean of the materialised cells, seeded from 0.5).
  local agg = s:getFieldAggregate(s.fieldData[2])
  T.ok("steep.aggregateSane", agg > 0 and agg <= 1, "aggregate out of range: " .. tostring(agg))
  T.ok("steep.aggregateDefined", s.fieldData[2].cellSum > 0, "cellSum should be positive")
end

-- Backstop cap: a field larger than the cap materialises at most CAP cells.
do
  local s = newSystem()
  s._cellSize = 10
  -- 40x40 cells = 1600 candidate cells, cap = 1000.
  makeTerrain(function(x, z) return (x + z) * 0.5 end)
  g_fieldManager = { fields = { makeField(3, { {0,0},{400,0},{400,400},{0,400} }) } }
  s.fieldData[3] = { fieldId = 3, moisture = 0.5, cells = {}, cellSum = 0, cellCount = 0, reliefScan = false }
  s:materialiseRelief(3)
  T.ok("cap.bounded", s.fieldData[3].cellCount <= SoilMoistureSystem.CELL_BACKSTOP_CAP,
      "cellCount " .. s.fieldData[3].cellCount .. " exceeded cap " .. SoilMoistureSystem.CELL_BACKSTOP_CAP)
end

T.summary()
