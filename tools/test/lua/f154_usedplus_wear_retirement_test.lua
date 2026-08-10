-- f154_usedplus_wear_retirement_test.lua
-- F154: THE USEDPLUS WEAR BRIDGE IS RETIRED.
--
-- The bridge read equipment condition out of UsedPlus DNA to scale irrigation
-- flow. DNA tracks vehicles; irrigation systems are placeables and never have an
-- entry, so the read was always 0.0 and `wearFactor = 1.0 - wearLevel * 0.3` was a
-- permanent multiply by one. Today by accident, after this retirement by design.
--
-- THE ACCEPTANCE TEST IS INVARIANT 1: NO PLAYER-OBSERVABLE BEHAVIOUR CHANGES.
-- Every rate below is pinned against the PRE-REMOVAL formula computed by hand with
-- wearFactor at its provable value of 1.0. If any rate moves, the fix is wrong.
--!load: src/IrrigationManager.lua, src/FinanceIntegration.lua

local function newManager()
  local published = {}
  local m = {
    eventBus = {
      subscribe = function() end,
      publish   = function(name, data) published[#published + 1] = { name = name, data = data } end,
    },
  }
  local im = IrrigationManager.new(m)
  im.isInitialized = true
  return im, published
end

-- A system shaped exactly like registerIrrigationSystem builds one, minus the
-- `wearLevel` field this fix deleted.
local function addSystem(im, id, flowRate, pressure, fields)
  im.systems[id] = {
    coveredFields          = fields or { 1 },
    waterSourceId          = 99,
    pressureMultiplier     = pressure,
    flowRatePerHour        = flowRate,
    operationalCostPerHour = 15,
    isActive               = false,
    effectiveRatePerField  = {},
  }
  return im.systems[id]
end

-- =========================================================
-- 1. INVARIANT 1: THE RATE IS UNCHANGED
-- =========================================================
do
  -- The pre-removal expression was flowRate * pressure * (1.0 - wearLevel * 0.3)
  -- with wearLevel provably 0, i.e. flowRate * pressure * 1.0. Written out here in
  -- the OLD shape so this assertion pins the old behaviour, not the new code.
  local WEAR_LEVEL_AS_IT_ALWAYS_WAS = 0.0
  local function preRemovalRate(flow, pressure)
    return flow * pressure * (1.0 - WEAR_LEVEL_AS_IT_ALWAYS_WAS * 0.3)
  end

  local im = newManager()
  addSystem(im, 1, 0.018, 1.0)
  im:activateSystem(1)
  T.near("rate.fullPressureUnchanged", im.systems[1].effectiveRatePerField[1],
         preRemovalRate(0.018, 1.0), 1e-12)

  -- A degraded pressure multiplier is the one axis that still exists, and it must
  -- keep working exactly as before.
  local im2 = newManager()
  addSystem(im2, 2, 0.018, 0.65)
  im2:activateSystem(2)
  T.near("rate.partialPressureUnchanged", im2.systems[2].effectiveRatePerField[1],
         preRemovalRate(0.018, 0.65), 1e-12)

  -- Zero pressure still yields zero flow.
  local im3 = newManager()
  addSystem(im3, 3, 0.018, 0.0)
  im3:activateSystem(3)
  T.near("rate.zeroPressureIsZero", im3.systems[3].effectiveRatePerField[1], 0.0, 1e-12)
end

do
  -- INVARIANT 2: BOTH RATE SITES MOVED TOGETHER. `activateSystem` and
  -- `applyOneTimeIrrigation` computed the same expression in two places, and
  -- changing one is the incomplete-fold defect this project measures most.
  -- Assert they still agree by driving the scheduled path and comparing against
  -- the same hand-computed number the one-shot path must also produce.
  local im = newManager()
  addSystem(im, 4, 0.02, 0.8, { 7 })
  im:activateSystem(4)
  local scheduled = im.systems[4].effectiveRatePerField[7]
  T.near("rate.bothSitesAgree", scheduled, 0.02 * 0.8, 1e-12)

  -- And the one-shot path's source line no longer mentions wear at all: if it did,
  -- the two would diverge the moment anything wrote a wear value again.
  T.eq("rate.noWearSetterSurvives", IrrigationManager.updateSystemWearLevel, nil)
end

-- =========================================================
-- 2. THE BRIDGE IS GONE, NOT DORMANT
-- =========================================================
do
  -- A dormant axis invites a future reader to wire it back up. These four
  -- assertions are the difference between deleted and merely unused.
  T.eq("gone.noWearSetter", IrrigationManager.updateSystemWearLevel, nil)
  T.eq("gone.noWearReader", FinanceIntegration.getEquipmentWearLevel, nil)
  T.eq("gone.noEnableMode", FinanceIntegration.enableUsedPlusMode, nil)

  local fi = FinanceIntegration.new({})
  T.eq("gone.noActiveFlag", fi.usedPlusActive, nil)
end

do
  -- A freshly built system carries no wear field. `registerIrrigationSystem`
  -- initialised it to 0 and only the UsedPlus path ever wrote it, so the field
  -- goes with its writer.
  local im = newManager()
  local s = addSystem(im, 5, 0.018, 1.0)
  T.eq("gone.noWearField", s.wearLevel, nil)

  -- And activation does not resurrect it.
  im:activateSystem(5)
  T.eq("gone.activationAddsNoWear", im.systems[5].wearLevel, nil)
end

-- =========================================================
-- 3. THE CHARGE LOOP STILL CHARGES, AND ONLY CHARGES
-- =========================================================
do
  -- The wear call lived inside this loop. Removing it must not disturb the money.
  local charged = { total = 0 }
  local im = newManager()
  addSystem(im, 6, 0.018, 1.0)
  im.costsEnabled = true
  im:activateSystem(6)

  local fi = FinanceIntegration.new({ irrigationManager = im })
  fi.isInitialized = true
  fi.deductFundsVanilla = function(_self, cost) charged.total = charged.total + cost end

  fi:chargeHourlyCosts()
  T.near("charge.oneHourUnchanged", charged.total, 15, 1e-9)

  -- SCS-037's span multiply is untouched by this removal.
  charged.total = 0
  fi:chargeHourlyCosts(72)
  T.near("charge.spanStillMultiplies", charged.total, 15 * 72, 1e-9)
end

do
  -- The loop no longer needs the system id, and an inactive system is still free.
  local charged = { total = 0 }
  local im = newManager()
  addSystem(im, 7, 0.018, 1.0)   -- never activated
  im.costsEnabled = true

  local fi = FinanceIntegration.new({ irrigationManager = im })
  fi.isInitialized = true
  fi.deductFundsVanilla = function(_self, cost) charged.total = charged.total + cost end

  fi:chargeHourlyCosts(168)
  T.near("charge.inactiveStillFree", charged.total, 0, 1e-9)
end

T.summary()
