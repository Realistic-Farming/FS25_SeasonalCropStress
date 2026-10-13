-- SF-73-field_report_reader_spec_test.lua
--
-- SF-73 Implementation v1.1 section 6, the SeasonalCropStress reader: the drought
-- accrual's nutrient-availability base reads Soil's crop-relative FIELD_REPORT
-- (getCropNutrientRelationship(fieldId), no coordinates) when it is complete, and the
-- whole legacy Poor count of getFieldInfo when it is not. Three BELOW keep 0.70, one or
-- two BELOW keep 0.85, APPROACHING interpolates from 1 at the lower edge to 0.85 one
-- window below, IDEAL and ABOVE give 1; the moisture factor applies afterwards.
--
-- ENTRY-POINT BAR: every accrual row runs the production hour, CropStressModifier:
-- hourlyUpdate(1), on a real modifier built by CropStressModifier.new, over a field in
-- its critical window (the manager's own fieldById map and the moisture slot the hour
-- reads). The only stand-in is Soil itself, answering through its published read
-- contract (the relationship record's shape, as SoilFertilitySystem returns it).
--
--!load: src/SoilFertilizerIntegration.lua, src/CropStressModifier.lua

g_currentMission = { _isServer = true, fieldManager = {} }
function g_currentMission:getIsServer() return self._isServer end
g_fruitTypeManager = { getFruitTypeByIndex = function(_, i) return ({ [1] = { name = "WHEAT" } })[i] end }

local function nutrient(kind, dist, width)
  return { relationship = kind, approachingDistance = dist, approachingWidth = width or 0.787,
           value = 40, lower = 39.2, upper = 40, knowledgeState = "KNOWN" }
end
local function report(n, p, k, scope)
  return { schema = 1, scope = scope or "FIELD_REPORT", quality = "ANALYSIS", fieldId = 7, cropKey = "wheat",
           nutrients = { N = n, P = p, K = k } }
end

--- One production hour on one wheat field at stage 4, moisture 0.20 (below wheat's
--- critical 0.35, inside the drought extreme). Returns the stress it accrued.
local function hour(rel, legacyStatus)
  local manager = { debugMode = false, fieldById = {} }
  local m = CropStressModifier.new(manager)
  m:initialize()
  manager.fieldById[7] = { fieldState = { fruitTypeIndex = 1, growthState = 4 } }
  manager.soilSystem = { fieldData = { [7] = { moisture = 0.20 } } }
  local soil = {
    getFieldInfo = function() return {
      nitrogen = { status = legacyStatus or "Good" }, phosphorus = { status = legacyStatus or "Good" },
      potassium = { status = legacyStatus or "Good" } } end,
  }
  if rel ~= false then soil.getCropNutrientRelationship = function(_, fieldId, x, z)
    if x ~= nil or z ~= nil then return nil end   -- the reader must ask for the FIELD report
    return rel
  end end
  g_currentMission.soilFertilityManager = { soilSystem = soil }
  m:hourlyUpdate(1)
  g_currentMission.soilFertilityManager = nil
  return m:getStress(7)
end

local ideal = hour(report(nutrient("IDEAL"), nutrient("IDEAL"), nutrient("ABOVE")))
local oneBelow = hour(report(nutrient("BELOW"), nutrient("IDEAL"), nutrient("IDEAL")))
local twoBelow = hour(report(nutrient("BELOW"), nutrient("BELOW"), nutrient("IDEAL")))
local threeBelow = hour(report(nutrient("BELOW"), nutrient("BELOW"), nutrient("BELOW")))
local halfway = hour(report(nutrient("APPROACHING", 0.3935, 0.787), nutrient("IDEAL"), nutrient("IDEAL")))

T.ok("R1 the production hour accrues drought stress", ideal > 0)
T.near("R2 one BELOW keeps 0.85 (stress / 0.85 of the ideal base)", oneBelow / ideal, 1 / 0.85, 1e-6)
T.near("R3 two BELOW keep 0.85", twoBelow / ideal, 1 / 0.85, 1e-6)
T.near("R4 three BELOW keep 0.70", threeBelow / ideal, 1 / 0.70, 1e-6)
T.near("R5 APPROACHING half a window below interpolates to 0.925", halfway / ideal, 1 / 0.925, 1e-6)

-- the new record decides even where the legacy Poor count would disagree
local reportOverPoor = hour(report(nutrient("IDEAL"), nutrient("IDEAL"), nutrient("IDEAL")), "Poor")
T.near("R6 a complete FIELD_REPORT of IDEAL overrides a legacy Poor", reportOverPoor, ideal, 1e-12)

-- an incomplete or foreign record takes the whole legacy path
local legacyPoor = hour(false, "Poor")
local undetermined = hour(report(nutrient("UNDETERMINED"), nutrient("IDEAL"), nutrient("IDEAL")), "Poor")
T.near("R7 an UNDETERMINED nutrient takes the complete legacy path", undetermined, legacyPoor, 1e-12)
local missing = hour(report(nutrient("IDEAL"), nil, nutrient("IDEAL")), "Poor")
T.near("R8 a missing nutrient takes the complete legacy path", missing, legacyPoor, 1e-12)
local footprint = hour(report(nutrient("IDEAL"), nutrient("IDEAL"), nutrient("IDEAL"), "FOOTPRINT"), "Poor")
T.near("R9 a vehicle FOOTPRINT never changes the field simulation", footprint, legacyPoor, 1e-12)
local badDistance = hour(report(nutrient("APPROACHING", 0 / 0, 0.787), nutrient("IDEAL"), nutrient("IDEAL")), "Poor")
T.near("R10 an unusable approaching distance takes the legacy path", badDistance, legacyPoor, 1e-12)
local noGetter = hour(false, "Good")
T.near("R11 an older Soil without the getter keeps the legacy result", noGetter, ideal, 1e-12)
T.near("R12 legacy three Poor still keeps 0.70", legacyPoor / ideal, 1 / 0.70, 1e-6)

-- Soil absent: neutral base
do
  local manager = { debugMode = false, fieldById = { [7] = { fieldState = { fruitTypeIndex = 1, growthState = 4 } } } }
  local m = CropStressModifier.new(manager)
  m:initialize()
  manager.soilSystem = { fieldData = { [7] = { moisture = 0.20 } } }
  g_currentMission.soilFertilityManager = nil
  m:hourlyUpdate(1)
  T.near("R13 Soil absent is neutral (same as an ideal report)", m:getStress(7), ideal, 1e-12)
end

-- the pure mapping
T.eq("M1 approaching a full window below is 0.85", CropStressModifier.relationshipAvailability(
  report(nutrient("APPROACHING", 0.787, 0.787), nutrient("IDEAL"), nutrient("IDEAL"))), 0.85)
T.eq("M2 a non-table record is nil", CropStressModifier.relationshipAvailability(nil), nil)

T.summary()
