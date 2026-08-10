-- scs037_caught_up_hour_test.lua
-- SCS-037 THE CAUGHT-UP HOUR. The hourly tick is an edge detector, so a time skip
-- used to produce ONE tick and discard the rest of the span. The elapsed count is
-- now carried as a parameter and every PER-HOUR consumer multiplies by it.
--
-- THE TWO ASSERTIONS THAT MATTER, and they pull against each other:
--   1. A 72-hour skip charges 72x, in each of the three consumers.
--   2. A NORMAL HOUR IS BIT-FOR-BIT TODAY'S BEHAVIOUR. Every default path is
--      pinned against a hand-computed pre-SCS-037 value, not against itself.
--!load: src/CropStressManager.lua, src/CropStressModifier.lua, src/FinanceIntegration.lua, src/SoilMoistureSystem.lua

-- =========================================================
-- 1. THE ELAPSED-COUNT CONTRACT (pure, no mission needed)
-- =========================================================
do
  local f = CropStressManager.elapsedHoursFrom

  T.eq("elapsed.normalHour", f(100, 101), 1)
  T.eq("elapsed.threeDaySkip", f(100, 172), 72)

  -- The first tick ever: lastHourKey is seeded to -1 in new(). Without this guard
  -- a fresh save would open with a full capped catch-up of weather it never had.
  T.eq("elapsed.firstTickIsOne", f(-1, 5000), 1)
  T.eq("elapsed.nilLastIsOne", f(nil, 5000), 1)

  -- The key cannot move backwards (currentMonotonicDay is monotonic), but a
  -- reseed on savegame switch could make it look that way. Never charge negative.
  T.eq("elapsed.backwardsIsOne", f(200, 100), 1)
  T.eq("elapsed.sameKeyIsOne", f(200, 200), 1)

  -- THE CAP is one in-game week, and it is a ceiling rather than a tuning number.
  T.eq("elapsed.capAtWeek", f(0, 168), 168)
  T.eq("elapsed.capHolds", f(0, 100000), CropStressManager.MAX_CATCHUP_HOURS)
  T.eq("elapsed.capIsAWeek", CropStressManager.MAX_CATCHUP_HOURS, 168)

  -- Always a whole number of hours: the consumers multiply raw amounts by it.
  T.eq("elapsed.floors", f(0, 10.7), 10)
end

-- =========================================================
-- 2. EVAPORATION / RAIN / IRRIGATION (SoilMoistureSystem)
-- =========================================================
local function newSoil()
  local m = { eventBus = { subscribe = function() end, publish = function() end } }
  local s = SoilMoistureSystem.new(m)
  s._cellSize = 10
  s.isInitialized = true
  return s
end

-- A weather stub whose numbers are chosen so the arithmetic is checkable by hand.
local function fakeWeather(evapMult, rain)
  return {
    getHourlyEvapMultiplier = function() return evapMult end,
    getHourlyRainAmount     = function() return rain end,
  }
end

-- Plain aggregate field (no cells, no value map): the simplest path through
-- hourlyUpdate, and the one where the net is applied directly.
local function seedPlainField(s, fieldId, moisture)
  s.fieldData[fieldId] = { fieldId = fieldId, moisture = moisture, soilType = "loamy" }
  return s.fieldData[fieldId]
end

local BASE = SoilMoistureSystem.BASE_EVAP_RATE
local LOAM = SoilMoistureSystem.SOIL_PARAMS.loamy

do
  -- One hour, no rain: exactly one BASE_EVAP_RATE step. This is the pin against
  -- pre-SCS-037 behaviour — the number is computed from the constants, not read
  -- back out of the system under test.
  local s = newSoil()
  local d = seedPlainField(s, 1, 0.5)
  s:hourlyUpdate(fakeWeather(1.0, 0.0))
  T.near("soil.oneHourUnchanged", d.moisture, 0.5 - BASE * LOAM.evapMod, 1e-9)
end

do
  -- 72 hours dries 72x as much as one hour, from the same start.
  local one = newSoil()
  local d1  = seedPlainField(one, 1, 0.9)
  one:hourlyUpdate(fakeWeather(1.0, 0.0))
  local oneHourLoss = 0.9 - d1.moisture

  local many = newSoil()
  local d72  = seedPlainField(many, 1, 0.9)
  many:hourlyUpdate(fakeWeather(1.0, 0.0), 72)
  local skipLoss = 0.9 - d72.moisture

  T.near("soil.skipIs72x", skipLoss, oneHourLoss * 72, 1e-9)
end

do
  -- Rain over a skip: gain scales with the span too.
  local s = newSoil()
  local d = seedPlainField(s, 1, 0.2)
  s:hourlyUpdate(fakeWeather(0.0, 0.01), 24)
  T.near("soil.rainScales", d.moisture, 0.2 + 0.01 * LOAM.rainAbsorb * 24, 1e-9)
end

do
  -- Irrigation gain scales with the span. This is the half that was ALREADY
  -- shipped by SCS-039; asserted here so the money assertion below has a partner.
  local s = newSoil()
  local d = seedPlainField(s, 1, 0.2)
  s.irrigationGains[1] = 0.005
  s:hourlyUpdate(fakeWeather(0.0, 0.0), 10)
  T.near("soil.irrigationScales", d.moisture, 0.2 + 0.005 * 10, 1e-9)
end

do
  -- Clamps still hold across a long catch-up: a week of drought cannot drive a
  -- field below zero, and a week of rain cannot drive it above one.
  local dry = newSoil()
  local dd  = seedPlainField(dry, 1, 0.1)
  dry:hourlyUpdate(fakeWeather(5.0, 0.0), 168)
  T.ok("soil.floorHolds", dd.moisture >= 0.0, "moisture went negative: " .. tostring(dd.moisture))

  local wet = newSoil()
  local dw  = seedPlainField(wet, 1, 0.9)
  wet:hourlyUpdate(fakeWeather(0.0, 0.05), 168)
  T.ok("soil.ceilingHolds", dw.moisture <= 1.0, "moisture exceeded 1.0: " .. tostring(dw.moisture))
end

-- =========================================================
-- 3. ROUND 2: THE RAIN SWITCH, AND IT IS INERT TODAY
-- =========================================================
do
  -- rainHours narrows ONLY the rain term. Evaporation still runs the whole span,
  -- because the record says nothing about temperature.
  local s = newSoil()
  local d = seedPlainField(s, 1, 0.2)
  s:hourlyUpdate(fakeWeather(1.0, 0.01), 48, 12)
  local expected = 0.2 - BASE * LOAM.evapMod * 48 + 0.01 * LOAM.rainAbsorb * 12
  T.near("round2.rainHoursNarrowsRainOnly", d.moisture, expected, 1e-9)
end

do
  -- nil rainHours is round-1 exactly: the two calls must agree bit for bit.
  local a = newSoil(); local da = seedPlainField(a, 1, 0.4)
  local b = newSoil(); local db = seedPlainField(b, 1, 0.4)
  a:hourlyUpdate(fakeWeather(1.0, 0.01), 30)
  b:hourlyUpdate(fakeWeather(1.0, 0.01), 30, nil)
  T.near("round2.nilIsRound1", da.moisture, db.moisture, 0)
end

do
  -- A record that claims more wet hours than the skip lasted is clamped to the
  -- span, and a negative one to zero. Neither can invent or destroy water.
  local hi = newSoil(); local dh = seedPlainField(hi, 1, 0.2)
  hi:hourlyUpdate(fakeWeather(0.0, 0.01), 10, 999)
  T.near("round2.clampsToSpan", dh.moisture, 0.2 + 0.01 * LOAM.rainAbsorb * 10, 1e-9)

  local lo = newSoil(); local dl = seedPlainField(lo, 1, 0.2)
  lo:hourlyUpdate(fakeWeather(0.0, 0.01), 10, -5)
  T.near("round2.clampsToZero", dl.moisture, 0.2, 1e-9)
end

do
  -- THE INERTNESS GUARD. SoilFertilizer publishes no manager-level Water Record
  -- delegate today, so the reader must answer nil and round-1 must hold. This
  -- assertion is the reason the feature is honest rather than half-wired: when
  -- somebody publishes `getWaterDaysInLast`, this test is what changes.
  local mgr = setmetatable({}, CropStressManager)

  g_currentMission.soilFertilityManager = nil
  T.eq("round2.absentSFIsNil", mgr:getSkipRainHours(72), nil)

  -- Present but without the delegate: still nil. Reaching three internal field
  -- names deep to `soilSystem.materialWetness` is exactly what we refuse to do.
  g_currentMission.soilFertilityManager = { soilSystem = { materialWetness = { waterRecord = {} } } }
  T.eq("round2.noDelegateIsNil", mgr:getSkipRainHours(72), nil)

  -- A single hour has nothing to reconstruct.
  g_currentMission.soilFertilityManager = {
    getWaterDaysInLast = function() return 3, 3 end,
  }
  T.eq("round2.oneHourIsNil", mgr:getSkipRainHours(1), nil)

  -- With the delegate present the span is scaled by the WET FRACTION OF KNOWN
  -- DAYS. 72 hours, 2 of 3 recorded days wet → 48 rain-bearing hours.
  g_currentMission.environment.currentMonotonicDay = 40
  local askedDays, askedThrough
  g_currentMission.soilFertilityManager = {
    getWaterDaysInLast = function(_self, days, throughDay)
      askedDays, askedThrough = days, throughDay
      return 2, 3
    end,
  }
  T.near("round2.scalesByWetFraction", mgr:getSkipRainHours(72), 48, 1e-9)
  -- The window asked for covers the whole span: 72 hours is 3 calendar days.
  T.eq("round2.asksWholeSpan", askedDays, 3)
  T.eq("round2.asksThroughToday", askedThrough, 40)

  -- A span that straddles a day boundary rounds UP, because both days have a
  -- verdict and asking for one of them would silently drop the other.
  T.eq("round2.partialDayRoundsUp", (function()
    mgr:getSkipRainHours(30)
    return askedDays
  end)(), 2)

  -- Fully wet and fully dry are both faithfully reported rather than clamped away.
  g_currentMission.soilFertilityManager = {
    getWaterDaysInLast = function() return 3, 3 end,
  }
  T.near("round2.allWetIsWholeSpan", mgr:getSkipRainHours(72), 72, 1e-9)
  g_currentMission.soilFertilityManager = {
    getWaterDaysInLast = function() return 0, 3 end,
  }
  T.near("round2.allDryIsZero", mgr:getSkipRainHours(72), 0, 1e-9)

  -- known == 0 means the record does not reach back at all: nil, not zero rain.
  -- Zero would be a claim ("it was dry"); nil is the truth ("we do not know").
  g_currentMission.soilFertilityManager = {
    getWaterDaysInLast = function() return 0, 0 end,
  }
  T.eq("round2.unknownIsNilNotZero", mgr:getSkipRainHours(72), nil)

  -- A delegate that throws must not cross the mod boundary.
  g_currentMission.soilFertilityManager = {
    getWaterDaysInLast = function() error("boom") end,
  }
  T.eq("round2.throwingDelegateIsNil", mgr:getSkipRainHours(72), nil)

  g_currentMission.soilFertilityManager = nil
  g_currentMission.environment.currentMonotonicDay = nil
end

-- =========================================================
-- 4. STRESS ACCUMULATION (CropStressModifier)
-- =========================================================
local function newModifier()
  local m = { debugMode = false }
  local mod = CropStressModifier.new(m)
  mod.isInitialized = true
  return mod
end

-- A field whose crop sits in a critical window, well below threshold.
local function stressField(cropName, stage)
  return { fieldState = { fruitTypeIndex = 7, growthState = stage } }
end

do
  -- Drive processFieldStress directly: it is the arithmetic under test, and it
  -- avoids standing up g_fruitTypeManager's whole surface for a multiply.
  local wheat = CropStressModifier.CROP_WINDOWS.wheat
  T.ok("stress.wheatWindowExists", wheat ~= nil, "CROP_WINDOWS.wheat missing")

  g_fruitTypeManager = {
    getFruitTypeByIndex = function(_self, _i) return { name = "WHEAT" } end,
  }

  local stage = wheat.stages[1]
  local moisture = wheat.criticalMoisture * 0.5   -- half the threshold
  local deficitRatio = (wheat.criticalMoisture - moisture) / wheat.criticalMoisture

  local one = newModifier()
  one:processFieldStress(stressField("wheat", stage), 1, moisture)
  T.near("stress.oneHourUnchanged", one.fieldStress[1],
         wheat.stressRatePerHour * deficitRatio, 1e-9)

  -- Six hours accrue six times as much (chosen small enough not to hit the cap).
  local six = newModifier()
  six:processFieldStress(stressField("wheat", stage), 1, moisture, 6)
  T.near("stress.sixHoursIs6x", six.fieldStress[1],
         wheat.stressRatePerHour * deficitRatio * 6, 1e-9)

  -- The 1.0 cap still bounds a full-week catch-up.
  local week = newModifier()
  week:processFieldStress(stressField("wheat", stage), 1, moisture, 168)
  T.ok("stress.capHolds", week.fieldStress[1] <= 1.0,
       "stress exceeded 1.0: " .. tostring(week.fieldStress[1]))

  -- A field ABOVE its threshold accrues nothing, however long the skip.
  local none = newModifier()
  none:processFieldStress(stressField("wheat", stage), 1, 1.0, 168)
  T.eq("stress.noDeficitNoStress", none.fieldStress[1], nil)

  g_fruitTypeManager = nil
end

-- =========================================================
-- 5. IRRIGATION RUNNING COST (FinanceIntegration)
-- =========================================================
local function newFinance(costPerHour, active)
  local charged = { total = 0, calls = 0 }
  local fi = FinanceIntegration.new({
    irrigationManager = {
      costsEnabled = true,
      systems = { [1] = { isActive = active, operationalCostPerHour = costPerHour } },
    },
  })
  fi.isInitialized = true
  fi.deductFundsVanilla = function(_self, cost)
    charged.total = charged.total + cost
    charged.calls = charged.calls + 1
  end
  return fi, charged
end

do
  local fi, c = newFinance(120, true)
  fi:chargeHourlyCosts()
  T.near("cost.oneHourUnchanged", c.total, 120, 1e-9)
  T.eq("cost.oneCallPerSystem", c.calls, 1)
end

do
  -- THE 72x CLAIM ON THE MONEY SIDE. The pump's water was already multiplied by
  -- the span before SCS-037; without this the player got 72 hours of free water.
  local fi, c = newFinance(120, true)
  fi:chargeHourlyCosts(72)
  T.near("cost.skipIs72x", c.total, 120 * 72, 1e-9)
end

do
  -- An idle system is charged nothing, whatever the span.
  local fi, c = newFinance(120, false)
  fi:chargeHourlyCosts(168)
  T.near("cost.inactiveIsFree", c.total, 0, 1e-9)
end

do
  -- Costs disabled by the player stays free across a catch-up.
  local fi, c = newFinance(120, true)
  fi.manager.irrigationManager.costsEnabled = false
  fi:chargeHourlyCosts(168)
  T.near("cost.disabledIsFree", c.total, 0, 1e-9)
end

do
  -- A garbage span never charges less than one hour and never charges NaN.
  local fi, c = newFinance(120, true)
  fi:chargeHourlyCosts("not a number")
  T.near("cost.garbageSpanIsOneHour", c.total, 120, 1e-9)
end

T.summary()
