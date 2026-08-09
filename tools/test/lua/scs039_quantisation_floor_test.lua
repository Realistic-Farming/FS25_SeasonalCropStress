-- scs039_quantisation_floor_test.lua
-- SCS-039 / GRID-1: the vendored moisture value map's correctness law.
--
-- THE BLOCKER THIS LOCKS: moisture spans 0..1 across 254 raw steps, so one raw
-- step is ~0.0039 moisture. Hourly rain and evaporation deltas are routinely
-- SMALLER than that. A naive per-hour write floors to zero every single time,
-- so a full day of light rain moves the map by NOTHING and the ground silently
-- stops responding to weather.
--
-- The moisture brief proved that shape on its own bench; this one locks the fix
-- in the shipped code: sub-step deltas accumulate through quantiseDelta() and
-- only whole raw steps are ever applied, with the remainder carried forward so
-- nothing is lost and nothing is double counted.
--!load: src/maps/CropStressValueMap.lua

local DEF   = CropStressValueMap.LAYER_DEF
local UPR   = CropStressValueMap._unitsPerRaw(DEF)      -- 1/254
local quant = CropStressValueMap.quantiseDelta

-- 1. The floor is where we think it is.
do
  T.near("upr.oneRawStep", UPR, 1 / 254, 1e-12)
  T.ok("upr.subStepIsRealisticallyReachable", UPR > 0.003 and UPR < 0.005)
end

-- 2. THE NAIVE FAILURE, reproduced so the regression is visible if anyone
--    removes the accumulator. A sub-step delta applied directly moves nothing.
do
  local hourlyRain = 0.001          -- well under one raw step
  local base = 0.500
  local rawBefore = CropStressValueMap._encode(base, DEF)
  local rawAfter  = CropStressValueMap._encode(base + hourlyRain, DEF)
  T.eq("naive.singleHourMovesNothing", rawAfter, rawBefore)

  -- Twenty four of them, applied one at a time without accumulation, still
  -- move nothing: each write re-reads the same unchanged value.
  local v = base
  for _ = 1, 24 do
    local raw = CropStressValueMap._encode(v + hourlyRain, DEF)
    v = CropStressValueMap._decode(raw, DEF)
  end
  T.near("naive.wholeDayMovesNothing", v, base, 1e-9)
end

-- 3. THE FIX: the same 24 hours through the accumulator DOES move the map,
--    and lands within one raw step of the honest total.
do
  local hourlyRain = 0.001
  local pending, applied = 0, 0
  for _ = 1, 24 do
    pending = pending + hourlyRain
    local step, rest = quant(pending)
    applied = applied + step
    pending = rest
  end
  T.ok("accumulated.dayActuallyMoves", applied > 0)
  T.near("accumulated.totalIsHonest", applied + pending, 24 * hourlyRain, 1e-12)
  T.ok("accumulated.remainderUnderOneStep", math.abs(pending) < UPR)
end

-- 4. NOTHING IS LOST AND NOTHING IS INVENTED, over a long noisy run.
--    applied + remaining must always equal everything fed in.
do
  local pending, applied, fed = 0, 0, 0
  local seed = 12345
  for i = 1, 500 do
    -- deterministic pseudo-noise, both signs, mostly sub-step
    seed = (seed * 1103515245 + 12345) % 2147483648
    local d = ((seed / 2147483648) - 0.5) * 0.004
    fed = fed + d
    pending = pending + d
    local step, rest = quant(pending)
    applied = applied + step
    pending = rest
  end
  T.near("conservation.nothingLost", applied + pending, fed, 1e-9)
  T.ok("conservation.remainderBounded", math.abs(pending) < UPR)
end

-- 5. SIGN DISCIPLINE: truncation is toward zero in BOTH directions. A positive
--    remainder must never produce a negative step, or a drying field would
--    oscillate around a value it never reaches.
do
  local step, rest = quant(UPR * 0.9)
  T.eq("sign.positiveSubStepApplies", step, 0)
  T.near("sign.positiveSubStepCarries", rest, UPR * 0.9, 1e-12)

  step, rest = quant(-UPR * 0.9)
  T.eq("sign.negativeSubStepApplies", step, 0)
  T.near("sign.negativeSubStepCarries", rest, -UPR * 0.9, 1e-12)

  step, rest = quant(UPR * 2.5)
  T.near("sign.positiveTakesWholeSteps", step, UPR * 2, 1e-12)
  T.ok("sign.positiveRemainderStaysPositive", rest > 0)

  step, rest = quant(-UPR * 2.5)
  T.near("sign.negativeTakesWholeSteps", step, -UPR * 2, 1e-12)
  T.ok("sign.negativeRemainderStaysNegative", rest < 0)
end

-- 6. EXACT STEP BOUNDARIES do not leak a phantom remainder.
do
  for n = 1, 6 do
    local step, rest = quant(UPR * n)
    T.near("boundary.applied." .. n, step, UPR * n, 1e-12)
    T.near("boundary.remainder." .. n, rest, 0, 1e-12)
  end
end

-- 7. ENCODE / DECODE round trip stays inside half a raw step across the range,
--    and the no-data sentinel is never produced by a legal value.
do
  for i = 0, 20 do
    local v = i / 20
    local raw = CropStressValueMap._encode(v, DEF)
    T.ok("encode.neverSentinel." .. i, raw >= 1 and raw <= 255)
    local back = CropStressValueMap._decode(raw, DEF)
    T.ok("encode.roundTrip." .. i, math.abs(back - v) <= UPR * 0.5 + 1e-9)
  end
  T.eq("decode.rawZeroIsNoData", CropStressValueMap._decode(0, DEF), nil)
  T.eq("decode.rawNilIsNoData", CropStressValueMap._decode(nil, DEF), nil)
end

-- 8. CLAMPING: out-of-range moisture cannot wrap into the sentinel or past the top.
do
  T.eq("clamp.belowRange", CropStressValueMap._encode(-5.0, DEF), 1)
  T.eq("clamp.aboveRange", CropStressValueMap._encode(5.0, DEF), 255)
  T.eq("clamp.exactFloor", CropStressValueMap._encode(0.0, DEF), 1)
  T.eq("clamp.exactCeiling", CropStressValueMap._encode(1.0, DEF), 255)
end

-- 9. ENGINE ABSENT IS INERT, NOT BROKEN. With no engine the map declines to
--    initialize and every accessor stays quiet, so the cell-store fallback runs
--    exactly as it does today.
do
  local m = CropStressValueMap.new()
  T.eq("inert.notAvailableBeforeInit", m.available, false)
  T.eq("inert.grainIsNil", m:getGrainMetres(), nil)
  T.eq("inert.readIsNil", (m:readValueAtWorld(0, 0)), nil)
  T.eq("inert.writeRefuses", m:writeValueAtWorld(0, 0, 0.5, 2), false)
  T.eq("inert.deltaAppliesNothing", m:applyDeltaToPolygon(nil, nil, 0, 0.5), 0)
  T.eq("inert.averageIsNil", (m:readAverageOfPolygon(nil, nil, 0)), nil)
  T.eq("inert.saveRefuses", m:saveToSavegame("/nowhere"), false)
end

-- 10. THE QUANTISER IS PURE and needs no engine at all, which is what lets the
--     accumulation law be proven off a running game.
do
  T.eq("pure.zeroIn", (quant(0)), 0)
  T.eq("pure.nilIn", (quant(nil)), 0)
  local _, rest = quant(nil)
  T.eq("pure.nilCarriesZero", rest, 0)
end

T.summary()
