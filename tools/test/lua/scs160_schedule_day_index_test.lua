-- scs160_schedule_day_index_test.lua
-- F160 THE WEEKLY SCHEDULE. The day-of-week index was read from
-- env.currentDayInPeriod, which the base game computes as
-- (currentDay - 1) % daysPerPeriod + 1 with daysPerPeriod defaulting to 1, so on
-- a default save it is ALWAYS 1: a weekday schedule ran every day (activeDays[1]
-- pinned true) and unticking day one stopped the pivot forever. The index is now
-- derived from the monotonic day modulo 7, so the weekend-off entries are
-- reachable and the schedule honours the days the player actually picked.
--
--!load: src/IrrigationManager.lua

-- 1. THE INDEX ADVANCES 1..7 FROM THE MONOTONIC DAY, IGNORING currentDayInPeriod.
do
  local mgr = IrrigationManager.new(nil)
  -- A default-save environment pins currentDayInPeriod at 1; the monotonic
  -- currentDay still advances. Day 1 is Monday, days 6 and 7 are the weekend.
  local function idx(currentDay)
    return mgr:dayOfWeekIndex({ currentDay = currentDay, currentDayInPeriod = 1 })
  end
  local expected = { 1, 2, 3, 4, 5, 6, 7, 1 }
  for day, want in ipairs(expected) do
    T.eq('index.advancesDay' .. day, idx(day), want)
  end
  -- The pinned currentDayInPeriod must NOT be consulted: on day 5 the index is 5,
  -- not the pinned 1.
  T.eq('index.ignoresPinnedDayInPeriod', idx(5), 5)
  T.eq('index.nilEnvIsOne', mgr:dayOfWeekIndex(nil), 1)
end

-- 2. THE WEEKEND-OFF DAYS ARE REACHABLE (the core defect).
-- A weekday schedule (five true, two false) must NOT run on Saturday or Sunday
-- even when currentDayInPeriod is pinned at 1 by the default save.
do
  local mgr = IrrigationManager.new(nil)
  mgr.isInitialized = true
  mgr.systems = {
    [1] = {
      waterSourceId = 1, pressureMultiplier = 1.0, flowRatePerHour = 1,
      coveredFields = { 1 },
      schedule = { startHour = 6, endHour = 10, activeDays = { true, true, true, true, true, false, false } },
    },
  }
  mgr.waterSources = { [1] = {} }

  -- Monday (day 1) runs; Saturday (6) and Sunday (7) rest, despite the pinned
  -- currentDayInPeriod = 1 that used to make every day a Monday.
  local function runOn(day)
    g_currentMission = { environment = { currentHour = 7, currentDay = day, currentDayInPeriod = 1 } }
    mgr.systems[1].isActive = false
    mgr:hourlyScheduleCheck()
    return mgr.systems[1].isActive
  end

  T.eq('weekday.mondayRuns', runOn(1), true)
  T.eq('weekday.fridayRuns', runOn(5), true)
  T.eq('weekday.saturdayRests', runOn(6), false)
  T.eq('weekday.sundayRests', runOn(7), false)
  T.eq('weekday.nextMondayRunsAgain', runOn(8), true)
end

-- 3. THE MIRROR CASE: UNTICKING DAY ONE NO LONGER STOPS THE PIVOT FOREVER.
-- A schedule active only on Wednesday runs on Wednesday even when the default save
-- would have pinned the day index at 1.
do
  local mgr = IrrigationManager.new(nil)
  mgr.isInitialized = true
  mgr.systems = {
    [1] = {
      waterSourceId = 1, pressureMultiplier = 1.0, flowRatePerHour = 1,
      coveredFields = { 1 },
      schedule = { startHour = 6, endHour = 10, activeDays = { false, false, true, false, false, false, false } },
    },
  }
  mgr.waterSources = { [1] = {} }

  local function runOn(day)
    g_currentMission = { environment = { currentHour = 7, currentDay = day, currentDayInPeriod = 1 } }
    mgr.systems[1].isActive = false
    mgr:hourlyScheduleCheck()
    return mgr.systems[1].isActive
  end

  T.eq('mirror.wednesdayRuns', runOn(3), true)
  T.eq('mirror.mondayRests', runOn(1), false)
end

T.summary()
