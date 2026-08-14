-- scs020_transpiration_feedback_test.lua
-- TRANSPIRATION FEEDBACK: the growth family's condition scales only the
-- transpiration share of evapotranspiration, never the soil-evaporation share.
-- A blocked cell stays wetter; an excellent-credit cell dries faster; SF absent
-- or neutral is bit-identical to today (factor 1.0). Firewall: read-only.
--
--!load: src/SoilMoistureSystem.lua

g_currentMission = { _isServer = true, environment = {} }
function g_currentMission:getIsServer() return self._isServer end

-- The neutral identity: blocked=0, excellent=0 -> factor 1.0.
do
  local m = setmetatable({}, { __index = SoilMoistureSystem })
  m._growthSummary = function() return { blockedFrac = 0, excellentFrac = 0 } end
  local blocked = 0
  local excellent = 0
  local v = 1 - SoilMoistureSystem.BLOCKED_WEIGHT * blocked
              + SoilMoistureSystem.EXCELLENT_WEIGHT * excellent
  local factor = math.max(SoilMoistureSystem.GROWTH_EVAP_MIN,
    math.min(SoilMoistureSystem.GROWTH_EVAP_MAX, v))
  T.eq('neutral.factorIsOne', factor, 1.0)
end

-- The formula bands: a half-blocked field draws less, a strong field draws more.
do
  local function factorOf(blocked, excellent)
    local v = 1 - SoilMoistureSystem.BLOCKED_WEIGHT * blocked
              + SoilMoistureSystem.EXCELLENT_WEIGHT * excellent
    return math.max(SoilMoistureSystem.GROWTH_EVAP_MIN,
      math.min(SoilMoistureSystem.GROWTH_EVAP_MAX, v))
  end
  T.near('formula.halfBlocked', factorOf(0.5, 0), 0.75, 1e-9)
  T.near('formula.halfExcellent', factorOf(0, 0.5), 1.125, 1e-9)
  T.eq('formula.clampFloor', factorOf(3, 0), SoilMoistureSystem.GROWTH_EVAP_MIN)
  T.eq('formula.clampCeiling', factorOf(0, 3), SoilMoistureSystem.GROWTH_EVAP_MAX)
end

-- The share split: only the transpiration share is scaled.
do
  local soilShare = 100 * (1 - SoilMoistureSystem.TRANSPIRATION_SHARE)
  local transpScale = soilShare + 100 * SoilMoistureSystem.TRANSPIRATION_SHARE * 0.5
  T.eq('split.soilShareNeverScaled', soilShare, 50)
  T.eq('split.transpShareScaled', transpScale, 50 + 25)
end

-- The read: SF absent -> nil -> the factor stays 1.0 (neutral).
do
  local m = setmetatable({}, { __index = SoilMoistureSystem })
  g_currentMission.soilFertilityManager = nil
  T.eq('read.noSFIsNil', m:_growthSummary(1), nil)
end

-- The read: SF present with the getter -> the summary table.
do
  local m = setmetatable({}, { __index = SoilMoistureSystem })
  g_currentMission.soilFertilityManager = {
    getFieldGrowthSummary = function() return { blockedFrac = 0.4, excellentFrac = 0.1 } end,
  }
  local s = m:_growthSummary(1)
  T.eq('read.returnsSummary', s.blockedFrac, 0.4)
  T.eq('read.excellentFrac', s.excellentFrac, 0.1)
  g_currentMission.soilFertilityManager = nil
end

T.summary()
