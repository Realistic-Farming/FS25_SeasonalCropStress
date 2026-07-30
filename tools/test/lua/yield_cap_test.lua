-- yield_cap_test.lua - the reduced yield cap and its save migration.
--
-- Context (Arissani ruling 2026-07-30): the harvest hook had never installed, so
-- CropStressModifier's yield penalty had never run on any save and NO stored
-- maxYieldLoss was ever actually experienced. The repair therefore ships at the
-- GENTLE END of the existing 0.30-0.75 clamp rather than the old 0.60, with the full
-- value routed to the suite balance pass. This file guards both halves: the shipped
-- default, and the migration that carries the ruling to saves already on disk.
--!load: src/CropStressModifier.lua, src/settings/CropStressSettings.lua

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

-- ── The save migration (regression guard for a SILENT no-op) ─────────────────
-- The first implementation compared the stored value with == and therefore never
-- fired: savegame14 held 0.600000, was not migrated, and nothing in the log said so.
-- A bug whose only symptom is absence needs a test that can see it.
do
  local migrate = CropStressSettings.migrateLegacyYieldCap

  -- The exact literal migrates.
  local v, did = migrate(0.60)
  T.near("migrate: legacy default -> new default", v, 0.30)
  T.ok("migrate: reports that it migrated", did)

  -- THE CASE THE == VERSION MISSED: a float that came back from XML text and is not
  -- bit-identical to the literal. Both of these are "0.6" as far as a player is
  -- concerned and both must migrate.
  v, did = migrate(0.60000002384185791)
  T.near("migrate: float-imprecise legacy value still migrates", v, 0.30)
  T.ok("migrate: imprecise value reports migrated", did)
  v, did = migrate(0.5999999)
  T.near("migrate: legacy value a hair low still migrates", v, 0.30)
  T.ok("migrate: hair-low value reports migrated", did)

  -- A deliberately chosen value is NEVER touched.
  v, did = migrate(0.75)
  T.near("migrate: deliberate 0.75 untouched", v, 0.75)
  T.ok("migrate: 0.75 not reported as migrated", not did)
  v, did = migrate(0.45)
  T.near("migrate: deliberate 0.45 untouched", v, 0.45)
  T.ok("migrate: 0.45 not reported as migrated", not did)

  -- The tolerance must not swallow a neighbouring deliberate choice.
  v, did = migrate(0.65)
  T.near("migrate: 0.65 is not the legacy default", v, 0.65)
  T.ok("migrate: 0.65 not reported as migrated", not did)
  v, did = migrate(0.55)
  T.near("migrate: 0.55 is not the legacy default", v, 0.55)
  T.ok("migrate: 0.55 not reported as migrated", not did)

  -- Already on the new default: nothing to do, and no misleading log.
  v, did = migrate(0.30)
  T.near("migrate: already on new default stays", v, 0.30)
  T.ok("migrate: new default not reported as migrated", not did)

  -- Absent / junk falls to the default without claiming a migration.
  v, did = migrate(nil)
  T.near("migrate: nil -> default", v, 0.30)
  T.ok("migrate: nil not reported as migrated", not did)
end
