-- ============================================================
-- WeatherIntegration.lua
-- Bridges FS25's environment/weather API to the moisture system.
-- Polled every in-game hour by CropStressManager:onHourlyTick().
--
-- Does NOT subscribe to MessageType events (FS25 event IDs are
-- integer-mapped and may differ by version). Instead, polls the
-- weather state directly — reliable and version-agnostic.
--
-- OPTIONAL MOD INTEGRATION:
-- - FS25_RealisticWeather: Detected at runtime, uses enhanced temperature/rain if present
-- ============================================================

-- Export to the global environment so other modules can access it.
-- getfenv(0) writes to the shared mod-global table, which is required because
-- plain module-level assignments stay in this file's local scope in FS25.
WeatherIntegration = WeatherIntegration or {}
WeatherIntegration.__index = WeatherIntegration
getfenv(0)["WeatherIntegration"] = WeatherIntegration

print("[CropStress] WeatherIntegration module loaded")

-- Season indices (matches g_currentMission.environment.currentSeason)
WeatherIntegration.SEASON_SPRING = 0
WeatherIntegration.SEASON_SUMMER = 1
WeatherIntegration.SEASON_AUTUMN = 2
WeatherIntegration.SEASON_WINTER = 3

-- Season display names (English — UI uses i18n keys)
WeatherIntegration.SEASON_NAMES = { [0]="Spring", [1]="Summer", [2]="Autumn", [3]="Winter" }

-- ============================================================
-- SCS-021 THE DRYING MODEL LEARNS WHAT HUMIDITY IS
-- The VPD multiplier: a hot dry wind takes moisture out faster than a
-- hot still muggy day. Constants, not settings; the future Agronomy
-- dial routes through the Option-Scaling Spine when it merges (the
-- EmergencyLoan.lua:26-29 pattern; neutral default until then).
-- Magnus-Tetens constants 17.27 and 237.3.
-- ============================================================
WeatherIntegration.VPD_EXPONENT = 0.40
WeatherIntegration.VPD_MOD_MIN  = 0.40
WeatherIntegration.VPD_MOD_MAX  = 2.20
WeatherIntegration.VPD_REF      = 0.6108 * math.exp(17.27 * 15.0 / (15.0 + 237.3)) * (1.0 - 0.65)  -- 15 C / 65 percent reference

--- The VPD multiplier (SCS-021, SDS 4g). Tetens SVP, vpd = svp * (1 - humidity),
--- mod = (vpd / VPD_REF) ^ VPD_EXPONENT, clamped to the bands. Clamp AFTER the
--- exponent, BEFORE any composition. Pure, no guard logic inside.
---@param tempC number degrees Celsius
---@param humidityFrac number 0..1 (normalized once at the point of read)
---@return number
function WeatherIntegration.computeVPDMultiplier(tempC, humidityFrac)
    local svp  = 0.6108 * math.exp(17.27 * tempC / (tempC + 237.3))
    local vpd  = svp * (1.0 - humidityFrac)
    local mod  = (vpd / WeatherIntegration.VPD_REF) ^ WeatherIntegration.VPD_EXPONENT
    if mod < WeatherIntegration.VPD_MOD_MIN then return WeatherIntegration.VPD_MOD_MIN end
    if mod > WeatherIntegration.VPD_MOD_MAX then return WeatherIntegration.VPD_MOD_MAX end
    return mod
end

-- ============================================================
-- LOGGING HELPER
-- ============================================================
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

function WeatherIntegration.new(manager)
    local self = setmetatable({}, WeatherIntegration)
    self.manager = manager

    -- Cached state (updated each hourly poll)
    self.currentTemp     = 15.0   -- degrees Celsius
    self.currentSeason   = WeatherIntegration.SEASON_SPRING
    self.currentHumidity = 0.5    -- 0.0-1.0
    self.currentHumidityDefaulted = true  -- [SCS-021] until a real read proves otherwise

    -- Rain state: rainScale is the FS25 normalized rain intensity (0.0-1.0)
    self.rainScale        = 0.0
    self.isRaining        = false

    -- Accumulated rain for the current hour (in moisture fraction units)
    -- Calculated from rainScale * absorption coefficient
    self.hourlyRainAmount = 0.0

    -- Optional mod integration flags
    self.realisticWeatherActive = false

    self.isInitialized = false
    return self
end

function WeatherIntegration:initialize()
    if g_currentMission == nil then
        csLog("WeatherIntegration: g_currentMission nil at init")
        return
    end

    -- Detect optional mods
    self:detectOptionalMods()

    -- Do an immediate poll to populate cached values
    self:update()
    self.isInitialized = true

    -- SEASON_NAMES is 0-indexed. currentSeason is normalised in update() so the
    -- lookup is always valid here (no more "Season=?" in the log).
    csLog(string.format(
        "WeatherIntegration initialized. Season=%s Temp=%.1f°C Rain=%s%s",
        WeatherIntegration.SEASON_NAMES[self.currentSeason] or tostring(self.currentSeason),
        self.currentTemp,
        tostring(self.isRaining),
        self.realisticWeatherActive and " (RealisticWeather)" or ""
    ))
end

-- ============================================================
-- OPTIONAL MOD DETECTION
-- ============================================================
function WeatherIntegration:detectOptionalMods()
    -- FS25_RealisticWeather detection
    -- This mod exposes g_realisticWeather global with enhanced weather data
    if getfenv(0)["g_realisticWeather"] ~= nil then
        self.realisticWeatherActive = true
        csLog("FS25_RealisticWeather detected — using enhanced weather data")
    elseif getfenv(0)["g_weatherSystem"] ~= nil then
        -- NOTE: g_weatherSystem might be a vanilla FS25 global on some builds.
        -- If the RealisticWeather API methods don't exist on it, getTemperatureFromWeather()
        -- and getHumidity() will return nil from the RW path and fall through to vanilla
        -- automatically — so this detection fails safe even if it's a false positive.
        self.realisticWeatherActive = true
        csLog("Weather mod detected (g_weatherSystem) — using enhanced weather data")
    end
end

-- Called every in-game hour by CropStressManager:onHourlyTick()
function WeatherIntegration:update()
    if g_currentMission == nil then return end
    local env = g_currentMission.environment
    if env == nil then return end

    -- Season: direct property access, not a method call.
    -- FS25 uses 0–3 (spring/summer/autumn/winter) in most builds but some
    -- return 1–4.  Normalise to 0-based so SEASON_NAMES / SEASON_START_MOISTURE
    -- always index correctly.
    local rawSeason = env.currentSeason or 0
    if rawSeason >= 1 and rawSeason <= 4 then
        rawSeason = rawSeason - 1   -- convert 1-based → 0-based
    end
    self.currentSeason = rawSeason

    -- Temperature - check RealisticWeather first, then fall back to vanilla
    self.currentTemp = self:getTemperatureFromWeather()

    -- Humidity (optional — used for extended forecast; fall back gracefully)
    -- [SCS-021] unpacks both returns: the fraction and whether it was defaulted.
    -- currentHumidityDefaulted is never persisted; recomputed every tick.
    self.currentHumidity, self.currentHumidityDefaulted = self:getHumidity()

    -- Rain intensity
    self.rainScale, self.isRaining = self:getRainFromWeather()

    -- Translate rain scale to moisture gain per hour.
    -- Base: 0.012 moisture fraction per hour at rainScale=1.0
    -- Heavy rain (scale ~1.5) gives 0.018/hr; drizzle (0.3) gives 0.0036/hr
    self.hourlyRainAmount = self.isRaining and (0.012 * self.rainScale) or 0.0

    if self.manager ~= nil and self.manager.debugMode then
        csLog(string.format(
            "WeatherUpdate: Rain=%s Scale=%.3f Amount=%.4f",
            tostring(self.isRaining), self.rainScale, self.hourlyRainAmount
        ))
    end
end

-- ============================================================
-- WEATHER DATA ACCESSORS (with RealisticWeather support)
-- ============================================================
function WeatherIntegration:getTemperatureFromWeather()
    -- [F93] WeatherGuard FIRST, when present. WeatherGuard is the ecosystem's
    -- sixth core service and publishes the certified temperature route:
    -- getCurrentSky().temperature reads weather.temperatureUpdater:getTemperatureAtTime()
    -- (certified in WeatherGuard.lua against four shipping call sites), and it
    -- warns once rather than substituting a number when the route is unreadable.
    -- The cross-mod handle is the mission bridge (g_currentMission.weatherGuard),
    -- exactly the delegate-when-present shape every core service uses. A bare
    -- global would be per-mod scoped and invisible here.
    local wg = g_currentMission and g_currentMission.weatherGuard
    if wg ~= nil and type(wg.getCurrentSky) == "function" then
        local ok, sky = pcall(function() return wg:getCurrentSky() end)
        if ok and sky and type(sky.temperature) == "number" then
            return sky.temperature
        end
    end

    -- Try RealisticWeather first if active.
    if self.realisticWeatherActive then
        local rw = g_realisticWeather or g_weatherSystem
        if rw ~= nil then
            local val = nil
            if type(rw.getTemperature) == "function" then
                val = rw:getTemperature()
            elseif type(rw.getCurrentTemperature) == "function" then
                val = rw:getCurrentTemperature()
            elseif rw.temperature ~= nil then
                val = rw.temperature
            elseif rw.currentTemp ~= nil then
                val = rw.currentTemp
            end
            if val ~= nil then return val end
        end
    end

    -- Fall back to vanilla FS25 weather
    local env = g_currentMission.environment
    if env ~= nil then
        -- [F93] The certified vanilla route. There is NO WeatherSystem class in
        -- FS25: Environment.weather is a Weather instance, and
        -- Weather:getCurrentTemperature() exists (certified at VehicleSystem.lua:158
        -- and in the decompile, Weather.lua:671-672 via temperatureUpdater). The old
        -- weatherSystem:getTemperature() probe below never matched anything, so SCS
        -- believed it was permanently 15 degrees.
        if env.weather ~= nil then
            if type(env.weather.getCurrentTemperature) == "function" then
                local ok, v = pcall(function() return env.weather:getCurrentTemperature() end)
                if ok and v ~= nil then return v end
            end
            if env.weather.temperature ~= nil then
                return env.weather.temperature
            end
        end

        -- Legacy or alternative access (FS22 style)
        if env.weatherSystem ~= nil then
            if type(env.weatherSystem.getTemperature) == "function" then
                return env.weatherSystem:getTemperature()
            elseif type(env.weatherSystem.getCurrentTemperature) == "function" then
                return env.weatherSystem:getCurrentTemperature()
            elseif env.weatherSystem.temperature ~= nil then
                return env.weatherSystem.temperature
            end
        end
    end

    return 15.0
end

function WeatherIntegration:getHumidity()
    -- [SCS-021] WeatherGuard FIRST, when present: the certified humidity route
    -- with its honest defaulted flag. sky.humidity and sky.humidityDefaulted are
    -- table fields, never positional. Normalize ONCE at the point of read (a
    -- percent value lands as a fraction), and return (humidityFrac, defaulted).
    -- A nil sky or nil flag falls through to the existing chain untouched.
    local wg = g_currentMission and g_currentMission.weatherGuard
    if wg ~= nil and type(wg.getCurrentSky) == "function" then
        local ok, sky = pcall(function() return wg:getCurrentSky() end)
        if ok and sky and type(sky.humidity) == "number" then
            local h = sky.humidity
            if h > 1.0 then h = h / 100.0 end
            return h, (sky.humidityDefaulted == true)
        end
    end

    -- Try RealisticWeather first if active.
    if self.realisticWeatherActive then
        local rw = g_realisticWeather or g_weatherSystem
        if rw ~= nil then
            local val = nil
            if type(rw.getHumidity) == "function" then
                val = rw:getHumidity()
            elseif rw.humidity ~= nil then
                val = rw.humidity
            elseif rw.relativeHumidity ~= nil then
                val = rw.relativeHumidity
            end
            if val ~= nil then return val, true end
        end
    end

    -- Fall back to vanilla
    local env = g_currentMission.environment
    if env ~= nil then
        -- FS25 primary weather system
        if env.weatherSystem ~= nil then
            if type(env.weatherSystem.getHumidity) == "function" then
                return env.weatherSystem:getHumidity(), true
            elseif env.weatherSystem.relativeHumidity ~= nil then
                return env.weatherSystem.relativeHumidity, true
            elseif env.weatherSystem.humidity ~= nil then
                return env.weatherSystem.humidity, true
            end
        end

        -- Legacy access
        if env.weather ~= nil and env.weather.relativeHumidity ~= nil then
            return env.weather.relativeHumidity, true
        end
    end

    return 0.5, true
end

function WeatherIntegration:getRainFromWeather()
    local rainScale = 0.0
    local isRaining = false

    -- Try RealisticWeather first if active
    if self.realisticWeatherActive then
        local rw = g_realisticWeather or g_weatherSystem
        if rw ~= nil then
            -- RealisticWeather rain methods - check multiple possible APIs
            if type(rw.getRainIntensity) == "function" then
                rainScale = rw:getRainIntensity() or 0.0
            elseif type(rw.getRainScale) == "function" then
                rainScale = rw:getRainScale() or 0.0
            elseif type(rw.getRainFallScale) == "function" then
                rainScale = rw:getRainFallScale() or 0.0
            elseif rw.rainIntensity ~= nil then
                rainScale = rw.rainIntensity
            elseif rw.rainScale ~= nil then
                rainScale = rw.rainScale
            end
            isRaining = rainScale > 0.01
            if isRaining then
                return rainScale, isRaining
            end
        end
    end

    -- Fall back to vanilla FS25 weather
    local env = g_currentMission.environment
    if env ~= nil then
        -- FS25 primary weather system
        if env.weatherSystem ~= nil then
            if type(env.weatherSystem.getRainFallScale) == "function" then
                rainScale = env.weatherSystem:getRainFallScale() or 0.0
            elseif type(env.weatherSystem.getRainScale) == "function" then
                rainScale = env.weatherSystem:getRainScale() or 0.0
            elseif env.weatherSystem.rainScale ~= nil then
                rainScale = env.weatherSystem.rainScale or 0.0
            end
        end

        -- Legacy or alternative access
        if rainScale <= 0.01 and env.weather ~= nil then
            if env.weather.rainScale ~= nil then
                rainScale = env.weather.rainScale or 0.0
            elseif type(env.weather.getRainFallScale) == "function" then
                rainScale = env.weather:getRainFallScale() or 0.0
            end
        end
    end
    isRaining = rainScale > 0.01

    return rainScale, isRaining
end

-- Evaporation multiplier for the current hour, combining temperature and season.
-- Returns a float (typically 0.2 – 2.5). Used by SoilMoistureSystem.
function WeatherIntegration:getHourlyEvapMultiplier()
    -- [SCS-021] THE HONESTY GUARD: absent real humidity data, this feature IS
    -- the shipped behaviour, bit for bit. Only with a live (non-defaulted) read
    -- does the VPD term replace the temperature-only linear term.
    if self.currentHumidityDefaulted then
        -- Temperature component: +3% per °C above 15°C
        local tempMod = 1.0 + math.max(0.0, (self.currentTemp - 15.0) * 0.03)

        -- Season component
        local seasonMods = { [0]=0.80, [1]=1.40, [2]=0.90, [3]=0.20 }
        local seasonMod  = seasonMods[self.currentSeason] or 1.0

        local multiplier = tempMod * seasonMod

        -- Significant reduction during rain (90% lower evaporation)
        if self.isRaining then
            multiplier = multiplier * 0.10
        end

        return multiplier
    end

    -- The VPD term, on the same season and rain frame. The helper is fed the
    -- current temperature and the live humidity; the season lookup and the rain
    -- switch move NOT AT ALL.
    local seasonMods = { [0]=0.80, [1]=1.40, [2]=0.90, [3]=0.20 }
    local seasonMod  = seasonMods[self.currentSeason] or 1.0

    local multiplier = WeatherIntegration.computeVPDMultiplier(self.currentTemp, self.currentHumidity) * seasonMod

    -- Significant reduction during rain (90% lower evaporation)
    if self.isRaining then
        multiplier = multiplier * 0.10
    end

    return multiplier
end

-- Returns the moisture gain per hour from current rainfall.
function WeatherIntegration:getHourlyRainAmount()
    return self.hourlyRainAmount
end

function WeatherIntegration:getCurrentSeason()
    return self.currentSeason
end

function WeatherIntegration:getCurrentTemp()
    return self.currentTemp
end

function WeatherIntegration:delete()
    -- No subscriptions to clean up (we poll instead)
    self.isInitialized = false
end
-- ============================================================
-- FORECAST API INVESTIGATION RESULT (Issue #69)
-- ============================================================
-- No FS25 weather forecast Lua API exists.
--
-- Investigation performed against FS25-Community-LUADOC and FS25-lua-scripting
-- reference packages (confirmed 2025). Specifically checked:
--   • env.weatherSystem — exposes current temp/rain/humidity only; no future states
--   • env.cloudUpdater  — exposes getCloudCoverage() only; no forecast queue
--   • Weather.getForecast() / weather:getForecast() — method does not exist
--   • XML savegame <forecast> block — no confirmed Lua accessor
--   • FS25_RealisticWeather (g_realisticWeather / g_weatherSystem) — enhanced
--     current-state data only; no getForecast() or equivalent method found
--
-- CONCLUSION: All projections below are APPROXIMATIONS based on:
--   Day 1-2 : cloud coverage signal + current rain state + rain duration heuristic
--   Day 3+  : season-based mean rain probability only
--   All days: season-typical daily mean temperature for evap (not snapshot)
--
-- isForecastApproximate() always returns true. HUD must show visual indicator.
-- ============================================================

-- Season-typical DAILY MEAN temperatures used for projected evap calculations.
-- Using daily means avoids snapshot bias (e.g. midday reads skewing all-day projection).
-- 0=spring, 1=summer, 2=autumn, 3=winter
WeatherIntegration.SEASON_MEAN_TEMP = { [0]=12.0, [1]=22.0, [2]=10.0, [3]=2.0 }

-- Seasonal baseline rain probability (fraction of hours with rain, season average).
-- 0=spring(wettest), 1=summer(dry), 2=autumn(high), 3=winter(moderate)
-- #740 one-story tune: reshaped to mirror SoilFertilizer's Normal-climate SEASONAL SHAPE
-- (spring > autumn > winter > summer) so SF's short-month fill and this forecast agree on
-- which seasons run wet. NOTE the unit gap: SF's CLIMATE_PRECIP is a per-DAY rain-day
-- fraction, this is a per-HOUR fraction, so the SHAPE is matched, not the raw magnitudes
-- (copying SF's day-fractions here would overstate the forecast). Magnitudes stay in this
-- constant's native band; retune is Arissani's balance call.
WeatherIntegration.SEASON_RAIN_PROB = { [0]=0.30, [1]=0.15, [2]=0.28, [3]=0.24 }

-- Returns true always: no FS25 forecast API exists, all projections are approximate.
function WeatherIntegration:isForecastApproximate()
    return true
end

-- ============================================================
-- 5-DAY MOISTURE FORECAST
-- Projects moisture for a field over the next N in-game days.
-- ALL RESULTS ARE APPROXIMATE — see API investigation note above.
-- ============================================================

-- The drilling-window outlook: how likely rain is over the next `daysAhead`
-- in-game days, 0..1. A THIN published wrapper over the same sky-reading the
-- moisture forecast uses (cloud coverage + current rain + rain-duration for days
-- 1-2, season priors beyond). No new model, no new tracking, and the result is
-- ALWAYS approximate: every consumer must hedge (the forecast law, carried in
-- the returned approximate flag). The per-day near-term formula below mirrors
-- getMoistureForecast's nearRainProb exactly; keep the two in lockstep.
function WeatherIntegration:getRainOutlook(daysAhead)
    daysAhead = math.max(1, math.floor(daysAhead or 3))

    local cloudCoverage = 0.0
    local env = g_currentMission and g_currentMission.environment
    if env ~= nil and env.cloudUpdater ~= nil
    and type(env.cloudUpdater.getCloudCoverage) == "function" then
        local ok, val = pcall(env.cloudUpdater.getCloudCoverage, env.cloudUpdater)
        if ok and val ~= nil then cloudCoverage = val end
    end

    local baseRainProb = WeatherIntegration.SEASON_RAIN_PROB[self.currentSeason] or 0.25

    local rainDurationBoost = 0.0
    if self.isRaining then
        rainDurationBoost = cloudCoverage * 0.15
    end

    local sum = 0
    for day = 1, daysAhead do
        local prob
        if day <= 2 then
            if self.isRaining then
                prob = math.min(0.80, math.max(0.20, cloudCoverage) + rainDurationBoost)
            else
                prob = cloudCoverage * 0.40
            end
            if day == 2 then
                prob = prob * 0.65 + baseRainProb * 0.35
            end
        else
            prob = baseRainProb
        end
        sum = sum + prob
    end
    return { likelihood = sum / daysAhead, approximate = true }
end

function WeatherIntegration:getMoistureForecast(fieldId, days)
    days = days or 5

    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil then
        local t = {}
        for i = 1, days do t[i] = 0.5 end
        return t
    end

    local current = soilSystem:getMoisture(fieldId) or 0.5

    local soilType = "loamy"
    if soilSystem.fieldData ~= nil and soilSystem.fieldData[fieldId] ~= nil then
        soilType = soilSystem.fieldData[fieldId].soilType or "loamy"
    end
    local soilParams = SoilMoistureSystem.SOIL_PARAMS[soilType]
        or SoilMoistureSystem.SOIL_PARAMS.loamy

    -- Cloud coverage (confirmed FS25 API: env.cloudUpdater:getCloudCoverage() → 0.0-1.0)
    local cloudCoverage = 0.0
    local env = g_currentMission and g_currentMission.environment
    if env ~= nil and env.cloudUpdater ~= nil
    and type(env.cloudUpdater.getCloudCoverage) == "function" then
        local ok, val = pcall(env.cloudUpdater.getCloudCoverage, env.cloudUpdater)
        if ok and val ~= nil then cloudCoverage = val end
    end

    local season      = self.currentSeason
    local baseRainProb = WeatherIntegration.SEASON_RAIN_PROB[season] or 0.25

    -- Typical moderate-rain moisture gain per raining hour (soil-independent)
    local typicalRainPerHour = 0.010

    -- Irrigation contribution (assumes currently active systems keep running)
    local irrigPerHour = 0.0
    if self.manager ~= nil and self.manager.irrigationManager ~= nil then
        irrigPerHour = self.manager.irrigationManager:getIrrigationRateForField(fieldId)
    end

    -- ── Projected evaporation uses the drying window WHOLE (SCS-021, 4e):
    -- the same VPD helper, fed the forecast day's own humidity from WeatherGuard
    -- and the season's mean temperature. A nil forecast humidity keeps the
    -- linear term for that day, silently. WeatherGuard is resolved exactly as
    -- getTemperatureFromWeather does; nil from either keeps the linear term.
    local meanTemp       = WeatherIntegration.SEASON_MEAN_TEMP[season] or 15.0
    local tempModMean    = 1.0 + math.max(0.0, (meanTemp - 15.0) * 0.03)
    local seasonMods     = { [0]=0.80, [1]=1.40, [2]=0.90, [3]=0.20 }
    local seasonEvapMod  = seasonMods[season] or 1.0

    local forecastWg = g_currentMission and g_currentMission.weatherGuard

    -- ── Rain duration heuristic for near-term signal (day 1-2).
    -- If it has been raining for a while AND cloud coverage is high, persistence
    -- is more likely than immediate clearing. This is a heuristic only.
    -- rainDurationBoost: 0.0 if dry, up to +0.15 if raining + heavy cloud.
    local rainDurationBoost = 0.0
    if self.isRaining then
        rainDurationBoost = cloudCoverage * 0.15
    end

    local projections = {}
    local moisture    = current

    for day = 1, days do
        local rainPerHour

        if day <= 2 then
            -- Near-term: combine cloud coverage + rain persistence heuristic.
            -- isRaining=true  → cloud coverage sustains rain probability (+ duration boost)
            -- isRaining=false → partial cloud coverage suggests rain may arrive (40% weight)
            local nearRainProb
            if self.isRaining then
                nearRainProb = math.max(0.20, cloudCoverage) + rainDurationBoost
                nearRainProb = math.min(nearRainProb, 0.80)    -- cap: we can't know for certain
            else
                nearRainProb = cloudCoverage * 0.40
            end
            -- Decay rain persistence signal on day 2 (uncertainty grows)
            if day == 2 then
                nearRainProb = nearRainProb * 0.65 + baseRainProb * 0.35
            end
            local sourceRate = (self.hourlyRainAmount > 0) and self.hourlyRainAmount
                                                            or typicalRainPerHour
            rainPerHour = sourceRate * nearRainProb

        else
            -- Medium/far-term (day 3+): seasonal probability baseline only.
            rainPerHour = typicalRainPerHour * baseRainProb
        end

        -- [SCS-021] The per-day evap term: VPD multiplier over the drying
        -- window's own humidity when WeatherGuard has a forecast for that day;
        -- otherwise the linear term exactly as before. nil from either keeps the
        -- linear term for that day, silently (spec claim 6).
        local projEvapMult = tempModMean * seasonEvapMod  -- no rain reduction: projection spans whole day
        if forecastWg ~= nil and type(forecastWg.getForecastHumidity) == "function" then
            local okH, forecastHumidity = pcall(forecastWg.getForecastHumidity, forecastWg, day)
            if okH and type(forecastHumidity) == "number" then
                projEvapMult = WeatherIntegration.computeVPDMultiplier(meanTemp, forecastHumidity) * seasonEvapMod
            end
        end

        local evapPerHour = SoilMoistureSystem.BASE_EVAP_RATE
            * projEvapMult
            * soilParams.evapMod

        local rainGain  = rainPerHour * soilParams.rainAbsorb
        local netHourly = rainGain + irrigPerHour - evapPerHour
        moisture = math.max(0.0, math.min(1.0, moisture + netHourly * 24))
        projections[day] = moisture
    end

    return projections
end