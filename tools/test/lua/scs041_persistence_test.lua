-- scs041_persistence_test.lua
-- SCS-041 §8: schema-3 sparse absorption persistence. A faithful mirror of the
-- spec bar's Group I, driven against the REAL capacity ledger (_applyAbsorptionSpan)
-- and the real pack/load methods (packAbsorptionWindow / loadAbsorptionWindow /
-- pruneAbsorptionMissingFields). Only the one carried current-hour window is
-- persisted; old windows expire, corrupt/foreign leaves stand down, markers
-- persist and normalize, and reload replaces rather than adds.
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/SoilMoistureSystem.lua

local acceptAll = function(_span, total) return total end

local function newSys(mode, restriction)
  local s = SoilMoistureSystem.new({})
  s.absorptionMode = mode
  s.agronomyRestriction = restriction or 1.0
  return s
end

-- Defaults produce a TRUTH:2:10:20 cell whose one-hour budget is exactly BASE
-- (loamy soilFactor 1.0, neutral compaction, restriction 1.0). The raw door
-- accepts and the compaction reader is neutral.
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

local function apply(s, over) return s:_applyAbsorptionSpan(normalArgs(over)) end

local function tableCount(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local function adler(bytes)
  -- mirror of the source's private adler, for the empty-bytes assertions
  local a, b = 1, 0
  for i = 1, #bytes do a = (a + string.byte(bytes, i)) % 65521; b = (b + a) % 65521 end
  return string.format("%08X", b * 65536 + a)
end

-- Build the canonical block once and reuse across the sub-cases.
local state = newSys("CAPPED", 1.0)
apply(state, { requestPerWindow = 0.015, acceptFn = acceptAll })
apply(state, {
  cellKey = "TRUTH:2:3:7", cellX = 3, cellZ = 7,
  providerCenterX = -2041, providerCenterZ = -2023,
  requestPerWindow = 0.005, acceptFn = acceptAll,
})
local block = state:packAbsorptionWindow()

T.eq("I1 outer StateLedger schema is three", block.outerSchema, 3)
T.eq("I2 absorption schema is two", block.schema, 2)
T.eq("I3 block carries provider mode", block.providerMode, "TRUTH")
T.eq("I4 block carries provider grain", block.providerGrainMetres, 2)
T.eq("I5 sparse state packs touched cells only", block.rowCount, 2)
T.ok("I6 rows are numerically sorted", string.find(block.rowsPacked, "1,3,7", 1, true) == 1)
T.eq("I7 Adler-32 covers exact packed bytes", block.rowsAdler32, adler(block.rowsPacked))
T.eq("I7a ordinary live window carries no stand-down marker", block.standDownThroughHourKey, nil)
T.eq("I7b ordinary live window carries no awaiting-hour flag", block.standDownAwaitingFirstValidHour, false)

do
  local restored = newSys("CAPPED", 1.0)
  local ok, reason = restored:loadAbsorptionWindow(block, "TRUTH", 2, 50)
  T.ok("I8 same-hour block restores", ok)
  T.eq("I9 restore disposition is exact", reason, "RESTORED")
  local resumed = apply(restored, { requestPerWindow = 0.015, acceptFn = acceptAll })
  T.near("I10 same-hour restore preserves remaining capacity", resumed.localWriteRequest, 0.003, 1e-12)
  T.near("I11 same-hour restore exposes already-used excess", resumed.candidateSurplus, 0.012, 1e-12)
  T.near("I12 restored cell reaches but does not exceed capacity",
    restored._absorption.cells["TRUTH:2:10:20"].used, 0.018, 1e-12)

  ok = restored:loadAbsorptionWindow(block, "TRUTH", 2, 50)
  T.ok("I13 second load is accepted", ok)
  T.eq("I14 second load replaces rather than adds rows", tableCount(restored._absorption.cells), 2)
  T.near("I15 second load does not double used gain",
    restored._absorption.cells["TRUTH:2:10:20"].used, 0.015, 1e-12)
end

local mismatch = newSys("CAPPED", 1.0)
do
  local ok, reason = mismatch:loadAbsorptionWindow(block, "ZONE", 10, 50)
  T.ok("I16 provider mismatch rejects saved rows", not ok)
  T.eq("I17 provider mismatch names its reason", reason, "PROVIDER_MISMATCH")
  T.eq("I18 provider mismatch restores no partial rows", tableCount(mismatch._absorption.cells), 0)
  T.eq("I19 provider mismatch uses the unified hour marker", mismatch._absorption.standDownThroughHourKey, 50)
  T.eq("I19a provider mismatch keeps its diagnostic reason", mismatch._absorption.standDownReason, "PROVIDER_MISMATCH")
end

do
  local badCount = {}; for k, v in pairs(block) do badCount[k] = v end
  badCount.rowCount = block.rowCount + 1
  local malformed = newSys("CAPPED", 1.0)
  local ok = malformed:loadAbsorptionWindow(badCount, "TRUTH", 2, 50)
  T.ok("I20 row-count mismatch rejects the whole block", not ok)
  T.eq("I21 row-count mismatch restores no partial rows", tableCount(malformed._absorption.cells), 0)

  local badHash = {}; for k, v in pairs(block) do badHash[k] = v end
  badHash.rowsAdler32 = "00000000"
  ok = malformed:loadAbsorptionWindow(badHash, "TRUTH", 2, 50)
  T.ok("I22 Adler mismatch rejects the whole block", not ok)
  T.eq("I23 Adler mismatch restores no partial rows", tableCount(malformed._absorption.cells), 0)
end

do
  local schema2 = newSys("CAPPED", 1.0)
  local ok, reason = schema2:loadAbsorptionWindow({ outerSchema = 2 }, "TRUTH", 2, 50)
  T.ok("I24 schema-two save migrates without invented absorption", ok)
  T.eq("I25 schema-two migration leaves the ledger empty", tableCount(schema2._absorption.cells), 0)
  T.eq("I26 schema-two migration is named", reason, "MIGRATED_SCHEMA_2")

  local uncapped = newSys("UNCAPPED", 1.0)
  ok, reason = uncapped:loadAbsorptionWindow(block, "TRUTH", 2, 50)
  T.ok("I27 uncapped mission accepts the save without restoring absorption", ok)
  T.eq("I28 uncapped mission names the ignored absorption block", reason, "UNCAPPED_IGNORED")
  T.eq("I29 uncapped mission restores no absorption rows", tableCount(uncapped._absorption.cells), 0)
end

local markerBlock = mismatch:packAbsorptionWindow()
T.eq("I30 marker-only save retains absorption schema two", markerBlock.schema, 2)
T.eq("I31 marker-only save persists the unified hour", markerBlock.standDownThroughHourKey, 50)
T.eq("I32 marker-only save persists its reason", markerBlock.standDownReason, "PROVIDER_MISMATCH")
T.eq("I33 marker-only save carries zero capacity rows", markerBlock.rowCount, 0)
T.eq("I34 marker-only empty bytes keep a valid Adler", markerBlock.rowsAdler32, adler(""))

do
  local markerReload = newSys("CAPPED", 1.0)
  local ok, reason = markerReload:loadAbsorptionWindow(markerBlock, "ZONE", 10, 50)
  T.ok("I35 marker-only block reloads", ok)
  T.eq("I36 marker-only reload names stand-down", reason, "RESTORED_STAND_DOWN")
  T.eq("I37 marker-only reload restores the same hour", markerReload._absorption.standDownThroughHourKey, 50)
  T.eq("I38 marker-only reload restores no capacity rows", tableCount(markerReload._absorption.cells), 0)
  local sameHour = apply(markerReload, { windowEnd = 50 })
  T.eq("I39 reloaded marker keeps the saved hour neutral", sameHour.neutralReason, "RESTORE_STAND_DOWN")
  local nextHour = apply(markerReload, { windowEnd = 51 })
  T.eq("I40 newer hour clears the reloaded marker", markerReload._absorption.standDownThroughHourKey, nil)
  T.eq("I41 newer hour returns to controlled work", nextHour.neutralReason, nil)
end

do
  local awaitingState = newSys("CAPPED", 1.0)
  awaitingState:_absorptionState().standDownAwaitingFirstValidHour = true
  awaitingState:_absorptionState().standDownReason = "CORRUPT_STATE"
  local awaitingBlock = awaitingState:packAbsorptionWindow()
  local awaitingReload = newSys("CAPPED", 1.0)
  local ok = awaitingReload:loadAbsorptionWindow(awaitingBlock, "TRUTH", 2, 50)
  T.ok("I42 awaiting-hour marker reloads", ok)
  T.ok("I43 awaiting-hour flag survives save and reload",
    awaitingReload._absorption.standDownAwaitingFirstValidHour)
end

do
  local schema1 = {}; for k, v in pairs(block) do schema1[k] = v end
  schema1.schema = 1
  schema1.standDownThroughHourKey = nil
  schema1.standDownAwaitingFirstValidHour = nil
  schema1.standDownReason = nil
  local schema1Reload = newSys("CAPPED", 1.0)
  local ok = schema1Reload:loadAbsorptionWindow(schema1, "TRUTH", 2, 50)
  T.ok("I44 absorption schema one migrates its rows", ok)
  T.eq("I45 schema-one migration restores no marker", schema1Reload._absorption.standDownThroughHourKey, nil)
end

-- Live provider change within one window: old rows plus a unified marker.
local mixedBlock
do
  local markerWithRows = newSys("CAPPED", 1.0)
  apply(markerWithRows, {})
  -- Same cell, a changed provider within the window -> provider-change stand-down
  -- (the old capacity row stays; a unified marker is planted).
  apply(markerWithRows, { providerMode = "ZONE", providerGrain = 10 })
  mixedBlock = markerWithRows:packAbsorptionWindow()
  T.ok("I46 live provider-change save contains old capacity rows", mixedBlock.rowCount > 0)
  T.eq("I47 live provider-change save contains the unified marker", mixedBlock.standDownThroughHourKey, 50)
  local mixedReload = newSys("CAPPED", 1.0)
  local ok, reason = mixedReload:loadAbsorptionWindow(mixedBlock, "ZONE", 10, 50)
  T.ok("I48 marker-plus-rows block reloads", ok)
  T.eq("I49 marker-plus-rows load restores stand-down first", reason, "RESTORED_STAND_DOWN")
  T.eq("I50 marker-plus-rows load preserves the saved hour", mixedReload._absorption.standDownThroughHourKey, 50)
  T.eq("I51 marker-plus-rows load discards every capacity row", tableCount(mixedReload._absorption.cells), 0)
end

do
  local changed = {}; for k, v in pairs(mixedBlock) do changed[k] = v end
  changed.providerMode = "TRUTH"; changed.providerGrainMetres = 2
  local reload = newSys("CAPPED", 1.0)
  local ok = reload:loadAbsorptionWindow(changed, "ZONE", 10, 50)
  T.ok("I52 persisted marker wins before provider mismatch validation", ok)
  T.eq("I53 provider mismatch cannot rewrite the saved marker", reload._absorption.standDownThroughHourKey, 50)
  T.eq("I54 provider mismatch marker load restores no rows", tableCount(reload._absorption.cells), 0)

  local uncappedMarker = newSys("UNCAPPED", 1.0)
  local reason2
  ok, reason2 = uncappedMarker:loadAbsorptionWindow(mixedBlock, "ZONE", 10, 50)
  T.ok("I55 uncapped mission accepts marker-plus-rows block", ok)
  T.eq("I56 uncapped ignore runs before marker restoration", reason2, "UNCAPPED_IGNORED")
  T.eq("I57 uncapped marker load restores no hour", uncappedMarker._absorption.standDownThroughHourKey, nil)
  T.eq("I58 uncapped marker load restores no rows", tableCount(uncappedMarker._absorption.cells), 0)
end

do
  local futureWindow = {}; for k, v in pairs(block) do futureWindow[k] = v end
  futureWindow.windowId = 60
  local reload = newSys("CAPPED", 1.0)
  local ok, reason = reload:loadAbsorptionWindow(futureWindow, "TRUTH", 2, 50)
  T.ok("I59 future ordinary window is rejected", not ok)
  T.eq("I60 future ordinary window names its rejection", reason, "FUTURE_WINDOW")
  T.eq("I61 future ordinary window normalizes to the current valid hour",
    reload._absorption.standDownThroughHourKey, 50)
  T.eq("I62 future ordinary window becomes corrupt-state stand-down",
    reload._absorption.standDownReason, "CORRUPT_STATE")
end

local futureMarkerBlock
do
  futureMarkerBlock = {}; for k, v in pairs(markerBlock) do futureMarkerBlock[k] = v end
  futureMarkerBlock.standDownThroughHourKey = 60
  futureMarkerBlock.standDownReason = "PROVIDER_MISMATCH"
  local reload = newSys("CAPPED", 1.0)
  local ok = reload:loadAbsorptionWindow(futureMarkerBlock, "ZONE", 10, 50)
  T.ok("I63 future persisted marker reloads as conservative stand-down", ok)
  T.eq("I64 future persisted marker normalizes to current hour", reload._absorption.standDownThroughHourKey, 50)
  T.eq("I65 future persisted marker is reclassified corrupt", reload._absorption.standDownReason, "CORRUPT_STATE")
  T.eq("I66 future persisted marker restores no rows", tableCount(reload._absorption.cells), 0)

  local noHour = newSys("CAPPED", 1.0)
  ok = noHour:loadAbsorptionWindow(futureMarkerBlock, "ZONE", 10, nil)
  T.ok("I67 numeric marker with no current hour reloads as awaiting", ok)
  T.eq("I68 numeric marker with no current hour retains no poisoned bound",
    noHour._absorption.standDownThroughHourKey, nil)
  T.ok("I69 numeric marker with no current hour sets awaiting",
    noHour._absorption.standDownAwaitingFirstValidHour)
end

do
  local noHour = newSys("CAPPED", 1.0)
  local ok, reason = noHour:loadAbsorptionWindow(block, "TRUTH", 2, nil)
  T.ok("I70 ordinary window with no current hour is rejected", not ok)
  T.eq("I71 unreadable current hour is named", reason, "UNREADABLE_CURRENT_HOUR")
  T.eq("I72 unreadable current hour retains no numeric marker", noHour._absorption.standDownThroughHourKey, nil)
  T.ok("I73 unreadable current hour sets awaiting", noHour._absorption.standDownAwaitingFirstValidHour)
end

do
  local reload = newSys("CAPPED", 1.0)
  local ok = reload:loadAbsorptionWindow(markerBlock, "ZONE", 10, 51)
  T.ok("I74 valid past marker reloads", ok)
  T.eq("I75 valid past marker remains unchanged", reload._absorption.standDownThroughHourKey, 50)
  T.eq("I76 valid past marker keeps its diagnostic reason", reload._absorption.standDownReason, "PROVIDER_MISMATCH")
end

local olderWindowBlock
do
  olderWindowBlock = {}; for k, v in pairs(block) do olderWindowBlock[k] = v end
  olderWindowBlock.windowId = 49
  local reload = newSys("CAPPED", 1.0)
  local ok, reason = reload:loadAbsorptionWindow(olderWindowBlock, "TRUTH", 2, 50)
  T.ok("I77 older saved capacity window expires cleanly", ok)
  T.eq("I78 older saved capacity window names expiry", reason, "EXPIRED_WINDOW")
  T.eq("I79 older saved capacity window restores no rows", tableCount(reload._absorption.cells), 0)
  T.eq("I80 older saved capacity window creates no stand-down marker",
    reload._absorption.standDownThroughHourKey, nil)

  local olderSchema1 = {}; for k, v in pairs(olderWindowBlock) do olderSchema1[k] = v end
  olderSchema1.schema = 1
  local reload1 = newSys("CAPPED", 1.0)
  ok, reason = reload1:loadAbsorptionWindow(olderSchema1, "TRUTH", 2, 50)
  T.ok("I81 older schema-one window expires through the ordinary row path", ok)
  T.eq("I82 older schema-one window names expiry", reason, "EXPIRED_WINDOW")
  T.eq("I83 older schema-one window restores no rows", tableCount(reload1._absorption.cells), 0)
end

do
  local pruneState = newSys("CAPPED", 1.0)
  pruneState:_absorptionState().cells = {
    a = { fieldId = 1 }, b = { fieldId = 2 }, c = { fieldId = 2 },
  }
  T.eq("I84 live-field prune removes every absent-field row",
    pruneState:pruneAbsorptionMissingFields({ [1] = true }), 2)
end
