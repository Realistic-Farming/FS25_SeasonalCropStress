-- weather_rw_detection_spec_test.lua
-- SCS / RealisticWeather interop (Discord testing wave 2026-08-23): SCS moisture
-- did not follow RealisticWeather. The RW detection probed only
-- getfenv(0)["g_realisticWeather"], the per-mod-scoped read that SCS's own
-- CLAUDE.md documents as unreliable cross-mod. _rwHandle now probes every surface
-- (bare global, g_currentMission bridge, getfenv(0)) and records which matched;
-- detection and the weather reads use the same resolver so they cannot disagree.
--!load: src/WeatherIntegration.lua

local function newWI()
  return setmetatable({}, WeatherIntegration)
end

local function clearRWGlobals()
  g_realisticWeather = nil
  g_weatherSystem = nil
  g_currentMission = g_currentMission or {}
  g_currentMission.realisticWeather = nil
  g_currentMission.weatherSystem = nil
  g_currentMission.weatherGuard = nil
end

-- 1. NO RW: nil handle, surface "none", detection leaves the flag off.
do
  clearRWGlobals()
  local wi = newWI()
  T.ok('none.nilHandle', wi:_rwHandle() == nil)
  T.eq('none.surface', wi._rwSurface, "none")
  wi:detectOptionalMods()
  T.ok('none.notActive', wi.realisticWeatherActive ~= true)
end

-- 2. BARE GLOBAL: g_realisticWeather resolves (the shared-env bench).
do
  clearRWGlobals()
  g_realisticWeather = { getTemperature = function() return 20.0 end }
  local wi = newWI()
  T.ok('bare.resolves', wi:_rwHandle() ~= nil)
  T.eq('bare.surface', wi._rwSurface, "g_realisticWeather")
  wi:detectOptionalMods()
  T.eq('bare.active', wi.realisticWeatherActive, true)
end

-- 3. MISSION BRIDGE: g_currentMission.realisticWeather resolves when the bare
--    global is invisible (the per-mod-scoped real-world case the probe exists for).
do
  clearRWGlobals()
  g_currentMission.realisticWeather = { getTemperature = function() return 18.0 end }
  local wi = newWI()
  T.ok('bridge.resolves', wi:_rwHandle() ~= nil)
  T.eq('bridge.surface', wi._rwSurface, "g_currentMission.realisticWeather")
end

-- 4. WEATHERSYSTEM FALLBACK: g_weatherSystem resolves and arms the flag.
do
  clearRWGlobals()
  g_weatherSystem = { getTemperature = function() return 16.0 end }
  local wi = newWI()
  T.ok('ws.resolves', wi:_rwHandle() ~= nil)
  T.eq('ws.surface', wi._rwSurface, "g_weatherSystem")
  wi:detectOptionalMods()
  T.eq('ws.active', wi.realisticWeatherActive, true)
end

-- 5. READS AGREE WITH DETECTION: with the flag on and the handle set, the
--    temperature read uses the RW path, not the vanilla fallback.
do
  clearRWGlobals()
  g_realisticWeather = { getTemperature = function() return 22.0 end }
  g_currentMission.environment = { weather = { getCurrentTemperature = function() return 9.0 end } }
  local wi = newWI()
  wi:detectOptionalMods()
  T.eq('read.usesRW', wi:getTemperatureFromWeather(), 22.0)
end

T.summary()
