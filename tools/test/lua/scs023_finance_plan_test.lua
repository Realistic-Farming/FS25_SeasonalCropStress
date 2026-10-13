-- scs023_finance_plan_test.lua
-- SCS-023 / GRID-1 (SDS 5.3/7): when the finite-water plan is present, finance
-- debits its FROZEN financeRows exactly once and ignores endpoint isActive; a
-- nil plan preserves the legacy isActive * hours fallback. Fitted pivots carry
-- no finance row (F200 owns them), and the plan freezes owner farm + effective
-- cost at PLAN time.
--!load: src/IrrigationManager.lua, src/FinanceIntegration.lua

local function newFinance(irrigationManager)
  local mgr = { irrigationManager = irrigationManager or {} }
  local fi = FinanceIntegration.new(mgr)
  fi.isInitialized = true
  return fi
end

-- 1. PLAN MODE debits frozen rows and ignores endpoint isActive.
do
  local debits = {}
  g_currentMission.addMoney = function(_self, amount, farmId)
    debits[#debits + 1] = { amount = amount, farmId = farmId }
  end
  local fi = newFinance({ costsEnabled = true, systems = { [10] = { isActive = false } } })
  fi:chargeHourlyCosts(1, { financeRows = {
    [10] = { farmId = 2, effectiveCostPerHour = 15, servedHours = 4, amount = 60 },
    [11] = { farmId = 0, amount = 999 },   -- spectator farm: zero debit
    [12] = { farmId = nil, amount = 999 }, -- missing farm: zero debit
  } })
  T.eq('plan.chargedOneFrozenRow', #debits, 1)
  T.near('plan.amountIsServedXCost', debits[1].amount, -60, 1e-9)
  T.eq('plan.chargedToFrozenFarm', debits[1].farmId, 2)
  g_currentMission.addMoney = nil
end

-- 2. PLAN FINANCE ROWS: only non-fitted served systems are frozen, with owner
--    farm and effective cost captured at plan time.
do
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = { [1] = { id = 1, finite = false } }
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, pressureMultiplier = 1.0, rainKeyFitted = false,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
    [20] = { id = 20, waterSourceId = 1, pressureMultiplier = 1.0, rainKeyFitted = true,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  mgr.getEffectiveCostPerHour = function(_self, _system) return 15 end
  local plan = mgr:planFiniteWater(2, 1 * 24 + 6, 0.0, false)
  T.eq('plan.financeUnfittedServed', plan.financeRows[10] ~= nil, true)
  T.near('plan.financeUnfittedServedHours', plan.financeRows[10].servedHours, 2, 1e-9)
  T.near('plan.financeAmount', plan.financeRows[10].amount, 30, 1e-9)
  T.eq('plan.fittedExcludedFromFinance', plan.financeRows[20], nil)
  T.eq('plan.fittedExcludedFromServed', plan.servedHoursBySystem[20], nil)
  T.eq('plan.unfittedServed', plan.servedHoursBySystem[10], 2)
end

T.summary()
