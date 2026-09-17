-- scs039_save_view_restore_test.lua
-- SCS-039 SDS 3.7/3.8 + SCS-041 SDS 5.1/5.13: the on-disk carrier and the one
-- restore barrier, driven against the REAL owners:
--   CropStressManager:ensureMissionWaterSaveCut   (the cached immutable view)
--   SaveLoadHandler:performMissionWaterSaveCut     (capture, native receipt, commit)
--   SaveLoadHandler:saveToXMLFile / loadFromXMLFile (full view on own XML)
--   SaveLoadHandler:buildStateTable / applyStateTable (full view on the ledger)
--   SaveLoadHandler:collectMoistureCandidates / selectMoistureCarrier / restoreMissionWater
--   CropStressManager:tryRestoreMissionWater        (readiness barrier, route enable)
--   SoilMoistureSystem:adoptNativeGeneration / declineNativeCarrier / loadAbsorptionWindow
-- The only stand-ins are the engine seams: a fake value map object (the native
-- handle), a spy on saveNativeMap (the engine receipt) and the prelude XML mock.
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua, src/CropStressManager.lua

local ROOT = "careerSavegame.cropStress"
local HOUR = 50   -- day 2, hour 2

fileExists = function() return true end
g_currentMission = {
  time = 1000,
  environment = { currentHour = 2, currentMonotonicDay = 2, currentDay = 2, daysPerPeriod = 1 },
  missionInfo = { savegameDirectory = "sg" },
}

local function tableCount(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- A capacity row on window HOUR at TRUTH:2 so packAbsorptionWindow has a leaf.
local function seedAbsorption(soil)
  soil.absorptionMode = "CAPPED"
  soil.agronomyRestriction = 1.0
  soil:_applyAbsorptionSpan({
    requestPerWindow = 0.015, windowEnd = HOUR, windowCount = 1,
    soilFactor = 1.0, fieldId = 1,
    providerMode = "TRUTH", providerGrain = 2,
    cellKey = "TRUTH:2:10:20",
    providerCenterX = -2101, providerCenterZ = -2087,
    cellX = 10, cellZ = 20,
    rawWrite = function() return true end,
    compactionReader = function() return nil end,
  })
end

local function fakeValueMap(log)
  return {
    available = true, resolution = 1024, loadedFromSave = true,
    getGrainMetres = function() return 2 end,
    -- RSF-F244: the one loader opens the file the envelope RECORDS.
    loadNativeFile = function(_self, dir, filename, width)
      log[#log + 1] = { dir = dir, filename = filename, width = width }
      return log.answer ~= false, true
    end,
    delete = function(self) self.available = false end,
  }
end

--- A soil in TRUTH with two fields, both pending stores and a CAPPED leaf.
local function truthSoil(revision, cursor, log)
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.62, soilType = "loamy", mapPending = 0.002 }
  soil.fieldData[2] = { fieldId = 2, moisture = 0.40, soilType = "sandy", mapPending = 0 }
  soil.moistureRevision = revision
  soil._lastSettledDay = cursor
  soil._mapWaterPending[1] = { [5] = 0.001 }
  soil.providerMode = "TRUTH"
  soil.valueMap = fakeValueMap(log or {})
  soil._nativeSaves = {}
  soil.saveNativeMap = function(self, dir, filename)
    self._nativeSaves[#self._nativeSaves + 1] = filename
    return self._nativeAnswer ~= false
  end
  soil._nativeAnswer = true
  seedAbsorption(soil)
  return soil
end

local function freshSoil(log, mode)
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.50, soilType = "loamy" }
  soil.fieldData[2] = { fieldId = 2, moisture = 0.50, soilType = "sandy" }
  soil.absorptionMode = "CAPPED"
  soil.agronomyRestriction = 1.0
  if mode == "ZONE" then
    soil.providerMode = "ZONE"
    soil.valueMap = nil
  else
    soil.providerMode = "TRUTH"
    soil.valueMap = fakeValueMap(log or {})
  end
  return soil
end

local function bareManager(soil)
  local m = setmetatable({}, CropStressManager)
  m.isInitialized = true
  m.soilSystem = soil
  m.stressModifier = { fieldStress = {}, getStress = function(self, fid) return self.fieldStress[fid] or 0 end }
  m.irrigationManager = { systems = {}, settled = {},
    settleFittedSystem = function(self, sys, reason) self.settled[#self.settled + 1] = reason; sys.activeGameHoursSinceSettle = 0 end }
  m.sprayerIntegration = { calls = 0, initialize = function(self) self.calls = self.calls + 1 end }
  m.irrigatorSectorIntegration = { calls = 0, initialize = function(self) self.calls = self.calls + 1 end }
  m.saveLoad = SaveLoadHandler.new(m)
  m.saveLoad:initialize()
  return m
end

local function allReady(m)
  local r = m:_restoreState()
  r.compactReady, r.fieldsReady, r.mapReady, r.settingsLoaded, r.absorptionFrozen = true, true, true, true, true
end

-- ============================================================
-- A. THE CUT: one cached immutable view; reused clean, recaptured dirty.
-- ============================================================
do
  local soil = truthSoil(7, 20)
  local m = bareManager(soil)
  m.irrigationManager.systems[1] = { rainKeyFitted = true, activeGameHoursSinceSettle = 0.5 }

  local v1 = m:ensureMissionWaterSaveCut("PUMP")
  T.eq("cut.fittedSettledForSave", m.irrigationManager.settled[1], "SAVE")
  T.eq("cut.nativeWrittenToFirstSlot", soil._nativeSaves[1], "csMoistureMap.s1.grle")
  T.eq("cut.generationAdvances", m.saveLoad._completePair.current.generation, 1)
  T.eq("cut.viewHasOneComplete", #v1.complete, 1)
  T.eq("cut.completeGeneration", v1.complete[1].generation, 1)
  T.eq("cut.completeFilename", v1.complete[1].filename, "csMoistureMap.s1.grle")
  T.eq("cut.completeMapWidth", v1.complete[1].mapWidth, 1024)
  T.eq("cut.leafCaptured", v1.complete[1].absorption ~= nil, true)
  T.eq("cut.leafWindow", v1.complete[1].absorption.windowId, HOUR)
  T.eq("cut.storedDigestAtCommittedGeneration",
    m.saveLoad:compactDigest(v1.complete[1]), v1.complete[1].digest)

  local v2 = m:ensureMissionWaterSaveCut("STATELEDGER")
  T.ok("cut.cleanViewReusedSameObject", v2 == v1)
  T.eq("cut.noSecondNativeWrite", #soil._nativeSaves, 1)
  T.eq("cut.noSecondSettle", #m.irrigationManager.settled, 1)

  m:markMissionWaterDirty()
  soil.moistureRevision = 8
  local v3 = m:ensureMissionWaterSaveCut("CAREER_XML")
  T.ok("cut.dirtyRecaptures", v3 ~= v1)
  T.eq("cut.secondGeneration", v3.complete[1].generation, 2)
  T.eq("cut.previousRetained", v3.complete[2].generation, 1)
  T.eq("cut.secondNativeSlot", soil._nativeSaves[2], "csMoistureMap.s2.grle")
end

-- ============================================================
-- B. FAILED NATIVE WRITE: no generation advance, cut stays dirty, PENDING_ONLY
--    row in the view; a later success cleans the cut.
-- ============================================================
do
  local soil = truthSoil(7, 20)
  local m = bareManager(soil)
  m:ensureMissionWaterSaveCut("PUMP")                -- generation 1
  m:markMissionWaterDirty()
  soil._nativeAnswer = false
  soil.moistureRevision = 9
  local v = m:ensureMissionWaterSaveCut("PUMP")
  T.eq("nativeFail.generationHeld", m.saveLoad._completePair.current.generation, 1)
  T.eq("nativeFail.pendingRowRecorded", v.pendingOnly ~= nil and v.pendingOnly.payloadKind, "PENDING_ONLY")
  T.eq("nativeFail.pendingBoundToRetainedGeneration", v.pendingOnly.baseGeneration, 1)
  T.eq("nativeFail.pendingBoundToRetainedRevision", v.pendingOnly.baseRevision, 7)
  T.eq("nativeFail.viewKeepsCompletePair", #v.complete, 1)
  T.eq("nativeFail.cutStaysDirty", m._waterSaveCut.dirty, true)
  T.eq("nativeFail.outcome", m._waterSaveCut.lastOutcome, "PENDING_ONLY")
  -- FS25 provider fail-closed is NOT tripped by the spy (soil.saveNativeMap is replaced),
  -- so the next caller in the same act retries and lands on the same row.
  local v2 = m:ensureMissionWaterSaveCut("STATELEDGER")
  T.eq("nativeFail.retryDoesNotAdvance", m.saveLoad._completePair.current.generation, 1)
  T.eq("nativeFail.retrySameDigest", v2.pendingOnly.digest, v.pendingOnly.digest)
  soil._nativeAnswer = true
  local v3 = m:ensureMissionWaterSaveCut("CAREER_XML")
  T.eq("nativeFail.recoveryCompletes", v3.complete[1].generation, 2)
  T.eq("nativeFail.pendingSuperseded", v3.pendingOnly, nil)
  T.eq("nativeFail.cutClean", m._waterSaveCut.dirty, false)
end

-- ============================================================
-- C. FULL-VIEW ROUND TRIP through own XML and the manager barrier.
-- ============================================================
local xmlHandle
do
  local soil = truthSoil(7, 20)
  local m = bareManager(soil)
  xmlHandle = {}
  m.saveLoad:saveToXMLFile(xmlHandle)                -- generation 1
  m:markMissionWaterDirty()
  soil.moistureRevision = 8
  soil.fieldData[1].moisture = 0.66
  soil.fieldData[1].mapPending = 0.004
  soil._mapWaterPending[1] = { [5] = 0.003 }
  xmlHandle = {}
  m.saveLoad:saveToXMLFile(xmlHandle)                -- generation 2, previous 1

  T.eq("xml.schema", xmlHandle[ROOT .. ".moisture#schema"], 3)
  T.eq("xml.currentGeneration", xmlHandle[ROOT .. ".moisture.complete(0)#generation"], 2)
  T.eq("xml.previousGeneration", xmlHandle[ROOT .. ".moisture.complete(1)#generation"], 1)
  T.eq("xml.currentFilename", xmlHandle[ROOT .. ".moisture.complete(0)#filename"], "csMoistureMap.s2.grle")
  T.eq("xml.previousFilename", xmlHandle[ROOT .. ".moisture.complete(1)#filename"], "csMoistureMap.s1.grle")
  T.eq("xml.leafAdler", type(xmlHandle[ROOT .. ".moisture.complete(0).absorption#rowsAdler32"]), "string")
  T.eq("xml.leafRowCount", xmlHandle[ROOT .. ".moisture.complete(0).absorption#rowCount"], 1)
  T.eq("xml.legacyRevisionKept", xmlHandle[ROOT .. "#moistureRevision"], 8)
  T.eq("xml.legacyGeneration", xmlHandle[ROOT .. "#saveGeneration"], 2)
  T.eq("xml.fieldRowKept", xmlHandle[ROOT .. ".fields.field(0)#id"] ~= nil, true)

  -- Reload through the manager: candidates from own XML, native probe adopts g2.
  local log = {}
  local soil2 = freshSoil(log)
  local m2 = bareManager(soil2)
  g_currentMission.missionInfo.xmlFile = xmlHandle
  allReady(m2)
  m2:_restoreState().compactReady = false
  m2:loadFromXMLFile()
  g_currentMission.missionInfo.xmlFile = nil
  local r = m2:_restoreState().result
  T.eq("xml.restoreMode", r.mode, "TRUTH")
  T.eq("xml.restoreGeneration", r.generation, 2)
  T.eq("xml.probeOnce", #log, 1)
  T.eq("xml.probeOpensTheRecordedFile", log[1].filename, "csMoistureMap.s2.grle")
  T.eq("xml.probeWidth", log[1].width, 1024)
  T.eq("xml.revision", soil2.moistureRevision, 8)
  T.eq("xml.cursor", soil2._lastSettledDay, 20)
  T.near("xml.aggregateFromEnvelope", soil2.fieldData[1].moisture, 0.66, 1e-12)
  T.near("xml.fieldPendingFromEnvelope", soil2.fieldData[1].mapPending, 0.004, 1e-12)
  T.eq("xml.clearedFieldPending", soil2.fieldData[2].mapPending, 0)
  T.near("xml.positionalFromEnvelope", soil2._mapWaterPending[1][5], 0.003, 1e-12)
  T.eq("xml.pairCurrent", m2.saveLoad._completePair.current.generation, 2)
  T.eq("xml.pairPrevious", m2.saveLoad._completePair.previous.generation, 1)
  T.eq("xml.absorptionRestored", r.absorption, "RESTORED")
  T.eq("xml.absorptionRows", tableCount(soil2:_absorptionState().cells), 1)
  T.eq("xml.providerTruth", soil2.providerMode, "TRUTH")
  T.eq("xml.routesEnabledOnce", m2.sprayerIntegration.calls, 1)
  T.eq("xml.sectorEnabledOnce", m2.irrigatorSectorIntegration.calls, 1)
  T.eq("xml.ready", m2:isMissionWaterReady(), true)
  -- The reloaded view resaves both envelopes unchanged.
  local again = m2.saveLoad:buildMoistureView()
  T.eq("xml.reloadedViewCurrent", again.complete[1].generation, 2)
  T.eq("xml.reloadedViewPrevious", again.complete[2].generation, 1)
end

-- ============================================================
-- D. FULL-VIEW ROUND TRIP through the StateLedger table.
-- ============================================================
local ledgerState
do
  local soil = truthSoil(7, 20)
  local m = bareManager(soil)
  m:ensureMissionWaterSaveCut("PUMP")                -- generation 1
  m:markMissionWaterDirty()
  soil.moistureRevision = 8
  soil.fieldData[1].mapPending = 0.004
  ledgerState = m.saveLoad:buildStateTable()          -- generation 2
  T.eq("ledger.schema", ledgerState.moistureEnvelope.schema, 3)
  T.eq("ledger.twoComplete", #ledgerState.moistureEnvelope.complete, 2)
  T.eq("ledger.leafCarried", ledgerState.moistureEnvelope.complete[1].absorption.rowsAdler32 ~= nil, true)
  T.eq("ledger.deepCopy", ledgerState.moistureEnvelope.complete[1] ~= m.saveLoad._completePair.current.envelope, true)

  local log = {}
  local soil2 = freshSoil(log)
  local m2 = bareManager(soil2)
  m2.saveLoad:applyStateTable(ledgerState)
  local r = m2.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil2:adoptNativeGeneration("sg", env) end,
    currentHour = HOUR,
  })
  T.eq("ledger.restoreMode", r.mode, "TRUTH")
  T.eq("ledger.restoreGeneration", r.generation, 2)
  T.eq("ledger.revision", soil2.moistureRevision, 8)
  T.near("ledger.fieldPending", soil2.fieldData[1].mapPending, 0.004, 1e-12)
  T.near("ledger.positional", soil2._mapWaterPending[1][5], 0.001, 1e-12)
  T.eq("ledger.absorptionRestored", r.absorption, "RESTORED")
  T.eq("ledger.source", r.source, "LEDGER")
end

-- ============================================================
-- E. NATIVE UNAVAILABLE: the newest valid compact degrades on its OWN pending
--    state and the live map is declined, never paired with generation 1's file.
-- ============================================================
do
  local log = { answer = false }
  local soil2 = freshSoil(log)
  local m2 = bareManager(soil2)
  m2.saveLoad:applyStateTable(ledgerState)
  local r = m2.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil2:adoptNativeGeneration("sg", env) end,
    currentHour = HOUR,
  })
  T.eq("degrade.mode", r.mode, "ZONE")
  T.eq("degrade.keepsNewestGeneration", r.generation, 2)
  T.eq("degrade.probedOnlyNewest", #log, 1)
  T.eq("degrade.mapDeclined", soil2.valueMap, nil)
  T.eq("degrade.providerZone", soil2.providerMode, "ZONE")
  T.near("degrade.ownPending", soil2.fieldData[1].mapPending, 0.004, 1e-12)
  T.eq("degrade.ownRevision", soil2.moistureRevision, 8)
  T.eq("degrade.declinedReason", type(r.declined), "string")
  -- The leaf was TRUTH:2; the live provider is now ZONE, so it stands down.
  T.eq("degrade.leafProviderMismatch", r.absorption, "PROVIDER_MISMATCH")
  T.eq("degrade.standDownAtCurrentHour", soil2:_absorptionState().standDownThroughHourKey, HOUR)
end

-- ============================================================
-- F. CORRUPT CANDIDATE: a mirror whose digest does not rebuild is rejected and
--    the next lower valid pair is selected.
-- ============================================================
do
  local handle = {}
  for k, v in pairs(xmlHandle) do handle[k] = v end
  handle[ROOT .. ".moisture.complete(0)#aggregates"] = "1=0.99;2=0.40"
  local log = {}
  local soil2 = freshSoil(log)
  local m2 = bareManager(soil2)
  m2.saveLoad:loadFromXMLFile(handle)
  local r = m2.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil2:adoptNativeGeneration("sg", env) end,
    currentHour = HOUR,
  })
  T.eq("corrupt.fallsToPrevious", r.generation, 1)
  T.eq("corrupt.previousIsTruth", r.mode, "TRUTH")
  T.eq("corrupt.probedGeneration1File", log[1].filename, "csMoistureMap.s1.grle")
  T.eq("corrupt.revisionFromGeneration1", soil2.moistureRevision, 7)
  T.near("corrupt.aggregateFromGeneration1", soil2.fieldData[1].moisture, 0.62, 1e-12)
end

-- ============================================================
-- G. CONFLICTING COMPLETE PAYLOADS for one generation invalidate it.
-- ============================================================
do
  local log = {}
  local soil2 = freshSoil(log)
  local m2 = bareManager(soil2)
  m2.saveLoad:loadFromXMLFile(xmlHandle)              -- XML: gen 2 digest A, gen 1
  -- A self-consistent but DIFFERENT ledger payload claiming generation 2.
  local other = m2.saveLoad:viewToTable({ schema = 3, complete = {
    m2.saveLoad._staged.XML.moistureEnvelope.complete[1],
    m2.saveLoad._staged.XML.moistureEnvelope.complete[2] } })
  other.complete[1].aggregates[1] = 0.11
  other.complete[1].digest = m2.saveLoad:compactDigest(other.complete[1])
  m2.saveLoad:applyStateTable({ fields = {}, moistureEnvelope = other })
  local candidates = m2.saveLoad:collectMoistureCandidates()
  T.eq("conflict.fourCandidates", #candidates, 4)
  local r = m2.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil2:adoptNativeGeneration("sg", env) end,
    currentHour = HOUR,
  })
  T.eq("conflict.generationTwoRejected", r.generation, 1)
  T.eq("conflict.selectsLowerPair", r.mode, "TRUTH")
  T.eq("conflict.neverProbedGenerationTwo", log[1].filename, "csMoistureMap.s1.grle")
end

-- ============================================================
-- H. PENDING_ONLY overlay: applied only against the exact retained identity,
--    replacing only the pending stores; the leaf follows the overlay.
-- ============================================================
do
  local soil = truthSoil(7, 20)
  local m = bareManager(soil)
  local handle = {}
  m.saveLoad:saveToXMLFile(handle)                    -- generation 1 (leaf at HOUR)
  m:markMissionWaterDirty()
  soil._nativeAnswer = false
  soil.moistureRevision = 9                           -- RAM moved on; row binds to 7
  soil.fieldData[1].mapPending = 0.02
  handle = {}
  m.saveLoad:saveToXMLFile(handle)                    -- PENDING_ONLY bound to gen 1
  T.eq("pending.rowWritten", handle[ROOT .. ".moisture.pendingOnly#payloadKind"], "PENDING_ONLY")
  T.eq("pending.baseRevision", handle[ROOT .. ".moisture.pendingOnly#baseRevision"], 7)

  local log = {}
  local soil2 = freshSoil(log)
  local m2 = bareManager(soil2)
  m2.saveLoad:loadFromXMLFile(handle)
  local r = m2.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil2:adoptNativeGeneration("sg", env) end,
    currentHour = HOUR,
  })
  T.eq("pending.truthKept", r.mode, "TRUTH")
  T.eq("pending.generationOne", r.generation, 1)
  T.eq("pending.applied", r.pendingStatus, "APPLIED")
  T.eq("pending.revisionFromPair", soil2.moistureRevision, 7)
  T.near("pending.storesFromOverlay", soil2.fieldData[1].mapPending, 0.02, 1e-12)
  T.eq("pending.rowRetained", m2.saveLoad._pendingOnly ~= nil, true)
  T.eq("pending.leafRestored", r.absorption, "RESTORED")

  -- A row whose base cursor does not match is left unapplied (BASE_MISMATCH).
  local mismatch = {}
  for k, v in pairs(handle) do mismatch[k] = v end
  mismatch[ROOT .. ".moisture.pendingOnly#baseLastSettledMonotonicDay"] = 21
  local soil3 = freshSoil({})
  local m3 = bareManager(soil3)
  m3.saveLoad:loadFromXMLFile(mismatch)
  local r3 = m3.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil3:adoptNativeGeneration("sg", env) end,
    currentHour = HOUR,
  })
  T.eq("pending.mismatchRejectedByDigest", r3.pendingStatus, "NONE")
  T.near("pending.mismatchKeepsPairStores", soil3.fieldData[1].mapPending, 0.002, 1e-12)
end

-- ============================================================
-- I. ABSORPTION LEAF admitted only against the matching provider identity.
-- ============================================================
do
  local soil2 = freshSoil({}, "ZONE")
  local m2 = bareManager(soil2)
  m2.saveLoad:applyStateTable(ledgerState)
  -- The compact-only selection (no probe) keeps the envelope but the mission is
  -- ZONE at 10 m: the TRUTH:2 leaf must not become live capacity.
  local r = m2.saveLoad:restoreMissionWater({ liveMode = "ZONE", liveGrain = 10, currentHour = HOUR })
  T.eq("leaf.identityMismatch", r.absorption, "PROVIDER_MISMATCH")
  T.eq("leaf.noRows", tableCount(soil2:_absorptionState().cells), 0)

  local soil3 = freshSoil({})
  local m3 = bareManager(soil3)
  m3.saveLoad:applyStateTable(ledgerState)
  local r3 = m3.saveLoad:restoreMissionWater({ nativeProbe = function() return true end,
    liveMode = "TRUTH", liveGrain = 2, currentHour = HOUR })
  T.eq("leaf.identityMatch", r3.absorption, "RESTORED")
  T.eq("leaf.rowsLive", tableCount(soil3:_absorptionState().cells), 1)

  -- Same identity, later hour: the saved window expired, no capacity restores.
  local soil4 = freshSoil({})
  local m4 = bareManager(soil4)
  m4.saveLoad:applyStateTable(ledgerState)
  local r4 = m4.saveLoad:restoreMissionWater({ nativeProbe = function() return true end,
    liveMode = "TRUTH", liveGrain = 2, currentHour = HOUR + 1 })
  T.eq("leaf.expiredWindow", r4.absorption, "EXPIRED_WINDOW")
end

-- ============================================================
-- J. LEGACY SCALAR SCHEMA 2 (no envelope) migrates with no absorption allowance.
-- ============================================================
do
  local legacy = {
    [ROOT .. ".fields.field(0)#id"] = 1, [ROOT .. ".fields.field(0)#moisture"] = 0.33,
    [ROOT .. ".fields.field(0)#stress"] = 0.2, [ROOT .. ".fields.field(0)#soilType"] = "clay",
    [ROOT .. ".fields.field(0)#mapPending"] = 0.001,
    [ROOT .. "#moistureRevision"] = 12, [ROOT .. "#lastSettledDay"] = 4,
    [ROOT .. "#saveGeneration"] = 0,
    [ROOT .. "#mapWaterPending"] = "R|1|5|0.002",
  }
  local soil2 = freshSoil({})
  local m2 = bareManager(soil2)
  m2.saveLoad:loadFromXMLFile(legacy)
  local r = m2.saveLoad:restoreMissionWater({ nativeProbe = function() return true end, currentHour = HOUR })
  T.eq("legacy.mode", r.mode, "NONE")
  T.eq("legacy.revision", soil2.moistureRevision, 12)
  T.eq("legacy.cursor", soil2._lastSettledDay, 4)
  T.near("legacy.scalar", soil2.fieldData[1].moisture, 0.33, 1e-12)
  T.eq("legacy.soilType", soil2.fieldData[1].soilType, "clay")
  T.near("legacy.stress", m2.stressModifier.fieldStress[1], 0.2, 1e-12)
  T.near("legacy.positional", soil2._mapWaterPending[1][5], 0.002, 1e-12)
  T.eq("legacy.noAbsorptionAllowance", r.absorption, "EMPTY_ABSORPTION")
  T.eq("legacy.mapKeptAsGenerationZero", soil2.providerMode, "TRUTH")
end

-- ============================================================
-- K. THE BARRIER: runs once, only when every readiness fact is set, in every
--    arrival order; repeated callbacks are idempotent; no field means not applied.
-- ============================================================
do
  local orders = {
    { "settingsLoaded", "fieldsReady", "mapReady", "compactReady", "absorptionFrozen" },
    { "fieldsReady", "mapReady", "settingsLoaded", "absorptionFrozen", "compactReady" },
    { "compactReady", "absorptionFrozen", "settingsLoaded", "fieldsReady", "mapReady" },
    { "mapReady", "compactReady", "fieldsReady", "absorptionFrozen", "settingsLoaded" },
  }
  for oi, order in ipairs(orders) do
    local soil2 = freshSoil({})
    local m2 = bareManager(soil2)
    m2.saveLoad:applyStateTable(ledgerState)
    local restores = 0
    local real = m2.saveLoad.restoreMissionWater
    m2.saveLoad.restoreMissionWater = function(self, ctx) restores = restores + 1; return real(self, ctx) end
    local r = m2:_restoreState()
    for step = 1, #order do
      r[order[step]] = true
      local applied = m2:tryRestoreMissionWater()
      if step < #order then
        T.eq(string.format("barrier.order%d.step%d.waits", oi, step), applied, false)
        T.eq(string.format("barrier.order%d.step%d.notReady", oi, step), m2:isMissionWaterReady(), false)
      else
        T.eq(string.format("barrier.order%d.applies", oi), applied, true)
      end
    end
    T.eq(string.format("barrier.order%d.restoredOnce", oi), restores, 1)
    T.eq(string.format("barrier.order%d.secondCallNoop", oi), m2:tryRestoreMissionWater(), false)
    T.eq(string.format("barrier.order%d.restoredStillOnce", oi), restores, 1)
    T.eq(string.format("barrier.order%d.routesOnce", oi), m2.sprayerIntegration.calls, 1)
    T.eq(string.format("barrier.order%d.sectorOnce", oi), m2.irrigatorSectorIntegration.calls, 1)
    T.eq(string.format("barrier.order%d.ready", oi), m2:isMissionWaterReady(), true)
    T.eq(string.format("barrier.order%d.sameProvider", oi), soil2.providerMode, "TRUTH")
    T.eq(string.format("barrier.order%d.sameGeneration", oi), r.result.generation, 2)
  end

  -- No enumerated field: not counted as applied, routes stay off.
  local empty = SoilMoistureSystem.new({})
  empty.absorptionMode = "CAPPED"
  local m3 = bareManager(empty)
  allReady(m3)
  T.eq("barrier.noFieldNotApplied", m3:tryRestoreMissionWater(), false)
  T.eq("barrier.noFieldFlagOff", m3:_restoreState().applied, false)
  T.eq("barrier.noFieldRoutesOff", m3.sprayerIntegration.calls, 0)

  -- loadFromXMLFile stages once: a second call does not re-read or re-stage.
  local soil4 = freshSoil({})
  local m4 = bareManager(soil4)
  local reads = 0
  local realLoad = m4.saveLoad.loadFromXMLFile
  m4.saveLoad.loadFromXMLFile = function(self, x) reads = reads + 1; return realLoad(self, x) end
  g_currentMission.missionInfo.xmlFile = xmlHandle
  m4:loadFromXMLFile()
  m4:loadFromXMLFile()
  g_currentMission.missionInfo.xmlFile = nil
  T.eq("barrier.compactReadOnce", reads, 1)
  T.eq("barrier.compactReadyFlag", m4:_restoreState().compactReady, true)
end

T.summary()
