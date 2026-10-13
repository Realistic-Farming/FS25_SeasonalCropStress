-- scs023_disposition_suppression_test.lua
-- SCS-023 / GRID-1 (SDS 5.2): a per-field disposition map suppresses ONLY the
-- fields the positional COVER pass accepted or refused this act. Every other
-- field keeps its incumbent field-wide accumulator, and a legacy caller with no
-- map keeps the whole-act bool suppression.
--!load: src/SoilMoistureSystem.lua

local function newSys()
  local s = SoilMoistureSystem.new({})
  s.isInitialized = true
  s.fieldData[1] = { fieldId = 1, moisture = 0.5, soilType = "loamy" }
  s.fieldData[2] = { fieldId = 2, moisture = 0.5, soilType = "loamy" }
  s.irrigationGains[1] = 0.10
  s.irrigationGains[2] = 0.20
  return s
end

local function fakeWeather()
  return { getHourlyEvapMultiplier = function() return 0 end,
           getHourlyRainAmount = function() return 0 end }
end

-- 1. PER-FIELD MAP: only the suppressed field loses its accumulator.
do
  local s = newSys()
  s:hourlyUpdate(fakeWeather(), 1, 0, false, { [1] = true })
  T.near('perfield.field1Suppressed', s.fieldData[1].moisture, 0.5, 1e-9)
  T.near('perfield.field2KeepsIncumbent', s.fieldData[2].moisture, 0.7, 1e-9)
end

-- 2. EMPTY MAP suppresses nothing (nothing was covered this act).
do
  local s = newSys()
  s:hourlyUpdate(fakeWeather(), 1, 0, false, {})
  T.near('empty.field1Keeps', s.fieldData[1].moisture, 0.6, 1e-9)
  T.near('empty.field2Keeps', s.fieldData[2].moisture, 0.7, 1e-9)
end

-- 3. NO MAP: legacy whole-act bool still suppresses every field.
do
  local s = newSys()
  s:hourlyUpdate(fakeWeather(), 1, 0, true, nil)
  T.near('legacy.field1Suppressed', s.fieldData[1].moisture, 0.5, 1e-9)
  T.near('legacy.field2Suppressed', s.fieldData[2].moisture, 0.5, 1e-9)
end

-- 4. NO MAP AND NO BOOL: incumbent accumulators apply everywhere.
do
  local s = newSys()
  s:hourlyUpdate(fakeWeather(), 1, 0, false, nil)
  T.near('off.field1Keeps', s.fieldData[1].moisture, 0.6, 1e-9)
  T.near('off.field2Keeps', s.fieldData[2].moisture, 0.7, 1e-9)
end

T.summary()
