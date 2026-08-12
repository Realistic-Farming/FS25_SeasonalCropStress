-- ============================================================
-- FinanceIntegration.lua
-- Handles operational costs for irrigation. Deduction goes through the vanilla
-- FS25 fund system and nowhere else.
--
-- F154: THE USEDPLUS WEAR BRIDGE IS RETIRED, not deferred. It read equipment
-- condition out of UsedPlus DNA to scale irrigation flow, and it never returned
-- anything: DNA tracks vehicles, irrigation systems are placeables, so the read
-- was always 0.0 and the wear factor was always a multiply by one. The bridge was
-- correctly built (runtime-detected, read-only, neutral when absent) and that is
-- exactly why nobody noticed. Not-needed and not-working look identical from
-- outside a defensive fallback.
--
-- Arissani's ruling of 2026-08-08 puts wear, money, repair and repair-button
-- reads from UsedPlus PERMANENTLY out of scope rather than deferred, with
-- AdvancedDamageSystem as the intended successor through its own design pass.
-- NOTHING HERE IS REPOINTED AT IT: repointing a dead probe at a live mod without
-- that pass is how a fallback chain becomes load-bearing with nobody deciding.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

FinanceIntegration = {}
FinanceIntegration.__index = FinanceIntegration

function FinanceIntegration.new(manager)
    local self = setmetatable({}, FinanceIntegration)
    self.manager = manager
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

    for _, system in pairs(irrMgr.systems) do
        if system.isActive then
            -- [SCS-038] Deduct the PRICED draw: the effective cost varies with
            -- the water actually drawn (base / pressure, plus the neutral LIFT
            -- term). Falls back to the flat per-hour number when the getter is
            -- absent or nil, so an unregistered edge never crashes the charge.
            local effCost = nil
            if type(irrMgr.getEffectiveCostPerHour) == "function" then
                effCost = irrMgr:getEffectiveCostPerHour(system)
            end
            self:deductFundsVanilla((effCost or (system.operationalCostPerHour or 0)) * hours)
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


function FinanceIntegration:delete()
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.unsubscribeAll(self)
    end
    self.isInitialized = false
end