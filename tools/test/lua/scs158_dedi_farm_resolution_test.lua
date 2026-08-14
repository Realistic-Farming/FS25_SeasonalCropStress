-- scs158_dedi_farm_resolution_test.lua
-- F158 THE WATER BILL. The irrigation running cost used to resolve the farm from
-- the local player, so on a dedicated server (no local player) nothing was billed
-- all season, and on a listen server every system on the map was billed to the
-- host. The bill now goes to the OWNER of each system's placeable, resolved at
-- charge time. This bar proves the per-system owner charge, the skip when no
-- owner resolves, and the deduction charging the given farm and never the viewer.
--
--!load: src/FinanceIntegration.lua

-- 1. DEDI: NO LOCAL PLAYER, AND EACH SYSTEM'S OWNER IS CHARGED.
do
  local charged = {}
  local fi = setmetatable({ isInitialized = true }, { __index = FinanceIntegration })
  fi.manager = { irrigationManager = {
    costsEnabled = true,
    getEffectiveCostPerHour = function(_self, s) return s.operationalCostPerHour end,
    systems = {
      { isActive = true, operationalCostPerHour = 15,
        placeable = { getOwnerFarmId = function() return 1 end } },
      { isActive = true, operationalCostPerHour = 20,
        placeable = { getOwnerFarmId = function() return 3 end } },
    },
  } }
  fi.deductFundsVanilla = function(_self, cost, farmId)
    charged[#charged + 1] = { cost = cost, farmId = farmId }
  end
  g_currentMission = { player = nil }   -- dedicated server: no local player

  fi:chargeHourlyCosts(1)
  T.eq('dedi.chargesBothSystems', #charged, 2)
  local byFarm = {}
  for _, c in ipairs(charged) do byFarm[c.farmId] = c.cost end
  T.eq('dedi.farm1PaysItsOwnPivot', byFarm[1], 15)
  T.eq('dedi.farm3PaysItsOwnPivot', byFarm[3], 20)
  T.ok('dedi.neverBillsTheViewer', charged[1].farmId ~= 9 and charged[2].farmId ~= 9)
end

-- 2. THE OLD READ IS THE RED CASE: A SYSTEM WITH NO RESOLVABLE OWNER IS SKIPPED,
-- NOT BILLED TO NOBODY AND NOT BILLED TO A SPECTATOR.
do
  local charged = {}
  local fi = setmetatable({ isInitialized = true }, { __index = FinanceIntegration })
  fi.manager = { irrigationManager = {
    costsEnabled = true,
    getEffectiveCostPerHour = function(_self, _s) return 15 end,
    systems = {
      { isActive = true, operationalCostPerHour = 15 },               -- no placeable
      { isActive = true, operationalCostPerHour = 15,
        placeable = { getOwnerFarmId = function() return 0 end } },   -- spectator owner
    },
  } }
  fi.deductFundsVanilla = function(_self, cost, farmId) charged[#charged + 1] = farmId end
  g_currentMission = { player = nil }

  fi:chargeHourlyCosts(1)
  T.eq('red.unresolvableOwnerIsSkipped', #charged, 0)
end

-- 3. THE DEDUCTION USES THE GIVEN FARM, NEVER THE VIEWER'S.
do
  g_currentMission = { player = { getOwnerFarmId = function() return 9 end }, money = {} }
  function g_currentMission:addMoney(amount, farmId, mtype, _a, _b)
    self.money[#self.money + 1] = { amount = amount, farmId = farmId, mtype = mtype }
  end
  MoneyType = { OTHER = 7 }

  local fi = setmetatable({ isInitialized = true }, { __index = FinanceIntegration })
  fi:deductFundsVanilla(100, 5)
  T.eq('deduct.chargesTheGivenFarm', g_currentMission.money[1].farmId, 5)
  T.eq('deduct.amountIsNegative', g_currentMission.money[1].amount, -100)
  T.eq('deduct.usesMoneyTypeOther', g_currentMission.money[1].mtype, 7)

  -- The spectator farm (0) is rejected by addMoney; the deduction skips it.
  g_currentMission.money = {}
  fi:deductFundsVanilla(100, 0)
  T.eq('deduct.skipsSpectatorFarm', #g_currentMission.money, 0)

  -- No farm at all: skip, never a crash.
  g_currentMission.money = {}
  fi:deductFundsVanilla(100, nil)
  T.eq('deduct.skipsNilFarm', #g_currentMission.money, 0)
end

T.summary()
