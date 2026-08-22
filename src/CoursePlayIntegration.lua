-- ============================================================
-- CoursePlayIntegration.lua
-- Optional integration with CoursePlay for FS25.
--
-- Detects CoursePlay presence and reads vehicle activity to
-- enrich crop stress alerts with context about which stressed
-- fields are currently being worked by autonomous vehicles.
--
-- This integration is READ-ONLY. We never start, stop, or
-- redirect CoursePlay vehicles. We only report status to the
-- player via the Crop Consultant alert system.
--
-- Detection global: g_Courseplay (capital P — confirmed FS25 source)
-- NOTE: FS22 used g_courseplay (lowercase). FS25 uses g_Courseplay.
--
-- Vehicle API used (confirmed from CpAIWorker.lua specialization):
--   vehicle:getIsCpActive()    → bool: CP job currently running
--   vehicle:hasCourse()        → bool: vehicle has an assigned course
--
-- Vehicle position: getWorldTranslation(vehicle.rootNode) → x, y, z
-- Field position matching uses g_currentMission.fieldManager:getFields()
-- and compares against each field's boundary with a radius fallback.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

CoursePlayIntegration = CoursePlayIntegration or {}
CoursePlayIntegration.__index = CoursePlayIntegration

-- Radius (metres) used to associate a vehicle with a field when
-- precise field boundary data is not available on the field object.
CoursePlayIntegration.FIELD_MATCH_RADIUS = 75

-- ============================================================
-- CONSTRUCTOR
-- ============================================================
function CoursePlayIntegration.new(manager)
    local self = setmetatable({}, CoursePlayIntegration)
    self.manager       = manager
    self.cpActive      = false     -- set by CropStressManager:detectOptionalMods()
    self.isInitialized = false

    -- Cache: fieldId → vehicle count; refreshed each hourly tick
    self.vehiclesPerField  = {}
    self.totalActiveVehicles = 0

    return self
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function CoursePlayIntegration:initialize()
    self.isInitialized = true
    if not self.cpActive then
        csLog("CoursePlayIntegration: CoursePlay not detected — running without CP context")
        return
    end
    csLog("CoursePlayIntegration: active — CP vehicle activity will appear in stress alerts")
end

-- ============================================================
-- ACTIVATION
-- Called by CropStressManager:detectOptionalMods().
-- ============================================================
function CoursePlayIntegration:enableCoursePlayMode()
    self.cpActive = true
end

-- ============================================================
-- IS ACTIVE
-- ============================================================
function CoursePlayIntegration:isActive()
    return self.cpActive and self.isInitialized
end

-- ============================================================
-- HOURLY REFRESH
-- Scans all vehicles, counts CP-active ones, and maps them to
-- fields by world position. Called from CropStressManager:onHourlyTick().
-- ============================================================
function CoursePlayIntegration:hourlyRefresh()
    if not self:isActive() then return end
    if g_currentMission == nil then return end

    -- Reset counters
    self.vehiclesPerField    = {}
    self.totalActiveVehicles = 0

    local vehicles = g_currentMission.vehicles
    if vehicles == nil then return end

    -- Pre-fetch field list once (not every vehicle iteration)
    local fields = nil
    if g_currentMission.fieldManager ~= nil then
        local ok, result = pcall(function()
            return g_currentMission.fieldManager:getFields()
        end)
        if ok then fields = result end
    end

    for _, vehicle in pairs(vehicles) do
        if vehicle == nil then
            -- Sparse table may have nil entries; skip
        elseif type(vehicle.getIsCpActive) == "function" then
            local ok, isActive = pcall(function()
                return vehicle:getIsCpActive()
            end)
            if ok and isActive then
                self.totalActiveVehicles = self.totalActiveVehicles + 1
                -- Map to field
                local fieldId = self:getFieldForVehicle(vehicle, fields)
                if fieldId ~= nil then
                    self.vehiclesPerField[fieldId] = (self.vehiclesPerField[fieldId] or 0) + 1
                end
            end
        end
    end

    if self.manager and self.manager.debugMode then
        csLog(string.format("CoursePlayIntegration: %d active CP vehicles", self.totalActiveVehicles))
    end
end

-- ============================================================
-- FIELD LOOKUP FOR A VEHICLE
-- Returns the fieldId of the field the vehicle is currently in,
-- or nil if no match found. Uses bounding box when available,
-- falls back to centre-point + radius.
-- ============================================================
function CoursePlayIntegration:getFieldForVehicle(vehicle, fields)
    if vehicle.rootNode == nil then return nil end
    if fields == nil then return nil end

    local ok, vx, _, vz = pcall(function()
        return getWorldTranslation(vehicle.rootNode)
    end)
    if not ok then return nil end

    for _, field in pairs(fields) do
        if self:positionInField(field, vx, vz) then
            return field.farmland and field.farmland.id
        end
    end
    return nil
end

-- ============================================================
-- POSITION-IN-FIELD TEST
-- Uses bounding box from field object when present; falls back
-- to centre + radius approximation.
-- ============================================================
function CoursePlayIntegration:positionInField(field, x, z)
    -- Prefer axis-aligned bounding box if the field object exposes it
    if field.minX ~= nil and field.maxX ~= nil
    and field.minZ ~= nil and field.maxZ ~= nil then
        return (x >= field.minX and x <= field.maxX
            and z >= field.minZ and z <= field.maxZ)
    end

    -- Fallback: centre + configured radius
    local fx = field.posX
        or (field.startX and (field.startX + (field.widthX  or 0) * 0.5))
        or x + 999  -- no match if position is unknown
    local fz = field.posZ
        or (field.startZ and (field.startZ + (field.heightZ or 0) * 0.5))
        or z + 999
    local radius = field.fieldRadius or CoursePlayIntegration.FIELD_MATCH_RADIUS

    local dx = x - fx
    local dz = z - fz
    return (dx * dx + dz * dz) <= (radius * radius)
end

-- ============================================================
-- PUBLIC ACCESSORS
-- ============================================================

-- Total number of CoursePlay-active vehicles across the entire map.
function CoursePlayIntegration:getActiveVehicleCount()
    return self.totalActiveVehicles
end

-- Number of CP-active vehicles currently on a specific field.
-- Returns 0 if none.
function CoursePlayIntegration:getVehiclesOnField(fieldId)
    return self.vehiclesPerField[fieldId] or 0
end

-- Returns a snapshot of {fieldId → vehicleCount} for all fields
-- that have at least one active CP vehicle.
function CoursePlayIntegration:getVehiclesOnStressedFields()
    if not self:isActive() then return {} end

    local result = {}
    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil then return result end

    local critThreshold = (self.manager.soilSystem.getCriticalMoisture ~= nil)
        and self.manager.soilSystem:getCriticalMoisture()
        or 0.30  -- fallback to conservative threshold

    for fieldId, vehicleCount in pairs(self.vehiclesPerField) do
        if vehicleCount > 0 then
            local moisture = soilSystem:getMoisture(fieldId)
            if moisture ~= nil and moisture <= critThreshold * 1.5 then
                -- Include fields that are stressed or approaching stress
                result[fieldId] = vehicleCount
            end
        end
    end

    return result
end

-- Returns a short localised context string for alert messages.
-- Returns nil when CoursePlay is inactive or no vehicles are relevant.
function CoursePlayIntegration:getContextForField(fieldId)
    if not self:isActive() then return nil end

    local count = self:getVehiclesOnField(fieldId)
    if count == 0 then return nil end

    -- getText() returns the key itself when a translation is missing — the standard FS25 pattern.
    -- Falling back to hardcoded English ensures players never see a raw "cs_cp_..." key.
    local key = (count == 1) and "cs_cp_vehicle_on_field" or "cs_cp_vehicles_on_field"
    if g_i18n ~= nil then
        local template = g_i18n:getText(key)
        if template ~= nil and template ~= key then
            return string.format(template, count)
        end
    end
    return string.format(count == 1
        and "CoursePlay: %d vehicle on this field"
        or  "CoursePlay: %d vehicles on this field", count)
end

-- ============================================================
-- CLEANUP
-- ============================================================
function CoursePlayIntegration:delete()
    self.vehiclesPerField    = {}
    self.totalActiveVehicles = 0
    self.isInitialized       = false
end
