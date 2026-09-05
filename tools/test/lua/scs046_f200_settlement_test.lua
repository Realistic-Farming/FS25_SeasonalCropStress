-- scs046_f200_settlement_test.lua
-- SCS-046 F200: fitted-pivot settlement. A fitted pivot settles its continuous
-- active hours through the one interval path whenever it deactivates (reason
-- travels) or at each admitted hour; deactivateSystem settles first so a trip
-- or Stop never strands water and cost, and the legacy whole-hour path never
-- runs for a fitted row.
--!load: src/IrrigationManager.lua

local function riggedManager()
  local mgr = IrrigationManager.new({ settings = { enabled = true } })
  mgr.manager = { settings = { enabled = true } }
  mgr.systems = {
    [1] = { id = 1, type = "pivot", ownerFarmId = 2, isActive = true,
            coveredFields = { 5 }, flowRatePerHour = 0.018, pressureMultiplier = 1.0,
            activeGameHoursSinceSettle = 2, rainKeyFitted = true },
  }
  local water = { calls = 0, gain = 0 }
  mgr.manager.soilSystem = {
    fieldData = { [5] = { centerX = 0, centerZ = 0 } },
    applyWaterAtCell = function(_s, _fid, _x, _z, gain)
      water.calls = water.calls + 1
      water.gain = water.gain + gain
      return true
    end,
  }
  local charged = { amount = 0, farmId = 0 }
  mgr.manager.financeIntegration = {
    deductFundsVanilla = function(_fi, amount, farmId) charged.amount = amount; charged.farmId = farmId end,
  }
  mgr.getEffectiveCostPerHour = function(_self, _s) return 15 end
  mgr._water = water
  mgr._charged = charged
  return mgr
end

-- 1. DEACTIVATE A FITTED ACTIVE SYSTEM SETTLES ITS RUN HOURS FIRST.
do
  local mgr = riggedManager()
  mgr:deactivateSystem(1, "RAIN_KEY_TRIPPED")
  T.eq('deact.settledWater', mgr._water.calls, 1)
  T.near('deact.settledGain', mgr._water.gain, 0.036, 1e-6)
  T.near('deact.settledCost', mgr._charged.amount, 30, 1e-6)
  T.eq('deact.chargedFarm', mgr._charged.farmId, 2)
  T.eq('deact.hoursCleared', mgr.systems[1].activeGameHoursSinceSettle, 0)
  T.eq('deact.inactive', mgr.systems[1].isActive, false)
end

-- 2. A NON-FITTED SYSTEM NEVER SETTLES THROUGH THE FITTED PATH.
do
  local mgr = riggedManager()
  mgr.systems[1].rainKeyFitted = false
  mgr.systems[1].activeGameHoursSinceSettle = 2
  mgr:deactivateSystem(1, "ANY_REASON")
  T.eq('unfitted.noSettle', mgr._water.calls, 0)
  T.eq('unfitted.inactive', mgr.systems[1].isActive, false)
end

-- 3. THE HOURLY INTERVAL SETTLE APPLIES WATER AND COST AND CLEARS HOURS.
do
  local mgr = riggedManager()
  mgr:settleFittedSystem(mgr.systems[1], "HOURLY")
  T.eq('hourly.settledWater', mgr._water.calls, 1)
  T.near('hourly.settledGain', mgr._water.gain, 0.036, 1e-6)
  T.near('hourly.settledCost', mgr._charged.amount, 30, 1e-6)
  T.eq('hourly.hoursCleared', mgr.systems[1].activeGameHoursSinceSettle, 0)
end

T.summary()
