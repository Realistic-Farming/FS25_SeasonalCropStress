-- scs041_capacity_ledger_test.lua
-- SCS-041 §6: the hourly capacity ledger, driven on real source. Mirrors the
-- spec bar's Groups C (capacityPerHour), E (planSpan) and D/F/G
-- (_applyAbsorptionSpan) against the shipped functions, so the port is proven
-- against the same contract numbers the pure model asserts.
--!load: src/SoilMoistureSystem.lua

local function cappedSys(restriction)
  local s = SoilMoistureSystem.new({})
  s.absorptionMode = "CAPPED"
  s.agronomyRestriction = restriction or 1.0
  return s
end

local function normalArgs(overrides)
  local args = {
    requestPerWindow = 0.015, windowEnd = 50, windowCount = 1,
    providerMode = "TRUTH", providerGrain = 2, cellKey = "TRUTH:2:10:20",
    fieldId = 1, cellX = 10, cellZ = 20,
    providerCenterX = -2037, providerCenterZ = -2017,
    executionGrain = 2, soilFactor = 1.0, compaction = 0, compactionGrain = 2,
    rawWrite = function() return true end,
  }
  for k, v in pairs(overrides or {}) do args[k] = v end
  return args
end

-- GROUP C: capacityPerHour (fixed base, soil, compaction, restriction).
do
  local CH = SoilMoistureSystem.capacityPerHour
  T.near("C4 base", SoilMoistureSystem.BASE_INFILTRATION_PER_HOUR, 0.018, 1e-12)
  T.near("C5 open sandy raises capacity", CH(1.25, 0, 2, 1.0), 0.0225, 1e-12)
  T.near("C6 half-compacted clay linear", CH(0.72, 50, 2, 1.0), 0.00648, 1e-12)
  T.near("C7 full compaction zero", CH(1.00, 100, 2, 1.0), 0, 1e-12)
  T.near("C8 nil grain neutral not field fallback", CH(0.72, 90, nil, 1.0), 0.01296, 1e-12)
  T.near("C9 relaxed divides", CH(1.00, 0, 2, 0.7), 0.018 / 0.7, 1e-12)
  T.near("C10 standard identity", CH(1.00, 0, 2, 1.0), 0.018, 1e-12)
  T.near("C11 punishing divides", CH(1.00, 0, 2, 1.4), 0.018 / 1.4, 1e-12)
  local inv, reason = CH(1.00, 0, 2, 0)
  T.eq("C12 invalid restriction refuses", inv, nil)
  T.eq("C13 invalid restriction names refusal", reason, "INVALID_RESTRICTION")
end

-- GROUP E: absorptionPlanSpan (catch-up span, carried exception, three-span cap).
do
  local PS = SoilMoistureSystem.absorptionPlanSpan
  local plan = PS(0.03, 0.02, 12, 5, 10, 0.015, 0.02)
  T.eq("E1 five-hour span starts at derived hour", plan.firstWindowId, 8)
  T.near("E2 keeps every requested gain", plan.totalRequested, 0.15, 1e-12)
  T.near("E3 carried hour subtracts used capacity", plan.totalAbsorbed, 0.085, 1e-12)
  T.near("E4 remaining becomes candidate", plan.totalCandidate, 0.065, 1e-12)
  T.eq("E5 at most three compact spans", #plan.spans, 3)
  T.eq("E6 first uniform span", plan.spans[1].firstWindowId, 8)
  T.eq("E7 carried exception isolated", plan.spans[2].firstWindowId, 10)
  T.eq("E8 trailing uniform span count", plan.spans[3].windowCount, 2)
  local none = PS(0.03, 0.02, 12, 5, nil, 0, nil)
  T.eq("E9 no exception one span", #none.spans, 1)
  T.near("E10 five capacity allowances", none.totalAbsorbed, 0.10, 1e-12)
end

-- GROUP D: shared cell/hour capacity and caller order.
do
  local s = cappedSys(1.0)
  local acceptAll = function(_span, total) return total end
  local first = s:_applyAbsorptionSpan(normalArgs({ acceptFn = acceptAll }))
  local second = s:_applyAbsorptionSpan(normalArgs({ acceptFn = acceptAll }))
  T.near("D1 first below capacity local", first.localWriteRequest, 0.015, 1e-12)
  T.near("D2 second only remaining capacity local", second.localWriteRequest, 0.003, 1e-12)
  T.near("D3 shared cell-hour allowance", s._absorption.cells["TRUTH:2:10:20"].used, 0.018, 1e-12)
  T.near("D4 second exposes excess candidate", second.candidateSurplus, 0.012, 1e-12)

  local reverse = cappedSys(1.0)
  local big = reverse:_applyAbsorptionSpan(normalArgs({ requestPerWindow = 0.02, acceptFn = acceptAll }))
  local small = reverse:_applyAbsorptionSpan(normalArgs({ requestPerWindow = 0.01, acceptFn = acceptAll }))
  T.near("D6 reversed order keeps total local", big.localWriteRequest + small.localWriteRequest, 0.018, 1e-12)
  T.near("D7 reversed order keeps total candidate", big.candidateSurplus + small.candidateSurplus, 0.012, 1e-12)

  local nextHour = s:_applyAbsorptionSpan(normalArgs({ windowEnd = 51, acceptFn = acceptAll }))
  T.near("D8 a new hour gets a fresh allowance", nextHour.localWriteRequest, 0.015, 1e-12)

  local reads, sampledX, sampledZ = 0, nil, nil
  local centred = cappedSys(1.0)
  local reader = function(x, z) reads = reads + 1; sampledX, sampledZ = x, z; return 50, 2 end
  centred:_applyAbsorptionSpan(normalArgs({ compactionReader = reader }))
  centred:_applyAbsorptionSpan(normalArgs({ compactionReader = reader }))
  T.eq("D9 compaction read once per cell-hour", reads, 1)
  T.near("D10 compaction samples provider-cell centre X", sampledX, -2037, 1e-12)
  T.near("D11 compaction samples provider-cell centre Z", sampledZ, -2017, 1e-12)

  local refused = cappedSys(1.0)
  local rawCalls = 0
  refused:_applyAbsorptionSpan(normalArgs({ rawWrite = function() rawCalls = rawCalls + 1; return false end }))
  T.eq("D12 a refused raw write still attempts the one raw door", rawCalls, 1)
  T.near("D13 a refused raw write consumes no capacity",
    refused._absorption.cells["TRUTH:2:10:20"].used, 0, 1e-12)
end

-- GROUP F: surplus acceptance and routing conservation.
do
  local partial = cappedSys(1.0):_applyAbsorptionSpan(normalArgs({
    requestPerWindow = 0.03,
    acceptFn = function(_span, total) return total * 0.5 end,
  }))
  T.near("F1 active cap creates candidate surplus", partial.candidateSurplus, 0.012, 1e-12)
  T.near("F2 sibling accepts part of candidate", partial.acceptedSurplus, 0.006, 1e-12)
  T.near("F3 unaccepted candidate folds local", partial.localWriteRequest, 0.024, 1e-12)
  T.near("F4 routing conserves requested gain",
    partial.localWriteRequest + partial.acceptedSurplus, partial.requestedGain, 1e-12)

  local noSibling = cappedSys(1.0):_applyAbsorptionSpan(normalArgs({ requestPerWindow = 0.03 }))
  T.eq("F5 absent sibling accepts zero", noSibling.acceptedSurplus, 0)
  T.near("F6 absent sibling keeps full local", noSibling.localWriteRequest, 0.03, 1e-12)

  local bad = cappedSys(1.0):_applyAbsorptionSpan(normalArgs({
    requestPerWindow = 0.03, acceptFn = function(_s, total) return total + 1 end }))
  T.eq("F7 over-accepting sibling rejected", bad.acceptedSurplus, 0)
  T.near("F8 rejected sibling folds local", bad.localWriteRequest, 0.03, 1e-12)

  local thrown = cappedSys(1.0):_applyAbsorptionSpan(normalArgs({
    requestPerWindow = 0.03, acceptFn = function() error("sibling failed") end }))
  T.eq("F9 throwing sibling accepts zero via pcall", thrown.acceptedSurplus, 0)
  T.near("F10 throwing sibling folds remainder local", thrown.localWriteRequest, 0.03, 1e-12)

  local runoffOnly = cappedSys(1.0)
  runoffOnly:_applyAbsorptionSpan(normalArgs({
    requestPerWindow = 0.03, rawWrite = function() return false end,
    acceptFn = function(_s, total) return total end }))
  T.near("F11 accepted runoff spends no refused local capacity",
    runoffOnly._absorption.cells["TRUTH:2:10:20"].used, 0, 1e-12)
end

-- GROUP G: provider failure and grain change are neutral.
do
  local missing = cappedSys(1.0)
  local mArgs = normalArgs(); mArgs.providerMode = nil
  local r = missing:_applyAbsorptionSpan(mArgs)
  T.near("G1 missing provider keeps full local", r.localWriteRequest, 0.015, 1e-12)
  T.eq("G2 missing provider no candidate", r.candidateSurplus, 0)
  T.eq("G3 missing provider neutral reason", r.neutralReason, "PROVIDER_UNAVAILABLE")

  local changed = cappedSys(1.0)
  changed:_applyAbsorptionSpan(normalArgs())
  r = changed:_applyAbsorptionSpan(normalArgs({ providerMode = "ZONE", providerGrain = 10 }))
  T.near("G4 mid-window provider change keeps full local", r.localWriteRequest, 0.015, 1e-12)
  T.eq("G5 mid-window provider change no guessed surplus", r.candidateSurplus, 0)
  T.eq("G6 mid-window provider change diagnosed", r.neutralReason, "PROVIDER_CHANGED")
  T.eq("G7 mismatch uses the unified stand-down hour", changed._absorption.standDownThroughHourKey, 50)
  r = changed:_applyAbsorptionSpan(normalArgs())
  T.eq("G8 original provider cannot reopen the stood-down hour", r.neutralReason, "RESTORE_STAND_DOWN")
  r = changed:_applyAbsorptionSpan(normalArgs({ windowEnd = 51 }))
  T.eq("G9 next valid hour clears provider stand-down", r.neutralReason, nil)

  local mixed = cappedSys(1.0)
  mixed:_applyAbsorptionSpan(normalArgs())
  mixed:_applyAbsorptionSpan(normalArgs({ providerMode = "ZONE", providerGrain = 10 }))
  r = mixed:_applyAbsorptionSpan(normalArgs({ windowEnd = 52, windowCount = 3,
    providerMode = "ZONE", providerGrain = 10 }))
  T.eq("G10 provider marker uses the mixed-span split", r.neutralReason, "RESTORE_SPLIT")
  T.near("G11 provider-marker split conserves routing",
    r.localWriteRequest + r.acceptedSurplus, r.requestedGain, 1e-12)
end
