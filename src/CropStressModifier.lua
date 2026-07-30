-- ============================================================
-- CropStressModifier.lua
-- Tracks accumulated yield stress per field and hooks into the
-- harvesting pipeline to reduce yield proportionally.
--
-- Stress accumulates each in-game hour when:
--   • The field has a crop in a "critical growth window" AND
--   • Soil moisture is below the crop's criticalMoisture threshold
--
-- At harvest, yield is reduced by: stress * MAX_YIELD_LOSS (default 60%)
--
-- HARVEST HOOK IMPLEMENTATION NOTES:
--   Uses Utils.overwrittenFunction on HarvestingMachine.doGroundWorkArea.
--   This intercepts before+after fill levels and removes the stress
--   portion. If two mods both overwrite this function, the last one loaded
--   wins — flag this in modDesc.xml compatibility notes if needed.
--   Verify exact function signature against LUADOC before testing.
-- ============================================================

CropStressModifier = {}
CropStressModifier.__index = CropStressModifier

-- Maximum yield reduction at stress = 1.0 (full stress).
--
-- 0.30 is the GENTLE END of the existing 0.30-0.75 settings clamp, ruled by Arissani
-- 2026-07-30 when the harvest hook was found never to have installed. Every balance
-- observation ever made about this mod was made with the penalty inert, so the old
-- 0.60 describes a system nobody has actually played. Shipping the repair at the
-- gentle end avoids a surprise tax on existing saves mid-season; the full value is
-- routed to the suite balance pass, where it rises with every other magnitude
-- considered together rather than alone. This is a DEFAULT, not new machinery.
CropStressModifier.MAX_YIELD_LOSS = 0.30

-- Crop stress configuration (matches cropStressDefaults.xml)
-- key = lowercase fruit type name as returned by FS25 field:getFruitType().name
CropStressModifier.CROP_WINDOWS = {
    -- Base game crops
    wheat        = { stages = {3,4,5},   criticalMoisture = 0.35, stressRatePerHour = 0.003 },
    barley       = { stages = {3,4,5},   criticalMoisture = 0.30, stressRatePerHour = 0.003 },
    corn         = { stages = {4,5},     criticalMoisture = 0.40, stressRatePerHour = 0.006 },
    canola       = { stages = {2,3},     criticalMoisture = 0.45, stressRatePerHour = 0.005 },
    sunflower    = { stages = {3,4,5},   criticalMoisture = 0.30, stressRatePerHour = 0.002 },
    soybeans     = { stages = {4,5},     criticalMoisture = 0.40, stressRatePerHour = 0.004 },
    sugarbeet    = { stages = {2,3,4},   criticalMoisture = 0.50, stressRatePerHour = 0.005 },
    potato       = { stages = {2,3,4},   criticalMoisture = 0.55, stressRatePerHour = 0.006 },
    -- Small grains
    oat          = { stages = {3,4,5},   criticalMoisture = 0.30, stressRatePerHour = 0.003 },
    rye          = { stages = {3,4,5},   criticalMoisture = 0.25, stressRatePerHour = 0.002 },
    spelt        = { stages = {3,4,5},   criticalMoisture = 0.35, stressRatePerHour = 0.003 },
    triticale    = { stages = {3,4,5},   criticalMoisture = 0.30, stressRatePerHour = 0.003 },
    -- Drought-tolerant row crops
    sorghum      = { stages = {3,4,5},   criticalMoisture = 0.25, stressRatePerHour = 0.002 },
    millet       = { stages = {3,4,5},   criticalMoisture = 0.25, stressRatePerHour = 0.002 },
    -- High-water row crops
    rice         = { stages = {3,4,5},   criticalMoisture = 0.70, stressRatePerHour = 0.008 },
    sugarcane    = { stages = {3,4,5},   criticalMoisture = 0.55, stressRatePerHour = 0.006 },
    cotton       = { stages = {3,4,5},   criticalMoisture = 0.45, stressRatePerHour = 0.005 },
    -- Legumes
    pintobean    = { stages = {3,4},     criticalMoisture = 0.40, stressRatePerHour = 0.004 },
    pea          = { stages = {2,3},     criticalMoisture = 0.40, stressRatePerHour = 0.004 },
    lentil       = { stages = {2,3},     criticalMoisture = 0.35, stressRatePerHour = 0.003 },
    -- Forage & cover crops
    alfalfa      = { stages = {2,3,4},   criticalMoisture = 0.45, stressRatePerHour = 0.004 },
    clover       = { stages = {2,3},     criticalMoisture = 0.45, stressRatePerHour = 0.003 },
    grass        = { stages = {1,2,3},   criticalMoisture = 0.35, stressRatePerHour = 0.002 },
    buckwheat    = { stages = {2,3,4},   criticalMoisture = 0.40, stressRatePerHour = 0.004 },
    -- Industrial / specialty
    hemp         = { stages = {2,3,4},   criticalMoisture = 0.45, stressRatePerHour = 0.004 },
    miscanthus   = { stages = {2,3,4},   criticalMoisture = 0.30, stressRatePerHour = 0.002 },
    poplar       = { stages = {2,3},     criticalMoisture = 0.40, stressRatePerHour = 0.003 },
    mint         = { stages = {2,3,4},   criticalMoisture = 0.55, stressRatePerHour = 0.005 },
    -- Root vegetables
    onion        = { stages = {2,3,4},   criticalMoisture = 0.50, stressRatePerHour = 0.005 },
    carrot       = { stages = {2,3,4},   criticalMoisture = 0.45, stressRatePerHour = 0.004 },
    beetroot     = { stages = {2,3,4},   criticalMoisture = 0.50, stressRatePerHour = 0.005 },
    parsnip      = { stages = {2,3,4},   criticalMoisture = 0.45, stressRatePerHour = 0.004 },
    -- Leafy / pod vegetables
    spinach      = { stages = {1,2,3},   criticalMoisture = 0.50, stressRatePerHour = 0.005 },
    greenbean    = { stages = {2,3,4},   criticalMoisture = 0.45, stressRatePerHour = 0.004 },
}

-- Whether the harvest hook has been installed (static flag, module-level)
CropStressModifier.harvestHookInstalled = false

-- ============================================================
-- LOGGING HELPER
-- g_logManager may be nil during early load; fall back to print().
-- ============================================================
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

function CropStressModifier.new(manager)
    local self = setmetatable({}, CropStressModifier)
    self.manager = manager

    -- Per-field accumulated stress: fieldId → float (0.0–1.0)
    self.fieldStress = {}

    -- Per-field last seen fruitTypeIndex: fieldId → int
    -- Used to detect when a new crop is planted after harvest so that
    -- accumulated stress from the previous crop does not bleed into the new one.
    self.lastFruitTypeIndex = {}

    -- When FS25_RealisticWeather is present, its getHarvestScaleMultiplier hook
    -- handles the yield penalty. We skip our Cutter.processCutterArea reduction
    -- to avoid stacking. Stress still accumulates for HUD display.
    self.rwModeActive = false

    -- External multiplier applied on top of settings rateMultiplier.
    -- Set by CropStressManager when FS25_RandomWorldEvents is active.
    self.rweMultiplier = 1.0

    self.isInitialized = false
    return self
end

function CropStressModifier:initialize()
    self.isInitialized = true
end

-- ============================================================
-- HOURLY STRESS ACCUMULATION
-- Called by CropStressManager:onHourlyTick()
-- ============================================================
function CropStressModifier:hourlyUpdate()
    if not self.isInitialized then return end
    if g_currentMission == nil or g_currentMission.fieldManager == nil then return end

    local soilSystem = self.manager.soilSystem
    if soilSystem == nil then return end

    -- Use the manager's pre-built fieldId→field map (built in lateInitialize).
    -- Avoids rebuilding it every hour and eliminates the getFieldByIndex trap:
    -- getFieldByIndex(n) returns fields[n] (array index), NOT the field with fieldId==n.
    local fieldById = (self.manager ~= nil) and self.manager.fieldById or {}

    for fieldId, data in pairs(soilSystem.fieldData) do
        local field = fieldById[fieldId]
        if field ~= nil then
            self:processFieldStress(field, fieldId, data.moisture)
        end
        -- If field not in map this tick, skip silently — map will be rebuilt on next lateInitialize
    end
end

function CropStressModifier:processFieldStress(field, fieldId, moisture)
    -- FS25 confirmed API: field.fieldState.fruitTypeIndex / field.fieldState.growthState
    -- (field:getFieldState(), field:getGrowthState(), field.fruitType do NOT exist in FS25)
    local fieldState = field.fieldState
    if fieldState == nil then return end

    local fruitTypeIndex = fieldState.fruitTypeIndex
    if fruitTypeIndex == nil or fruitTypeIndex == 0 then
        -- No crop on this field — reset any accumulated stress so next season starts clean
        if (self.fieldStress[fieldId] or 0) > 0 then
            self.fieldStress[fieldId] = 0
            if self.manager ~= nil and self.manager.debugMode then
                csLog(string.format("Field %d: no crop — stress reset to 0", fieldId))
            end
        end
        -- Clear the last-seen crop index so the next planting is treated as fresh
        self.lastFruitTypeIndex[fieldId] = nil
        return
    end

    -- Detect crop change: player planted a new crop after harvest.
    -- The old fruitTypeIndex → new fruitTypeIndex transition means any stress
    -- accumulated for the previous crop must not carry over to the new one.
    local lastIndex = self.lastFruitTypeIndex[fieldId]
    if lastIndex ~= nil and lastIndex ~= fruitTypeIndex then
        local prevStress = self.fieldStress[fieldId] or 0
        self.fieldStress[fieldId] = 0
        if self.manager ~= nil and self.manager.debugMode then
            csLog(string.format(
                "Field %d: crop changed (fti %d → %d) — stress reset from %.3f to 0",
                fieldId, lastIndex, fruitTypeIndex, prevStress
            ))
        end
    end
    self.lastFruitTypeIndex[fieldId] = fruitTypeIndex

    local fruitType = g_fruitTypeManager ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return end

    -- FS25 fruit names are uppercase ("WHEAT", "BARLEY"). CROP_WINDOWS keys are lowercase.
    local cropName = fruitType.name:lower()
    local window = CropStressModifier.CROP_WINDOWS[cropName]
    if window == nil then return end

    local growthState = fieldState.growthState or 0
    if growthState == 0 then return end

    -- Check if in a critical growth window
    local inCriticalWindow = false
    for _, s in ipairs(window.stages) do
        if growthState == s then
            inCriticalWindow = true
            break
        end
    end
    if not inCriticalWindow then return end

    -- Below critical moisture threshold → accumulate stress
    if moisture < window.criticalMoisture then
        local deficit      = window.criticalMoisture - moisture
        local deficitRatio = deficit / window.criticalMoisture
        local rateMultiplier = (self.rateMultiplier or 1.0) * (self.rweMultiplier or 1.0)
        local stressIncrease = window.stressRatePerHour * deficitRatio * rateMultiplier

        local prev = self.fieldStress[fieldId] or 0.0
        self.fieldStress[fieldId] = math.min(1.0, prev + stressIncrease)

        if self.manager ~= nil and self.manager.debugMode then
            csLog(string.format(
                "Stress Field %d (%s stage %d): +%.4f → total %.3f (moisture %.1f%% < %.0f%%)",
                fieldId, cropName, growthState, stressIncrease,
                self.fieldStress[fieldId], moisture * 100, window.criticalMoisture * 100
            ))
        end
    end
end

-- ============================================================
-- GETTERS
-- ============================================================
function CropStressModifier:getStress(fieldId)
    return self.fieldStress[fieldId] or 0.0
end

function CropStressModifier:resetStress(fieldId)
    self.fieldStress[fieldId] = 0.0
    self.lastFruitTypeIndex[fieldId] = nil
end

-- Returns estimated yield impact as a display string, e.g. "-18%".
-- Uses the instance method (not the class constant) so the player's
-- configured max yield loss setting is reflected in dialog display.
function CropStressModifier:getYieldImpactString(fieldId)
    local stress = self:getStress(fieldId)
    local loss = stress * self:getMaxYieldLoss() * 100
    if loss < 0.5 then return "0%" end
    return string.format("-%.0f%%", loss)
end

-- ============================================================
-- POSITION → FIELD ID HELPER
-- FS25 confirmed pattern: g_farmlandManager:getFarmlandAtWorldPosition(x, z)
-- returns the farmland object; farmland.id is the field identifier.
-- (field:containsPoint() does not exist in FS25.)
-- ============================================================
function CropStressModifier.getFieldIdAtPosition(x, z)
    if g_farmlandManager == nil then return nil end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    return farmland and farmland.id or nil
end

-- ============================================================
-- HARVEST HOOK INSTALLATION
-- Called from main.lua at module-load time (before vehicles exist).
--
-- FS25 harvest flow (confirmed from SDK):
--   Cutter:processCutterArea(workArea, dt)
--     → calls FSDensityMapUtil.cutFruitArea  (removes crop from density map)
--     → calls g_currentMission:getHarvestScaleMultiplier(...)
--     → stores: spec.workAreaParameters.lastMultiplierArea += area * multiplier
--   Combine reads lastMultiplierArea each update and calls addFillUnitFillLevel
--
-- We hook processCutterArea and scale lastMultiplierArea by our stress keep-factor.
-- This is equivalent to reducing yield — the combine receives less grain per pass.
--
-- HarvestingMachine does NOT exist in FS25. setFillUnitFillLevel does NOT exist.
-- ============================================================
function CropStressModifier.installHarvestHook()
    if CropStressModifier.harvestHookInstalled then return end
    if Cutter == nil then
        csLog("Cutter specialization not found — harvest hook skipped")
        return
    end
    if Cutter.processCutterArea == nil then
        csLog("Cutter.processCutterArea not found — harvest hook skipped")
        return
    end

    Cutter.processCutterArea = Utils.overwrittenFunction(
        Cutter.processCutterArea,
        function(self, superFunc, workArea, dt)
            -- Capture accumulated multiplier area before this cut pass
            local spec = self.spec_cutter
            local multAreaBefore = spec ~= nil and spec.workAreaParameters ~= nil
                and spec.workAreaParameters.lastMultiplierArea or 0

            local lastArea, totalArea = superFunc(self, workArea, dt)

            -- No area cut this pass, or manager not ready — nothing to do
            if lastArea == nil or lastArea <= 0 then return lastArea, totalArea end
            if g_cropStressManager == nil or not g_cropStressManager.isInitialized then
                return lastArea, totalArea
            end

            local stressModifier = g_cropStressManager.stressModifier

            -- RW mode: RW's getHarvestScaleMultiplier handles yield; we step aside
            if stressModifier.rwModeActive then return lastArea, totalArea end

            -- Identify field from the cut position
            local xs, _, zs = getWorldTranslation(workArea.start)
            local fieldId = CropStressModifier.getFieldIdAtPosition(xs, zs)
            if fieldId == nil then return lastArea, totalArea end

            local stress = stressModifier:getStress(fieldId)
            if stress <= 0.01 then return lastArea, totalArea end

            -- Scale the grain added during this pass.
            -- lastMultiplierArea was incremented by superFunc; we reduce that delta.
            if spec ~= nil and spec.workAreaParameters ~= nil then
                local maxLoss    = stressModifier:getMaxYieldLoss()
                local keepFactor = 1.0 - (stress * maxLoss)
                local added = spec.workAreaParameters.lastMultiplierArea - multAreaBefore
                if added > 0 then
                    spec.workAreaParameters.lastMultiplierArea = multAreaBefore + added * keepFactor
                end

                if g_cropStressManager.debugMode then
                    csLog(string.format(
                        "Harvest field %d: stress=%.2f → yield reduced by %.0f%%",
                        fieldId, stress, (1.0 - keepFactor) * 100
                    ))
                end
            end

            return lastArea, totalArea
        end
    )

    CropStressModifier.harvestHookInstalled = true
    csLog("Harvest yield hook installed on Cutter.processCutterArea")
end

function CropStressModifier:delete()
    self.isInitialized = false
    -- Note: the harvest hook patch cannot be uninstalled without storing the original.
    -- On mod reload, the whole game restarts so this is not a concern.
end

-- Enable/disable RW integration mode (called by CropStressManager:detectOptionalMods)
function CropStressModifier:setRWMode(active)
    self.rwModeActive = active == true
    if self.rwModeActive then
        csLog("CropStressModifier: RW mode active — harvest yield penalty deferred to RW")
    end
end

-- Set stress rate multiplier from settings
function CropStressModifier:setRateMultiplier(multiplier)
    self.rateMultiplier = multiplier or 1.0
end

-- Set external multiplier from FS25_RandomWorldEvents active events.
-- Layered on top of rateMultiplier; reset to 1.0 when no event is active.
function CropStressModifier:setRWEMultiplier(multiplier)
    self.rweMultiplier = multiplier or 1.0
end

-- Set maximum yield loss from settings
function CropStressModifier:setMaxYieldLoss(loss)
    self.maxYieldLoss = math.max(0.30, math.min(0.75, loss or CropStressModifier.MAX_YIELD_LOSS))
end

-- Override MAX_YIELD_LOSS for settings compatibility
function CropStressModifier:getMaxYieldLoss()
    return self.maxYieldLoss or CropStressModifier.MAX_YIELD_LOSS
end