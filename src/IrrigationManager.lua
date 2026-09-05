-- ============================================================
-- IrrigationManager.lua
-- Tracks all placed irrigation systems and water sources.
-- Handles registration, coverage detection, scheduling,
-- activation, and publishes irrigation gain events.
-- ============================================================

IrrigationManager = IrrigationManager or {}
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
    -- Final fallback â€” placeable may store position directly on some versions
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

    -- SCS-023 v2.3 (SDS 4): session-only effective-mode latch. nil until the
    -- first act seeds it; the fill-once edge reacts only to a true->false
    -- transition and never to repeated false or false->true.
    self.previousFiniteWaterActive = nil

    -- SCS-023 v2.3 (SDS 6/F200): the most recent AUTHORIZED Irrigate Now result
    -- per farm. Wrong-farm results are returned to the requester only and never
    -- stored here.
    self.lastIrrigateNowResultByFarm = {}

    -- SCS-023 v2.3 (SDS 8): transient pure-client private snapshot mirror. A
    -- farm's private rows become current only after its complete
    -- CropStressIrrigationStateEvent applied; never persisted.
    self._clientFarmCurrent = {}   -- farmId -> true once the complete snapshot applied
    self._clientFarmSystems = {}   -- farmId -> copied private system rows
    self._clientFarmSources = {}   -- farmId -> copied source rows

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
    local x, y, z = getPlaceablePosition(placeable)
    -- SCS-023: the source row carries finite-water state. waterRemaining is the
    -- sole mutable truth; hasWater derives from it. Unlimited (capacity <= 0)
    -- never writes or draws remainder. farmId comes from the pump placeable.
    local capacity = tonumber(placeable.waterUnitsCapacity)
    local finite = capacity ~= nil and capacity > 0
    local remaining = placeable.waterRemaining
    if remaining == nil then
        remaining = finite and capacity or nil  -- full for a new pump
    end
    self.waterSources[placeable.id] = {
        id           = placeable.id,
        x            = x,
        y            = y,  -- SCS-038: the LIFT term's source height, read once at registration
        z            = z,
        hasWater     = not finite or (remaining or 0) > 0,
        flowCapacity = placeable.waterFlowCapacity or 1000,
        -- SCS-023 finite water
        finite       = finite,
        capacity     = finite and capacity or nil,
        waterRemaining = remaining,
        -- SCS-023 v2.3: the source row retains the authored per-rain-hour refill
        -- rate from the placeable so the planner never hard-codes it.
        waterUnitsRefillPerRainHour = placeable.waterUnitsRefillPerRainHour,
        farmId       = placeable.ownerFarmId
            or (placeable.getOwnerFarmId and placeable:getOwnerFarmId() or nil),
    }
    csLog(string.format("Water source %d registered at (%.1f, %.1f) finite=%s",
        placeable.id, x, z, tostring(finite)))

    -- Re-connect any irrigation systems that registered before this pump was placed.
    -- Placement order (pivot first, then pump) would otherwise leave systems permanently
    -- disconnected since findNearestWaterSource() is only called once at system registration.
    -- SCS-023: registration/rebinding passes requireWater=false, so a dry source remains
    -- a deterministic peer/load candidate.
    local reconnected = 0
    for sysId, sys in pairs(self.systems) do
        if sys.waterSourceId == nil then
            local sourceId, dist = self:findNearestWaterSource(sys.x, sys.z, sys.ownerFarmId, false)
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

-- SCS-023: revalidate a source's bindings after an owner change. Fills only nil
-- bindings; a dry source may bind. New wet pumps do not steal a valid retained
-- binding.
function IrrigationManager:rebindWaterSource(sourceId, newFarmId)
    local source = self.waterSources[sourceId]
    if source == nil then return end
    source.farmId = newFarmId
    for sysId, sys in pairs(self.systems) do
        if sys.waterSourceId == nil then
            local srcId, dist = self:findNearestWaterSource(sys.x, sys.z, sys.ownerFarmId, false)
            if srcId ~= nil then
                sys.waterSourceId      = srcId
                sys.distanceToSource   = dist
                sys.pressureMultiplier = self:calculatePressureMultiplier(dist)
            end
        end
    end
end

-- ============================================================
-- SCS-023 FINITE WATER SOURCE STATE
-- ============================================================

--- Set a finite source's waterRemaining (authoritative server change). Clamps,
--- writes the placeable, derives hasWater, and raises the pump dirty flag only
--- for an authoritative server change (fromSync clients never originate dirt).
function IrrigationManager:setSourceWaterRemaining(sourceId, value, fromSync)
    local source = self.waterSources[sourceId]
    if source == nil or not source.finite then return end
    local clamped = math.max(0, tonumber(value) or 0)
    source.waterRemaining = clamped
    source.hasWater = clamped > 0
    if source.placeable ~= nil then
        source.placeable.waterRemaining = clamped
        if not fromSync and g_server ~= nil and source.placeable.setDirtyFlag ~= nil then
            source.placeable:setDirtyFlag(true)
        end
    end
end

--- Effective finite-water mode. False unless settings exist, settings.finiteWater
--- is true, and the release gate reports the system live.
function IrrigationManager:isFiniteWaterActive()
    local settings = self.manager ~= nil and self.manager.settings or nil
    if settings == nil then return false end
    if settings.finiteWater ~= true then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == "function" then
        return ReleaseGate.isSystemLive("finite_irrigation_water") == true
    end
    return true
end

--- SCS-023 v2.3 (SDS 4): session-only active-to-inactive edge. The first call
--- seeds the latch with the loaded effective mode and fills nothing. A later
--- active-to-inactive edge fills every finite source once on the server (sets
--- it to capacity, derives wet state, raises authoritative dirt through the
--- setter), clears no reasons (hasWater derives) and updates the stored value.
--- Repeated false, and false-to-true, never fill.
---@return string "seeded" | "filled" | "unchanged"
function IrrigationManager:handleFiniteWaterModeEdge()
    local active = self:isFiniteWaterActive()
    if self.previousFiniteWaterActive == nil then
        self.previousFiniteWaterActive = active
        return "seeded"
    end
    if self.previousFiniteWaterActive == true and active == false then
        if g_server ~= nil then
            for id, source in pairs(self.waterSources) do
                if source.finite then
                    self:setSourceWaterRemaining(id, source.capacity or 0, false)
                end
            end
        end
        self.previousFiniteWaterActive = false
        return "filled"
    end
    self.previousFiniteWaterActive = active
    return "unchanged"
end

--- Resolve the OptionScaling finiteWaterDrawScale once per hourly act.
function IrrigationManager:resolveFiniteWaterDrawScale()
    -- Agronomy declaration, base/neutral 1.0. Delegate-when-present.
    local resolver = g_currentMission ~= nil and g_currentMission.optionScalingResolver or nil
    if resolver == nil then return 1.0 end
    if type(resolver.readProfile) == "function" and type(resolver.resolve) == "function" then
        local profile = resolver:readProfile()
        if profile ~= nil then
            local v = resolver:resolve(profile, "AGRO", "finiteWaterDrawScale")
            if type(v) == "number" and v > 0 then return v end
        end
    end
    return 1.0
end

-- ============================================================
-- Irrigation System Registration
-- ============================================================
function IrrigationManager:registerIrrigationSystem(placeable)
    local x, y, z = getPlaceablePosition(placeable)
    local coveredFields = self:detectCoveredFields(placeable, x, z)

    -- SCS-023: system registration passes the owning farm id (F158-style, read
    -- once) and binds WITHOUT requiring water, so a dry source remains the
    -- deterministic peer/load candidate. Activation validates hasWater separately.
    local ownerFarmId = placeable.ownerFarmId
        or (placeable.getOwnerFarmId and placeable:getOwnerFarmId() or nil)
    local waterSourceId, distance = self:findNearestWaterSource(x, z, ownerFarmId, false)
    local pressureMultiplier = 0
    if waterSourceId ~= nil then
        pressureMultiplier = self:calculatePressureMultiplier(distance)
    end

    local system = {
        id                     = placeable.id,
        type                   = placeable.irrigationType or "pivot",
        -- F158: the OWNING PLACEABLE is held so the owner farm can be resolved at
        -- charge time (a placeable changes hands; a stored farm id would go stale).
        -- deregisterIrrigationSystem removes this record when the placeable goes,
        -- so the reference cannot dangle.
        placeable              = placeable,
        x                      = x,
        y                      = y,   -- SCS-038: the LIFT term's pivot height, read once at registration
        z                      = z,
        radius                 = placeable.radius or 200,
        endX                   = placeable.endX,
        endZ                   = placeable.endZ,
        lineSpacing            = placeable.lineSpacing or 0.8,
        coveredFields          = coveredFields,
        waterSourceId          = waterSourceId,
        distanceToSource       = distance,
        pressureMultiplier     = pressureMultiplier,
        flowRatePerHour        = placeable.flowRatePerHour or 0.018,
        operationalCostPerHour = placeable.operationalCostPerHour or 15,
        liftCoeff              = placeable.liftCoeff or 0.0,
        schedule = {
            startHour  = placeable.defaultStartHour or 6,
            endHour    = placeable.defaultEndHour   or 10,
            activeDays = placeable.defaultActiveDays or {true, true, true, true, true, false, false},
        },
        isActive             = false,
        -- [BUILD 00:33] Auto/Manual. false = the weekly schedule drives start and
        -- stop through hourlyScheduleCheck; true = the player owns Start/Stop and
        -- the schedule check leaves this row alone. Persisted by SaveLoadHandler
        -- (absent flag = Auto).
        manualMode           = false,
        effectiveRatePerField = {},
        -- SCS-046 RAIN KEY. Optional per-pivot equipment. A fitted pivot watches
        -- current rain at that machine; meaningful rain trips the key and stops
        -- controlled irrigation water, pivot movement and operating cost together.
        -- Unfitted pivots are bit-for-bit the old behaviour.
        rainKeyFitted              = placeable.rainKeyFitted == true,
        rainKeyTripMm              = tonumber(placeable.rainKeyTripMm) or 2.5,
        rainKeyAccumulatedMm       = 0.0,
        rainKeyDryElapsedMinutes   = 0,
        rainKeyTripped             = false,
        rainKeyInputState          = "UNAVAILABLE",
        rainKeyStateRevision       = 0,
        -- Authoritative owner farm, read once at registration (F158-style). The
        -- SCS-023 local variable and the SCS-046 placeable read are the same value.
        ownerFarmId                = ownerFarmId,
        -- Runtime-only fractional accumulator (never persisted).
        activeGameHoursSinceSettle = 0.0,
        _lastRainKeyPausePublished = false,
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
            "WARNING: system %d covers 0 fields â€” pivot at (%.1f, %.1f) radius=%.0f. " ..
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

    -- Use g_fieldManager.fields directly â€” same source as SoilMoistureSystem and buildFieldMap.
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
-- FS25 Field.polygonPoints holds scene-node ids, not coordinates â€” each
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
-- SCS-023: split binding from activation. Always filter to the same current owner
-- farm and the existing 500 m cap. Distance wins; equal distance chooses the lower
-- numeric source id. requireWater=false keeps a dry source a deterministic
-- peer/load candidate; activation validates hasWater separately.
function IrrigationManager:findNearestWaterSource(x, z, farmId, requireWater)
    local nearestId = nil
    local minDist   = math.huge

    for id, source in pairs(self.waterSources) do
        if requireWater ~= true or source.hasWater then
            if farmId == nil or farmId <= 0 or source.farmId == farmId then
                local dx   = source.x - x
                local dz   = source.z - z
                local dist = math.sqrt(dx * dx + dz * dz)
                if dist <= IrrigationManager.MAX_PUMP_DISTANCE then
                    if dist < minDist or (dist == minDist and (nearestId == nil or id < nearestId)) then
                        minDist   = dist
                        nearestId = id
                    end
                end
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

--- F160: the 1..7 day-of-week index for a schedule's activeDays. Derived from the
--- MONOTONIC day modulo 7, never read from env.currentDayInPeriod. The base game
--- computes currentDayInPeriod as (currentDay - 1) % daysPerPeriod + 1 and
--- daysPerPeriod defaults to 1, so on a default save currentDayInPeriod is ALWAYS
--- 1: a weekday schedule ran every day (activeDays[1] pinned true) and unticking
--- day one stopped the pivot forever. Deriving from the monotonic day makes the
--- index actually advance day to day, so the weekend-off entries are reachable.
function IrrigationManager:dayOfWeekIndex(env)
    if env == nil then return 1 end
    local currentDay = env.currentDay or env.currentMonotonicDay or 1
    if type(currentDay) ~= "number" or currentDay < 1 then currentDay = 1 end
    local dow = ((currentDay - 1) % 7) + 1
    if dow < 1 or dow > 7 then dow = 1 end
    return dow
end

function IrrigationManager:hourlyScheduleCheck()
    if not self.isInitialized then return end
    if g_currentMission == nil then return end

    local env = g_currentMission.environment
    if env == nil then return end

    local hour      = env.currentHour or 0
    local dayOfWeek = self:dayOfWeekIndex(env)

    for id, system in pairs(self.systems) do
        -- Check if water source is still valid
        if system.waterSourceId ~= nil and self.waterSources[system.waterSourceId] == nil then
            if system.isActive then self:deactivateSystem(id) end
            system.waterSourceId      = nil
            system.pressureMultiplier = 0
        end

        -- [BUILD 00:33] Manual hands Start/Stop to the player: the window neither
        -- auto-starts nor auto-stops this row. The water-source-loss stop above is
        -- deliberately outside this gate (a row with no source cannot water).
        if not system.manualMode then
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
                -- SCS-046: scheduled activation routes through the same gate. A fitted
                -- tripped or input-unavailable row stays off; the reason is honest.
                local gateOpen = self:isRainKeyGateOpen(system)
                if gateOpen then
                    self:activateSystem(id)
                else
                    csLog(string.format(
                        "Irrigation system %d schedule skipped (%s)",
                        id, select(2, self:isRainKeyGateOpen(system))))
                end
            elseif not shouldBeActive and system.isActive then
                self:deactivateSystem(id)
            end
        end
    end
end

--- [BUILD 00:33] One-shot schedule apply. Called on the first update frame after
--- isMissionStarted flips true (CropStressManager.update) and whenever a schedule
--- or the Auto/Manual mode changes on the server (CropStressScheduleSyncEvent,
--- AUTO_MANUAL_TOGGLE). It runs the hourly window check only: never the Finite
--- Water Planner (planFiniteWater / collectScheduledHours), which stays on the
--- hourly tick, and it charges nothing.
function IrrigationManager:applyScheduleNow()
    self:hourlyScheduleCheck()
end

-- ============================================================
-- SCS-038 THE PRICED DRAW
-- Irrigation's operational cost varies with the water it actually draws.
-- The effective rate is operationalCostPerHour / pressureMultiplier: at full
-- pressure (1.0) the rate is exactly the XML number; a distant source costs
-- more per effective hour because the pressure drop means less water moves
-- for the same pump time. Nil when there is no source (which already means
-- no run and no charge). SCS-024's held design consumes the same getter when
-- it builds; neither edits the other.
-- ============================================================

--- The effective hourly cost of one irrigation system, in money per hour.
--- nil when the system has no water source or no pressure (no run, no charge).
---@param system table an entry of self.systems
---@return number|nil
function IrrigationManager:getEffectiveCostPerHour(system)
    if system == nil then return nil end
    if system.waterSourceId == nil or system.pressureMultiplier == nil or system.pressureMultiplier <= 0 then
        return nil
    end
    local base = system.operationalCostPerHour or 0
    if base <= 0 then return 0 end
    local effCost = base / system.pressureMultiplier

    -- SCS-038 ROUND-2 LIFT TERM, designed-in and NEUTRAL at 0.0: a pivot that
    -- pumps uphill against the source spends more. effCost = base / pressure *
    -- (1 + LIFT_COEFF * max(0, pivotY - sourceY) / 10). LIFT_COEFF is an XML
    -- balance value defaulting to 0.0, so bit-for-bit round-1 until tuned.
    local liftCoeff = system.liftCoeff or 0.0
    if liftCoeff ~= 0.0 then
        local source = self.waterSources and self.waterSources[system.waterSourceId]
        local pivotY = system.y or 0
        local sourceY = source and source.y or 0
        local lift = 1.0 + liftCoeff * math.max(0, pivotY - sourceY) / 10
        effCost = effCost * lift
    end
    return effCost
end

-- ============================================================
-- REINKE SPRAY HELPER (BUILD 22:43)
-- One water-on flag: system.isActive. A Reinke pivot's spray
-- (spec.isSprayActive) is derived from it here, on the server, inside
-- activateSystem / deactivateSystem, so a scheduled, remote or AUTO_START
-- water-on also wets the field visually instead of only ticking the model.
-- The spec is soft-detected from system.placeable with the same scan as
-- getReinkeSpec in CropStressPivotRemoteEvent.lua (named table first, then
-- the key scan), so drip and Rainstar systems, which have no spec, no-op.
-- Mirrors toggleSprayActive in centerPivot.lua: write the flag, raise the
-- pivot's dirty flag so the stream carries it to clients, start or stop the
-- particles (client-only inside the pivot), and sync lastSprayLogged so the
-- spray-flip check in onUpdateTick does not fire the particles a second time.
-- ============================================================
local function getReinkeSpec(placeable)
    if placeable == nil then
        return nil
    end
    if ReinkeIrrigationPivot ~= nil and type(ReinkeIrrigationPivot.SPEC_TABLE_NAME) == "string" then
        local spec = placeable[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
        if spec ~= nil then
            return spec
        end
    end
    for k, v in pairs(placeable) do
        if type(k) == "string" and k:find("reinkeIrrigationPivot", 1, true) and type(v) == "table" then
            if v.armAngle ~= nil or v.autoMinAngleDeg ~= nil or v.doorOpen ~= nil then
                return v
            end
        end
    end
    return nil
end

local function setReinkeSpray(system, on)
    local placeable = system ~= nil and system.placeable or nil
    local spec = getReinkeSpec(placeable)
    if spec == nil then
        return false
    end
    spec.isSprayActive = on
    if type(placeable.raiseDirtyFlags) == "function" and spec.dirtyFlag ~= nil then
        placeable:raiseDirtyFlags(spec.dirtyFlag)
    end
    local particles = on and placeable.startSprayerParticles or placeable.stopSprayerParticles
    if type(particles) == "function" then
        local okCall, err = pcall(particles, placeable)
        if not okCall then
            csLog(string.format("Irrigation system %s spray particles %s failed: %s",
                tostring(system.id), on and "start" or "stop", tostring(err)))
        end
    end
    spec.lastSprayLogged = on
    return true
end

-- ============================================================
-- Activation / Deactivation
-- ============================================================
function IrrigationManager:activateSystem(id)
    local system = self.systems[id]
    if system == nil or system.isActive then return end

    -- SCS-046: the ordinary water-on gate lives here. A fitted tripped row refuses
    -- every automatic and remote start; input-unavailable also holds water off.
    local gateOpen, gateReason = self:isRainKeyGateOpen(system)
    if not gateOpen then
        csLog(string.format("Irrigation system %d activation refused (%s)", id, gateReason))
        return false, gateReason
    end

    -- F154: the wear factor is gone rather than dormant. It read UsedPlus DNA,
    -- which never has an entry for a placeable, so it was provably 1.0 at every
    -- activation this mod has ever performed. NO RATE MOVES.
    local effectiveRate = system.flowRatePerHour * system.pressureMultiplier

    system.effectiveRatePerField = {}
    for _, fieldId in ipairs(system.coveredFields) do
        system.effectiveRatePerField[fieldId] = effectiveRate
        -- SCS-046: fitted pivots settle through the fractional active-hour path
        -- (settleFittedSystem) and must NEVER add to the legacy whole-hour gain.
        -- Unfitted systems keep the incumbent event.
        if not (system.rainKeyFitted == true)
           and self.manager ~= nil and self.manager.eventBus ~= nil then
            self.manager.eventBus.publish("CS_IRRIGATION_STARTED", {
                placeableId = id,
                fieldId     = fieldId,
                ratePerHour = effectiveRate,
            })
        end
    end

    system.isActive = true
    -- BUILD 22:43: spray follows the one water-on flag (no-op without a Reinke spec).
    setReinkeSpray(system, true)
    csLog(string.format("Irrigation system %d activated, rate=%.4f", id, effectiveRate))
    return true, nil
end

function IrrigationManager:deactivateSystem(id, reason)
    local system = self.systems[id]
    if system == nil or not system.isActive then return end

    -- SCS-046 F200: a fitted pivot settles its already-run continuous interval
    -- before it stops, so a trip or Stop never strands water and cost. The
    -- reason travels to the settle for diagnostics; nil keeps legacy callers.
    if system.rainKeyFitted == true and (system.activeGameHoursSinceSettle or 0) > 0
       and self.settleFittedSystem ~= nil then
        self:settleFittedSystem(system, reason or "DEACTIVATE")
    end

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
    setReinkeSpray(system, false)
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

    -- F154: same removal as activateSystem, and the two must always move together.
    local effectiveRate = system.flowRatePerHour * system.pressureMultiplier

    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil then return false end

    local applied = 0
    for _, fieldId in ipairs(system.coveredFields) do
        local d = soilSystem.fieldData[fieldId]
        if d ~= nil then
            -- SCS-018 3.6 / 3.5: water lands on the places the system covers, not
            -- the whole field. A pivot wets its circle; a drip line wets cells
            -- within half the row spacing of the segment. The per-cell write path
            -- materialises cells and the field aggregate follows honestly.
            local x0 = system.x
            local z0 = system.z
            if system.type == "pivot" then
                local radius = system.radius or 200
                local r2 = radius * radius
                for _, field in pairs(self:_fieldsForId(fieldId)) do
                    local vx, vz, n = self:getFieldPolygonWorld(field)
                    if vx ~= nil then
                        local cs = soilSystem:getCellSize()
                        for _, entry in ipairs(self:_cellsInPolygon(vx, vz, n, cs)) do
                            local dx = entry.wx - x0
                            local dz = entry.wz - z0
                            if dx * dx + dz * dz <= r2 then
                                soilSystem:applyWaterAtCell(fieldId, entry.wx, entry.wz, effectiveRate)
                            end
                        end
                    end
                end
            elseif system.type == "drip" then
                local startX = system.x
                local startZ = system.z
                local endX = system.endX or (system.x + 100)
                local endZ = system.endZ or system.z
                local spacing = system.lineSpacing or 0.8
                local half = spacing * 0.5
                for _, field in pairs(self:_fieldsForId(fieldId)) do
                    local vx, vz, n = self:getFieldPolygonWorld(field)
                    if vx ~= nil then
                        local cs = soilSystem:getCellSize()
                        for _, entry in ipairs(self:_cellsInPolygon(vx, vz, n, cs)) do
                            local dsq = pointSegDistSq(entry.wx, entry.wz, startX, startZ, endX, endZ)
                            if dsq <= half * half then
                                soilSystem:applyWaterAtCell(fieldId, entry.wx, entry.wz, effectiveRate)
                            end
                        end
                    end
                end
            else
                -- Fallback: field-level (unchanged behaviour for unknown types).
                soilSystem:applyWaterAtCell(fieldId, d.centerX or 0, d.centerZ or 0, effectiveRate)
            end
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
-- SCS-023 IRRIGATE NOW TRANSACTION
--
-- Irrigate Now is an extra one-hour draw even if the schedule also served that
-- hour. When finite mode is inactive, it routes through the incumbent one-shot
-- and returns its result without source draw. When active it is the fixed
-- requestedDraw = 1.0 transaction with servedFraction, committedHours, and the
-- six result codes. Server-authoritative.
--
-- Result fields: accepted, resultCode, servedFraction, acceptedTargetCount,
-- committedHours.
-- ============================================================

--- Run the finite-aware Irrigate Now transaction for a system. One transaction
--- wrapper owns every finite, Unlimited and mode-off Irrigate Now request
--- (F200 / SCS-023 SDS 6). Gate order: missing row, live requester farm and
--- placeable owner, SCS master, fitted expected revision, source and pressure,
--- then the fixed requestedDraw = 1.0 transaction.
---@param systemId number
---@param requesterFarmId number|nil  farm id to authorise against
---@param expectedRainKeyRevision number|nil  -1 (default) for unfitted systems
---@return table result
function IrrigationManager:applyIrrigateNowTransaction(systemId, requesterFarmId, expectedRainKeyRevision)
    local result = {
        accepted = false, resultCode = "no_source", servedFraction = 0,
        acceptedTargetCount = 0, committedHours = 0, stateRevision = 0,
    }
    local system = self.systems[systemId]
    if system == nil then
        result.resultCode = "no_source"
        return result
    end
    result.stateRevision = system.StateRevision or 0

    -- Authorise: numeric farm match against the LIVE placeable owner (falling
    -- back to the retained row owner when no placeable is attached).
    local liveOwner = system.ownerFarmId
    if system.placeable ~= nil and type(system.placeable.getOwnerFarmId) == "function" then
        local owner = system.placeable:getOwnerFarmId()
        if type(owner) == "number" and owner > 0 then liveOwner = owner end
    end
    if requesterFarmId == nil or requesterFarmId <= 0
       or liveOwner == nil or liveOwner <= 0
       or requesterFarmId ~= liveOwner then
        result.resultCode = "wrong_farm"
        return result
    end

    -- SCS master: settings.enabled false disables the whole act.
    if self.manager ~= nil and self.manager.settings ~= nil
       and self.manager.settings.enabled == false then
        result.resultCode = "master_disabled"
        return result
    end

    -- A fitted pivot confirms against its current rain-key state revision; a
    -- stale confirmation mutates nothing.
    expectedRainKeyRevision = expectedRainKeyRevision or -1
    if expectedRainKeyRevision ~= -1
       and (system.StateRevision or 0) ~= expectedRainKeyRevision then
        result.resultCode = "stale_confirmation"
        return result
    end

    local source = self.waterSources[system.waterSourceId]
    if source == nil or (system.pressureMultiplier or 0) <= 0 then
        result.resultCode = "no_source"
        return result
    end

    local finiteActive = self:isFiniteWaterActive()
    if finiteActive and source.finite then
        local requestedDraw = 1.0
        local remaining = source.waterRemaining or 0
        if remaining <= 0 then
            result.resultCode = "dry_source"
            return result
        end
        local servedFraction = math.min(1, remaining / requestedDraw)
        local gain = (system.flowRatePerHour or 0) * (system.pressureMultiplier or 0) * servedFraction
        local acceptedCount = self:_applyOneShotGain(system, gain)
        if acceptedCount > 0 then
            local committedHours = requestedDraw * servedFraction
            self:setSourceWaterRemaining(system.waterSourceId, remaining - committedHours, false)
            result.accepted = true
            result.resultCode = servedFraction >= 1 and "success" or "partial"
            result.servedFraction = servedFraction
            result.acceptedTargetCount = acceptedCount
            result.committedHours = committedHours
        else
            result.resultCode = "no_ground"
        end
        return result
    end

    -- Unlimited AND mode-off: full service with fraction 1 and no remainder
    -- write. Irrigate Now debits zero operating cost in every mode.
    local gain = (system.flowRatePerHour or 0) * (system.pressureMultiplier or 0)
    local acceptedCount = self:_applyOneShotGain(system, gain)
    result.accepted = acceptedCount > 0
    result.resultCode = acceptedCount > 0 and "success" or "no_ground"
    result.servedFraction = 1
    result.acceptedTargetCount = acceptedCount
    result.committedHours = 0
    return result
end

--- The shared engine farm resolver (F200): uses ONLY g_currentMission:getFarmId
--- on the server. A nil connection (listen host) takes the engine host branch; a
--- dedicated client must send its real connection. No UserManager, connection.user,
--- local-player or farm-1 fallback.
function IrrigationManager:resolveRequesterFarmId(connection)
    local mission = g_currentMission
    if mission == nil or type(mission.getFarmId) ~= "function" then return nil end
    local farmId = mission:getFarmId(connection)
    if type(farmId) ~= "number" or farmId <= 0 then return nil end
    return farmId
end

--- Send the Irrigate Now result to the requester and store it only when it is
--- authorized for that farm. Wrong-farm results return to the requester only
--- and are never stored. No result history, retry or terminal sweep survives.
function IrrigationManager:dispatchIrrigateNowResult(systemId, result, connection, farmId)
    if result ~= nil and result.resultCode ~= "wrong_farm"
       and farmId ~= nil and farmId > 0 then
        self.lastIrrigateNowResultByFarm[farmId] = {
            systemId = systemId,
            accepted = result.accepted == true,
            resultCode = result.resultCode,
            servedFraction = result.servedFraction or 0,
            acceptedTargetCount = result.acceptedTargetCount or 0,
            committedHours = result.committedHours or 0,
            stateRevision = result.stateRevision or 0,
        }
    end
    if CropStressIrrigateNowResultEvent ~= nil and connection ~= nil then
        connection:sendEvent(CropStressIrrigateNowResultEvent.new(systemId, result))
    end
end

--- Host (listen server / single player): run the full chain with a nil
--- connection and handle the result locally through the same dispatch.
function IrrigationManager:runIrrigateNowHost(systemId)
    local farmId = self:resolveRequesterFarmId(nil)
    local result = self:applyIrrigateNowTransaction(systemId, farmId)
    self:dispatchIrrigateNowResult(systemId, result, nil, farmId)
    return result
end

--- Shared positional one-shot gain writer. Returns the count of cells that
--- accepted the application path.
function IrrigationManager:_applyOneShotGain(system, gain)
    if system == nil or gain <= 0 then return 0 end
    local soilSystem = self.manager ~= nil and self.manager.soilSystem or nil
    if soilSystem == nil or soilSystem.fieldData == nil then return 0 end
    local x0 = system.x or 0
    local z0 = system.z or 0
    local count = 0
    for _, fieldId in ipairs(system.coveredFields or {}) do
        local d = soilSystem.fieldData[fieldId]
        if d ~= nil then
            for _, field in ipairs(self:_fieldsForId(fieldId)) do
                local vx, vz, n = self:getFieldPolygonWorld(field)
                if vx ~= nil then
                    local cs = soilSystem:getCellSize()
                    for _, entry in ipairs(self:_cellsInPolygon(vx, vz, n, cs)) do
                        local hit = false
                        if system.type == "pivot" then
                            local radius = system.radius or 200
                            local dx = entry.wx - x0
                            local dz = entry.wz - z0
                            hit = dx * dx + dz * dz <= radius * radius
                        elseif system.type == "drip" then
                            local startX = x0
                            local startZ = z0
                            local endX = system.endX or (x0 + 100)
                            local endZ = system.endZ or z0
                            local spacing = system.lineSpacing or 0.8
                            hit = pointSegDistSq(entry.wx, entry.wz, startX, startZ, endX, endZ) <= (spacing * 0.5) ^ 2
                        end
                        if hit then
                            local accepted = soilSystem:applyWaterAtCell(fieldId, entry.wx, entry.wz, gain)
                            if accepted then count = count + 1 end
                        end
                    end
                end
            end
        end
    end
    return count
end

-- ============================================================
-- SCS-018 GEOMETRY HELPERS (irrigation water lands on places)
-- ============================================================

-- The g_fieldManager field objects for a farmland id.
function IrrigationManager:_fieldsForId(fieldId)
    local out = {}
    if g_fieldManager ~= nil and g_fieldManager.fields ~= nil then
        for _, f in pairs(g_fieldManager.fields) do
            if f.farmland ~= nil and f.farmland.id == fieldId then
                out[#out + 1] = f
            end
        end
    end
    return out
end

-- Cell centres inside a field polygon on the SCS cell grid.
function IrrigationManager:_cellsInPolygon(vx, vz, n, cellSize)
    local out = {}
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        if vx[i] < minX then minX = vx[i] end
        if vx[i] > maxX then maxX = vx[i] end
        if vz[i] < minZ then minZ = vz[i] end
        if vz[i] > maxZ then maxZ = vz[i] end
    end
    local cs = cellSize or 10
    for cx = math.floor(minX / cs), math.floor(maxX / cs) do
        for cz = math.floor(minZ / cs), math.floor(maxZ / cs) do
            local wx = (cx + 0.5) * cs
            local wz = (cz + 0.5) * cs
            if pointInPolygon(wx, wz, vx, vz, n) then
                out[#out + 1] = { wx = wx, wz = wz }
            end
        end
    end
    return out
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

-- F154: `updateSystemWearLevel` is deleted rather than kept as a public setter
-- for some future wear source. Its only caller was the UsedPlus bridge, so
-- keeping it would have made it a built-and-uncalled mechanism the moment that
-- bridge went, and this suite already carries several of those. Build the setter
-- when a design actually needs it.

-- ============================================================
-- SCS-046 RAIN KEY ENGINE
--
-- A center pivot may carry an optional rain key that watches current rain at
-- that machine. Meaningful rain trips the key and stops controlled irrigation
-- water, pivot movement and operating cost together while the farmer's schedule
-- stays intact. Thirty readable dry game minutes clear the latch without
-- surprise-starting the pivot.
--
-- Effective rain is isRaining == true AND rainScale >= 0.05 (the brief's
-- threshold). While a fitted system is active, only actual continuous active
-- game hours add to activeGameHoursSinceSettle; the fractional water and cost
-- are settled before a trip, Stop, source loss, hour boundary, save, remove,
-- transfer or master disable. Fitted pivots never contribute to the legacy
-- whole-hour irrigation gain or chargeHourlyCosts() pass.
--
-- Input unreadable freezes event state and shows INPUT_UNAVAILABLE. Unreadable
-- weather is unknown, never dry. Nil rain is never treated as zero.
-- ============================================================

-- Effective rain scale threshold (modelled mm-equivalent rain intensity).
IrrigationManager.RAIN_KEY_EFFECTIVE_SCALE = 0.05
-- Design-owned calibration: modelled mm accumulated per rainScale game hour at
-- full scale. The build brief pins 5.0 modelled mm per game hour at scale 1.0.
IrrigationManager.RAIN_KEY_MM_PER_HOUR_FULL_SCALE = 5.0
-- Continuous readable dry game minutes that clear the latch.
IrrigationManager.RAIN_KEY_DRY_RESET_MINUTES = 30

--- Is effective rain falling right now for this system?
---@param system table a fitted system row
---@param rainScale number|nil current rain scale
---@param isRaining boolean|nil current isRaining
---@return boolean
function IrrigationManager:rainKeyEffectiveRain(system, rainScale, isRaining)
    if type(rainScale) ~= "number" or type(isRaining) ~= "boolean" then return false end
    return isRaining == true and rainScale >= IrrigationManager.RAIN_KEY_EFFECTIVE_SCALE
end

--- Derived rain-key state enum for a system row.
---@return string  UNFITTED | ARMED | COLLECTING | TRIPPED | INPUT_UNAVAILABLE
function IrrigationManager:getRainKeyState(system)
    if system == nil or system.rainKeyFitted ~= true then return "UNFITTED" end
    if system.rainKeyTripped == true then return "TRIPPED" end
    if system.rainKeyInputState ~= "OK" then return "INPUT_UNAVAILABLE" end
    if system.rainKeyAccumulatedMm and system.rainKeyAccumulatedMm > 0 then return "COLLECTING" end
    return "ARMED"
end

--- Advance the rain-key sensor for every fitted system. Server-only continuous
--- update. Called from CropStressManager:update(dt) BEFORE the hour-key branch so
--- a long skipped span still settles correctly.
---@param dt number frame delta ms
---@return table changes  { [systemId] = { publish=true, reason=string } }
function IrrigationManager:updateRainKeySensor(dt)
    if self.manager == nil or self.manager.weatherIntegration == nil then return {} end
    if g_server == nil then return {} end

    -- The one current-rain read per tick. UNAVAILABLE when both routes fail.
    local readable, rainScale, isRaining = self.manager.weatherIntegration:getCurrentRainKey()
    local effectiveRain = readable and self:rainKeyEffectiveRain(nil, rainScale, isRaining) or false

    local elapsedGameHours = 0
    if g_currentMission ~= nil and g_currentMission.getEffectiveTimeScale ~= nil then
        elapsedGameHours = dt * g_currentMission:getEffectiveTimeScale() / 3600000
    elseif g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        elapsedGameHours = dt * (g_currentMission.missionInfo.timeScale or 1) / 3600000
    end
    if elapsedGameHours < 0 then elapsedGameHours = 0 end

    local changes = {}
    for id, system in pairs(self.systems) do
        if system.rainKeyFitted == true then
            system.rainKeyInputState = readable and "OK" or "UNAVAILABLE"
            local before = system.rainKeyTripped
            local hadEvent = system._lastRainKeyPausePublished == true

            if not readable then
                -- Unreadable input freezes event state. No accumulation, no dry time.
            elseif effectiveRain then
                -- Effective rain clears dry elapsed and adds modelled mm.
                system.rainKeyDryElapsedMinutes = 0
                local mm = IrrigationManager.RAIN_KEY_MM_PER_HOUR_FULL_SCALE
                    * rainScale * elapsedGameHours
                system.rainKeyAccumulatedMm = (system.rainKeyAccumulatedMm or 0) + mm
                -- First crossing at or above the dial: settle, latch, deactivate, publish once.
                if not system.rainKeyTripped
                   and system.rainKeyAccumulatedMm >= system.rainKeyTripMm then
                    system.rainKeyTripped = true
                    system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
                    if system.isActive then
                        self:deactivateSystem(id, "RAIN_KEY_TRIPPED")
                    end
                    changes[id] = { publish = true, reason = "RAIN_KEY_TRIPPED" }
                end
            else
                -- Dry gap: only continuous readable dry game minutes count toward reset.
                local dryMinutes = elapsedGameHours * 60
                if system.rainKeyDryElapsedMinutes == nil then system.rainKeyDryElapsedMinutes = 0 end
                system.rainKeyDryElapsedMinutes = system.rainKeyDryElapsedMinutes + dryMinutes
                if system.rainKeyTripped and system.rainKeyDryElapsedMinutes
                   >= IrrigationManager.RAIN_KEY_DRY_RESET_MINUTES then
                    -- 30 continuous dry game minutes clear event and latch, do not start.
                    system.rainKeyTripped = false
                    system.rainKeyAccumulatedMm = 0
                    system.rainKeyDryElapsedMinutes = 0
                    system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
                    changes[id] = { publish = true, reason = "DRY_RESET" }
                end
            end

            -- Publish the RAIN_PAUSED enter/leave edge once (quiet baseline for joins).
            local nowPaused = system.rainKeyTripped == true
            if nowPaused and not hadEvent then
                system._lastRainKeyPausePublished = true
                if changes[id] == nil then changes[id] = { publish = true, reason = "RAIN_KEY_TRIPPED" } end
            elseif not nowPaused and hadEvent then
                system._lastRainKeyPausePublished = false
                if changes[id] == nil then changes[id] = { publish = true, reason = "RESUMED" } end
            end
        end
    end
    return changes
end

--- Is this system's operational gate open? Returns true, or false plus a stable
--- reason. A fitted tripped row refuses every automatic and remote start.
---@return boolean, string|nil
function IrrigationManager:isRainKeyGateOpen(system)
    if system == nil then return true, nil end
    if system.rainKeyFitted ~= true then return true, nil end
    if system.rainKeyTripped == true then return false, "RAIN_KEY_TRIPPED" end
    if system.rainKeyInputState ~= "OK" then
        -- INPUT_UNAVAILABLE freezes event state: water stays off, reason is honest.
        return false, "INPUT_UNAVAILABLE"
    end
    return true, nil
end

--- Get a snapshot row for the rain-key read contract (SCS-046 UI companion).
--- Copy-only; mutating it cannot affect the live system.
---@param system table
---@return table
function IrrigationManager:getRainKeySnapshot(system)
    local snap = {
        systemId          = system.id,
        ownerFarmId       = system.ownerFarmId,
        rainKeyFitted     = system.rainKeyFitted == true,
        rainKeyTripMm     = system.rainKeyTripMm,
        rainKeyAccumulatedMm = system.rainKeyAccumulatedMm or 0,
        rainKeyDryElapsedMinutes = system.rainKeyDryElapsedMinutes or 0,
        weatherReadable   = system.rainKeyInputState == "OK",
        rainKeyState      = self:getRainKeyState(system),
        rainKeyTripped    = system.rainKeyTripped == true,
        activityState     = system.isActive == true and "RUNNING" or "OFF",
        pauseReason       = "NONE",
        nextWakeKind      = "NONE",
        nextWakeGameMinutes = nil,
        stateRevision     = system.rainKeyStateRevision or 0,
    }
    if system.rainKeyFitted == true and system.rainKeyTripped == true then
        snap.activityState = "RAIN_PAUSED"
        snap.pauseReason   = "RAIN_KEY_TRIPPED"
        snap.nextWakeKind  = "DRY_RESET"
    elseif system.rainKeyFitted == true and system.rainKeyInputState ~= "OK" then
        snap.pauseReason   = "INPUT_UNAVAILABLE"
        snap.nextWakeKind  = "PLAYER_ACTION"
    end
    return snap
end

--- Fit or remove a rain key, set the dial, all through the one server command path.
--- SCS-046 B (F200): FIT and SET require the rain_key_pause release row live; a
--- stale expected revision is rejected before any mutation; REMOVE settles the
--- already-run interval first.
---@param systemId number
---@param action string  FIT | REMOVE | SET_TRIP_MM
---@param value number|nil
---@param expectedRevision number|nil  rain-key state revision the requester saw
---@return boolean ok, string|nil error
function IrrigationManager:applyRainKeyCommand(systemId, action, value, expectedRevision)
    local system = self.systems[systemId]
    if system == nil then return false, "UNKNOWN_SYSTEM" end
    expectedRevision = expectedRevision or -1
    if expectedRevision ~= -1 and (system.rainKeyStateRevision or 0) ~= expectedRevision then
        return false, "STALE_CONFIRMATION"
    end
    if action == "FIT" or action == "SET_TRIP_MM" then
        if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == "function"
           and ReleaseGate.isSystemLive("rain_key_pause") ~= true then
            return false, "RELEASE_LOCKED"
        end
    end
    if action == "FIT" then
        if system.type ~= "pivot" then return false, "NOT_A_PIVOT" end
        system.rainKeyFitted = true
        system.rainKeyTripMm = tonumber(system.rainKeyTripMm) or 2.5
        system.rainKeyAccumulatedMm = 0
        system.rainKeyDryElapsedMinutes = 0
        system.rainKeyTripped = false
        system.rainKeyInputState = "UNAVAILABLE"
        system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
        system._lastRainKeyPausePublished = false
        return true, nil
    elseif action == "REMOVE" then
        -- F200: REMOVE settles the already-run continuous interval first.
        if system.rainKeyFitted == true then
            self:settleFittedSystem(system, "REMOVE")
        end
        system.rainKeyFitted = false
        system.rainKeyTripMm = 2.5
        system.rainKeyAccumulatedMm = 0
        system.rainKeyDryElapsedMinutes = 0
        system.rainKeyTripped = false
        system.rainKeyInputState = "UNAVAILABLE"
        system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
        system._lastRainKeyPausePublished = false
        return true, nil
    elseif action == "SET_TRIP_MM" then
        local v = tonumber(value)
        if v == nil then return false, "INVALID_TRIP_MM" end
        -- Operator range 0.5 to 10.0 in exact 0.5 steps. Never round or clamp malformed input.
        if v < 0.5 or v > 10.0 or (math.abs(v * 2 - math.floor(v * 2 + 0.5)) > 1e-9) then
            return false, "INVALID_TRIP_MM"
        end
        -- Lowering the dial through current accumulation trips in the same transaction.
        if system.rainKeyFitted and not system.rainKeyTripped
           and (system.rainKeyAccumulatedMm or 0) >= v then
            system.rainKeyTripped = true
            system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
            if system.isActive then self:deactivateSystem(id, "TRIP_DIAL_CROSS") end
            system._lastRainKeyPausePublished = true
        end
        system.rainKeyTripMm = v
        system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
        return true, nil
    end
    return false, "UNKNOWN_ACTION"
end

-- ============================================================
-- SCS-046 FRACTIONAL ACCOUNTING (water + cost for a trip/stop/etc.)
-- Fitted pivots settle continuous active game hours through the existing
-- footprint, then zero the accumulator. Unfitted systems keep the legacy
-- whole-hour path. The same interval never reaches both.
-- ============================================================
function IrrigationManager:settleFittedSystem(system, reason)
    if system == nil or system.rainKeyFitted ~= true then return end
    local hours = system.activeGameHoursSinceSettle or 0
    if hours <= 0 then return end

    -- Apply effectiveRatePerHour * hours through the existing pivot footprint
    -- (per-cell positional water), and charge effectiveCostPerHour * hours to the
    -- row's current owner farm.
    local rate = (system.flowRatePerHour or 0) * (system.pressureMultiplier or 0)
    if rate > 0 and self.manager ~= nil and self.manager.soilSystem ~= nil then
        local soil = self.manager.soilSystem
        if soil.fieldData ~= nil then
            for _, fieldId in ipairs(system.coveredFields or {}) do
                local d = soil.fieldData[fieldId]
                if d ~= nil then
                    soil:applyWaterAtCell(fieldId, d.centerX or 0, d.centerZ or 0, rate * hours)
                end
            end
        end
    end
    if self.manager ~= nil and self.manager.financeIntegration ~= nil
       and self.manager.financeIntegration.deductFundsVanilla ~= nil then
        local effCost = self:getEffectiveCostPerHour(system) or (system.operationalCostPerHour or 0)
        local farmId = system.ownerFarmId
        if farmId and farmId ~= 0 then
            self.manager.financeIntegration:deductFundsVanilla(effCost * hours, farmId)
        end
    end
    system.activeGameHoursSinceSettle = 0
    system.rainKeyStateRevision = (system.rainKeyStateRevision or 0) + 1
    return reason
end

-- SCS-023 FINITE IRRIGATION WATER ENGINE
--
-- A pump carries a finite store in irrigation-hours. Scheduled systems and
-- Irrigate Now consume it; rain refills it; a dry source stops its systems and
-- says why. Finite water applies only to placed pivot/drip infrastructure.
-- The existing 500 m pump range is unchanged.
--
-- The sole mutable truth is source.waterRemaining (written onto the pump
-- placeable). Fitted/legacy modes: finite (capacity > 0), unlimited (capacity
-- <= 0), and inactive (settings.finiteWater false or release-gated off).
-- ============================================================

--- Is this system's bound source wet right now?
---@return boolean, string|nil reason
function IrrigationManager:systemHasUsableWater(system)
    if system == nil then return false, "NO_SOURCE" end
    local source = self.waterSources[system.waterSourceId]
    if source == nil then return false, "NO_SOURCE" end
    if source.finite and not source.hasWater then return false, "DRY_SOURCE" end
    if (system.pressureMultiplier or 0) <= 0 then return false, "PRESSURE_UNAVAILABLE" end
    return true, nil
end

--- Enriched stop reason for a farm-filtered system row.
---@return string|nil  dry_source | no_source | nil
function IrrigationManager:getSystemStopReason(system)
    if system == nil then return nil end
    local source = self.waterSources[system.waterSourceId]
    if source == nil then return "no_source" end
    if source.finite and not source.hasWater then return "dry_source" end
    return nil
end

--- Pure: is this system scheduled at a given hour-key? Uses the day/hour
--- calculation directly (F160-safe, no currentDay ambiguity).
---@param system table
---@param hourKey number  day*24+hour
---@return boolean
function IrrigationManager:isScheduledAtHour(system, hourKey)
    if system == nil or system.schedule == nil then return false end
    local day = math.floor(hourKey / 24)
    local hour = hourKey - day * 24
    local dow = ((day - 1) % 7) + 1
    local sched = system.schedule
    if sched.activeDays == nil or sched.activeDays[dow] ~= true then return false end
    local startHour = sched.startHour or 0
    local endHour   = sched.endHour   or 24
    if startHour <= endHour then
        return hour >= startHour and hour < endHour
    end
    return hour >= startHour or hour < endHour
end

--- Collect incumbent scheduled hours with fraction 1.0 for each scheduled system
--- that has its valid binding and pressure, mutating no source. Pure mode when
--- finite water is inactive. Returns servedHoursBySystem (systemId -> hours).
function IrrigationManager:collectScheduledHours(elapsedHours, currentHourKey)
    local served = {}
    for i = 1, elapsedHours do
        local hourKey = currentHourKey - elapsedHours + i
        for id, system in pairs(self.systems) do
            if self:isScheduledAtHour(system, hourKey)
               and not (system.rainKeyFitted == true) then
                local usable = self:systemHasUsableWater(system)
                if usable then
                    served[id] = (served[id] or 0) + 1
                end
            end
        end
    end
    return served
end

--- The bounded finite-water PLANNER (PURE, SDS 5.1). Server-only. For each
--- represented hour:
---   1. group scheduled systems by bound same-farm source,
---   2. iterate every registered source (dry and inactive included),
---   3. finite source: compose the authored rain refill (clamped to capacity)
---      and the requested pressure draw scaled ONCE per act by
---      finiteWaterDrawScale, distribute one shared service fraction to its
---      scheduled systems, and carry the remainder forward in the plan,
---   4. unlimited source: give every scheduled system fraction 1.0, no remainder,
---   5. add fraction to each system's served-hours total.
--- MUTATES NOTHING. The plan carries each finite source's before/after so
--- commitFiniteWaterPlan writes the sole mutable truth exactly once.
---@return table plan  { servedHoursBySystem, sourceRows } where
---  sourceRows[sourceId] = { sourceId, before, refillAdded, consumed, after }
function IrrigationManager:planFiniteWater(elapsedHours, currentHourKey, rainScale, isRaining)
    local served = {}
    local sourceRows = {}
    local drawScale = self:resolveFiniteWaterDrawScale()

    local function refillPerHour(source)
        local r = source.waterUnitsRefillPerRainHour
        if type(r) ~= "number" or r <= 0 then r = 2.0 end
        return r
    end

    local function rowFor(sourceId, source)
        local row = sourceRows[sourceId]
        if row == nil then
            row = {
                sourceId = sourceId,
                before   = source.waterRemaining or 0,
                refillAdded = 0,
                consumed = 0,
                after    = source.waterRemaining or 0,
            }
            sourceRows[sourceId] = row
        end
        return row
    end

    for i = 1, elapsedHours do
        local hourKey = currentHourKey - elapsedHours + i
        -- Group scheduled systems by bound same-farm source.
        local bySource = {}
        for id, system in pairs(self.systems) do
            if self:isScheduledAtHour(system, hourKey) and system.waterSourceId ~= nil
               and not (system.rainKeyFitted == true) then
                local sid = system.waterSourceId
                bySource[sid] = bySource[sid] or {}
                bySource[sid][#bySource[sid] + 1] = system
            end
        end
        for sourceId, source in pairs(self.waterSources) do
            local group = bySource[sourceId]
            if group ~= nil and #group > 0 then
                if source.finite then
                    local row = rowFor(sourceId, source)
                    -- Rain refill applies once per hour, authored per placeable,
                    -- and never pushes the store past its capacity.
                    if isRaining == true and type(rainScale) == "number" and rainScale > 0 then
                        local refill = refillPerHour(source) * rainScale
                        row.after = row.after + refill
                        row.refillAdded = row.refillAdded + refill
                        local cap = source.capacity
                        if type(cap) == "number" and cap > 0 and row.after > cap then
                            local clipped = row.after - cap
                            row.refillAdded = row.refillAdded - clipped
                            row.after = cap
                        end
                    end
                    -- requested draw per scheduled system-hour, pressure-scaled
                    -- then scaled once per act by the finite draw scale.
                    local requested = 0
                    for _, system in ipairs(group) do
                        requested = requested + (system.pressureMultiplier or 0)
                    end
                    requested = requested * drawScale
                    local fraction = 0
                    if requested > 0 and row.after > 0 then
                        fraction = math.min(1, row.after / requested)
                    end
                    for _, system in ipairs(group) do
                        served[system.id] = (served[system.id] or 0) + fraction
                    end
                    local consumed = requested * fraction
                    row.consumed = row.consumed + consumed
                    row.after = row.after - consumed
                else
                    for _, system in ipairs(group) do
                        served[system.id] = (served[system.id] or 0) + 1
                    end
                end
            end
        end
    end
    -- F200 owns every rainKeyFitted pivot: it is excluded from SCS-023 source
    -- service, coverage and finance, and only ever settles through its own
    -- continuous-interval path. financeRows freeze the current owner farm and
    -- the current effective cost getter per served non-fitted system.
    local financeRows = {}
    for systemId, servedHours in pairs(served) do
        local system = self.systems[systemId]
        if system ~= nil and not (system.rainKeyFitted == true) then
            local effCost = nil
            if type(self.getEffectiveCostPerHour) == "function" then
                effCost = self:getEffectiveCostPerHour(system)
            end
            effCost = effCost or (system.operationalCostPerHour or 0)
            local farmId = nil
            if system.placeable ~= nil and type(system.placeable.getOwnerFarmId) == "function" then
                farmId = system.placeable:getOwnerFarmId()
            end
            servedHours = servedHours or 0
            financeRows[systemId] = {
                farmId = farmId,
                effectiveCostPerHour = effCost,
                servedHours = servedHours,
                amount = effCost * servedHours,
            }
        end
    end
    return { servedHoursBySystem = served, sourceRows = sourceRows, financeRows = financeRows }
end

--- Commit a pure finite-water plan (SDS 5.3): write each finite source's planned
--- `after` through the authoritative setSourceWaterRemaining exactly once. The
--- planner never writes; this is the single commit. Returns the number of
--- finite sources committed.
function IrrigationManager:commitFiniteWaterPlan(plan)
    if plan == nil or type(plan.sourceRows) ~= "table" then return 0 end
    local committed = 0
    for sourceId, row in pairs(plan.sourceRows) do
        if type(row) == "table" and row.after ~= nil then
            self:setSourceWaterRemaining(sourceId, row.after, false)
            committed = committed + 1
        end
    end
    return committed
end

--- Apply accumulated served hours through the system's real coverage geometry.
--- Positional per-cell write; one shared helper for scheduled + Irrigate Now.
--- SCS-023 v2.3 (SDS 5.2): COVER writes moisture and returns FIELD EVIDENCE.
--- Returns:
---   { wholeActLegacy = true }  when soil machinery is absent (nothing written;
---     the caller keeps the incumbent field-wide answer for every field), or
---   { wholeActLegacy = false, fields = { [fieldId] = "ACCEPTED"|"REFUSED" } }
---   otherwise. Before each field write the current farmland owner must equal
---   the system farm; a missing mapping, invalid system owner or a field owned
---   by another farm is POSITIONAL_REFUSED with no write. A literal true receipt
---   from applyWaterAtCell is Accepted; false, nil or any other non-true is
---   Refused. A valid unresolved leaf is literal true, never "no target".
function IrrigationManager:applyGainToSystemCoverage(system, gain)
    if system == nil or gain <= 0 then
        return { wholeActLegacy = false, fields = {} }
    end
    local soilSystem = self.manager ~= nil and self.manager.soilSystem or nil
    if soilSystem == nil or soilSystem.fieldData == nil
       or type(soilSystem.applyWaterAtCell) ~= "function"
       or type(self._cellsInPolygon) ~= "function"
       or type(self.getFieldPolygonWorld) ~= "function" then
        return { wholeActLegacy = true }
    end

    local evidence = { wholeActLegacy = false, fields = {} }
    local systemFarm = system.ownerFarmId
    local ownerInvalid = not (type(systemFarm) == "number" and systemFarm > 0)
    local farmlandMap = g_farmlandManager ~= nil and g_farmlandManager.farmlandMapping or nil

    local x0 = system.x or 0
    local z0 = system.z or 0
    for _, fieldId in ipairs(system.coveredFields or {}) do
        local d = soilSystem.fieldData[fieldId]
        if d ~= nil then
            local currentFarm = farmlandMap ~= nil and farmlandMap[fieldId] or nil
            if ownerInvalid or currentFarm == nil or currentFarm ~= systemFarm then
                evidence.fields[fieldId] = "REFUSED"
            else
                local accepted = 0
                for _, field in ipairs(self:_fieldsForId(fieldId)) do
                    local vx, vz, n = self:getFieldPolygonWorld(field)
                    if vx ~= nil then
                        local cs = soilSystem:getCellSize()
                        for _, entry in ipairs(self:_cellsInPolygon(vx, vz, n, cs)) do
                            local inside = false
                            if system.type == "pivot" then
                                local radius = system.radius or 200
                                local dx = entry.wx - x0
                                local dz = entry.wz - z0
                                inside = dx * dx + dz * dz <= radius * radius
                            elseif system.type == "drip" then
                                local startX = x0
                                local startZ = z0
                                local endX = system.endX or (x0 + 100)
                                local endZ = system.endZ or z0
                                local spacing = system.lineSpacing or 0.8
                                local half = spacing * 0.5
                                inside = pointSegDistSq(entry.wx, entry.wz,
                                    startX, startZ, endX, endZ) <= half * half
                            end
                            if inside and soilSystem:applyWaterAtCell(fieldId, entry.wx, entry.wz, gain) == true then
                                accepted = accepted + 1
                            end
                        end
                    end
                end
                evidence.fields[fieldId] = (accepted > 0) and "ACCEPTED" or "REFUSED"
            end
        end
    end
    return evidence
end

--- Farm-filtered enriched read rows. When farmId is supplied, rows carry
--- ownerFarmId, waterSourceId and derived stopReason.
--- SCS-023 v2.3 (SDS 8): ONE mutation-safe copy of a system row. The public form
--- omits farm-private fields; includePrivate adds ownerFarmId, waterSourceId and
--- the derived stopReason. Used by the farm getters and the private state event,
--- never a second snapshot protocol.
function IrrigationManager:copyIrrigationSystemRow(system, includePrivate)
    local covered = {}
    if system.coveredFields ~= nil then
        for i = 1, #system.coveredFields do covered[i] = system.coveredFields[i] end
    end
    local row = {
        id                     = system.id,
        type                   = system.type,
        isActive               = system.isActive == true,
        coveredFields          = covered,
        schedule               = system.schedule,
        flowRatePerHour        = system.flowRatePerHour,
        operationalCostPerHour = system.operationalCostPerHour,
    }
    if includePrivate then
        row.ownerFarmId  = system.ownerFarmId
        row.waterSourceId = system.waterSourceId
        row.stopReason   = self:getSystemStopReason(system)
    end
    return row
end

--- Farm-scoped enriched read rows. farmId supplied: only that farm's systems,
--- each a copied row WITH private fields. farmId nil: every system's PUBLIC row
--- (no private fields).
function IrrigationManager:getIrrigationSystemsRows(farmId)
    local out = {}
    for id, sys in pairs(self.systems) do
        local includePrivate = farmId ~= nil
        if includePrivate and sys.ownerFarmId ~= farmId then
            -- a different farm's system never appears in this farm's copy
        else
            out[#out + 1] = self:copyIrrigationSystemRow(sys, includePrivate)
        end
    end
    return out
end

--- Farm-filtered water-source read rows with the travelled keys
--- waterCapacity / isUnlimited / connectedSystemIds (legacy capacity /
--- unlimited / connectedSystems aliases retained for older readers).
function IrrigationManager:getIrrigationWaterSources(farmId)
    local out = {}
    for id, source in pairs(self.waterSources) do
        if farmId == nil or farmId <= 0 or source.farmId == farmId then
            local connected = {}
            for sysId, sys in pairs(self.systems) do
                if sys.waterSourceId == id then connected[#connected + 1] = sysId end
            end
            table.sort(connected)
            local connectedCopy = {}
            for i = 1, #connected do connectedCopy[i] = connected[i] end
            out[#out + 1] = {
                id = id,
                ownerFarmId = source.farmId,
                waterCapacity = source.capacity,
                waterRemaining = source.finite and source.waterRemaining or nil,
                isUnlimited = not source.finite,
                hasWater = source.hasWater == true,
                -- BUILD 07:10: getText on a key absent from l10n returns the truthy
                -- "Missing '...'" string, so an `or` fallback after it never fires.
                -- Ask hasText first, for the key the 26 translation files carry.
                label = (g_i18n ~= nil and g_i18n:hasText("cs_irr_water_source")
                    and g_i18n:getText("cs_irr_water_source")) or "Water source",
                connectedSystemIds = connectedCopy,
                -- legacy aliases for older readers
                capacity = source.capacity,
                unlimited = not source.finite,
                connectedSystems = connectedCopy,
            }
        end
    end
    table.sort(out, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return out
end

--- SDS 8: apply one farm's complete private snapshot on a pure client. The
--- shared completion flag makes both positive-farm getters current together.
function IrrigationManager:applyFarmPrivateSnapshot(farmId, systemRows, sourceRows)
    self._clientFarmSystems[farmId] = systemRows or {}
    self._clientFarmSources[farmId] = sourceRows or {}
    self._clientFarmCurrent[farmId] = true
    return true
end

--- SDS 8: cached mutation-safe system rows for a current farm (client mirror).
function IrrigationManager:getCachedFarmSystems(farmId)
    local rows = self._clientFarmSystems[farmId]
    if rows == nil then return nil end
    local out = {}
    for i = 1, #rows do out[i] = rows[i] end
    return out
end

--- SDS 8: cached mutation-safe source rows for a current farm (client mirror).
function IrrigationManager:getCachedFarmSources(farmId)
    local rows = self._clientFarmSources[farmId]
    if rows == nil then return nil end
    local out = {}
    for i = 1, #rows do out[i] = rows[i] end
    return out
end

--- SDS 8: teardown / new session clears the transient client mirror.
function IrrigationManager:clearClientPrivateSnapshot()
    self._clientFarmCurrent = {}
    self._clientFarmSystems = {}
    self._clientFarmSources = {}
end

--- SDS 8: build one farm's complete private snapshot for the state event from
--- the live manager (server side). systemRows are copied private rows; sourceRows
--- are the copied farm-filtered canonical rows.
function IrrigationManager:buildFarmPrivateSnapshot(farmId)
    return {
        systemRows = self:getIrrigationSystemsRows(farmId),
        sourceRows = self:getIrrigationWaterSources(farmId),
    }
end
