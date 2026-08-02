-- weather_temp_f93_test.lua - F93: SCS reads the REAL temperature, not 15.0
--
-- Root cause: getTemperatureFromWeather() probed env.weatherSystem:getTemperature(),
-- but there is no WeatherSystem class in FS25 (Environment.weather is a Weather
-- instance). Every probe missed, so SCS believed it was permanently 15 degrees and
-- every heat-driven behaviour was inert. The fix, in order:
--   1. WeatherGuard first (the sixth core service) - getCurrentSky().temperature,
--      the certified temperatureUpdater route, via the mission bridge.
--   2. The certified vanilla route: Weather:getCurrentTemperature() (exists,
--      certified at VehicleSystem.lua:158 and the decompile Weather.lua:671-672).
--   3. RealisticWeather (legacy, retired from the ecosystem but still probed).
--   4. The old broken weatherSystem probes last, as harmless legacy.
--
--!load: src/WeatherIntegration.lua

local function newWI(env, weatherGuard)
  g_currentMission = { environment = env or {} }
  if weatherGuard ~= nil then g_currentMission.weatherGuard = weatherGuard end
  return setmetatable({}, WeatherIntegration)
end

-- ── WeatherGuard delegates first, when present ───────────────────────────────
do
  local wg = { getCurrentSky = function() return { temperature = 21.5 } end }
  local wi = newWI({ weather = { getCurrentTemperature = function() return 9.0 end } }, wg)
  T.near("WeatherGuard temperature wins when present", wi:getTemperatureFromWeather(), 21.5, 1e-9)
end

do
  -- WeatherGuard present but its sky is unreadable: fall through, never a crash.
  local wg = { getCurrentSky = function() return nil end }
  local env = { weather = { getCurrentTemperature = function() return 17.0 end } }
  local wi = newWI(env, wg)
  T.near("WeatherGuard nil sky falls through to vanilla", wi:getTemperatureFromWeather(), 17.0, 1e-9)
end

do
  -- WeatherGuard getCurrentSky throws: pcall-guarded, fall through.
  local wg = { getCurrentSky = function() error("boom") end }
  local env = { weather = { getCurrentTemperature = function() return 12.0 end } }
  local wi = newWI(env, wg)
  T.near("WeatherGuard throw falls through", wi:getTemperatureFromWeather(), 12.0, 1e-9)
end

-- ── No WeatherGuard: the certified vanilla route reads the REAL temperature ──
do
  local env = { weather = { getCurrentTemperature = function() return 8.4 end } }
  local wi = newWI(env, nil)
  T.near("vanilla Weather:getCurrentTemperature is read", wi:getTemperatureFromWeather(), 8.4, 1e-9)
end

do
  -- temperatureUpdater-backed route works through Weather:getCurrentTemperature.
  local env = { weather = { getCurrentTemperature = function() return 13.7 end } }
  local wi = newWI(env, nil)
  T.near("the certified route returns the real value", wi:getTemperatureFromWeather(), 13.7, 1e-9)
end

-- ── The old broken weatherSystem probes never win over a working route ──────
do
  -- Even when weatherSystem:getTemperature exists (a third-party patch), the
  -- certified env.weather route is tried FIRST and wins.
  local env = {
    weather = { getCurrentTemperature = function() return 16.0 end },
    weatherSystem = { getTemperature = function() return 5.0 end },
  }
  local wi = newWI(env, nil)
  T.near("certified route wins over a legacy weatherSystem", wi:getTemperatureFromWeather(), 16.0, 1e-9)
end

-- ── No weather at all: the 15.0 floor is the last honest fallback ───────────
do
  local wi = newWI({}, nil)
  T.eq("no weather: floor stays 15.0", wi:getTemperatureFromWeather(), 15.0)
end

-- ── The cached value flows through getCurrentTemp (used by heat stress) ─────
do
  local env = { weather = { getCurrentTemperature = function() return 27.3 end } }
  local wi = newWI(env, nil)
  wi:update()
  T.near("update() caches the real temperature", wi.currentTemp, 27.3, 1e-9)
end
