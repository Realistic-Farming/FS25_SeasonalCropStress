-- scs039_capture_persistence_test.lua
-- SCS-039 / GRID-1 (SDS 3.5 capture groundwork): the provider revision, the
-- settled-day cursor and the field-wide pending carry are persisted on both
-- save surfaces. They are what the SDS 3.5 COMPLETE envelope carries at the
-- capture revision; until then they were simply lost on save and reload
-- (revision reset to 1, mapPending dropped).
--
-- These tests round-trip the REAL SaveLoadHandler against the REAL
-- SoilMoistureSystem seams, once through the own-XML path (in-memory handle
-- driven by the prelude XML mocks) and once through the StateLedger table path
-- (buildStateTable / applyStateTable).
--!load: src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua

local function soilWithFields()
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.62, soilType = "loamy", mapPending = 0.002 }
  soil.fieldData[2] = { fieldId = 2, moisture = 0.40, soilType = "sandy", mapPending = 0 }
  soil.moistureRevision = 34
  soil._lastSettledDay = 12
  soil._mapWaterPending[1] = { [5] = 0.001 }
  return soil
end

local function emptySoilWithFields()
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.50, soilType = "loamy" }
  soil.fieldData[2] = { fieldId = 2, moisture = 0.50, soilType = "sandy" }
  return soil
end

local function newSaveLoad(soil)
  local stressModifier = { fieldStress = {}, getStress = function() return 0.0 end }
  local handler = SaveLoadHandler.new({ soilSystem = soil, stressModifier = stressModifier })
  handler:initialize()
  return handler
end

-- 1. OWN-XML ROUND TRIP: revision, cursor and both pending namespaces survive.
do
  local sourceSoil = soilWithFields()
  local sh = newSaveLoad(sourceSoil)
  local handle = {}
  sh:saveToXMLFile(handle)

  local targetSoil = emptySoilWithFields()
  local sh2 = newSaveLoad(targetSoil)
  sh2:loadFromXMLFile(handle)

  T.eq("xml.revisionSurvives", targetSoil.moistureRevision, 34)
  T.eq("xml.cursorSurvives", targetSoil._lastSettledDay, 12)
  T.near("xml.fieldPendingSurvives", targetSoil.fieldData[1].mapPending, 0.002, 1e-12)
  T.eq("xml.clearedPendingSurvives", targetSoil.fieldData[2].mapPending, 0)
  T.near("xml.positionalSurvives", targetSoil._mapWaterPending[1][5], 0.001, 1e-12)
  T.near("xml.scalarSurvives", targetSoil.fieldData[1].moisture, 0.62, 1e-12)
end

-- 2. LEDGER TABLE ROUND TRIP mirrors the own-XML carrier exactly.
do
  local sourceSoil = soilWithFields()
  local sh = newSaveLoad(sourceSoil)
  local state = sh:buildStateTable()

  T.eq("ledger.revisionCarried", state.moistureRevision, 34)
  T.eq("ledger.cursorCarried", state.lastSettledDay, 12)
  T.near("ledger.fieldPendingCarried", state.fields[1].mapPending, 0.002, 1e-12)
  T.eq("ledger.clearedPendingAbsent", state.fields[2].mapPending, nil)

  local targetSoil = emptySoilWithFields()
  local sh2 = newSaveLoad(targetSoil)
  sh2:applyStateTable(state)

  T.eq("ledger.revisionApplied", targetSoil.moistureRevision, 34)
  T.eq("ledger.cursorApplied", targetSoil._lastSettledDay, 12)
  T.near("ledger.fieldPendingApplied", targetSoil.fieldData[1].mapPending, 0.002, 1e-12)
  T.near("ledger.positionalApplied", targetSoil._mapWaterPending[1][5], 0.001, 1e-12)
  T.near("ledger.scalarApplied", targetSoil.fieldData[1].moisture, 0.62, 1e-12)
end

-- 3. A FRESH SAVE (no keys present) does not invent a revision or a cursor:
--    the defaults from SoilMoistureSystem.new stand.
do
  local sourceSoil = SoilMoistureSystem.new({})
  sourceSoil.fieldData[1] = { fieldId = 1, moisture = 0.50, soilType = "loamy" }
  local sh = newSaveLoad(sourceSoil)
  local handle = {}
  sh:saveToXMLFile(handle)
  local targetSoil = emptySoilWithFields()
  local sh2 = newSaveLoad(targetSoil)
  sh2:loadFromXMLFile(handle)
  T.eq("fresh.keepsDefaultRevision", targetSoil.moistureRevision, 1)
  T.eq("fresh.keepsNilCursor", targetSoil._lastSettledDay, nil)
  T.eq("fresh.noPositional", type(targetSoil._mapWaterPending[1]), "nil")
end

T.summary()
