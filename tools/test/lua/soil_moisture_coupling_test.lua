-- soil_moisture_coupling_test.lua
-- Arrow-2 (compaction sharpens the wet/dry swing) + the soil-moisture coupling
-- (moisture extremes reduce effective nutrient uptake, so the same deficit
-- stresses the crop harder). All SCS-side reads of SF's getFieldInfo, never a
-- write: the single-writer firewall holds.
--
--!load: src/SoilFertilizerIntegration.lua, src/CropStressModifier.lua

g_currentMission = { _isServer = true }
function g_currentMission:getIsServer() return self._isServer end

-- ══════════════════════════════════════════════════════════
-- ARROW-2: THE COMPACTION MODIFIER
-- ══════════════════════════════════════════════════════════

do
  local sf = SoilFertilizerIntegration.new(nil)
  T.eq('compact.neutralAtNil', sf:computeCompactMod(nil), 0.0)
  T.eq('compact.neutralBelowMid', sf:computeCompactMod(10), 0.0)
  T.eq('compact.midAt50', sf:computeCompactMod(50), 0.02)
  T.eq('compact.highAt80', sf:computeCompactMod(80), 0.05)
  T.eq('compact.highAbove80', sf:computeCompactMod(100), 0.05)
end

-- The cache stores it and the accessor returns it.
do
  local sf = SoilFertilizerIntegration.new(nil)
  sf.isActive = function() return true end
  sf.fieldCache[7] = { evapMod = 1.0, stressMod = 0.01, compactMod = 0.05, lastHourKey = 1 }
  T.eq('compact.cachedRead', sf:getFieldCompactMod(7), 0.05)
  T.eq('compact.neutralWhenEmpty', sf:getFieldCompactMod(99), 0.0)
end

-- refreshField captures compaction alongside OM/pH (a nil SF is neutral).
do
  local sf = SoilFertilizerIntegration.new(nil)
  sf.isActive = function() return true end
  g_currentMission.soilFertilityManager = { soilSystem = {
    getFieldInfo = function() return { organicMatter = 4, pH = 6.5, compaction = 85 } end,
  } }
  sf.fieldCache = {}
  sf:refreshField(3, 100)
  T.near('compact.capturedInRefresh', sf.fieldCache[3].compactMod, 0.05, 1e-9)
  g_currentMission.soilFertilityManager = nil
end

-- ══════════════════════════════════════════════════════════
-- THE SOIL-MOISTURE COUPLING: NUTRIENT AVAILABILITY
-- ══════════════════════════════════════════════════════════

local function cm()
  return setmetatable({ fieldStress = {} }, { __index = CropStressModifier })
end

-- Normal moisture, good NPK: neutral 1.0.
do
  local m = cm()
  g_currentMission.soilFertilityManager = { soilSystem = {
    getFieldInfo = function() return {
      nitrogen = { status = "Good" }, phosphorus = { status = "Good" }, potassium = { status = "Good" },
    } end,
  } }
  T.near('avail.neutralAtNormal', m:_nutrientAvailability(1, 0.5), 1.0, 1e-9)
  g_currentMission.soilFertilityManager = nil
end

-- Drought extreme (< 30%) reduces availability.
do
  local m = cm()
  local dry = m:_nutrientAvailability(1, 0.10)
  local wet = m:_nutrientAvailability(1, 0.50)
  T.ok('avail.droughtReducesUptake', dry < wet)
  T.ok('avail.droughtStaysAboveFloor', dry >= 0.5)
end

-- Waterlog extreme (> 90%) reduces availability.
do
  local m = cm()
  local wl = m:_nutrientAvailability(1, 0.95)
  local n  = m:_nutrientAvailability(1, 0.50)
  T.ok('avail.waterlogReducesUptake', wl < n)
end

-- Poor NPK on top of drought reduces availability further than drought alone.
do
  local m = cm()
  g_currentMission.soilFertilityManager = { soilSystem = {
    getFieldInfo = function() return {
      nitrogen = { status = "Poor" }, phosphorus = { status = "Poor" }, potassium = { status = "Poor" },
    } end,
  } }
  local poorDry = m:_nutrientAvailability(1, 0.10)
  g_currentMission.soilFertilityManager = nil
  local goodDry = m:_nutrientAvailability(1, 0.10)   -- SF absent -> neutral base, drought only
  T.ok('avail.poorNutrientsHitHarder', poorDry < goodDry)
end

-- SF absent entirely: neutral base, drought extreme still applies (the coupling
-- is moisture-first, nutrients sharpen it).
do
  local m = cm()
  g_currentMission.soilFertilityManager = nil
  T.eq('avail.noSFStillNeutralAtNormal', m:_nutrientAvailability(1, 0.5), 1.0)
  T.ok('avail.noSFDroughtStillBites', m:_nutrientAvailability(1, 0.05) < 1.0)
end

T.summary()
