-- yield_cap_test.lua - the reduced yield cap and its save migration.
--
-- Context (Arissani ruling 2026-07-30): the harvest hook had never installed, so
-- CropStressModifier's yield penalty had never run on any save and NO stored
-- maxYieldLoss was ever actually experienced. The repair therefore ships at the
-- GENTLE END of the existing 0.30-0.75 clamp rather than the old 0.60, with the full
-- value routed to the suite balance pass. This file guards both halves: the shipped
-- default, and the migration that carries the ruling to saves already on disk.
--!load: src/CropStressModifier.lua

-- ── The shipped default ──────────────────────────────────────────────────────
do
  T.near("cap: shipped default is the gentle end of the clamp",
         CropStressModifier.MAX_YIELD_LOSS, 0.30)
end

-- ── The clamp is untouched: this was a DEFAULT change, not new machinery ─────
do
  local mod = setmetatable({}, CropStressModifier)

  mod:setMaxYieldLoss(0.90)
  T.near("cap: clamp still tops out at 0.75", mod:getMaxYieldLoss(), 0.75)

  mod:setMaxYieldLoss(0.10)
  T.near("cap: clamp still floors at 0.30", mod:getMaxYieldLoss(), 0.30)

  -- A player who deliberately chose the old value still gets it. The ruling lowered
  -- the DEFAULT; it did not remove 0.60 from the range.
  mod:setMaxYieldLoss(0.60)
  T.near("cap: an explicit 0.60 is still honoured", mod:getMaxYieldLoss(), 0.60)

  -- nil must fall through to the shipped default, not a stale hardcoded 0.60.
  mod:setMaxYieldLoss(nil)
  T.near("cap: nil falls back to the shipped default", mod:getMaxYieldLoss(), 0.30)
end

-- ── Keep-factor at the new default ───────────────────────────────────────────
-- The harvest hook applies keepFactor = 1 - (stress * maxLoss), so the harshest
-- outcome a default install can produce is now 0.70 rather than 0.40.
do
  local mod = setmetatable({ fieldStress = { [1] = 1.0, [2] = 0.5 } }, CropStressModifier)
  mod:setMaxYieldLoss(CropStressModifier.MAX_YIELD_LOSS)

  local function keep(fieldId)
    return 1.0 - (mod:getStress(fieldId) * mod:getMaxYieldLoss())
  end

  T.near("keep: full stress at the default cap keeps 0.70", keep(1), 0.70)
  T.near("keep: half stress at the default cap keeps 0.85", keep(2), 0.85)
  T.near("keep: untracked field keeps 1.0",                 keep(99), 1.0)
end

-- ── The yield-impact string tracks the configured cap, not the constant ──────
-- getYieldImpactString reads the instance method so the player's own setting is what
-- the dialog reports. At the default cap a fully stressed field reads -30%.
do
  local mod = setmetatable({ fieldStress = { [1] = 1.0, [2] = 0.0 } }, CropStressModifier)
  mod:setMaxYieldLoss(CropStressModifier.MAX_YIELD_LOSS)
  T.eq("impact: full stress at default cap reads -30%", mod:getYieldImpactString(1), "-30%")
  T.eq("impact: no stress reads 0%",                    mod:getYieldImpactString(2), "0%")

  -- Raise the cap and the same stress must report the harsher number.
  mod:setMaxYieldLoss(0.60)
  T.eq("impact: reflects a raised cap", mod:getYieldImpactString(1), "-60%")
end
