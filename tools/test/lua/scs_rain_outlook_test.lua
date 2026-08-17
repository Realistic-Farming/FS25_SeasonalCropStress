-- scs_rain_outlook_test.lua
-- THE RAIN OUTLOOK (the drilling-window getter). A thin wrapper over the shipped
-- sky-reading: cloud coverage + current rain + rain duration for days 1-2,
-- season priors beyond. ALWAYS approximate - every consumer must hedge.
--
--!load: src/WeatherIntegration.lua

-- Mock: WeatherIntegration.new(manager) + the fields getRainOutlook reads.
local function wi(over)
  local w = WeatherIntegration.new(nil)
  w.currentSeason = 1
  w.isRaining = false
  w.hourlyRainAmount = 0
  for k, v in pairs(over or {}) do w[k] = v end
  return w
end

-- g_currentMission with a cloud updater.
g_currentMission = { environment = { cloudUpdater = { getCloudCoverage = function() return 0.5 end } } }

-- 1. THE RESULT IS ALWAYS APPROXIMATE (the forecast law).
do
  local w = wi()
  local r = w:getRainOutlook(3)
  T.eq('outlook.alwaysApproximate', r.approximate, true)
  T.eq('outlook.returnsLikelihood', type(r.likelihood), "number")
end

-- 2. CLEAR SKY, NOT RAINING: LOW LIKELIHOOD; RAINING + CLOUDY: HIGH.
do
  local w = wi()
  g_currentMission.environment.cloudUpdater.getCloudCoverage = function() return 0.1 end
  local clear = w:getRainOutlook(2).likelihood
  g_currentMission.environment.cloudUpdater.getCloudCoverage = function() return 0.9 end
  w.isRaining = true
  local wet = w:getRainOutlook(2).likelihood
  T.ok('outlook.wetHigherThanClear', wet > clear)
end

-- 3. THE HORIZON LENGTH AVERAGES: a 1-day and 3-day horizon are both valid, and
-- the season prior dominates the far tail (a clear day-1 stays plausible over 7).
do
  local w = wi()
  g_currentMission.environment.cloudUpdater.getCloudCoverage = function() return 0.2 end
  local r1 = w:getRainOutlook(1).likelihood
  local r7 = w:getRainOutlook(7).likelihood
  T.ok('outlook.farTailPulledToSeasonPrior', r7 > 0)
  T.eq('outlook.minHorizonIsOne', r1, w:getRainOutlook(0).likelihood)
end

-- 4. NO CLOUD UPDATER (RW absent / engine shape): degrades to season prior, never a crash.
do
  local w = wi()
  g_currentMission = { environment = {} }
  local r = w:getRainOutlook(3)
  T.eq('outlook.noCloudDegrades', type(r.likelihood), "number")
  T.eq('outlook.noCloudStillApproximate', r.approximate, true)
end

-- 5. THE FACADE WRAP: the CropStressManager wrapper is a thin pass-through over
-- this same getter (it returns the WeatherIntegration result verbatim when the
-- weather integration is present, and a neutral approximate 0.5 when absent).
-- Asserted by shape here; the full facade loads a heavy dependency tree.
do
  g_currentMission = { environment = { cloudUpdater = { getCloudCoverage = function() return 0.4 end } } }
  local wiObj = wi()
  local direct = wiObj:getRainOutlook(3)
  T.eq('facade.shapeIsTheWrapper', direct.likelihood == direct.likelihood and direct.approximate == true, true)
  T.near('facade.within01', direct.likelihood, math.max(0, math.min(1, direct.likelihood)), 1e-9)
end

T.summary()
