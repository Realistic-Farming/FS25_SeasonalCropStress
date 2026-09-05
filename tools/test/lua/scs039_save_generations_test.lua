-- scs039_save_generations_test.lua
-- SCS-039 / GRID-1 (SDS 3.5): the synchronous immutable capture and the
-- two-generation commit/selection state machine. The COMPLETE generation
-- advances only after the native write AND the compact write both succeed; a
-- native failure with a usable compact write records one PENDING_ONLY bound to
-- the base generation; identical mirrors deduplicate, conflicting digests
-- reject a generation, and the highest valid COMPLETE native pair wins.
--
-- This is the engine-free core the file layer will drive (Group D and Group K
-- model the same contract).
--!load: src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua

local function soilAt(revision, cursor)
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy", mapPending = 0.02 }
  soil.moistureRevision = revision
  soil._lastSettledDay = cursor
  soil._mapWaterPending[1] = { [5] = 0.001 }
  return soil
end

local function newHandler(soil)
  return SaveLoadHandler.new({ soilSystem = soil })
end

-- 1. CAPTURE freezes the revision, cursor, aggregates and both pending packs.
do
  local sh = newHandler(soilAt(7, 20))
  local env = sh:captureMoistureEnvelope()
  T.eq("capture.generation", env.generation, 0)
  T.eq("capture.revision", env.moistureRevision, 7)
  T.eq("capture.cursor", env.lastSettledMonotonicDay, 20)
  T.eq("capture.payloadKind", env.payloadKind, "COMPLETE")
  T.near("capture.aggregate", env.aggregates[1], 0.55, 1e-12)
  T.near("capture.fieldPending", env.fieldPending[1], 0.02, 1e-12)
  T.eq("capture.positionalCount", #env.positionalRows, 1)
  T.near("capture.positionalAmount", env.positionalRows[1].amount, 0.001, 1e-12)
  T.ok("capture.hasDigest", env.digest ~= nil)
end

-- 2. COMMIT mirrors Group K: both true advances, native-false + compact-true
--    records a base-bound PENDING_ONLY, any compact failure keeps the pair.
do
  local sh = newHandler(soilAt(7, 20))
  local env = sh:captureMoistureEnvelope()

  T.eq("commit.bothTrueCompletes", sh:commitMoistureEnvelope(env, true, true), "COMPLETE")
  T.eq("commit.generationAdvances", sh._completePair.current.generation, 1)
  T.eq("commit.previousRetained", sh._completePair.previous.generation, 0)
  T.eq("commit.currentDigest", sh._completePair.current.digest, env.digest)
  T.eq("commit.currentRevision", sh._completePair.current.revision, 7)

  local env2 = sh:captureMoistureEnvelope()
  T.eq("commit.captureTracksCurrent", env2.generation, 1)
  T.eq("commit.nativeFailPendingOnly", sh:commitMoistureEnvelope(env2, false, true), "PENDING_ONLY")
  T.eq("commit.pairHeldOnNativeFail", sh._completePair.current.generation, 1)
  local po = sh._pendingOnly
  T.eq("commit.pendingBoundGeneration", po.baseGeneration, 1)
  T.eq("commit.pendingBoundRevision", po.baseRevision, 7)
  T.eq("commit.pendingZoneOk", po.zoneOk, true)
  T.ok("commit.pendingHasDigest", po.digest ~= nil)
  T.near("commit.pendingKeepsFieldWater", po.fieldPending[1], 0.02, 1e-12)

  T.eq("commit.compactFailHoldsPair", sh:commitMoistureEnvelope(env2, true, false), "FAILED")
  T.eq("commit.bothFailHoldsPair", sh:commitMoistureEnvelope(env2, false, false), "FAILED")
  T.eq("commit.generationStillOne", sh._completePair.current.generation, 1)

  T.eq("commit.nextCompleteClearsPending",
    sh:commitMoistureEnvelope(env2, true, true), "COMPLETE")
  T.eq("commit.advancesToTwo", sh._completePair.current.generation, 2)
  T.eq("commit.previousNowOne", sh._completePair.previous.generation, 1)
  T.eq("commit.pendingSuperseded", sh._pendingOnly, nil)
end

-- 3. SELECTION mirrors Group D: dedupe, conflict fallback, ZONE degrade and
--    exact PENDING_ONLY binding.
local function completeRow(gen, digest, nativeOk, revision, cursor)
  return { payloadKind = "COMPLETE", generation = gen, digest = digest,
           compactOk = true, nativeOk = nativeOk, revision = revision,
           lastSettledMonotonicDay = cursor }
end
local function pendingRow(baseGen, digest, baseRev, baseCursor)
  return { payloadKind = "PENDING_ONLY", baseGeneration = baseGen, digest = digest,
           compactOk = true, zoneOk = true, baseRevision = baseRev,
           baseLastSettledMonotonicDay = baseCursor }
end

do
  local sh = newHandler(soilAt(7, 20))
  local mode, gen, digest = sh:selectMoistureCarrier({
    completeRow(6, "sixA", true, 60, 20),
    completeRow(6, "sixB", true, 60, 20),
    completeRow(5, "five", true, 50, 17),
  })
  T.eq("select.conflictFallsToNext", mode, "TRUTH")
  T.eq("select.conflictGeneration", gen, 5)

  mode, gen, digest = sh:selectMoistureCarrier({
    completeRow(6, "six", true, 60, 20),
    completeRow(6, "six", true, 60, 20),
  })
  T.eq("select.identicalMirrorsDedupe", mode, "TRUTH")
  T.eq("select.dedupeGeneration", gen, 6)
  T.eq("select.dedupeDigest", digest, "six")

  mode, gen, digest = sh:selectMoistureCarrier({
    completeRow(6, "six", false, 60, 20),
    completeRow(5, "five", true, 50, 17),
  })
  T.eq("select.newestCompactDegrades", mode, "ZONE")
  T.eq("select.zoneKeepsOwnGeneration", gen, 6)
  T.eq("select.zoneKeepsOwnDigest", digest, "six")

  local pendingDigest, pendingStatus
  mode, gen, digest, pendingDigest, pendingStatus = sh:selectMoistureCarrier({
    completeRow(6, "six", true, 60, 20),
    pendingRow(6, "p6", 60, 20),
    pendingRow(6, "p6", 60, 20),
  })
  T.eq("select.pendingBindKeepsTruth", mode, "TRUTH")
  T.eq("select.pendingBindGeneration", gen, 6)
  T.eq("select.identicalPendingDedupe", pendingDigest, "p6")
  T.eq("select.pendingApplied", pendingStatus, "APPLIED")

  mode, gen, digest, pendingDigest, pendingStatus = sh:selectMoistureCarrier({
    completeRow(6, "six", true, 60, 20),
    pendingRow(6, "p6-wrong", 60, 21),
  })
  T.eq("select.wrongCursorKeepsCarrier", mode, "TRUTH")
  T.eq("select.wrongCursorRejected", pendingStatus, "BASE_MISMATCH")

  mode, gen, digest, pendingDigest, pendingStatus = sh:selectMoistureCarrier({
    pendingRow(7, "p7", 70, 14),
  })
  T.eq("select.zoneRecoveryOnly", mode, "ZONE")
  T.eq("select.recoveryGeneration", gen, 7)
  T.eq("select.recoveryDigest", pendingDigest, "p7")
  T.eq("select.recoveryApplied", pendingStatus, "APPLIED")

  mode = sh:selectMoistureCarrier({})
  T.eq("select.none", mode, "NONE")
end

T.summary()
