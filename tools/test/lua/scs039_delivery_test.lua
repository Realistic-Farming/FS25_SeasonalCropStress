-- scs039_delivery_test.lua
-- SCS-039 / GRID-1: MP row delivery, the release gate, the degrade path, and
-- the SCS-037 composition seam.
--
-- The wire itself is not testable off a running game, but the PACKING is, and
-- that is where a sync bug hides: a row that packs and unpacks to something
-- other than what it was leaves a client's ground quietly wrong, with nothing
-- in the log and no crash to notice.
--!load: src/maps/CropStressValueMap.lua, src/ReleaseGate.lua, src/SoilMoistureSystem.lua

local pack   = CropStressValueMap.packRow
local unpack = CropStressValueMap.unpackRow

local function sameRow(name, a, b, width)
  if #a ~= #b then
    T.ok(name .. ".length", false)
    return
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      T.ok(name .. ".index" .. i, false)
      return
    end
  end
  T.ok(name, true)
end

-- 1. RUN-LENGTH ROUND TRIP is lossless on the shapes a moisture map actually has.
do
  -- The dominant real shape: a long off-field run at the raw-0 sentinel, one
  -- field at a uniform level, then sentinel again.
  local row = {}
  for i = 1, 200 do row[i] = 0 end
  for i = 80, 140 do row[i] = 128 end
  sameRow("pack.fieldInSentinel", unpack(pack(row), 200), row, 200)

  -- Fully uniform: the best case, and it must not lose the value.
  local uni = {}
  for i = 1, 100 do uni[i] = 77 end
  sameRow("pack.uniform", unpack(pack(uni), 100), uni, 100)
  T.eq("pack.uniformIsOneRun", #pack(uni), 2)

  -- Fully noisy: the worst case. Still lossless, just not compressed.
  local noisy = {}
  for i = 1, 64 do noisy[i] = (i * 37) % 256 end
  sameRow("pack.noisy", unpack(pack(noisy), 64), noisy, 64)

  -- A single pixel.
  sameRow("pack.single", unpack(pack({ 42 }), 1), { 42 }, 1)

  -- Empty in, empty out, no crash.
  T.eq("pack.emptyIsEmpty", #pack({}), 0)
  T.eq("pack.unpackEmptyIsEmpty", #unpack({}, 10), 0)
  T.eq("pack.unpackNilIsEmpty", #unpack(nil, 10), 0)
end

-- 2. UNPACK NEVER OVER-ALLOCATES. A malformed or hostile run table must not be
--    able to make a client allocate past its own map width.
do
  local hostile = { 999999, 200 }          -- claims a run far wider than the map
  local out = unpack(hostile, 64)
  T.eq("pack.widthClamped", #out, 64)

  local ragged = { 3, 10, 2 }              -- trailing length with no value
  local r = unpack(ragged, 64)
  T.ok("pack.raggedSurvives", #r >= 3)
end

-- 3. THE RELEASE GATE holds the map off for a player who has not opted in.
--    SCS-039 ships LOCKED, so this is the default experience.
do
  T.ok("gate.rowExists", ReleaseGate.EXPERIMENTAL.cs_grid_concordance ~= nil)
  T.eq("gate.lockedWithoutOptIn", ReleaseGate.isReleased("cs_grid_concordance", false), false)
  T.eq("gate.liveWithOptIn", ReleaseGate.isReleased("cs_grid_concordance", true), true)
  -- The shipped baseline is untouched by the new row.
  T.eq("gate.baselineStillReleased", ReleaseGate.isReleased("something_shipped", false), true)
end

-- 4. THE DEGRADE PATH: a map that will not stand up leaves no half-built object
--    behind, and does not retry the engine probe on every later call.
do
  local sys = SoilMoistureSystem.new({})
  sys.isInitialized = true
  -- No engine in the bench, so initialize() declines.
  T.eq("degrade.initReturnsFalse", sys:initValueMap(nil), false)
  T.eq("degrade.noHalfBuiltMap", sys.valueMap, nil)
  T.eq("degrade.mapNotActive", sys:mapActive(), false)
  T.eq("degrade.triedFlagSet", sys._valueMapTried, true)
  -- Second call short-circuits rather than re-probing.
  T.eq("degrade.secondCallStillFalse", sys:initValueMap(nil), false)
end

-- 5. SYNC REFUSES CLEANLY when there is no map, rather than queueing work that
--    can never be delivered.
do
  local sys = SoilMoistureSystem.new({})
  sys.isInitialized = true
  T.eq("sync.queueRefusesWithoutMap", sys:queueMapSync({}), false)
  T.eq("sync.updateIsZeroWhenIdle", sys:updateMapSync(), 0)
end

-- 6. THE INSTRUMENT answers even before anything has run, so csMapStats never
--    errors on a fresh session.
do
  local sys = SoilMoistureSystem.new({})
  sys.isInitialized = true
  local s = sys:getMapStats()
  T.eq("stats.inactive", s.active, false)
  T.eq("stats.noRowsSent", s.syncRowsSent, 0)
  T.eq("stats.noPending", s.syncPending, 0)
  T.eq("stats.noSeededFields", s.seededFields, 0)
end

-- 7. THE SCS-037 SEAM: elapsed hours scale every per-hour term, and the default
--    of 1 is arithmetically identical to what shipped.
do
  local weather = {
    getHourlyEvapMultiplier = function() return 1.0 end,
    getHourlyRainAmount     = function() return 0.0 end,
  }

  local function runWith(hours)
    local sys = SoilMoistureSystem.new({})
    sys.isInitialized = true
    sys.fieldData[1] = {
      fieldId = 1, moisture = 0.80, soilType = "loamy", irrigationGain = 0.0,
      centerX = 0, centerZ = 0, cells = {}, cellSum = 0, cellCount = 0,
    }
    sys:hourlyUpdate(weather, hours)
    return sys.fieldData[1].moisture
  end

  local oneHour   = runWith(1)
  local defaulted = runWith(nil)
  T.near("seam.defaultEqualsOneHour", defaulted, oneHour, 1e-12)

  -- Three hours must dry three hours' worth, not one.
  local threeHours = runWith(3)
  local lossOne    = 0.80 - oneHour
  local lossThree  = 0.80 - threeHours
  T.ok("seam.threeHoursDriesMore", lossThree > lossOne)
  T.near("seam.threeHoursIsThreeTimes", lossThree, lossOne * 3, 1e-9)

  -- A garbage elapsed count cannot run time backwards.
  T.near("seam.zeroFloorsToOne", runWith(0), oneHour, 1e-12)
  T.near("seam.negativeFloorsToOne", runWith(-5), oneHour, 1e-12)
end

T.summary()
