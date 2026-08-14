-- SCS-038-priced_draw_spec_test.lua
-- THE PRICED DRAW. Irrigation's operational cost varies with the water it
-- actually draws. The effective rate is operationalCostPerHour /
-- pressureMultiplier: neutral beside a pump (15 exactly), 21.43 at range
-- (15 / 0.7). The executable bar for the getter and the FinanceIntegration
-- charge line, written from the brief's contract.
--
-- THE INVARIANTS THAT MATTER:
--   nil when there is no source (no run, no charge),
--   the LIFT term is neutral at LIFT_COEFF = 0.0 (bit-for-bit round-1),
--   the charge line uses the getter and falls back flat on any nil.
--!load: src/IrrigationManager.lua, src/FinanceIntegration.lua

-- 1. THE GETTER'S CORE: base / pressure.
do
  local mgr = IrrigationManager.new(nil)

  -- Neutral beside a pump: full pressure, cost exactly the XML number.
  local sysFull = { waterSourceId = 1, pressureMultiplier = 1.0, operationalCostPerHour = 15 }
  T.near('getter.neutralBesidePump', mgr:getEffectiveCostPerHour(sysFull), 15, 1e-9)

  -- At range: 15 / 0.7 = 21.43.
  local sysRange = { waterSourceId = 1, pressureMultiplier = 0.7, operationalCostPerHour = 15 }
  T.near('getter.rangeCostsMore', mgr:getEffectiveCostPerHour(sysRange), 15 / 0.7, 1e-9)

  -- Drip line, its own numbers.
  local sysDrip = { waterSourceId = 1, pressureMultiplier = 0.9, operationalCostPerHour = 8 }
  T.near('getter.dripRate', mgr:getEffectiveCostPerHour(sysDrip), 8 / 0.9, 1e-9)
end

-- 2. NO SOURCE = NIL (no run, no charge), never a number.
do
  local mgr = IrrigationManager.new(nil)
  local sysNoSource = { waterSourceId = nil, pressureMultiplier = 0, operationalCostPerHour = 15 }
  T.eq('getter.noSourceIsNil', mgr:getEffectiveCostPerHour(sysNoSource), nil)
  local sysZeroPressure = { waterSourceId = 1, pressureMultiplier = 0, operationalCostPerHour = 15 }
  T.eq('getter.zeroPressureIsNil', mgr:getEffectiveCostPerHour(sysZeroPressure), nil)
  T.eq('getter.nilSystemIsNil', mgr:getEffectiveCostPerHour(nil), nil)
end

-- 3. THE LIFT TERM, neutral at LIFT_COEFF = 0.0, live above 0.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { y = 10 } }

  -- LIFT_COEFF 0.0: bit-for-bit round-1.
  local sysNeutral = { waterSourceId = 1, pressureMultiplier = 0.7, operationalCostPerHour = 15, liftCoeff = 0.0, y = 50 }
  T.near('lift.neutralIsRoundOne', mgr:getEffectiveCostPerHour(sysNeutral), 15 / 0.7, 1e-9)

  -- A tuned LIFT_COEFF prices uphill lift: 15/0.7 * (1 + 2 * 40/10) = 15/0.7 * 9.
  local sysLift = { waterSourceId = 1, pressureMultiplier = 0.7, operationalCostPerHour = 15, liftCoeff = 2.0, y = 50 }
  T.near('lift.pricesUphill', mgr:getEffectiveCostPerHour(sysLift), 15 / 0.7 * (1 + 2.0 * 40 / 10), 1e-9)

  -- Downhill (pivot below source): max(0, ...) kills the lift.
  local sysDownhill = { waterSourceId = 1, pressureMultiplier = 0.7, operationalCostPerHour = 15, liftCoeff = 2.0, y = 5 }
  T.near('lift.downhillNeutral', mgr:getEffectiveCostPerHour(sysDownhill), 15 / 0.7, 1e-9)
end

-- 4. THE CHARGE LINE uses the getter and falls back flat on any nil.
do
  local charged = {}
  local fi = setmetatable({ isInitialized = true }, { __index = FinanceIntegration })
  fi.manager = { irrigationManager = {
    costsEnabled = true,
    systems = {
      { isActive = true, waterSourceId = 1, pressureMultiplier = 0.7, operationalCostPerHour = 15, placeable = { getOwnerFarmId = function() return 1 end } },
    },
    getEffectiveCostPerHour = function(_self, _sys) return 15 / 0.7 end,
  } }
  fi.deductFundsVanilla = function(_self, cost) charged[#charged + 1] = cost end

  fi:chargeHourlyCosts(1)
  T.ok('charge.usesPricedDraw', #charged == 1)
  T.near('charge.amountIsPriced', charged[1], 15 / 0.7, 1e-9)
end

-- 5. THE FLAT FALLBACK: a manager without the getter charges the old number.
do
  local charged = {}
  local fi = setmetatable({ isInitialized = true }, { __index = FinanceIntegration })
  fi.manager = { irrigationManager = {
    costsEnabled = true,
    systems = {
      { isActive = true, waterSourceId = 1, pressureMultiplier = 0.7, operationalCostPerHour = 15, placeable = { getOwnerFarmId = function() return 1 end } },
    },
  } }
  fi.deductFundsVanilla = function(_self, cost) charged[#charged + 1] = cost end

  fi:chargeHourlyCosts(1)
  T.ok('charge.flatFallbackCharges', #charged == 1)
  T.near('charge.flatFallbackIsFlat', charged[1], 15, 1e-9)
end

T.summary()
