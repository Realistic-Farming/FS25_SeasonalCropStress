-- scs041_envelope_leaf_test.lua
-- SCS-041 §8 / slice 9b: the absorption leaf nests in the real SCS-039 provider
-- envelope core (SaveLoadHandler.captureMoistureEnvelope / commitMoistureEnvelope
-- / selectedAbsorptionLeaf). Group M's M14-M20 replace-not-add rule is mirrored
-- against the real envelope vocabulary: a PENDING_ONLY recovery row may replace
-- the COMPLETE envelope's leaf only when its base identity (generation, revision,
-- cursor) matches the capture exactly, and the compact digest binds the leaf so
-- identical mirrors dedupe and a drifted leaf changes the digest.
--
-- The engine-free core is what exists today: selectMoistureCarrier has no live
-- file-layer caller, so this test drives capture/commit/select the same way
-- scs039_save_generations_test does. The on-disk carrier that reads a leaf back
-- into loadAbsorptionWindow is the SDS §8 file-layer remainder.
--!load: src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua

local function absorptionLeafFor(soil)
  local handler = SaveLoadHandler.new({ soilSystem = soil })
  return handler:captureMoistureEnvelope()
end

local acceptAll = function(_span, total) return total end

local function normalArgs(over)
  local a = {
    requestPerWindow = 0.015, windowEnd = 50, windowCount = 1,
    soilFactor = 1.0, fieldId = 1,
    providerMode = "TRUTH", providerGrain = 2,
    cellKey = "TRUTH:2:10:20",
    providerCenterX = -2101, providerCenterZ = -2087,
    cellX = 10, cellZ = 20,
    rawWrite = function() return true end,
    compactionReader = function() return nil end,
    acceptFn = nil,
  }
  if over then for k, v in pairs(over) do a[k] = v end end
  return a
end

local function apply(s, over)
  return s:_applyAbsorptionSpan(normalArgs(over or {}))
end

-- A real CAPPED ledger with one accepted capacity row on the carried window.
local function cappedSoilWithRow()
  local s = SoilMoistureSystem.new({})
  s.absorptionMode = "CAPPED"
  s.agronomyRestriction = 1.0
  s.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy" }
  s.moistureRevision = 7
  s._lastSettledDay = 20
  apply(s, { requestPerWindow = 0.015, acceptFn = acceptAll })
  return s
end

-- 1. CAPTURE nests the absorption leaf only for a CAPPED ledger that carries
--    state; an empty CAPPED ledger and an UNCAPPED ledger stay leaf-less.
do
  local soil = cappedSoilWithRow()
  local env = absorptionLeafFor(soil)
  T.eq("E1 CAPPED capture carries the absorption leaf schema", env.absorption.schema, 2)
  T.eq("E2 CAPPED capture carries the carried window id", env.absorption.windowId, 50)
  T.ok("E3 CAPPED capture packs its capacity rows", env.absorption.rowCount > 0)
  T.ok("E4 leaf bytes ride under a valid Adler", env.absorption.rowsAdler32 ~= nil)
  T.ok("E5 envelope digest is present", env.digest ~= nil)

  local empty = SoilMoistureSystem.new({})
  empty.absorptionMode = "CAPPED"
  empty.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy" }
  local emptyEnv = absorptionLeafFor(empty)
  T.eq("E6 empty CAPPED ledger nests no leaf", emptyEnv.absorption, nil)

  local uncapped = SoilMoistureSystem.new({})
  uncapped.absorptionMode = "UNCAPPED"
  uncapped.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy" }
  apply(uncapped, { requestPerWindow = 0.015, acceptFn = acceptAll })
  local uncappedEnv = absorptionLeafFor(uncapped)
  T.eq("E7 UNCAPPED ledger never nests a leaf", uncappedEnv.absorption, nil)

  local preFeature = SoilMoistureSystem.new({})
  preFeature.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy" }
  local preEnv = absorptionLeafFor(preFeature)
  T.eq("E8 pre-absorption envelope stays leaf-less", preEnv.absorption, nil)
end

-- 2. The digest binds the leaf: two identical captures dedupe, a drifted row
--    changes the digest, and a leaf-less capture is unchanged by the nesting.
do
  local a = cappedSoilWithRow()
  local b = cappedSoilWithRow()
  local envA = absorptionLeafFor(a)
  local envB = absorptionLeafFor(b)
  T.eq("E9 identical CAPPED captures produce one digest", envA.digest, envB.digest)

  b._absorption.cells["TRUTH:2:10:20"].used = b._absorption.cells["TRUTH:2:10:20"].used + 0.002
  local envDrift = absorptionLeafFor(b)
  T.ok("E10 a drifted absorption row changes the envelope digest",
    envDrift.digest ~= envA.digest)

  local plain = SoilMoistureSystem.new({})
  plain.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy" }
  local plainEnv = absorptionLeafFor(plain)
  local plain2 = SoilMoistureSystem.new({})
  plain2.fieldData[1] = { fieldId = 1, moisture = 0.55, soilType = "loamy" }
  local plainEnv2 = absorptionLeafFor(plain2)
  T.eq("E11 leaf-less captures still dedupe", plainEnv.digest, plainEnv2.digest)
end

-- 3. COMMIT carries the leaf: a PENDING_ONLY recovery row keeps the captured
--    leaf bound to the retained pair identity; a COMPLETE advances and clears it.
do
  local soil = cappedSoilWithRow()
  local handler = SaveLoadHandler.new({ soilSystem = soil })
  local capture = handler:captureMoistureEnvelope()
  T.eq("E12 complete advance carries the envelope", handler:commitMoistureEnvelope(capture, true, true), "COMPLETE")
  T.eq("E13 complete advance clears any pending leaf", handler._pendingOnly, nil)

  local capture2 = handler:captureMoistureEnvelope()
  T.eq("E14 native failure records PENDING_ONLY", handler:commitMoistureEnvelope(capture2, false, true), "PENDING_ONLY")
  local pending = handler._pendingOnly
  T.eq("E15 pending row is bound to the retained generation", pending.baseGeneration, 1)
  T.eq("E16 pending row is bound to the retained revision", pending.baseRevision, 7)
  T.eq("E17 pending row is bound to the retained cursor", pending.baseLastSettledMonotonicDay, 20)
  T.eq("E18 pending row keeps the captured absorption leaf", pending.absorption, capture2.absorption)
  T.ok("E19 pending leaf still carries its window", pending.absorption.windowId, 50)
end

-- 4. selectedAbsorptionLeaf mirrors Group M replace-not-add (M14-M20) against
--    the real base-identity vocabulary.
do
  local handler = SaveLoadHandler.new({ soilSystem = SoilMoistureSystem.new({}) })
  local complete = {
    payloadKind = "COMPLETE", generation = 4,
    moistureRevision = 19, lastSettledMonotonicDay = 91,
    absorption = { schema = 2, windowId = 50 },
  }
  local matchingPending = {
    payloadKind = "PENDING_ONLY",
    baseGeneration = 4, baseRevision = 19, baseLastSettledMonotonicDay = 91,
    absorption = { schema = 2, windowId = 51 },
  }
  T.eq("M15 matching PENDING_ONLY may replace the absorption leaf",
    handler:selectedAbsorptionLeaf(complete, matchingPending).windowId, 51)

  local wrongGeneration = {}
  for k, v in pairs(matchingPending) do wrongGeneration[k] = v end
  wrongGeneration.baseGeneration = 5
  wrongGeneration.absorption = { schema = 2, windowId = 99 }
  T.eq("M16 mismatched pending identity cannot replace absorption",
    handler:selectedAbsorptionLeaf(complete, wrongGeneration).windowId, 50)

  local wrongRevision = {}
  for k, v in pairs(matchingPending) do wrongRevision[k] = v end
  wrongRevision.baseRevision = 20
  wrongRevision.absorption = { schema = 2, windowId = 99 }
  T.eq("M17 mismatched moisture revision cannot replace absorption",
    handler:selectedAbsorptionLeaf(complete, wrongRevision).windowId, 50)

  local wrongDay = {}
  for k, v in pairs(matchingPending) do wrongDay[k] = v end
  wrongDay.baseLastSettledMonotonicDay = 92
  wrongDay.absorption = { schema = 2, windowId = 99 }
  T.eq("M19 mismatched committed day cannot replace absorption",
    handler:selectedAbsorptionLeaf(complete, wrongDay).windowId, 50)

  local noLeaf = { payloadKind = "COMPLETE", generation = 1 }
  T.eq("M20 absent absorption leaf means no prior absorption state",
    handler:selectedAbsorptionLeaf(noLeaf, nil), nil)
  T.eq("M20a absent complete with no pending restores no leaf",
    handler:selectedAbsorptionLeaf(nil, nil), nil)
  T.eq("M20b pending without a leaf leaves the complete leaf in charge",
    handler:selectedAbsorptionLeaf(complete, { payloadKind = "PENDING_ONLY",
      baseGeneration = 4, baseRevision = 19, baseLastSettledMonotonicDay = 91 }).windowId, 50)
end

T.summary()
