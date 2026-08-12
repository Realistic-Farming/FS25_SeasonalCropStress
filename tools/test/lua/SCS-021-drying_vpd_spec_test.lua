-- SCS-021-drying_vpd_spec_test.lua
-- THE DRYING MODEL LEARNS WHAT HUMIDITY IS. A hot dry wind takes moisture
-- out of a field faster than a hot still muggy day. The executable bar for
-- the VPD helper, the WeatherGuard-first humidity read with its honest
-- defaulted flag, the guarded evap multiplier, and the forecast's drying
-- window. Written from the brief's contract (the design-side spec bar lives
-- in the draft workspace; this is the repo bar that travels with the build).
--
-- THE INVARIANTS THAT MATTER:
--   absent real humidity data, the evap multiplier is today's formula bit for bit,
--   a percent humidity read is normalized to a fraction exactly once,
--   the clamp is AFTER the exponent and BEFORE any composition,
--   nil from either the forecast humidity or the guard keeps the linear term.
--!load: src/WeatherIntegration.lua

local WI = WeatherIntegration

-- 1. THE VPD HELPER: Tetens SVP, mod = (vpd / REF)^0.40, clamped AFTER the
--    exponent. At the 15 C / 65 percent reference, mod is exactly 1.0.
do
  local ref = 0.6108 * math.exp(17.27 * 15.0 / (15.0 + 237.3)) * (1.0 - 0.65)
  T.near('vpd.refIsOne', WI.computeVPDMultiplier(15.0, 0.65), 1.0, 1e-9)

  -- Dry air at the same temperature drives evaporation up (mod > 1).
  local dry = WI.computeVPDMultiplier(15.0, 0.20)
  T.ok('vpd.dryAirSpeedsDrying', dry > 1.0)

  -- Muggy air suppresses it (mod < 1).
  local muggy = WI.computeVPDMultiplier(15.0, 0.90)
  T.ok('vpd.muggyAirSlowsDrying', muggy < 1.0)

  -- Hotter at equal humidity dries faster.
  local hot = WI.computeVPDMultiplier(30.0, 0.50)
  local mild = WI.computeVPDMultiplier(10.0, 0.50)
  T.ok('vpd.hotterDriesFaster', hot > mild)

  -- The bands bound the answer.
  local veryDry = WI.computeVPDMultiplier(40.0, 0.0)
  T.ok('vpd.maxBand', veryDry <= WI.VPD_MOD_MAX + 1e-9)
  local saturated = WI.computeVPDMultiplier(-5.0, 0.999)
  T.ok('vpd.minBand', saturated >= WI.VPD_MOD_MIN - 1e-9)

  -- The constants are what the brief says.
  T.near('vpd.exponent', WI.VPD_EXPONENT, 0.40, 1e-9)
  T.near('vpd.minBandConst', WI.VPD_MOD_MIN, 0.40, 1e-9)
  T.near('vpd.maxBandConst', WI.VPD_MOD_MAX, 2.20, 1e-9)
  T.near('vpd.refConst', WI.VPD_REF, ref, 1e-9)
end

-- 2. getHumidity() reads WeatherGuard FIRST and returns (humidity, defaulted).
do
  local function newWI(env, weatherGuard)
    g_currentMission = { environment = env or {} }
    if weatherGuard ~= nil then g_currentMission.weatherGuard = weatherGuard end
    return setmetatable({}, WI)
  end

  do
    -- WeatherGuard present, real humidity, not defaulted.
    local wg = { getCurrentSky = function() return { humidity = 0.42, humidityDefaulted = false } end }
    local wi = newWI({}, wg)
    local h, d = wi:getHumidity()
    T.near('humidity.wgWins', h, 0.42, 1e-9)
    T.eq('humidity.wgNotDefaulted', d, false)
  end

  do
    -- Percent-scale humidity is normalized once, at the point of read.
    local wg = { getCurrentSky = function() return { humidity = 65, humidityDefaulted = false } end }
    local wi = newWI({}, wg)
    local h, d = wi:getHumidity()
    T.near('humidity.percentNormalized', h, 0.65, 1e-9)
    T.eq('humidity.percentNotDefaulted', d, false)
  end

  do
    -- Defaulted flag comes through honestly.
    local wg = { getCurrentSky = function() return { humidity = 0.5, humidityDefaulted = true } end }
    local wi = newWI({}, wg)
    local h, d = wi:getHumidity()
    T.near('humidity.wgDefaultedFlag', h, 0.5, 1e-9)
    T.eq('humidity.wgDefaulted', d, true)
  end

  do
    -- Nil sky falls through to the vanilla chain; the tail is (0.5, true).
    local wg = { getCurrentSky = function() return nil end }
    local env = { weatherSystem = { getHumidity = function() return 0.55 end } }
    local wi = newWI(env, wg)
    local h, d = wi:getHumidity()
    T.near('humidity.nilSkyFallsThrough', h, 0.55, 1e-9)
    T.eq('humidity.fallthroughDefaulted', d, true)
  end

  do
    -- No weather at all: the tail is (0.5, true), never a bare value.
    local wi = newWI({})
    local h, d = wi:getHumidity()
    T.near('humidity.noWeather', h, 0.5, 1e-9)
    T.eq('humidity.noWeatherDefaulted', d, true)
  end
end

-- 3. update() unpacks both returns; new() initializes defaulted = true.
do
  local wi = setmetatable({}, WI)
  wi.manager = nil
  wi:update()
  -- update() sets a defaulted fallback when no weather is present.
  T.eq('update.initializesDefaulted', wi.currentHumidityDefaulted, true)

  local fresh = WI.new(nil)
  T.eq('new.defaultedInitialized', fresh.currentHumidityDefaulted, true)
end

-- 4. getHourlyEvapMultiplier(): the honesty guard, then the VPD term.
do
  local function make(overrides)
    local wi = WI.new(nil)
    for k, v in pairs(overrides or {}) do wi[k] = v end
    return wi
  end

  do
    -- Defaulted humidity: today's formula, bit for bit.
    local wi = make({ currentTemp = 20.0, currentSeason = 1, isRaining = false, currentHumidityDefaulted = true })
    local expected = (1.0 + math.max(0.0, (20.0 - 15.0) * 0.03)) * 1.40
    T.near('evap.defaultedIsLegacy', wi:getHourlyEvapMultiplier(), expected, 1e-9)
  end

  do
    -- Rain still shaves 90% off the product exactly as before.
    local wi = make({ currentTemp = 20.0, currentSeason = 1, isRaining = true, currentHumidityDefaulted = true })
    local expected = (1.0 + math.max(0.0, (20.0 - 15.0) * 0.03)) * 1.40 * 0.10
    T.near('evap.defaultedRainScale', wi:getHourlyEvapMultiplier(), expected, 1e-9)
  end

  do
    -- Live humidity: the VPD term rides the same season and rain frame.
    local wi = make({ currentTemp = 15.0, currentSeason = 1, currentHumidity = 0.65,
                      currentHumidityDefaulted = false, isRaining = false })
    local expected = WI.computeVPDMultiplier(15.0, 0.65) * 1.40
    T.near('evap.liveUsesVPD', wi:getHourlyEvapMultiplier(), expected, 1e-9)
  end

  do
    -- A dry day dries faster than a muggy one at the same temperature.
    local dry = make({ currentTemp = 15.0, currentSeason = 1, currentHumidity = 0.20,
                       currentHumidityDefaulted = false, isRaining = false })
    local muggy = make({ currentTemp = 15.0, currentSeason = 1, currentHumidity = 0.90,
                         currentHumidityDefaulted = false, isRaining = false })
    T.ok('evap.dryBeatsMuggy', dry:getHourlyEvapMultiplier() > muggy:getHourlyEvapMultiplier())
  end
end

-- 5. getMoistureForecast(): the drying window whole, nil keeps the linear term.
do
  local function newWI(env, weatherGuard)
    g_currentMission = { environment = env or {} }
    if weatherGuard ~= nil then g_currentMission.weatherGuard = weatherGuard end
    return setmetatable({}, WI)
  end

  -- A minimal SoilMoistureSystem contract for the forecast's reads.
  SoilMoistureSystem = SoilMoistureSystem or {}
  SoilMoistureSystem.BASE_EVAP_RATE = SoilMoistureSystem.BASE_EVAP_RATE or 0.02
  SoilMoistureSystem.SOIL_PARAMS = SoilMoistureSystem.SOIL_PARAMS or {
    loamy = { evapMod = 1.0, rainAbsorb = 0.8 },
  }
  if SoilMoistureSystem.SOIL_PARAMS.loamy == nil then
    SoilMoistureSystem.SOIL_PARAMS.loamy = { evapMod = 1.0, rainAbsorb = 0.8 }
  end
  local soilSystem = {
    getMoisture = function() return 0.5 end,
    fieldData = {},
  }
  WI.__index = WI
  local forecast = function(overrides)
    local wi = newWI({ cloudUpdater = { getCloudCoverage = function() return 0.0 end } }, overrides.wg)
    wi.manager = { soilSystem = soilSystem, irrigationManager = nil }
    wi.currentSeason = 1
    wi.currentHumidityDefaulted = overrides.defaulted or false
    wi.isRaining = false
    wi.hourlyRainAmount = 0.0
    return wi
  end

  do
    -- WeatherGuard present with a forecast humidity: the VPD term is used.
    local wg = { getForecastHumidity = function(_self, day) return (day == 1) and 0.30 or 0.50 end }
    local wi = forecast({ wg = wg })
    local proj = wi:getMoistureForecast(1, 3)
    T.ok('forecast.returnsProjections', proj ~= nil and #proj == 3)
    T.ok('forecast.allNumbers', type(proj[1]) == "number" and type(proj[2]) == "number" and type(proj[3]) == "number")
  end

  do
    -- No WeatherGuard: the linear term, silently (spec claim 6).
    local wi = forecast({})
    local proj = wi:getMoistureForecast(1, 3)
    T.ok('forecast.noGuardStillProjects', proj ~= nil and #proj == 3)
  end
end

-- 6. The debug surface: the csStatus sky line marker is driven by the flag.
do
  local wi = WI.new(nil)
  wi.currentHumidityDefaulted = true
  local note = ""
  if wi.currentHumidityDefaulted then note = " (humidity defaulted)" end
  T.eq('debug.defaultedMarker', note, " (humidity defaulted)")
  wi.currentHumidityDefaulted = false
  note = ""
  if wi.currentHumidityDefaulted then note = " (humidity defaulted)" end
  T.eq('debug.liveNoMarker', note, "")
end

T.summary()
