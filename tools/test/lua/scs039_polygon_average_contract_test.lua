-- scs039_polygon_average_contract_test.lua
-- SCS-039 / PR178 (Iris Design answer: "OK needs a real mean; empty is not dry").
--
-- readAverageOfPolygon is a TYPED producer. A valid native read with no written
-- moisture (zero written pixels, or a positive count that averages to the raw-0
-- no-data sentinel) is EMPTY, not a measured-dry OK. A genuinely WRITTEN zero
-- moisture value (raw RAW_MIN, decodes to 0.0) stays a valid OK. Missing, thrown
-- or non-finite native results stay PROVIDER_REFUSAL. Malformed geometry keeps its
-- own outcome. This locks the producer so it can never hand _refreshFieldAggregate
-- an "OK" carrying a nil mean, which is the field-scalar nil that crashed the
-- per-frame HUD moisture sort (getFieldsSortedByMoisture).
--!load: src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua

local DEF = CropStressValueMap.LAYER_DEF
local enc = CropStressValueMap._encode
local vx, vz, n = {0, 10, 10}, {0, 0, 10}, 3

-- ─────────────────────────────────────────────────────────
-- Producer: readAverageOfPolygon typed outcomes.
-- A test double: the real readAverageOfPolygon / _setPolygonRegion over a stub
-- polygon modifier whose executeGet returns whatever the case supplies. The native
-- DensityValueCompareType global is absent on the bench, so the producer takes its
-- unfiltered branch and the stub executeGet drives the classification directly.
-- ─────────────────────────────────────────────────────────
local function makeMap(executeGetFn)
  local modifier = {
    clearPolygonPoints         = function() end,
    addPolygonPointWorldCoords = function() end,
    executeGet                 = executeGetFn,
  }
  return setmetatable({
    available      = true,
    hasPolygonOps  = true,
    modifier       = modifier,
    filter         = { setValueCompareParams = function() end },
    getGrainMetres = function() return 2 end,
  }, { __index = CropStressValueMap })
end

local function read(executeGetFn)
  return makeMap(executeGetFn):readAverageOfPolygon(vx, vz, n)
end

-- 1. Written pixels with a real mean -> OK carrying that mean.
do
  local raw = enc(0.5, DEF)
  local outcome, mean = read(function() return raw * 4, 4 end)
  T.eq("pavg.validMeanIsOK", outcome, "OK")
  T.near("pavg.validMeanValue", mean, 0.5, 0.01)
end

-- 2. A genuinely WRITTEN zero-moisture value is a valid OK (~0), never EMPTY.
do
  local raw = enc(0.0, DEF)
  local outcome, mean = read(function() return raw * 3, 3 end)
  T.eq("pavg.writtenZeroIsOK", outcome, "OK")
  T.near("pavg.writtenZeroValue", mean, 0.0, 0.01)
end

-- 3. Zero written pixels -> EMPTY, no mean.
do
  local outcome, mean = read(function() return 0, 0 end)
  T.eq("pavg.zeroPixelsIsEmpty", outcome, "EMPTY")
  T.eq("pavg.zeroPixelsMeanNil", mean, nil)
end

-- 4. A positive count that averages to raw-0 (all-no-data / coverage of holes) is
--    EMPTY, NOT an OK carrying a nil mean. This is the crash root cause.
do
  local outcome, mean = read(function() return 0, 5 end)
  T.eq("pavg.allNoDataIsEmpty", outcome, "EMPTY")
  T.eq("pavg.allNoDataMeanNil", mean, nil)
end

-- 5. Mixed coverage still yields OK over a positive written mean.
do
  local raw = enc(0.75, DEF)
  local outcome, mean = read(function() return raw * 2, 2 end)
  T.eq("pavg.mixedWrittenIsOK", outcome, "OK")
  T.near("pavg.mixedWrittenValue", mean, 0.75, 0.01)
end

-- 6. Non-finite accumulator -> PROVIDER_REFUSAL.
do
  T.eq("pavg.nanAccIsRefusal", select(1, read(function() return 0/0, 5 end)), "PROVIDER_REFUSAL")
end

-- 7. Non-finite or negative count -> PROVIDER_REFUSAL.
do
  T.eq("pavg.infCountIsRefusal", select(1, read(function() return 10, math.huge end)), "PROVIDER_REFUSAL")
  T.eq("pavg.negCountIsRefusal", select(1, read(function() return 10, -3 end)), "PROVIDER_REFUSAL")
end

-- 8. A thrown native read -> PROVIDER_REFUSAL, not EMPTY.
do
  T.eq("pavg.throwIsRefusal", select(1, read(function() error("native boom") end)), "PROVIDER_REFUSAL")
end

-- 9. Malformed geometry keeps its own outcome, before any native call.
do
  local map = makeMap(function() return 100, 4 end)
  T.eq("pavg.invalidGeometry", select(1, map:readAverageOfPolygon(nil, nil, 0)), "INVALID_FIELD_GEOMETRY")
end

-- 10. An unavailable provider refuses; it does not read as empty.
do
  local map = makeMap(function() return 100, 4 end)
  map.available = false
  T.eq("pavg.unavailableIsRefusal", select(1, map:readAverageOfPolygon(vx, vz, n)), "PROVIDER_REFUSAL")
end

-- ─────────────────────────────────────────────────────────
-- Consumer: _refreshFieldAggregate honours the typed outcomes. OK with a finite
-- mean publishes the scalar and clears dirty; EMPTY keeps the last cached scalar
-- and stays dirty (not published as current); refusal fails the provider closed; a
-- defensive OK-with-nil-mean never nils the scalar.
-- ─────────────────────────────────────────────────────────
local function makeSoil(outcome, mean)
  return setmetatable({
    valueMap = { readAverageOfPolygon = function() return outcome, mean end },
    mapActive        = function() return true end,
    _getFieldVerts   = function() return vx, vz, n end,
    _failNativeClosed = function(self) self._failed = true end,
  }, { __index = SoilMoistureSystem })
end

-- OK publishes the mean and clears dirty.
do
  local soil = makeSoil("OK", 0.42)
  local d = { moisture = 0.60, aggregateDirty = true }
  soil:_refreshFieldAggregate(7, d)
  T.near("refresh.okPublishesMean", d.moisture, 0.42, 1e-9)
  T.eq("refresh.okClearsDirty", d.aggregateDirty, false)
end

-- EMPTY keeps the cached scalar and stays dirty.
do
  local soil = makeSoil("EMPTY", nil)
  local d = { moisture = 0.60, aggregateDirty = true }
  soil:_refreshFieldAggregate(7, d)
  T.near("refresh.emptyKeepsCachedScalar", d.moisture, 0.60, 1e-9)
  T.eq("refresh.emptyStaysDirty", d.aggregateDirty, true)
end

-- PROVIDER_REFUSAL fails the provider closed and leaves the scalar alone.
do
  local soil = makeSoil("PROVIDER_REFUSAL", nil)
  local d = { moisture = 0.60, aggregateDirty = true }
  soil:_refreshFieldAggregate(7, d)
  T.eq("refresh.refusalFailsClosed", soil._failed, true)
  T.near("refresh.refusalKeepsScalar", d.moisture, 0.60, 1e-9)
end

-- Defensive: an OK with a nil mean must never nil the scalar.
do
  local soil = makeSoil("OK", nil)
  local d = { moisture = 0.60, aggregateDirty = true }
  soil:_refreshFieldAggregate(7, d)
  T.near("refresh.okNilMeanKeepsScalar", d.moisture, 0.60, 1e-9)
  T.eq("refresh.okNilMeanStaysDirty", d.aggregateDirty, true)
end
