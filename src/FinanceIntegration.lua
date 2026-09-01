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

FinanceIntegration = FinanceIntegration or {}
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
--- SCS-037: `elapsedHours` is how many in-game hours this tick stands for. The
--- pump ran for all of them, so the running cost is charged for all of them.
--- Defaults to 1, which is arithmetically identical to what shipped.
---
--- THE WATER AND THE MONEY ARE NOW ON THE SAME CLOCK, which is the point: the
--- moisture path already multiplied irrigation GAIN by the elapsed count, so
--- leaving the charge at one hour would hand a player 72 hours of free water.
---@param elapsedHours number|nil
---@param servedHoursBySystem table|nil  SCS-023: when the finite planner's served
---   map is present, charge getEffectiveCostPerHour * servedHours per system even
---   if the endpoint schedule left the system inactive. nil keeps isActive * hours.
function FinanceIntegration:chargeHourlyCosts(elapsedHours, servedHoursBySystem)
    if not self.isInitialized then return end
    local irrMgr = self.manager.irrigationManager
    if irrMgr == nil then return end

    local hours = math.max(1, math.floor(tonumber(elapsedHours) or 1))

    -- Respect the irrigation costs setting (costsEnabled == false means player disabled costs)
    -- nil means the flag was never set (default = costs enabled); only skip on explicit false.
    if irrMgr.costsEnabled == false then return end

    for _, system in pairs(irrMgr.systems) do
        -- SCS-046: fitted pivots settle water AND cost through the fractional
        -- active-hour path (settleFittedSystem), never this legacy whole-hour
        -- pass. Unfitted systems keep the exact incumbent behaviour.
        -- SCS-023: charge from the served-hours map when present, even for a
        -- system the endpoint schedule left inactive this hour.
        if system.isActive and not (system.rainKeyFitted == true) then
            local servedHours = nil
            if servedHoursBySystem ~= nil then
                servedHours = servedHoursBySystem[system.id]
            end
            local chargeHours = servedHours ~= nil and servedHours or hours
            -- [SCS-038] Deduct the PRICED draw: the effective cost varies with
            -- the water actually drawn (base / pressure, plus the neutral LIFT
            -- term). Falls back to the flat per-hour number when the getter is
            -- absent or nil, so an unregistered edge never crashes the charge.
            local effCost = nil
            if type(irrMgr.getEffectiveCostPerHour) == "function" then
                effCost = irrMgr:getEffectiveCostPerHour(system)
            end
            -- F158: the water bill goes to the OWNER of the system's placeable,
            -- resolved at charge time, never the local player. A dedicated server
            -- has no local player, so the old read billed nobody all season; a
            -- listen server billed every system on the map to the host, so the
            -- farmer paid for his neighbours' pivots. The placeable is the truth:
            -- a pivot belongs to whoever owns it (the base game charges water the
            -- same way, PlaceableHusbandryWater with self:getOwnerFarmId()).
            local farmId = nil
            if system.placeable ~= nil and type(system.placeable.getOwnerFarmId) == "function" then
                farmId = system.placeable:getOwnerFarmId()
            end
            if farmId and farmId ~= 0 then
                self:deductFundsVanilla((effCost or (system.operationalCostPerHour or 0)) * chargeHours, farmId)
            end
        end
    end
end

-- Deduct operational cost via the vanilla FS25 fund system, charging the farm
-- the system belongs to. The farm is always passed in; it is never derived from
-- the local player (F158).
function FinanceIntegration:deductFundsVanilla(cost, farmId)
    if g_currentMission == nil then return end
    local moneyType = (MoneyType ~= nil and MoneyType.OTHER) or 0
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