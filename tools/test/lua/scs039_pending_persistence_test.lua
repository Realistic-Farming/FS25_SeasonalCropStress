-- scs039_pending_persistence_test.lua
-- SCS-039 / GRID-1 (SDS 3.4 tail, slice 8): the positional accepted-water store
-- is persisted deterministically. Slice 3 preserved UNRESOLVED world leaves and
-- resolved pixel remainders in-mission only; this locks the seams that carry
-- them across save and reload so no accepted water is lost.
--
-- The pure contract is already modelled by the authoritative bar: Group C
-- (sparse packing deterministic by field then pixel, every non-zero entry, no
-- hidden 1024 ceiling, exact-total round trip) and Group O (unresolved status
-- and source width survive a compact round trip). These live tests drive the
-- real SoilMoistureSystem pack/unpack seams against that model.
--!load: src/SoilMoistureSystem.lua

local function newSystem()
  local sys = SoilMoistureSystem.new({})
  sys._mapWaterPending = {}
  return sys
end

local function leafTotal(sys)
  local total = 0
  for _, acc in pairs(sys._mapWaterPending) do
    for key, value in pairs(acc) do
      if type(key) == "number" then
        total = total + value
      elseif type(value) == "table" then
        total = total + (value.amount or 0)
      end
    end
  end
  return total
end

-- 1. DETERMINISTIC ORDER: resolved leaves ascend by field then pixel key
--    (Group C C5/C6), zero amounts are skipped, negative remainders are kept.
do
  local sys = newSystem()
  sys._mapWaterPending = {
    [2] = { [11] = 0.00125, [4] = 0.00250 },
    [1] = { [8] = -0.00075, [9] = 0 },
  }
  local rows = sys:packMapWaterPending()
  T.eq("pack.keepsEveryNonZeroEntry", #rows, 3)
  T.eq("pack.deterministicField", rows[1].fieldId, 1)
  T.eq("pack.deterministicPixel", rows[2].pixelKey, 4)
  T.eq("pack.fieldThenPixel", rows[1].pixelKey, 8)
  T.eq("pack.statusResolved", rows[1].status, "RESOLVED")
  T.eq("pack.keepsNegativeRemainder", rows[1].amount, -0.00075)
  T.near("pack.preservesAmount", rows[3].amount, 0.00125, 1e-12)
end

-- 2. NO HIDDEN 1024-ENTRY CEILING (Group C C8).
do
  local sys = newSystem()
  local acc = {}
  for i = 1, 1025 do acc[i] = i / 10000000 end
  sys._mapWaterPending = { [1] = acc }
  local rows = sys:packMapWaterPending()
  T.eq("pack.noCeiling", #rows, 1025)
end

-- 3. UNRESOLVED world leaves ride the pack AFTER the field's resolved leaves,
--    preserving status, world coords and source width (Group O O6/O7).
do
  local sys = newSystem()
  sys._mapWaterPending = {
    [3] = {
      [5] = 0.002,
      ["WORLD:10,20"] = { status = "UNRESOLVED", worldX = 10, worldZ = 20, sourceWidth = 2, amount = 0.01 },
    },
  }
  local rows = sys:packMapWaterPending()
  T.eq("pack.unresolvedAfterResolved", #rows, 2)
  T.eq("pack.unresolvedLast", rows[2].status, "UNRESOLVED")
  T.eq("pack.unresolvedWorldX", rows[2].worldX, 10)
  T.eq("pack.unresolvedWorldZ", rows[2].worldZ, 20)
  T.eq("pack.unresolvedSourceWidth", rows[2].sourceWidth, 2)
  T.near("pack.unresolvedAmount", rows[2].amount, 0.01, 1e-12)
end

-- 4. ROW ROUND TRIP onto a fresh store conserves the exact total and rebuilds
--    both key kinds exactly (Group C C7, Group O O6/O7).
do
  local sys = newSystem()
  sys._mapWaterPending = {
    [1] = { [8] = 0.00125, [2] = 0.00250 },
    [3] = {
      [5] = 0.002,
      ["WORLD:10,20"] = { status = "UNRESOLVED", worldX = 10, worldZ = 20, sourceWidth = 2, amount = 0.01 },
    },
  }
  local totalBefore = leafTotal(sys)
  local rows = sys:packMapWaterPending()
  local fresh = newSystem()
  local restored = fresh:unpackMapWaterPending(rows)
  T.eq("rows.restoredCount", restored, 4)
  T.near("rows.totalConserved", leafTotal(fresh), totalBefore, 1e-12)
  T.near("rows.resolvedExact", fresh._mapWaterPending[1][8], 0.00125, 1e-12)
  T.eq("rows.resolvedKeyIsNumber", type(fresh._mapWaterPending[1][8]), "number")
  local leaf = fresh._mapWaterPending[3]["WORLD:10,20"]
  T.eq("rows.unresolvedStatus", leaf ~= nil and leaf.status or nil, "UNRESOLVED")
  T.eq("rows.unresolvedSourceWidth", leaf ~= nil and leaf.sourceWidth or nil, 2)
  T.near("rows.unresolvedAmount", leaf ~= nil and leaf.amount or -1, 0.01, 1e-12)
end

-- 5. STRING ROUND TRIP (the own-XML path) returns the exact same doubles.
do
  local sys = newSystem()
  sys._mapWaterPending = {
    [2] = { [11] = 0.00125, [4] = 0.00250 },
    [3] = {
      ["WORLD:10,20"] = { status = "UNRESOLVED", worldX = 10, worldZ = 20, sourceWidth = 2, amount = 0.01 },
    },
  }
  local totalBefore = leafTotal(sys)
  local packed = sys:packMapWaterPendingString()
  T.ok("string.packedWhenNonEmpty", packed ~= nil)
  local fresh = newSystem()
  local restored = fresh:unpackMapWaterPendingString(packed)
  T.eq("string.restoredCount", restored, 3)
  T.near("string.totalConserved", leafTotal(fresh), totalBefore, 1e-12)
  T.near("string.resolvedExact", fresh._mapWaterPending[2][11], 0.00125, 1e-12)
  local leaf = fresh._mapWaterPending[3]["WORLD:10,20"]
  T.eq("string.unresolvedStatus", leaf ~= nil and leaf.status or nil, "UNRESOLVED")
  T.near("string.unresolvedAmount", leaf ~= nil and leaf.amount or -1, 0.01, 1e-12)
end

-- 6. EMPTY store packs to nothing, and a missing string restores nothing.
do
  local sys = newSystem()
  T.eq("empty.packRows", #sys:packMapWaterPending(), 0)
  T.eq("empty.packStringNil", sys:packMapWaterPendingString(), nil)
  T.eq("empty.unpackStringNil", sys:unpackMapWaterPendingString(nil), 0)
  T.eq("empty.unpackStringEmpty", sys:unpackMapWaterPendingString(""), 0)
  T.eq("empty.unpackRowsNil", sys:unpackMapWaterPending(nil), 0)
end

-- 7. An all-zero or all-empty store packs to nothing (only non-zero entries
--    are ever emitted, so a cleared store round trips as an empty one).
do
  local sys = newSystem()
  sys._mapWaterPending[1] = { [4097] = 0 }
  T.eq("allZero.packRows", #sys:packMapWaterPending(), 0)
  T.eq("allZero.packStringNil", sys:packMapWaterPendingString(), nil)
end

T.summary()
