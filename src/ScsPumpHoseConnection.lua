-- ============================================================
-- ScsPumpHoseConnection.lua
-- Suite-owned visible EMP (Aggregat) <-> Rainstar supply hose.
--
-- BUILD 21:42: R = world ScsPumpHoseActivatable (ACTIVATE_OBJECT).
-- Start/Stop pump stays on EVC (SCS_TOGGLE_PUMP / K) with a real
-- controlTrigger Shape. Do not restore ScsPumpStartActivatable.
-- Keep getRequiresPower while TurnOn / crank; FillUnit WATER
-- transfer; ISI untouched.
-- ============================================================

ScsPumpHoseConnection = {}

ScsPumpHoseConnection.modDir = g_currentModDirectory
ScsPumpHoseConnection.currentModName = g_currentModName

ScsPumpHoseConnection.MAX_RANGE_M = 8.0
ScsPumpHoseConnection.ACTIVATE_RANGE_M = 4.5
ScsPumpHoseConnection.DISCONNECT_SLACK_M = 0.75
ScsPumpHoseConnection.UPDATE_MS = 100
ScsPumpHoseConnection.TRANSFER_LPS = 120.0
ScsPumpHoseConnection.WATER_FILL_UNIT = 1
ScsPumpHoseConnection.HOSE_I3D = "vehicles/irrigatorPlay/i3d/rwsmPumpHoseTemplate.i3d"
ScsPumpHoseConnection.HOSE_SHAPE_NAME = "rwsmGroundHoseTemplate"
ScsPumpHoseConnection.HOSE_TEMPLATE_LENGTH = 0.5
ScsPumpHoseConnection.HOSE_SEGMENTS = 3
ScsPumpHoseConnection.SAG_M = 0.35
-- The sag is applied to a straight line between two joints that both sit low on
-- their machines. On level or rising ground the middle of that curve ends up
-- under the terrain, which is the hose disappearing into the map. Every point is
-- clamped to at least this far above the ground.
ScsPumpHoseConnection.GROUND_CLEARANCE_M = 0.08

local function phNormalizePath(path)
    return string.lower(string.gsub(tostring(path or ""), "\\", "/"))
end

local function phIsRainstar(vehicle)
    if vehicle == nil then
        return false
    end
    if vehicle.typeName == "rwsmPlayRainstar" then
        return true
    end
    local path = phNormalizePath(vehicle.configFileName)
    return string.find(path, "rainstar.xml", 1, true) ~= nil
end

local function phResolveHoseJoint(vehicle)
    if vehicle == nil then
        return nil
    end
    local node = I3DUtil.indexToObject(vehicle.components, "hoseJoint", vehicle.i3dMappings)
    if node ~= nil and node ~= 0 then
        return node
    end
    if vehicle.components ~= nil and vehicle.components[1] ~= nil then
        return vehicle.components[1].node
    end
    return nil
end

local function phWorldDistance(ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function phGroundHeight(x, z)
    local terrainNode = g_currentMission ~= nil and g_currentMission.terrainRootNode or g_terrainNode
    if terrainNode == nil or getTerrainHeightAtWorldPos == nil then
        return nil
    end
    local ok, height = pcall(getTerrainHeightAtWorldPos, terrainNode, x, 0, z)
    if not ok then
        return nil
    end
    return tonumber(height)
end

local function phFindNodeByName(node, wantedName)
    if node == nil or node == 0 then
        return nil
    end
    if getName ~= nil and getName(node) == wantedName then
        return node
    end
    local count = getNumOfChildren ~= nil and getNumOfChildren(node) or 0
    for i = 0, count - 1 do
        local found = phFindNodeByName(getChildAt(node, i), wantedName)
        if found ~= nil then
            return found
        end
    end
    return nil
end

local function phTr(key, fallback)
    if g_i18n ~= nil then
        if g_i18n:hasText(key) then
            return g_i18n:getText(key)
        end
        local env = ScsPumpHoseConnection.currentModName
        if env ~= nil and g_i18n:hasText(key, env) then
            return g_i18n:getText(key, env)
        end
    end
    return fallback
end

local function phIsPumpRunning(pump)
    if pump == nil then
        return false
    end
    if pump.getIsTurnedOn ~= nil then
        local ok, value = pcall(pump.getIsTurnedOn, pump)
        if ok and value == true then
            return true
        end
    end
    if pump.spec_turnOnVehicle ~= nil and pump.spec_turnOnVehicle.isTurnedOn == true then
        return true
    end
    -- A running diesel engine is NOT a running pump.
    return false
end

local function phGetReelPartner(pump)
    local spec = pump ~= nil and pump.spec_scsPumpHose or nil
    if spec == nil or not spec.connected then
        return nil
    end
    local partner = spec.partner
    if partner == nil or partner.RAR == nil then
        return nil
    end
    return partner
end

local function phWaterFillType()
    if g_fillTypeManager ~= nil then
        local idx = g_fillTypeManager:getFillTypeIndexByName("WATER")
        if idx ~= nil then
            return idx
        end
    end
    if FillType ~= nil then
        return FillType.WATER
    end
    return nil
end

function ScsPumpHoseConnection.getIsPumpRunning(pump)
    return phIsPumpRunning(pump)
end

function ScsPumpHoseConnection.initSpecialization()
end

function ScsPumpHoseConnection.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(FillUnit, specializations)
end

function ScsPumpHoseConnection.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "setScsHoseConnected", ScsPumpHoseConnection.setScsHoseConnected)
    SpecializationUtil.registerFunction(vehicleType, "getScsHoseConnected", ScsPumpHoseConnection.getScsHoseConnected)
    SpecializationUtil.registerFunction(vehicleType, "getScsHosePartner", ScsPumpHoseConnection.getScsHosePartner)
end

-- getStopMotorOnLeave = stopMotorOnLeave and not getRequiresPower.
-- Require power while pump TurnOn or intentional crank; never permanent stopMotorOnLeave=false.
function ScsPumpHoseConnection.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(
        vehicleType, "getRequiresPower", ScsPumpHoseConnection.getRequiresPower)
end

function ScsPumpHoseConnection:getRequiresPower(superFunc)
    local spec = self.spec_scsPumpHose
    if spec ~= nil then
        if self.getIsTurnedOn ~= nil then
            local ok, value = pcall(self.getIsTurnedOn, self)
            if ok and value == true then
                return true
            end
        end
        if spec.pendingTurnOn == true then
            return true
        end
        if spec.walkUpMotorIntent == true and self.getMotorState ~= nil and MotorState ~= nil then
            local ok, state = pcall(self.getMotorState, self)
            if ok and (state == MotorState.STARTING or state == MotorState.ON) then
                return true
            end
        end
    end
    return superFunc(self)
end

function ScsPumpHoseConnection.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterExternalActionEvents", ScsPumpHoseConnection)
end

function ScsPumpHoseConnection:onLoad(savegame)
    local spec = {}
    self.spec_scsPumpHose = spec
    spec.hoseJoint = phResolveHoseJoint(self)
    spec.connected = false
    spec.partner = nil
    spec.updateTimer = 0
    spec.transferTimer = 0
    spec.hoseRoot = nil
    spec.hoseSharedRequestId = nil
    spec.hoseTemplate = nil
    spec.hoseSegments = {}
    spec.candidate = nil
    spec.reelActionEvents = {}
    spec.activatable = ScsPumpHoseActivatable.new(self)
    spec.activatableRegistered = false
    -- Motor start is asynchronous: tryStartMotor enters STARTING (~3 s crank).
    spec.pendingTurnOn = false
    spec.pendingTurnOnTimer = 0
    spec.sawMotorStart = false
    -- Intentional walk-up start: keeps getRequiresPower true through crank/ON.
    spec.walkUpMotorIntent = false
    -- EVC pump-function handle (update text / active). Hose is not on EVC.
    spec.evcPumpData = nil

    -- Soft path for vendored parking brake / COBD (RPC.virtualHoseConnected).
    if self.RPC == nil then
        self.RPC = {}
    end
    self.RPC.virtualHoseConnected = false
    self.RPC.virtualRainstar = nil
end

function ScsPumpHoseConnection:onDelete()
    local spec = self.spec_scsPumpHose
    if spec == nil then
        return
    end
    if spec.connected then
        self:setScsHoseConnected(false, true)
    end
    if spec.activatableRegistered and g_currentMission ~= nil
            and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
        spec.activatableRegistered = false
    end
    ScsPumpHoseConnection.deleteHoseVisual(self)
end

function ScsPumpHoseConnection:getScsHoseConnected()
    local spec = self.spec_scsPumpHose
    return spec ~= nil and spec.connected == true
end

function ScsPumpHoseConnection:getScsHosePartner()
    local spec = self.spec_scsPumpHose
    return spec ~= nil and spec.partner or nil
end

function ScsPumpHoseConnection:setScsHoseConnected(connected, force)
    local spec = self.spec_scsPumpHose
    if spec == nil then
        return
    end
    connected = connected == true
    if not force and connected == spec.connected then
        return
    end

    if connected then
        local partner = spec.candidate
        if partner == nil or not phIsRainstar(partner) then
            return
        end
        local dist = ScsPumpHoseConnection.getJointDistance(self, partner)
        if dist == nil or dist > ScsPumpHoseConnection.MAX_RANGE_M then
            return
        end

        if partner.rwsmVirtualPump ~= nil and partner.rwsmVirtualPump ~= self
                and partner.rwsmVirtualPump.setScsHoseConnected ~= nil then
            partner.rwsmVirtualPump:setScsHoseConnected(false, true)
        end

        spec.connected = true
        spec.partner = partner
        partner.rwsmVirtualPump = self
        if self.RPC == nil then
            self.RPC = {}
        end
        self.RPC.virtualHoseConnected = true
        self.RPC.virtualRainstar = partner
        ScsPumpHoseConnection.ensureHoseVisual(self)
        if spec.activatable ~= nil then
            spec.activatable:updateActivateText()
        end
    else
        local partner = spec.partner
        spec.connected = false
        spec.partner = nil
        if self.RPC ~= nil then
            self.RPC.virtualHoseConnected = false
            self.RPC.virtualRainstar = nil
        end
        if partner ~= nil and partner.rwsmVirtualPump == self then
            partner.rwsmVirtualPump = nil
        end
        ScsPumpHoseConnection.deleteHoseVisual(self)
        if spec.activatable ~= nil then
            spec.activatable:updateActivateText()
        end
    end
end

function ScsPumpHoseConnection.getJointDistance(pump, rainstar)
    local a = phResolveHoseJoint(pump)
    local b = phResolveHoseJoint(rainstar)
    if a == nil or b == nil then
        return nil
    end
    local ax, ay, az = getWorldTranslation(a)
    local bx, by, bz = getWorldTranslation(b)
    return phWorldDistance(ax, ay, az, bx, by, bz)
end

function ScsPumpHoseConnection.findNearestRainstar(pump)
    local mission = g_currentMission
    if mission == nil then
        return nil, nil
    end
    local vehicles = (mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles) or mission.vehicles
    if vehicles == nil then
        return nil, nil
    end

    local best, bestDist = nil, nil
    for _, vehicle in pairs(vehicles) do
        if vehicle ~= pump and phIsRainstar(vehicle) then
            local dist = ScsPumpHoseConnection.getJointDistance(pump, vehicle)
            if dist ~= nil and dist <= ScsPumpHoseConnection.MAX_RANGE_M then
                if bestDist == nil or dist < bestDist then
                    best, bestDist = vehicle, dist
                end
            end
        end
    end
    return best, bestDist
end

function ScsPumpHoseConnection.ensureHoseVisual(vehicle)
    if vehicle == nil or not vehicle.isClient then
        return
    end
    local spec = vehicle.spec_scsPumpHose
    if spec == nil then
        return
    end
    if spec.hoseTemplate ~= nil then
        return
    end

    local filename = Utils.getFilename(ScsPumpHoseConnection.HOSE_I3D, ScsPumpHoseConnection.modDir)
    local rootNode, sharedRequestId, failedReason
    if g_i3DManager ~= nil and g_i3DManager.loadSharedI3DFile ~= nil then
        rootNode, sharedRequestId, failedReason = g_i3DManager:loadSharedI3DFile(filename, false, false, false)
    elseif loadI3DFile ~= nil then
        rootNode, failedReason = loadI3DFile(filename, false, false, false)
    end
    if rootNode == nil or rootNode == 0 then
        print(string.format("[CropStress] ScsPumpHose: pump hose template failed (%s)", tostring(failedReason)))
        return
    end

    local template = phFindNodeByName(rootNode, ScsPumpHoseConnection.HOSE_SHAPE_NAME)
    if template == nil then
        delete(rootNode)
        print("[CropStress] ScsPumpHose: pump hose shape node missing")
        return
    end

    if getParent(rootNode) == nil or getParent(rootNode) == 0 then
        link(getRootNode(), rootNode)
    end
    setVisibility(rootNode, true)
    setVisibility(template, false)

    spec.hoseRoot = rootNode
    spec.hoseSharedRequestId = sharedRequestId
    spec.hoseTemplate = template
    spec.hoseSegments = {}

    for _ = 1, ScsPumpHoseConnection.HOSE_SEGMENTS do
        local seg = clone(template, false, false, false)
        if seg ~= nil and seg ~= 0 then
            link(getRootNode(), seg)
            setVisibility(seg, false)
            table.insert(spec.hoseSegments, seg)
        end
    end
end

function ScsPumpHoseConnection.deleteHoseVisual(vehicle)
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil then
        return
    end
    for _, seg in ipairs(spec.hoseSegments or {}) do
        if seg ~= nil and seg ~= 0 then
            delete(seg)
        end
    end
    spec.hoseSegments = {}
    if spec.hoseRoot ~= nil and spec.hoseRoot ~= 0 then
        delete(spec.hoseRoot)
    end
    if spec.hoseSharedRequestId ~= nil and g_i3DManager ~= nil
            and g_i3DManager.releaseSharedI3DFile ~= nil then
        g_i3DManager:releaseSharedI3DFile(spec.hoseSharedRequestId)
    end
    spec.hoseRoot = nil
    spec.hoseSharedRequestId = nil
    spec.hoseTemplate = nil
end

function ScsPumpHoseConnection.updateHosePose(vehicle)
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil or not vehicle.isClient or not spec.connected then
        return
    end
    local partner = spec.partner
    if partner == nil then
        return
    end
    ScsPumpHoseConnection.ensureHoseVisual(vehicle)
    if spec.hoseTemplate == nil or #spec.hoseSegments == 0 then
        return
    end

    local a = phResolveHoseJoint(vehicle)
    local b = phResolveHoseJoint(partner)
    if a == nil or b == nil then
        return
    end
    local ax, ay, az = getWorldTranslation(a)
    local bx, by, bz = getWorldTranslation(b)
    local total = phWorldDistance(ax, ay, az, bx, by, bz)
    if total < 0.05 then
        for _, seg in ipairs(spec.hoseSegments) do
            setVisibility(seg, false)
        end
        return
    end

    local n = #spec.hoseSegments
    local points = {}
    for i = 0, n do
        local t = i / n
        local x = ax + (bx - ax) * t
        local y = ay + (by - ay) * t
        local z = az + (bz - az) * t
        local sagFactor = 4 * t * (1 - t)
        y = y - ScsPumpHoseConnection.SAG_M * sagFactor
        if i > 0 and i < n then
            local groundY = phGroundHeight(x, z)
            if groundY ~= nil then
                y = math.max(y, groundY + ScsPumpHoseConnection.GROUND_CLEARANCE_M)
            end
        end
        points[i + 1] = { x, y, z }
    end

    for i = 1, n do
        local p1, p2 = points[i], points[i + 1]
        local seg = spec.hoseSegments[i]
        local dx, dy, dz = p2[1] - p1[1], p2[2] - p1[2], p2[3] - p1[3]
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        if length > 0.001 and seg ~= nil and seg ~= 0 then
            local visualLength = length + 0.02
            setDirection(seg, dx / length, dy / length, dz / length, 0, 1, 0)
            setScale(seg, 1, 1, visualLength / ScsPumpHoseConnection.HOSE_TEMPLATE_LENGTH)
            setTranslation(seg, p1[1], p1[2], p1[3])
            setVisibility(seg, true)
        elseif seg ~= nil and seg ~= 0 then
            setVisibility(seg, false)
        end
    end
end

function ScsPumpHoseConnection.transferWater(pump, dt)
    local spec = pump.spec_scsPumpHose
    if spec == nil or not spec.connected or spec.partner == nil then
        return
    end
    if not phIsPumpRunning(pump) then
        return
    end

    local rainstar = spec.partner
    local waterIndex = phWaterFillType()
    if waterIndex == nil then
        return
    end

    local toolType = ToolType ~= nil and ToolType.UNDEFINED or nil
    local farmId = pump.getOwnerFarmId ~= nil and pump:getOwnerFarmId() or 1
    local fillUnit = ScsPumpHoseConnection.WATER_FILL_UNIT
    local liters = ScsPumpHoseConnection.TRANSFER_LPS * (tonumber(dt) or 0) * 0.001
    if liters <= 0 then
        return
    end

    local available = 0
    if pump.getFillUnitFillLevel ~= nil then
        available = tonumber(pump:getFillUnitFillLevel(fillUnit)) or 0
    end
    if available <= 0 then
        return
    end

    local free = liters
    if rainstar.getFillUnitFreeCapacity ~= nil then
        free = tonumber(rainstar:getFillUnitFreeCapacity(fillUnit, waterIndex, farmId)) or 0
    elseif rainstar.getFillUnitCapacity ~= nil and rainstar.getFillUnitFillLevel ~= nil then
        free = (tonumber(rainstar:getFillUnitCapacity(fillUnit)) or 0)
            - (tonumber(rainstar:getFillUnitFillLevel(fillUnit)) or 0)
    end
    local move = math.min(liters, available, math.max(0, free))
    if move <= 0.001 then
        return
    end

    local drained = pump:addFillUnitFillLevel(farmId, fillUnit, -move, waterIndex, toolType, nil)
    local actuallyDrained = math.abs(tonumber(drained) or 0)
    if actuallyDrained <= 0.001 then
        return
    end
    rainstar:addFillUnitFillLevel(farmId, fillUnit, actuallyDrained, waterIndex, toolType, nil)
end

-- ------------------------------------------------------------
-- Reel toggle (N) on the pump side.
-- ------------------------------------------------------------

function ScsPumpHoseConnection:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    local spec = self.spec_scsPumpHose
    if not self.isClient or spec == nil or InputAction.RWSM53_REEL_TOGGLE == nil then
        return
    end

    self:clearActionEventsTable(spec.reelActionEvents)

    if not isActiveForInputIgnoreSelection then
        return
    end

    local _, actionEventId = self:addActionEvent(
        spec.reelActionEvents,
        InputAction.RWSM53_REEL_TOGGLE,
        self,
        ScsPumpHoseConnection.actionEventReelToggle,
        false,
        true,
        false,
        true,
        nil
    )

    if actionEventId ~= nil then
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
        g_inputBinding:setActionEventActive(actionEventId, false)
    end
end

function ScsPumpHoseConnection.updateReelActionEvent(pump)
    local spec = pump ~= nil and pump.spec_scsPumpHose or nil
    local action = spec ~= nil and spec.reelActionEvents ~= nil
        and spec.reelActionEvents[InputAction.RWSM53_REEL_TOGGLE] or nil
    if action == nil or action.actionEventId == nil then
        return
    end

    local partner = phGetReelPartner(pump)
    g_inputBinding:setActionEventActive(action.actionEventId, partner ~= nil)
    if partner ~= nil then
        g_inputBinding:setActionEventText(action.actionEventId, g_i18n:getText(
            partner.RAR.reelCommandActive
                and "action_RAINSTAR_REEL_STOP"
                or "action_RAINSTAR_REEL_START"))
    end
end

function ScsPumpHoseConnection.actionEventReelToggle(self, actionName, inputValue, callbackState, isAnalog)
    local partner = phGetReelPartner(self)
    print(string.format(
        "[CropStress] Reel toggle pressed from the pump (partner=%s, reelSpec=%s)",
        tostring(partner ~= nil),
        tostring(RWSM53AutoReel ~= nil and RWSM53AutoReel.toggleReel ~= nil)))
    if partner == nil or RWSM53AutoReel == nil or RWSM53AutoReel.toggleReel == nil then
        return
    end
    RWSM53AutoReel.toggleReel(partner)
    ScsPumpHoseConnection.updateReelActionEvent(self)
end

-- ------------------------------------------------------------
-- BUILD 21:42 ExternalVehicleControl — pump only (K). Hose is world R.
-- ------------------------------------------------------------

function ScsPumpHoseConnection:onRegisterExternalActionEvents(trigger, name, xmlFile, key)
    if name == "scsTogglePump" then
        local data = self:registerExternalActionEvent(
            trigger, name,
            ScsPumpHoseConnection.externalPumpRegister,
            ScsPumpHoseConnection.externalPumpUpdate)
        if self.spec_scsPumpHose ~= nil then
            self.spec_scsPumpHose.evcPumpData = data
        end
    end
end

function ScsPumpHoseConnection.pumpActionText(vehicle)
    if phIsPumpRunning(vehicle) then
        return phTr("action_SCS_STOP_PUMP", "Stop pump")
    end
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec ~= nil and (spec.pendingTurnOn == true or spec.walkUpMotorIntent == true) then
        local cranking = spec.pendingTurnOn == true
        if not cranking and vehicle.getMotorState ~= nil and MotorState ~= nil then
            local ok, state = pcall(vehicle.getMotorState, vehicle)
            cranking = ok and state == MotorState.STARTING
        end
        if cranking then
            return phTr("action_SCS_STARTING_PUMP", "Starting pump…")
        end
    end
    return phTr("action_SCS_START_PUMP", "Start pump")
end

function ScsPumpHoseConnection.hoseActionText(vehicle)
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec ~= nil and spec.connected then
        return phTr("action_SCS_DISCONNECT_HOSE", "Disconnect hose")
    end
    return phTr("action_SCS_CONNECT_HOSE", "Connect hose")
end

function ScsPumpHoseConnection.togglePump(vehicle)
    if vehicle == nil then
        return
    end
    local spec = vehicle.spec_scsPumpHose
    if phIsPumpRunning(vehicle) then
        if spec ~= nil then
            spec.pendingTurnOn = false
            spec.pendingTurnOnTimer = 0
            spec.sawMotorStart = false
            spec.walkUpMotorIntent = false
        end
        if vehicle.setIsTurnedOn ~= nil then
            pcall(vehicle.setIsTurnedOn, vehicle, false)
        end
        if vehicle.stopMotor ~= nil then
            pcall(vehicle.stopMotor, vehicle)
        end
        return
    end

    if spec ~= nil and spec.pendingTurnOn == true then
        return
    end
    if Motorized ~= nil and type(Motorized.tryStartMotor) == "function" then
        pcall(Motorized.tryStartMotor, vehicle)
    end
    if spec ~= nil then
        spec.pendingTurnOn = true
        spec.pendingTurnOnTimer = 0
        spec.sawMotorStart = false
        spec.walkUpMotorIntent = true
    end
    if vehicle.raiseActive ~= nil then
        pcall(vehicle.raiseActive, vehicle)
    end
    ScsPumpHoseConnection.updatePendingTurnOn(vehicle, 0)
end

function ScsPumpHoseConnection.toggleHose(vehicle)
    if vehicle == nil or not vehicle.isServer then
        return
    end
    local spec = vehicle.spec_scsPumpHose
    if spec == nil then
        return
    end
    if spec.connected then
        vehicle:setScsHoseConnected(false)
    else
        vehicle:setScsHoseConnected(true)
    end
end

function ScsPumpHoseConnection.externalPumpRegister(data, vehicle)
    local action = InputAction.SCS_TOGGLE_PUMP
    if action == nil then
        return
    end
    local function onAction(_, actionName, inputValue, callbackState, isAnalog)
        ScsPumpHoseConnection.togglePump(vehicle)
        ScsPumpHoseConnection.externalPumpUpdate(data, vehicle)
    end
    local _, actionEventId = g_inputBinding:registerActionEvent(
        action, data, onAction, false, true, false, true)
    data.actionEventId = actionEventId
    if actionEventId ~= nil then
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    end
    ScsPumpHoseConnection.externalPumpUpdate(data, vehicle)
end

function ScsPumpHoseConnection.externalPumpUpdate(data, vehicle)
    if data == nil or data.actionEventId == nil then
        return
    end
    local text = ScsPumpHoseConnection.pumpActionText(vehicle)
    g_inputBinding:setActionEventText(data.actionEventId, text)
    g_inputBinding:setActionEventActive(data.actionEventId, true)
end

-- Vanilla tryStartMotor brings the motor to STARTING. Leave-stop via getRequiresPower.
function ScsPumpHoseConnection.updatePendingTurnOn(pump, dt)
    local spec = pump ~= nil and pump.spec_scsPumpHose or nil
    if spec == nil or not spec.pendingTurnOn then
        return
    end

    if pump.raiseActive ~= nil then
        pcall(pump.raiseActive, pump)
    end

    if pump.getIsTurnedOn ~= nil then
        local ok, value = pcall(pump.getIsTurnedOn, pump)
        if ok and value == true then
            spec.pendingTurnOn = false
            spec.pendingTurnOnTimer = 0
            spec.sawMotorStart = false
            print("[CropStress] ScsPumpHose: pump turned on, reel gate is open")
            if spec.evcPumpData ~= nil then
                ScsPumpHoseConnection.externalPumpUpdate(spec.evcPumpData, pump)
            end
            return
        end
    end

    local motorState = nil
    if pump.getMotorState ~= nil then
        local ok, state = pcall(pump.getMotorState, pump)
        if ok then
            motorState = state
        end
    end

    if MotorState ~= nil then
        if motorState == MotorState.STARTING or motorState == MotorState.ON then
            spec.sawMotorStart = true
        elseif spec.sawMotorStart and (motorState == MotorState.OFF or motorState == MotorState.IGNITION) then
            spec.pendingTurnOn = false
            spec.pendingTurnOnTimer = 0
            spec.sawMotorStart = false
            spec.walkUpMotorIntent = false
            print("[CropStress] ScsPumpHose: pump turn-on aborted, motor returned to off")
            if spec.evcPumpData ~= nil then
                ScsPumpHoseConnection.externalPumpUpdate(spec.evcPumpData, pump)
            end
            return
        end
    end

    spec.pendingTurnOnTimer = (spec.pendingTurnOnTimer or 0) + (tonumber(dt) or 0)
    if spec.pendingTurnOnTimer > 15000 then
        spec.pendingTurnOn = false
        spec.pendingTurnOnTimer = 0
        spec.sawMotorStart = false
        spec.walkUpMotorIntent = false
        print("[CropStress] ScsPumpHose: pump turn-on timed out")
        if spec.evcPumpData ~= nil then
            ScsPumpHoseConnection.externalPumpUpdate(spec.evcPumpData, pump)
        end
        return
    end

    local powered = MotorState ~= nil
        and (motorState == MotorState.STARTING or motorState == MotorState.ON)
    if powered and pump.setIsTurnedOn ~= nil then
        pcall(pump.setIsTurnedOn, pump, true)
    end
end

function ScsPumpHoseConnection:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self.spec_scsPumpHose
    if spec == nil then
        return
    end

    spec.updateTimer = (spec.updateTimer or 0) + (tonumber(dt) or 0)
    if spec.updateTimer < ScsPumpHoseConnection.UPDATE_MS then
        return
    end
    spec.updateTimer = 0

    if spec.connected then
        local partner = spec.partner
        local dist = partner ~= nil and ScsPumpHoseConnection.getJointDistance(self, partner) or nil
        if partner == nil or dist == nil
                or dist > (ScsPumpHoseConnection.MAX_RANGE_M + ScsPumpHoseConnection.DISCONNECT_SLACK_M) then
            if self.isServer then
                self:setScsHoseConnected(false)
            end
        else
            ScsPumpHoseConnection.updateHosePose(self)
        end
    end
end

function ScsPumpHoseConnection:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self.spec_scsPumpHose
    if spec == nil then
        return
    end

    ScsPumpHoseConnection.updatePendingTurnOn(self, dt)

    if spec.walkUpMotorIntent and not spec.pendingTurnOn and not phIsPumpRunning(self) then
        local motorOff = true
        if self.getMotorState ~= nil and MotorState ~= nil then
            local ok, state = pcall(self.getMotorState, self)
            if ok and (state == MotorState.STARTING or state == MotorState.ON) then
                motorOff = false
            end
        end
        if motorOff then
            spec.walkUpMotorIntent = false
            spec.sawMotorStart = false
        end
    end

    if self.isClient then
        ScsPumpHoseConnection.updateReelActionEvent(self)
        if spec.evcPumpData ~= nil then
            ScsPumpHoseConnection.externalPumpUpdate(spec.evcPumpData, self)
        end
    end

    if self.isServer and spec.connected then
        ScsPumpHoseConnection.transferWater(self, dt)
    end

    if not spec.connected then
        spec.candidate = ScsPumpHoseConnection.findNearestRainstar(self)
    else
        spec.candidate = spec.partner
    end

    if g_currentMission == nil or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    local shouldOffer = false
    if spec.candidate ~= nil then
        local dist = ScsPumpHoseConnection.getJointDistance(self, spec.candidate)
        if dist ~= nil and dist <= ScsPumpHoseConnection.MAX_RANGE_M then
            shouldOffer = true
        end
    end
    if spec.connected then
        shouldOffer = spec.partner ~= nil
    end

    if shouldOffer then
        if not spec.activatableRegistered then
            g_currentMission.activatableObjectsSystem:addActivatable(spec.activatable)
            spec.activatableRegistered = true
        end
        if spec.activatable ~= nil then
            spec.activatable:updateActivateText()
        end
    elseif spec.activatableRegistered then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
        spec.activatableRegistered = false
    end
end

print("[CropStress] ScsPumpHoseConnection loaded (BUILD 21:42 hose world R + EVC pump K)")

-- ------------------------------------------------------------
-- Walk-up hose Activatable (vanilla ACTIVATE_OBJECT / R). Hose only.
-- Do not add a second ACTIVATE_OBJECT peer for Start/Stop.
-- ------------------------------------------------------------

ScsPumpHoseActivatable = {}
local ScsPumpHoseActivatable_mt = Class(ScsPumpHoseActivatable)

function ScsPumpHoseActivatable.new(vehicle)
    local self = setmetatable({}, ScsPumpHoseActivatable_mt)
    self.vehicle = vehicle
    self.activateText = phTr("action_SCS_CONNECT_HOSE", "Connect hose")
    return self
end

function ScsPumpHoseActivatable:updateActivateText()
    local spec = self.vehicle ~= nil and self.vehicle.spec_scsPumpHose or nil
    if spec ~= nil and spec.connected then
        self.activateText = phTr("action_SCS_DISCONNECT_HOSE", "Disconnect hose")
    else
        self.activateText = phTr("action_SCS_CONNECT_HOSE", "Connect hose")
    end
    if self.actionEventId ~= nil then
        g_inputBinding:setActionEventText(self.actionEventId, self.activateText)
    end
end

function ScsPumpHoseActivatable:getIsActivatable()
    local vehicle = self.vehicle
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil then
        return false
    end

    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local ok, current = pcall(g_localPlayer.getCurrentVehicle, g_localPlayer)
        if ok and current ~= nil then
            return false
        end
    end

    local partner = spec.connected and spec.partner or spec.candidate
    if partner == nil then
        return false
    end
    local dist = ScsPumpHoseConnection.getJointDistance(vehicle, partner)
    if dist == nil or dist > ScsPumpHoseConnection.MAX_RANGE_M then
        return false
    end

    local mission = g_currentMission
    local aos = mission ~= nil and mission.activatableObjectsSystem or nil
    if aos ~= nil and aos.posX ~= nil then
        local playerDist = self:getDistance(aos.posX, aos.posY or 0, aos.posZ)
        if playerDist >= math.huge then
            return false
        end
    end

    self:updateActivateText()
    return true
end

function ScsPumpHoseActivatable:getDistance(x, y, z)
    local vehicle = self.vehicle
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil then
        return math.huge
    end
    local partner = spec.connected and spec.partner or spec.candidate
    local a = phResolveHoseJoint(vehicle)
    local b = partner ~= nil and phResolveHoseJoint(partner) or nil
    if a == nil then
        return math.huge
    end
    local ax, ay, az = getWorldTranslation(a)
    local mx, my, mz = ax, ay, az
    if b ~= nil then
        local bx, by, bz = getWorldTranslation(b)
        mx = (ax + bx) * 0.5
        my = (ay + by) * 0.5
        mz = (az + bz) * 0.5
    end
    local d = phWorldDistance(x, y, z, mx, my, mz)
    if d > ScsPumpHoseConnection.ACTIVATE_RANGE_M then
        return math.huge
    end
    return d
end

function ScsPumpHoseActivatable:registerCustomInput(inputContext)
    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_OBJECT, self, self.run, false, true, false, true, nil, true, false)
    g_inputBinding:setActionEventText(actionEventId, self.activateText)
    g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
    g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    self.actionEventId = actionEventId
end

function ScsPumpHoseActivatable:removeCustomInput()
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
end

function ScsPumpHoseActivatable:run()
    local vehicle = self.vehicle
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil then
        return
    end
    if not vehicle.isServer then
        return
    end
    if spec.connected then
        vehicle:setScsHoseConnected(false)
    else
        vehicle:setScsHoseConnected(true)
    end
    self:updateActivateText()
end

