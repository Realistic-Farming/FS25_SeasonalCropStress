-- facade_readapi_test.lua — B3.2b companion read-facade contract.
-- Exercises the getters CropStressManager exposes on g_currentMission.cropStressManager
-- for the SCS irrigation-ops + economy consumers. No engine needed: we build a bare
-- manager (setmetatable, no :new) and wire fake subsystems, then assert:
--   • every getter is nil/neutral-safe when its subsystem is absent,
--   • promoted reads delegate to the right subsystem method,
--   • getIrrigationSystems / getIrrigationSchedule hand back COPIES (mutating the
--     result cannot corrupt the live sim), and the coveredFields ipairs-array
--     contract survives the copy,
--   • schedule lookup only reports ACTIVE systems,
--   • the heat-fold decision holds: getStress is moisture-only, heat lives on
--     getTemperature / getEvaporativeDemand.
--!load: src/CropStressManager.lua

local function newManager(overrides)
  local m = setmetatable({}, CropStressManager)
  for k, v in pairs(overrides or {}) do m[k] = v end
  return m
end

-- 1. Bare manager, no subsystems → neutral values, never an error ────────────
do
  local m = newManager({})
  T.eq("empty.getMoisture nil",        m:getMoisture(1),            nil)
  T.eq("empty.getStress 0",            m:getStress(1),              0.0)
  T.eq("empty.getIrrigationRate 0",    m:getIrrigationRate(1),      0.0)
  T.eq("empty.isFieldIrrigated false", m:isFieldIrrigated(1),       false)
  T.eq("empty.getIrrigationSystems 0", #m:getIrrigationSystems(),   0)
  T.eq("empty.getIrrigationSchedule",  m:getIrrigationSchedule(1),  nil)
  T.eq("empty.getFieldPolygonWorld",   m:getFieldPolygonWorld({}),  nil)
  T.eq("empty.getCriticalAlertHint",   m:getCriticalAlertHint(),    nil)
  T.eq("empty.getTemperature 15",      m:getTemperature(),          15.0)
  T.eq("empty.getEvaporativeDemand 1", m:getEvaporativeDemand(),    1.0)
end

-- 2. Fully wired manager → promotes delegate, snapshots isolate ───────────────
do
  local fakeIrr = {
    getIrrigationRateForField = function(_self, fid) return (fid == 10) and 0.02 or 0.0 end,
    getFieldPolygonWorld = function(_self, field)
      if field.ok then return {1, 2, 3}, {4, 5, 6}, 3 end
      return nil
    end,
    systems = {
      [100] = {
        id = 100, type = "pivot", isActive = true,
        coveredFields = { 10, 11 },
        schedule = { startHour = 6, endHour = 10, activeDays = {true,true,true,true,true,false,false} },
        flowRatePerHour = 0.018, operationalCostPerHour = 15,
      },
      [200] = {
        id = 200, type = "drip", isActive = false,   -- inactive: must NOT report a schedule
        coveredFields = { 12 },
        schedule = { startHour = 5, endHour = 8, activeDays = {true,false,true,false,true,false,false} },
        flowRatePerHour = 0.01, operationalCostPerHour = 8,
      },
    },
  }
  local fakeAD = { getCriticalAlertHint = function() return "haul water" end }
  local fakeWeather = {
    getCurrentTemp          = function() return 28.5 end,
    getHourlyEvapMultiplier = function() return 2.1 end,
  }
  local m = newManager({
    irrigationManager    = fakeIrr,
    autoDriveIntegration = fakeAD,
    weatherIntegration   = fakeWeather,
  })

  -- irrigation rate + coverage boolean
  T.near("rate field 10",       m:getIrrigationRate(10), 0.02)
  T.ok("field 10 irrigated",    m:isFieldIrrigated(10))
  T.ok("field 99 not irrigated", not m:isFieldIrrigated(99))

  -- systems snapshot
  local sys = m:getIrrigationSystems()
  T.eq("systems count", #sys, 2)
  local snap
  for _, s in ipairs(sys) do if s.id == 100 then snap = s end end
  T.ok("snapshot has system 100", snap ~= nil)
  T.eq("snapshot type",           snap.type, "pivot")
  T.eq("snapshot isActive",       snap.isActive, true)
  T.eq("snapshot cost",           snap.operationalCostPerHour, 15)
  T.eq("coveredFields ipairs len", #snap.coveredFields, 2)
  -- mutating the snapshot must not touch the live system
  snap.coveredFields[1] = -1
  snap.schedule.startHour = 99
  T.eq("live coveredFields intact", fakeIrr.systems[100].coveredFields[1], 10)
  T.eq("live schedule intact",      fakeIrr.systems[100].schedule.startHour, 6)

  -- schedule lookup: active-covered field yields a copy; inactive/uncovered → nil
  local sch = m:getIrrigationSchedule(10)
  T.ok("schedule for active field", sch ~= nil)
  T.eq("schedule startHour", sch and sch.startHour, 6)
  T.eq("schedule endHour",   sch and sch.endHour, 10)
  sch.activeDays[1] = false
  T.eq("schedule copy isolates activeDays", fakeIrr.systems[100].schedule.activeDays[1], true)
  T.eq("inactive system → no schedule", m:getIrrigationSchedule(12), nil)
  T.eq("uncovered field → no schedule", m:getIrrigationSchedule(999), nil)

  -- polygon promote (real return arity)
  T.eq("polygon nil without data", m:getFieldPolygonWorld({}), nil)
  local _vx, _vz, n = m:getFieldPolygonWorld({ ok = true })
  T.eq("polygon vertex count", n, 3)

  -- advisory + heat promotes
  T.eq("critical alert hint", m:getCriticalAlertHint(), "haul water")
  T.near("temperature promote", m:getTemperature(), 28.5)
  T.near("evaporative demand promote", m:getEvaporativeDemand(), 2.1)
end

-- 3. Heat-fold contract: getStress folds NO heat ─────────────────────────────
-- A field with zero moisture stress but a scorching evaporative demand must
-- report stress 0 and heat via the weather getters — proving SCS-010/013 have
-- to read heat separately, never off getStress.
do
  local fakeStress = { getStress = function(_self, _fid) return 0.0 end }
  local fakeWeather = {
    getCurrentTemp          = function() return 40.0 end,
    getHourlyEvapMultiplier = function() return 2.4 end,
  }
  local m = newManager({ stressModifier = fakeStress, weatherIntegration = fakeWeather })
  T.eq("heatwave: stress still 0",        m:getStress(1), 0.0)
  T.near("heatwave: temperature exposed", m:getTemperature(), 40.0)
  T.near("heatwave: evap demand exposed", m:getEvaporativeDemand(), 2.4)
end
