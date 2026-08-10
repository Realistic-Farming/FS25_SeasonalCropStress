-- ============================================================
-- FinanceIntegration.lua
-- Handles operational costs for irrigation.
-- Phase 2: simple fund deduction via updateFunds.
-- Phase 4: will integrate with UsedPlus.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

-- Primary path: g_currentMission.usedPlusAPI (UP v2.15.4.96+ — the only reliable
-- cross-mod path in FS25's sandboxed environment). Bare globals kept as fallbacks.
local function getUPAPI()
    return (g_currentMission and g_currentMission.usedPlusAPI) or UsedPlusAPI or g_usedPlusManager
end

FinanceIntegration = {}
FinanceIntegration.__index = FinanceIntegration

function FinanceIntegration.new(manager)
    local self = setmetatable({}, FinanceIntegration)
    self.manager = manager
    self.usedPlusActive = false  -- set by CropStressManager:detectOptionalMods()
    self.isInitialized  = false
    return self
end

function FinanceIntegration:initialize()
    self.isInitialized = true
end

--- SCS-037: `elapsedHours` is how many in-game hours this tick stands for. The
--- pump ran for all of them, so the running cost is charged for all of them.
--- Defaults to 1, which is arithmetically identical to what shipped.
---
--- THE WATER AND THE MONEY ARE NOW ON THE SAME CLOCK, which is the point: the
--- moisture path already multiplied irrigation GAIN by the elapsed count, so
--- leaving the charge at one hour would hand a player 72 hours of free water.
---@param elapsedHours number|nil
function FinanceIntegration:chargeHourlyCosts(elapsedHours)
    if not self.isInitialized then return end
    local irrMgr = self.manager.irrigationManager
    if irrMgr == nil then return end

    local hours = math.max(1, math.floor(tonumber(elapsedHours) or 1))

    -- Respect the irrigation costs setting (costsEnabled == false means player disabled costs)
    -- nil means the flag was never set (default = costs enabled); only skip on explicit false.
    if irrMgr.costsEnabled == false then return end

    for id, system in pairs(irrMgr.systems) do
        if system.isActive then
            -- Deduct operational cost via vanilla FS25 fund system.
            -- UsedPlus public API (UsedPlusAPI) does not expose recordExpense() —
            -- confirmed against UsedPlusAPI wiki. Costs always go through vanilla updateFunds.
            self:deductFundsVanilla((system.operationalCostPerHour or 0) * hours)

            -- Update wear level from UsedPlus DNA (if UsedPlus active).
            -- Placeables typically have no DNA entry, so this usually returns 0.0.
            -- IrrigationManager:activateSystem() scales flow by (1 - wearLevel * 0.3).
            if self.usedPlusActive then
                local wearLevel = self:getEquipmentWearLevel(id)
                irrMgr:updateSystemWearLevel(id, wearLevel)
            end
        end
    end
end

-- Deduct operational cost via the vanilla FS25 fund system.
function FinanceIntegration:deductFundsVanilla(cost)
    if g_currentMission == nil then return end
    local moneyType = (MoneyType ~= nil and MoneyType.OTHER) or 0
    local farmId = g_currentMission.player ~= nil and g_currentMission.player:getOwnerFarmId()
    -- Farm 0 is the spectator farm — addMoney rejects it. Skip if no valid farm.
    if not farmId or farmId == 0 then return end
    g_currentMission:addMoney(-cost, farmId, moneyType, true)
end

function FinanceIntegration:getEquipmentWearLevel(vehicleId)
    if not self.usedPlusActive then return 0.0 end

    -- Use getUPAPI() to reach g_currentMission.usedPlusAPI (v2.15.4.96+ primary path)
    -- with bare globals as fallback. Wrapped in pcall — API signature varies by version.
    -- Note: UsedPlus DNA tracks vehicles (tractors, combines). Irrigation systems are
    -- placeables and typically have no DNA entry, so dna will be nil → returns 0.0.
    local api = getUPAPI()
    local dna = nil
    if api ~= nil and api.getVehicleDNA ~= nil then
        local ok, result = pcall(api.getVehicleDNA, vehicleId)
        if ok then dna = result end
    end
    if dna == nil then return 0.0 end

    -- DNA reliability range: 0.6 (heavily worn) → 1.4 (new)
    -- Converted to wear level: 0.0 (new) → 1.0 (at limit)
    local reliability = dna.reliability
    if reliability == nil then return 0.0 end
    return math.max(0.0, math.min(1.0, (1.4 - reliability) / 0.8))
end

-- Enable UsedPlus mode - called by CropStressManager after detection.
-- With UsedPlus active: DNA wear tracking enabled (affects flow rate).
-- Operational costs always go through vanilla updateFunds (recordExpense not in public API).
function FinanceIntegration:enableUsedPlusMode()
    self.usedPlusActive = true
    csLog("FinanceIntegration: UsedPlus active — DNA wear tracking enabled")
end

function FinanceIntegration:delete()
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.unsubscribeAll(self)
    end
    self.isInitialized = false
end