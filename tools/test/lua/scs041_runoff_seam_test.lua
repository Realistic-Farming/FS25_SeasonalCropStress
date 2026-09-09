-- scs041_runoff_seam_test.lua
-- SCS-041 §7 (and SCS-042 §5): the runoff seam. Two halves, both against the
-- real capacity ledger with only the leaf functions stubbed:
--   1. the source-side acceptFn wiring in _absorptionApplyOne, and
--   2. the private terminal helper _acceptRunoffDestinationSpan.
-- The SCS-042 sibling itself does not exist yet; the seam is defensive (nil when
-- absent) and the destination helper is unit-driven directly, matching the
-- SCS-042 spec bar's Group C/D/E contract.
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/SoilMoistureSystem.lua

local BASE = SoilMoistureSystem.BASE_INFILTRATION_PER_HOUR  -- 0.018

-- A CAPPED system on loamy ground (rainAbsorb 1.0), neutral compaction and
-- restriction 1.0, so one provider-cell hourly budget is exactly BASE.
local function sys()
  local s = SoilMoistureSystem.new({})
  s.absorptionMode = "CAPPED"
  s.agronomyRestriction = 1.0
  s.fieldData[1] = { soilType = "loamy" }
  -- neutral compaction -> capacityPerHour = BASE * 1.0 * 1.0 / 1.0
  s._readCompactionAtWorld = function() return nil end
  return s
end

-- A fixed destination carrier cell whose centre is deliberately NOT the query
-- position, so a test can prove the source position (not the cell centre) is the
-- field-eligibility anchor.
local function fixedCell()
  return { mode = "TRUTH", grain = 2, cellX = 10, cellZ = 20,
           centerX = 999, centerZ = 999, cellKey = "TRUTH:2:10:20" }
end

-- A square cultivated polygon covering (0,0)-(100,100). The destination helper
-- reads geometry through _getFieldPolygons (the parcel collection seam), so the
-- stub replaces that seam with a one-polygon parcel.
local function squareField(s)
  s._getFieldPolygons = function() return { { vx = {0, 100, 100, 0}, vz = {0, 0, 100, 100}, n = 4 } } end
end

-- ============================================================
-- PART 1: source-side acceptFn wiring (§7)
-- ============================================================

-- 1. No runoff sibling on the manager -> acceptFn stays nil, the whole candidate
--    surplus folds into the local write (request lands in full at the raw door).
do
  local s = sys()
  s._resolveProviderCell = function() return fixedCell() end
  local lastWrite
  s._applyRawWaterAtCell = function(_self, _fid, _x, _z, gain) lastWrite = gain; return true, true end
  local r = s:_absorptionApplyOne(1, 50, 50, 100, 1, 0.08)
  T.near("noSibling.localWriteIsFullRequest", lastWrite, 0.08, 1e-12)
  T.eq("noSibling.acceptedZero", r.acceptedSurplus, 0)
  T.near("noSibling.candidateSurplus", r.candidateSurplus, 0.08 - BASE, 1e-12)
end

-- 2. A live sibling is offered the candidate span with the correct arguments,
--    and the accepted amount is subtracted from the local write.
do
  local s = sys()
  s._resolveProviderCell = function() return fixedCell() end
  local rawWrite
  s._applyRawWaterAtCell = function(_self, _fid, _x, _z, gain) rawWrite = gain; return true, true end
  local seen
  s.manager.runoffSystem = {
    acceptSurplusSpan = function(_self, fieldId, wx, wz, grain, firstWindowId, windowCount, candidate)
      seen = { fieldId = fieldId, wx = wx, wz = wz, grain = grain,
               firstWindowId = firstWindowId, windowCount = windowCount, candidate = candidate }
      return candidate  -- accept the whole candidate span
    end,
  }
  local r = s:_absorptionApplyOne(1, 50, 55, 100, 1, 0.08)
  T.eq("sibling.offered", seen ~= nil, true)
  T.eq("sibling.fieldId", seen.fieldId, 1)
  T.eq("sibling.sourceXisOriginal", seen.wx, 50)         -- NOT the cell centre 999
  T.eq("sibling.sourceZisOriginal", seen.wz, 55)
  T.eq("sibling.providerGrain", seen.grain, 2)
  T.eq("sibling.firstWindowId", seen.firstWindowId, 100)
  T.eq("sibling.windowCount", seen.windowCount, 1)
  T.near("sibling.candidatePerWindow", seen.candidate, 0.08 - BASE, 1e-12)
  -- absorbed BASE locally + candidate offered and fully accepted -> local write is BASE
  T.near("sibling.localWriteAfterAccept", rawWrite, BASE, 1e-12)
  T.near("sibling.acceptedSurplus", r.acceptedSurplus, 0.08 - BASE, 1e-12)
  T.near("sibling.conservation", r.localWriteRequest + r.acceptedSurplus, r.requestedGain, 1e-12)
end

-- 3. A throwing sibling contributes zero (pcall guard in absorptionAcceptedForSpans);
--    the whole candidate folds back local.
do
  local s = sys()
  s._resolveProviderCell = function() return fixedCell() end
  local rawWrite
  s._applyRawWaterAtCell = function(_self, _fid, _x, _z, gain) rawWrite = gain; return true, true end
  s.manager.runoffSystem = { acceptSurplusSpan = function() error("sibling down") end }
  local r = s:_absorptionApplyOne(1, 50, 50, 100, 1, 0.08)
  T.eq("throwSibling.acceptedZero", r.acceptedSurplus, 0)
  T.near("throwSibling.localWriteFull", rawWrite, 0.08, 1e-12)
end

-- ============================================================
-- PART 2: _acceptRunoffDestinationSpan (§7 / SCS-042 §5)
-- ============================================================

-- 4. Partial headroom: candidate 0.08 >> destination capacity BASE -> the
--    destination absorbs exactly BASE, writes it once, commits after acceptance.
do
  local s = sys(); squareField(s)
  s._resolveProviderCell = function() return fixedCell() end
  local rawCalls, rawGain = 0, 0
  s._applyRawWaterAtCell = function(_self, _fid, _x, _z, gain) rawCalls = rawCalls + 1; rawGain = gain; return true, true end
  local accepted = s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, 50, 50)
  T.near("dest.acceptsCapacity", accepted, BASE, 1e-12)
  T.eq("dest.oneRawWrite", rawCalls, 1)
  T.near("dest.rawGainIsAccepted", rawGain, BASE, 1e-12)
  T.near("dest.committedUsed", s._absorption.cells["TRUTH:2:10:20"].used, BASE, 1e-12)
end

-- 5. Raw refusal commits no capacity and returns zero.
do
  local s = sys(); squareField(s)
  s._resolveProviderCell = function() return fixedCell() end
  s._applyRawWaterAtCell = function() return false, false end
  local accepted = s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, 50, 50)
  T.eq("destRefused.zero", accepted, 0)
  T.eq("destRefused.noCommit", s._absorption.cells["TRUTH:2:10:20"].used, 0)
end

-- 6. Destination outside the cultivated polygon accepts zero and never writes.
do
  local s = sys(); squareField(s)
  local rawCalls = 0
  s._resolveProviderCell = function() return fixedCell() end
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  local accepted = s:_acceptRunoffDestinationSpan(1, 150, 150, 2, 100, 1, 0.08, 50, 50)
  T.eq("offField.zero", accepted, 0)
  T.eq("offField.noRawWrite", rawCalls, 0)
end

-- 7. Source outside the field (a deed-margin source that shares the id but is not
--    on cultivated ground) resolves no containing polygon -> zero.
do
  local s = sys(); squareField(s)
  local rawCalls = 0
  s._resolveProviderCell = function() return fixedCell() end
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  local accepted = s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, 150, 150)
  T.eq("srcOffField.zero", accepted, 0)
  T.eq("srcOffField.noRawWrite", rawCalls, 0)
end

-- 8. Missing/non-finite source context returns zero, not a first-field fallback.
do
  local s = sys(); squareField(s)
  local rawCalls = 0
  s._resolveProviderCell = function() return fixedCell() end
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  T.eq("nilSource.zero", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, nil, nil), 0)
  T.eq("nanSource.zero", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, 0/0, 50), 0)
  T.eq("missingSource.noRawWrite", rawCalls, 0)
end

-- 9. Unavailable geometry returns zero.
do
  local s = sys()
  s._getFieldPolygons = function() return nil end
  s._resolveProviderCell = function() return fixedCell() end
  local rawCalls = 0
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  T.eq("noGeom.zero", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, 50, 50), 0)
  T.eq("noGeom.noRawWrite", rawCalls, 0)
end

-- 10. Invalid spans mutate nothing.
do
  local s = sys(); squareField(s)
  s._resolveProviderCell = function() return fixedCell() end
  local rawCalls = 0
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  T.eq("badSpan.zeroCount", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 0, 0.08, 50, 50), 0)
  T.eq("badSpan.negCandidate", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, -0.01, 50, 50), 0)
  T.eq("badSpan.nonIntFirst", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100.5, 1, 0.08, 50, 50), 0)
  T.eq("badSpan.badGrain", s:_acceptRunoffDestinationSpan(1, 60, 60, 0, 100, 1, 0.08, 50, 50), 0)
  T.eq("badSpan.overCount", s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 169, 0.08, 50, 50), 0)
  T.eq("badSpan.noRawWrite", rawCalls, 0)
end

-- 11. Competing sources serialize through one shared destination-capacity row:
--     0.7*BASE then 0.7*BASE against BASE headroom -> 0.7*BASE then 0.3*BASE,
--     second source keeps a 0.4*BASE remainder; the row never overbooks.
do
  local s = sys(); squareField(s)
  s._resolveProviderCell = function() return fixedCell() end
  s._applyRawWaterAtCell = function() return true, true end
  local first  = s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.7 * BASE, 50, 50)
  local second = s:_acceptRunoffDestinationSpan(1, 61, 61, 2, 100, 1, 0.7 * BASE, 51, 51)
  T.near("compete.firstAbsorbs", first, 0.7 * BASE, 1e-12)
  T.near("compete.secondGetsRemainder", second, 0.3 * BASE, 1e-12)
  T.near("compete.rowFilledExactly", s._absorption.cells["TRUTH:2:10:20"].used, BASE, 1e-12)
end

-- 12. The destination helper never re-offers runoff, even when a live sibling is
--     present on the manager (one hop only).
do
  local s = sys(); squareField(s)
  s._resolveProviderCell = function() return fixedCell() end
  s._applyRawWaterAtCell = function() return true, true end
  local siblingCalls = 0
  s.manager.runoffSystem = { acceptSurplusSpan = function() siblingCalls = siblingCalls + 1; return 0 end }
  s:_acceptRunoffDestinationSpan(1, 60, 60, 2, 100, 1, 0.08, 50, 50)
  T.eq("noRecursion.siblingUntouched", siblingCalls, 0)
end
