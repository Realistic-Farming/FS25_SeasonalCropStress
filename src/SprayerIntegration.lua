-- ============================================================
-- SprayerIntegration.lua
-- Detects when a vehicle-based sprayer applies water to a field.
-- Intercepts Sprayer:processSprayerArea to add moisture.
-- ============================================================

SprayerIntegration = {}
SprayerIntegration.__index = SprayerIntegration

-- Scaling factor: how much 1 liter of water adds to 1 sqm of moisture fraction.
-- 1mm of water = 1 liter/sqm.
-- If 1mm = 0.0024 moisture fraction (from rain balance), then:
SprayerIntegration.MOISTURE_PER_LITER_PER_SQM = 0.0024

function SprayerIntegration.new(manager)
    local self = setmetatable({}, SprayerIntegration)
    self.manager = manager
    self.isInitialized = false
    return self
end

function SprayerIntegration:initialize()
    if self.isInitialized then return end

    -- Hook into Sprayer:processSprayerArea to intercept water application
    if Sprayer ~= nil and type(Sprayer.processSprayerArea) == "function" then
        Sprayer.processSprayerArea = Utils.overwrittenFunction(Sprayer.processSprayerArea, SprayerIntegration.overwrittenProcessSprayerArea)
        print("[CropStress] SprayerIntegration: Hooked Sprayer.processSprayerArea")
    end

    self.isInitialized = true
end

function SprayerIntegration.overwrittenProcessSprayerArea(self, superFunc, workArea, dt)
    -- Run original function and capture area changed
    local changedArea, totalArea = superFunc(self, workArea, dt)

    -- If no area was changed or we're not the server, nothing more to do
    if changedArea <= 0 or not self.isServer then
        return changedArea, totalArea
    end

    -- Sector irrigators (Rainstar play kit) are watered by
    -- IrrigatorSectorIntegration, which models the real pie sector. Letting the
    -- rectangle work area ALSO credit moisture would double-count the same water.
    if IrrigatorSectorIntegration ~= nil
            and self.typeName ~= nil
            and IrrigatorSectorIntegration.VEHICLE_TYPES[self.typeName] == true then
        return changedArea, totalArea
    end

    local spec = self.spec_sprayer
    if spec == nil or spec.workAreaParameters == nil then
        return changedArea, totalArea
    end

    -- Check if we are spraying WATER
    local fillType = spec.workAreaParameters.sprayFillType
    if fillType == nil or fillType == FillType.UNKNOWN then
        return changedArea, totalArea
    end

    -- Ensure we have the WATER fill type index. Cache it for performance.
    if SprayerIntegration.WATER_FILL_TYPE == nil then
        SprayerIntegration.WATER_FILL_TYPE = g_fillTypeManager:getFillTypeIndexByName("WATER")
    end

    if fillType == SprayerIntegration.WATER_FILL_TYPE then
        -- AI buy-mode detection: detect AI helper with buy-mode enabled
        -- and inject computed usage so the moisture guard passes.
        -- Base-game helpers (getIsAIActive) and CoursePlay specs covered.
        local isAI = false
        if type(self.getIsAIActive) == "function" then
            isAI = self:getIsAIActive()
        end
        if not isAI and self.spec_aiVehicle ~= nil then isAI = true end
        if not isAI and self.spec_aiJobVehicle ~= nil then isAI = true end

        local isFieldWork = false
        if g_currentMission ~= nil and type(g_currentMission.getIsFieldWorkActive) == "function" then
            isFieldWork = g_currentMission:getIsFieldWorkActive(self)
        end

        local speed = self.lastSpeedReal or 0
        local isMoving = speed > 0.5

        local isBuyMode = false
        if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
            local mi = g_currentMission.missionInfo
            if mi.helperBuyFertilizer == true or mi.helperManureSource == 2 or mi.helperSlurrySource == 2 then
                isBuyMode = true
            end
        end

        if isAI and isFieldWork and isMoving and isBuyMode then
            local workWidth = (spec.workAreaParameters ~= nil and spec.workAreaParameters.width) or 3.0
            local sprayCapacity = (spec.sprayFillType ~= nil and spec.sprayFillTypeCapacity) or 1000
            local litersPerSecond = (sprayCapacity / 1000) * 0.1
            local computedUsage = speed * workWidth * litersPerSecond
            spec.workAreaParameters.usage = computedUsage
            spec.workAreaParameters.sprayFillLevel = 1.0
            spec.workAreaParameters.sprayFillType = FillType.WATER
        end

        -- Calculate moisture gain based on usage
        -- usage is in liters per dt
        local usage = spec.workAreaParameters.usage or 0
        if usage > 0 then
            -- Determine field at the start point of the work area
            local sx, _, sz = getWorldTranslation(workArea.start)
            local farmland = g_farmlandManager:getFarmlandAtWorldPosition(sx, sz)
            if farmland ~= nil then
                local fieldId = farmland.id
                local soilSystem = g_cropStressManager and g_cropStressManager.soilSystem
                if soilSystem ~= nil then
                    -- How much moisture to add?
                    -- 1 liter over 'totalArea' sqm.
                    -- Gain = (usage / totalArea) * MOISTURE_PER_LITER_PER_SQM
                    -- But wait, changedArea is better for actual application.
                    local area = math.max(1.0, totalArea) -- avoid div by zero
                    local gain = (usage / area) * SprayerIntegration.MOISTURE_PER_LITER_PER_SQM

                    -- Scale it up to make it a viable alternative (e.g. 5x more effective for gameplay)
                    gain = gain * 5.0

                    local current = soilSystem:getMoisture(fieldId)
                    if current ~= nil then
                        local newMoisture = math.min(1.0, current + gain)
                        -- SCS-018: water lands on the place, not the whole field.
                        -- Route through the single per-cell write path so the
                        -- cell materialises and the aggregate follows honestly.
                        soilSystem:applyWaterAtCell(fieldId, sx, sz, gain)

                        if g_cropStressManager.debugMode then
                            print(string.format("[CropStress] Sprayer water applied to Field %d @(%.1f,%.1f): +%.4f moisture (usage=%.2f area=%.1f)", fieldId, sx, sz, gain, usage, area))
                        end
                    end
                end
            end
        end
    end

    return changedArea, totalArea
end

function SprayerIntegration:delete()
    -- Note: Overwritten functions cannot be easily "un-overwritten" without
    -- storing the original, which Utils.overwrittenFunction doesn't return
    -- to us. But we don't need to as the mod is being destroyed.
    self.isInitialized = false
end
