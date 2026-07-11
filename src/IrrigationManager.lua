-- ============================================================
-- IrrigationManager.lua
-- Tracks all placed irrigation systems and water sources.
-- Handles registration, coverage detection, scheduling,
-- activation, and publishes irrigation gain events.
-- ============================================================

IrrigationManager = {}
IrrigationManager.__index = IrrigationManager

-- Constants
IrrigationManager.MAX_PUMP_DISTANCE = 500  -- meters
IrrigationManager.PRESSURE_FALLOFF  = 0.3  -- 30% loss at max distance

-- ============================================================
-- LOGGING HELPER
-- ============================================================
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ============================================================
-- POSITION HELPER
-- FS25 placeables have no getPosition() method.
-- Position is read via Giants engine getWorldTranslation() on the root node.
-- ============================================================
local function getPlaceablePosition(placeable)
    local node = placeable.rootNode or placeable.nodeId
    if node ~= nil then
        return getWorldTranslation(node)
    end
    -- Final fallback — placeable may store position directly on some versions
    return placeable.posX or 0, 0, placeable.posZ or 0
end

-- ============================================================
-- GEOMETRY HELPERS
-- ============================================================
-- Squared distance from point (px,pz) to segment (ax,az)-(bx,bz).
local function pointSegDistSq(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local len2 = dx * dx + dz * dz
    local t = 0.0
    if len2 > 0.0 then
        t = ((px - ax) * dx + (pz - az) * dz) / len2
        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    end
    local qx, qz = ax + t * dx, az + t * dz
    local ex, ez = px - qx, pz - qz
    return ex * ex + ez * ez
end

-- Even-odd (ray-cast) point-in-polygon test. vx/vz are 1..n vertex arrays.
-- The (vz[i] > pz) ~= (vz[j] > pz) guard means vz[j]-vz[i] is never 0 in the
-- division below, so horizontal edges can't divide by zero.
local function pointInPolygon(px, pz, vx, vz, n)
    local inside = false
    local j = n
    for i = 1, n do
        if ((vz[i] > pz) ~= (vz[j] > pz)) and
           (px < (vx[j] - vx[i]) * (pz - vz[i]) / (vz[j] - vz[i]) + vx[i]) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function IrrigationManager.new(manager)
    local self = setmetatable({}, IrrigationManager)
    self.manager = manager

    -- Systems keyed by placeableId
    self.systems = {}
    -- Water sources (pumps) keyed by placeableId
    self.waterSources = {}

    self.isInitialized = false
    return self
end

function IrrigationManager:initialize()
    self.isInitialized = true
    csLog("IrrigationManager initialized")
end

-- ============================================================
-- Water Source Registration
-- ============================================================
function IrrigationManager:registerWaterSource(placeable)
    local x, _, z = getPlaceablePosition(placeable)
    self.waterSources[placeable.id] = {
        id           = placeable.id,
        x            = x,
        z            = z,
        hasWater     = true,  -- Phase 2: always true; Phase 4: could be finite
        flowCapacity = placeable.waterFlowCapacity or 1000,
    }
    csLog(string.format("Water source %d registered at (%.1f, %.1f)", placeable.id, x, z))

    -- Re-connect any irrigation systems that registered before this pump was placed.
    -- Placement order (pivot first, then pump) would otherwise leave systems permanently
    -- disconnected since findNearestWaterSource() is only called once at system registration.
    local reconnected = 0
    for sysId, sys in pairs(self.systems) do
        if sys.waterSourceId == nil then
            local sourceId, dist = self:findNearestWaterSource(sys.x, sys.z)
            if sourceId ~= nil then
                sys.waterSourceId      = sourceId
                sys.distanceToSource   = dist
                sys.pressureMultiplier = self:calculatePressureMultiplier(dist)
                reconnected = reconnected + 1
                csLog(string.format("Irrigation system %d reconnected to water source %d (%.1f m)", sysId, sourceId, dist))
            end
        end
    end
    if reconnected > 0 then
        csLog(string.format("Reconnected %d irrigation system(s) after pump placement", reconnected))
    end
end

function IrrigationManager:deregisterWaterSource(placeableId)
    self.waterSources[placeableId] = nil
    -- Deactivate any irrigation systems that depended on this source
    for sysId, sys in pairs(self.systems) do
        if sys.waterSourceId == placeableId then
            self:deactivateSystem(sysId)
            sys.waterSourceId = nil
        end
    end
end

-- ============================================================
-- Irrigation System Registration
-- ============================================================
function IrrigationManager:registerIrrigationSystem(placeable)
    local x, _, z = getPlaceablePosition(placeable)
    local coveredFields = self:detectCoveredFields(placeable, x, z)

    -- Find nearest water source within range
    local waterSourceId, distance = self:findNearestWaterSource(x, z)
    local pressureMultiplier = 0
    if waterSourceId ~= nil then
        pressureMultiplier = self:calculatePressureMultiplier(distance)
    end

    local system = {
        id                     = placeable.id,
        type                   = placeable.irrigationType or "pivot",
        x                      = x,
        z                      = z,
        coveredFields          = coveredFields,
        waterSourceId          = waterSourceId,
        distanceToSource       = distance,
        pressureMultiplier     = pressureMultiplier,
        flowRatePerHour        = placeable.flowRatePerHour or 0.018,
        operationalCostPerHour = placeable.operationalCostPerHour or 15,
        wearLevel              = 0,  -- Phase 4
        schedule = {
            startHour  = placeable.defaultStartHour or 6,
            endHour    = placeable.defaultEndHour   or 10,
            activeDays = placeable.defaultActiveDays or {true, true, true, true, true, false, false},
        },
        isActive             = false,
        effectiveRatePerField = {},
    }

    self.systems[placeable.id] = system

    csLog(string.format(
        "Irrigation system %d (%s) registered, covers %d fields, water source %s (distance %.1f m, pressure %.0f%%)",
        placeable.id, system.type, #coveredFields,
        waterSourceId ~= nil and tostring(waterSourceId) or "none",
        distance or 0, (pressureMultiplier or 0) * 100
    ))
    if #coveredFields == 0 then
        csLog(string.format(
            "WARNING: system %d covers 0 fields — pivot at (%.1f, %.1f) radius=%.0f. " ..
            "Check pivot placement relative to field boundaries.",
            placeable.id, x, z, placeable.radius or 200
        ))
    end
end

function IrrigationManager:deregisterIrrigationSystem(placeableId)
    if self.systems[placeableId] ~= nil and self.systems[placeableId].isActive then
        self:deactivateSystem(placeableId)
    end
    self.systems[placeableId] = nil
end

-- ============================================================
-- Field Coverage Detection
-- ============================================================
function IrrigationManager:detectCoveredFields(placeable, cx, cz)
    local covered = {}

    -- Use g_fieldManager.fields directly — same source as SoilMoistureSystem and buildFieldMap.
    -- g_currentMission.fieldManager:getFields() returns empty at placeable placement time.
    if g_fieldManager == nil or g_fieldManager.fields == nil then return covered end
    local fields = g_fieldManager.fields

    if placeable.irrigationType == "pivot" then
        local radius = placeable.radius or 200
        for _, field in pairs(fields) do
            if self:fieldIntersectsCircle(field, cx, cz, radius) then
                local fid = field.farmland and field.farmland.id
                if fid ~= nil then table.insert(covered, fid) end
            end
        end
    elseif placeable.irrigationType == "drip" then
        local startX, _, startZ = placeable.startX or cx, 0, placeable.startZ or cz
        local endX, _, endZ = placeable.endX or (cx + 100), 0, placeable.endZ or cz
        local spacing = placeable.lineSpacing or 0.8
        for _, field in pairs(fields) do
            if self:fieldIntersectsDripLine(field, startX, startZ, endX, endZ, spacing) then
                local fid = field.farmland and field.farmland.id
                if fid ~= nil then table.insert(covered, fid) end
            end
        end
    end

    return covered
end

-- ============================================================
-- Field polygon (world space)
-- FS25 Field.polygonPoints holds scene-node ids, not coordinates — each
-- vertex world position comes from getWorldTranslation(node). Returns
-- vx, vz, n, or nil when the field has no usable polygon.
-- ============================================================
function IrrigationManager:getFieldPolygonWorld(field)
    local pts = field.polygonPoints
    if pts == nil then return nil end
    local n = #pts
    if n < 3 then return nil end
    local vx, vz = {}, {}
    for i = 1, n do
        local node = pts[i]
        if node == nil or node == 0 then return nil end
        local wx, _, wz = getWorldTranslation(node)
        vx[i] = wx
        vz[i] = wz
    end
    return vx, vz, n
end

-- Circle vs. field polygon intersection.
-- True when the pivot circle overlaps the field's actual boundary: the pivot
-- centre lies inside the polygon (large field enclosing the whole circle), or
-- the circle reaches any polygon edge. Falls back to an area-derived radius
-- around the label point if the field has no polygon nodes (not expected on
-- stock maps, but keeps a degenerate field from silently vanishing).
function IrrigationManager:fieldIntersectsCircle(field, cx, cz, radius)
    local vx, vz, n = self:getFieldPolygonWorld(field)
    if vx == nil then
        local fx, fz = field.posX, field.posZ
        if fx == nil or fz == nil then return false end
        local fr = math.sqrt(math.max(field.areaHa or 1, 0.01) * 10000 / math.pi)
        local dx, dz = cx - fx, cz - fz
        local reach = radius + fr
        return (dx * dx + dz * dz) <= (reach * reach)
    end

    local r2 = radius * radius
    if pointInPolygon(cx, cz, vx, vz, n) then return true end
    -- Circle reaches any field edge (also covers "a vertex is inside the circle").
    local j = n
    for i = 1, n do
        if pointSegDistSq(cx, cz, vx[i], vz[i], vx[j], vz[j]) <= r2 then
            return true
        end
        j = i
    end
    return false
end

-- Drip line vs. field polygon intersection.
-- True when either drip endpoint is inside the field, when a field vertex is
-- within half the row spacing of the line, or when either endpoint is that
-- close to a field edge. Spacing is tiny relative to a field, so an endpoint
-- landing inside the polygon is the dominant case.
function IrrigationManager:fieldIntersectsDripLine(field, startX, startZ, endX, endZ, spacing)
    local half = (spacing or 0) * 0.5
    local vx, vz, n = self:getFieldPolygonWorld(field)
    if vx == nil then
        local fx, fz = field.posX, field.posZ
        if fx == nil or fz == nil then return false end
        local fr = math.sqrt(math.max(field.areaHa or 1, 0.01) * 10000 / math.pi)
        local reach = fr + half
        return pointSegDistSq(fx, fz, startX, startZ, endX, endZ) <= (reach * reach)
    end

    if pointInPolygon(startX, startZ, vx, vz, n) then return true end
    if pointInPolygon(endX,   endZ,   vx, vz, n) then return true end

    local reach2 = half * half
    local j = n
    for i = 1, n do
        -- field vertex close to the drip line
        if pointSegDistSq(vx[i], vz[i], startX, startZ, endX, endZ) <= reach2 then
            return true
        end
        -- drip endpoints close to a field edge
        if pointSegDistSq(startX, startZ, vx[i], vz[i], vx[j], vz[j]) <= reach2 or
           pointSegDistSq(endX,   endZ,   vx[i], vz[i], vx[j], vz[j]) <= reach2 then
            return true
        end
        j = i
    end
    return false
end

-- ============================================================
-- Water Source Lookup
-- ============================================================
function IrrigationManager:findNearestWaterSource(x, z)
    local nearestId = nil
    local minDist   = math.huge

    for id, source in pairs(self.waterSources) do
        if source.hasWater then
            local dx   = source.x - x
            local dz   = source.z - z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= IrrigationManager.MAX_PUMP_DISTANCE and dist < minDist then
                minDist   = dist
                nearestId = id
            end
        end
    end

    if nearestId ~= nil then
        return nearestId, minDist
    end
    return nil, nil
end

function IrrigationManager:calculatePressureMultiplier(distance)
    if distance > IrrigationManager.MAX_PUMP_DISTANCE then return 0 end
    return 1.0 - (distance / IrrigationManager.MAX_PUMP_DISTANCE) * IrrigationManager.PRESSURE_FALLOFF
end

-- ============================================================
-- Hourly Schedule Check
-- ============================================================
function IrrigationManager:hourlyScheduleCheck()
    if not self.isInitialized then return end
    if g_currentMission == nil then return end

    local env = g_currentMission.environment
    if env == nil then return end

    -- env.currentHour and env.currentDayInPeriod are direct properties in FS25.
    -- currentDayInPeriod is 1–7 within the current growth period (matches schedule activeDays).
    -- IMPORTANT: currentDayInPeriod may be nil on some FS25 builds/map combinations.
    -- Fallback: derive a 1-7 day index from currentDay (monotonic) so scheduling
    -- never silently defaults to day 1 and makes schedules appear broken.
    local hour      = env.currentHour         or 0
    local dayOfWeek = env.currentDayInPeriod
    if dayOfWeek == nil then
        -- env.currentDay is 1-based within the current period; use modulo as fallback
        local currentDay = env.currentDay or env.currentMonotonicDay or 0
        dayOfWeek = (currentDay % 7) + 1   -- maps any integer → 1..7
    end
    -- Clamp to valid range in case the API returns an unexpected value
    if dayOfWeek < 1 or dayOfWeek > 7 then dayOfWeek = 1 end

    for id, system in pairs(self.systems) do
        -- Check if water source is still valid
        if system.waterSourceId ~= nil and self.waterSources[system.waterSourceId] == nil then
            if system.isActive then self:deactivateSystem(id) end
            system.waterSourceId      = nil
            system.pressureMultiplier = 0
        end

        local shouldBeActive = false
        if system.waterSourceId ~= nil and system.pressureMultiplier > 0 then
            local sched = system.schedule
            if sched.activeDays[dayOfWeek] == true then
                -- Support wrap-around schedules (e.g. startHour=23, endHour=2)
                if sched.startHour <= sched.endHour then
                    shouldBeActive = hour >= sched.startHour and hour < sched.endHour
                else
                    shouldBeActive = hour >= sched.startHour or hour < sched.endHour
                end
            end
        end

        if shouldBeActive and not system.isActive then
            self:activateSystem(id)
        elseif not shouldBeActive and system.isActive then
            self:deactivateSystem(id)
        end
    end
end

-- ============================================================
-- Activation / Deactivation
-- ============================================================
function IrrigationManager:activateSystem(id)
    local system = self.systems[id]
    if system == nil or system.isActive then return end

    local wearFactor    = 1.0 - system.wearLevel * 0.3
    local effectiveRate = system.flowRatePerHour * system.pressureMultiplier * wearFactor

    system.effectiveRatePerField = {}
    for _, fieldId in ipairs(system.coveredFields) do
        system.effectiveRatePerField[fieldId] = effectiveRate
        if self.manager ~= nil and self.manager.eventBus ~= nil then
            self.manager.eventBus.publish("CS_IRRIGATION_STARTED", {
                placeableId = id,
                fieldId     = fieldId,
                ratePerHour = effectiveRate,
            })
        end
    end

    system.isActive = true
    csLog(string.format("Irrigation system %d activated, rate=%.4f", id, effectiveRate))
end

function IrrigationManager:deactivateSystem(id)
    local system = self.systems[id]
    if system == nil or not system.isActive then return end

    for _, fieldId in ipairs(system.coveredFields) do
        if self.manager ~= nil and self.manager.eventBus ~= nil then
            self.manager.eventBus.publish("CS_IRRIGATION_STOPPED", {
                placeableId = id,
                fieldId     = fieldId,
                ratePerHour = system.effectiveRatePerField[fieldId] or 0,
            })
        end
    end

    system.effectiveRatePerField = {}
    system.isActive = false
    csLog(string.format("Irrigation system %d deactivated", id))
end

-- ============================================================
-- Get Irrigation Rate for a Field (sum of all active systems)
-- ============================================================
function IrrigationManager:getIrrigationRateForField(fieldId)
    local total = 0
    for _, system in pairs(self.systems) do
        if system.isActive and system.effectiveRatePerField[fieldId] ~= nil then
            total = total + system.effectiveRatePerField[fieldId]
        end
    end
    return total
end

-- ============================================================
-- One-Shot Manual Irrigation
-- Bypasses the schedule and immediately applies one hour's worth
-- of irrigation gain directly to soil moisture. Used by the
-- "Irrigate Now" button so the effect is instant and not subject
-- to the hourly-tick scheduling cycle.
-- Returns true if moisture was applied to at least one field.
-- ============================================================
function IrrigationManager:applyOneTimeIrrigation(systemId)
    local system = self.systems[systemId]
    if system == nil then return false end
    if system.waterSourceId == nil or system.pressureMultiplier <= 0 then
        csLog(string.format("applyOneTimeIrrigation: system %s has no water source", tostring(systemId)))
        return false
    end
    if #system.coveredFields == 0 then
        csLog(string.format("applyOneTimeIrrigation: system %s covers 0 fields", tostring(systemId)))
        return false
    end

    local wearFactor    = 1.0 - system.wearLevel * 0.3
    local effectiveRate = system.flowRatePerHour * system.pressureMultiplier * wearFactor

    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil then return false end

    local applied = 0
    for _, fieldId in ipairs(system.coveredFields) do
        local d = soilSystem.fieldData[fieldId]
        if d ~= nil then
            d.moisture = math.max(0.0, math.min(1.0, d.moisture + effectiveRate))
            applied = applied + 1
        end
    end

    csLog(string.format(
        "One-time irrigation: system %s applied rate=%.4f to %d/%d fields",
        tostring(systemId), effectiveRate, applied, #system.coveredFields
    ))
    return applied > 0
end

-- ============================================================
-- Cleanup
-- ============================================================
function IrrigationManager:delete()
    for id, system in pairs(self.systems) do
        if system.isActive then
            self:deactivateSystem(id)
        end
    end
    self.systems      = {}
    self.waterSources = {}
    self.isInitialized = false
end

-- Set irrigation costs enabled flag from settings
function IrrigationManager:setCostsEnabled(enabled)
    self.costsEnabled = not not enabled
end

-- Update wear level for a specific irrigation system.
-- Called by FinanceIntegration when UsedPlus provides DNA wear data.
-- wearLevel: 0.0 (new) to 1.0 (heavily worn); affects flow rate at next activation.
function IrrigationManager:updateSystemWearLevel(systemId, wearLevel)
    local system = self.systems[systemId]
    if system ~= nil then
        system.wearLevel = math.max(0.0, math.min(1.0, wearLevel or 0.0))
    end
end