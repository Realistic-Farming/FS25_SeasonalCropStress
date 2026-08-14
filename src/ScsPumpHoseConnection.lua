-- ============================================================
-- ScsPumpHoseConnection.lua
-- Suite-owned visible EMP (Aggregat) <-> Rainstar supply hose.
--
-- BUILD 22:53: server-sticky walk-up turn-on (tryStartMotor then
-- setIsTurnedOn while STARTING/ON so SetTurnedOnEvent lands before
-- leave-stop); pump raiseActive while getIsTurnedOn; K = pump only.
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

--- Is this vehicle still backed by live engine nodes?
--- A sold vehicle's Lua table outlives its component entities: Vehicle:delete unlinks and
--- deletes the component nodes, but any table still holding a reference to that vehicle keeps
--- a perfectly valid-looking Lua object whose node ids now point at nothing. So a non-nil
--- partner proves nothing, and the component root is the thing worth asking about: if it is
--- gone, every child node under it is gone too.
local function phVehicleAlive(vehicle)
    if vehicle == nil then
        return false
    end
    if vehicle.isDeleted == true then
        return false
    end
    if type(vehicle.getIsBeingDeleted) == "function" and vehicle:getIsBeingDeleted() then
        return false
    end
    local components = vehicle.components
    if components == nil or components[1] == nil then
        return false
    end
    local root = components[1].node
    if root == nil or root == 0 or entityExists == nil or not entityExists(root) then
        return false
    end
    return true
end

--- Resolve a vehicle's hose joint, or nil if there is nothing live to resolve.
---
--- BUILD 17:07: this is the ONE place the guard lives, and that is deliberate. Every
--- getWorldTranslation on a hose joint in this file takes its node from here, so guarding the
--- call sites instead would leave the next one somebody adds unguarded. Selling the Rainstar
--- used to flood the client because this returned a stale id and the callers trusted it.
---
--- The liveness gate is checked BEFORE indexToObject, not after: that walk reads
--- vehicle.components and steps through child nodes itself, so it is not safe to call on a
--- vehicle whose components the engine has already destroyed.
local function phResolveHoseJoint(vehicle)
    if not phVehicleAlive(vehicle) then
        return nil
    end
    local node = I3DUtil.indexToObject(vehicle.components, "hoseJoint", vehicle.i3dMappings)
    if node ~= nil and node ~= 0 and entityExists(node) then
        return node
    end
    -- Fallback to the component root. phVehicleAlive already proved this one exists, but it
    -- is re-checked rather than assumed so the two can never drift apart.
    local root = vehicle.components[1].node
    if root ~= nil and root ~= 0 and entityExists(root) then
        return root
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

--- BUILD 06:39 (Vera F2): "running" and "settled on" are not the same question.
--- phIsPumpRunning answers the raw frame. The button text needs the STABLE answer, the
--- same one the 06:22 latch uses, or the label flickers on reads the latch is busy
--- absorbing. One definition so the two cannot drift apart again.
local function phPumpSettledOn(vehicle)
    if not phIsPumpRunning(vehicle) then
        return false
    end
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil then
        return true
    end
    -- Settled once the turn-on has held for the latch window, or once the gate has
    -- already been declared open for this run.
    return (spec.turnedOnHoldMs or 0) >= 250 or spec.loggedGateOpen == true
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
        -- Pending / walk-up intent must be sticky on the server for the whole
        -- crank window (leave-stop ~250 ms). Do not gate intent on motor state.
        if spec.pendingTurnOn == true or spec.walkUpMotorIntent == true then
            return true
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
    -- BUILD 17:07: unconditional and idempotent. The old version only disconnected when
    -- spec.connected was true and only unregistered when the flag said it was registered,
    -- which leaves a stale candidate and a live prompt in exactly the case that matters:
    -- connected already false, partner or candidate still pointing at something.
    self:setScsHoseConnected(false, true)
    spec.partner = nil
    spec.candidate = nil
    spec.connected = false
    ScsPumpHoseConnection.releaseHoseActivatable(self)
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

--- Drop the hose activatable. Unconditional on purpose: vanilla does the same in
--- Dog:delete and AnimalLoadingTrigger:delete, and calls it repeatedly from an update
--- branch with no registration flag, so it is safe to call when nothing is registered.
--- Gating this on activatableRegistered would mean a flag that has drifted out of step
--- leaves a dead prompt on screen, which is the failure being fixed here.
function ScsPumpHoseConnection.releaseHoseActivatable(pump)
    local spec = pump ~= nil and pump.spec_scsPumpHose or nil
    if spec == nil then
        return
    end
    local aos = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if aos ~= nil and spec.activatable ~= nil then
        aos:removeActivatable(spec.activatable)
    end
    spec.activatableRegistered = false
end

--- Forget a peer whose nodes the engine has destroyed.
---
--- BUILD 17:07: guarding the joint reads stops the log flood, but on its own it would leave
--- the pump connected to a vehicle that no longer exists, still offering a hose prompt. This
--- is the other half. It runs from the tick and from the top of the activatable query, since
--- that query is what gets polled every frame and so notices first.
---
--- The disconnect is forced because spec.connected may already read false while partner is
--- still set, and the unforced path returns early on exactly that case.
---@return boolean true when something stale was dropped
function ScsPumpHoseConnection.invalidateDeadPeer(pump)
    local spec = pump ~= nil and pump.spec_scsPumpHose or nil
    if spec == nil then
        return false
    end
    local dropped = false
    if spec.partner ~= nil and not phVehicleAlive(spec.partner) then
        if pump.setScsHoseConnected ~= nil then
            pump:setScsHoseConnected(false, true)
        end
        -- setScsHoseConnected already nils partner on its disconnect branch. Repeated here so
        -- a later edit to that branch cannot silently leave the dead reference behind.
        spec.partner = nil
        spec.connected = false
        dropped = true
    end
    if spec.candidate ~= nil and not phVehicleAlive(spec.candidate) then
        spec.candidate = nil
        dropped = true
    end
    if dropped then
        if pump.RPC ~= nil then
            pump.RPC.virtualHoseConnected = false
            pump.RPC.virtualRainstar = nil
        end
        ScsPumpHoseConnection.releaseHoseActivatable(pump)
        ScsPumpHoseConnection.deleteHoseVisual(pump)
    end
    return dropped
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
    -- BUILD 06:39 (Vera F2): stable latch, not the raw frame. Was phIsPumpRunning here,
    -- which flickered the label on exactly the reads 06:22 exists to absorb.
    if phPumpSettledOn(vehicle) then
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
            -- BUILD 06:39 (Vera F3): the hold counters are latch state and must reset
            -- wherever the latch does. Left standing, a stop-then-start let the previous
            -- run's turnedOnHoldMs count the very next frame as settled.
            spec.turnedOnHoldMs = 0
            spec.motorOffHoldMs = 0
            spec.loggedGateOpen = false
        end
        if ScsPumpWalkUpIntentEvent ~= nil and ScsPumpWalkUpIntentEvent.send ~= nil then
            ScsPumpWalkUpIntentEvent.send(vehicle, false)
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

    -- Vanilla EVC order: start motor, then turn-on once STARTING/ON so
    -- SetTurnedOnEvent is the server leave-stop shield (not client-only pending).
    if Motorized ~= nil and type(Motorized.tryStartMotor) == "function" then
        pcall(Motorized.tryStartMotor, vehicle)
    end
    if spec ~= nil then
        spec.pendingTurnOn = true
        spec.pendingTurnOnTimer = 0
        spec.sawMotorStart = false
        spec.walkUpMotorIntent = true
        -- Fresh crank, fresh holds (Vera F3).
        spec.turnedOnHoldMs = 0
        spec.motorOffHoldMs = 0
        spec.loggedGateOpen = false
    end

    local motorState = nil
    if vehicle.getMotorState ~= nil then
        local ok, state = pcall(vehicle.getMotorState, vehicle)
        if ok then
            motorState = state
        end
    end
    if MotorState ~= nil
            and (motorState == MotorState.STARTING or motorState == MotorState.ON)
            and vehicle.setIsTurnedOn ~= nil then
        pcall(vehicle.setIsTurnedOn, vehicle, true)
    end

    -- Dedicated: mirror intent onto the server so getRequiresPower sticks
    -- even if SetTurnedOnEvent lags past the 250 ms leave-stop window.
    if ScsPumpWalkUpIntentEvent ~= nil and ScsPumpWalkUpIntentEvent.send ~= nil then
        ScsPumpWalkUpIntentEvent.send(vehicle, true)
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
        -- BUILD 06:22: this used to act on a SINGLE true read. One flickering frame
        -- dropped the crank intent and flipped the prompt back to Start pump, which is
        -- the on/off flutter in the report. Require the state to hold before believing it.
        if ok and value == true then
            spec.turnedOnHoldMs = (spec.turnedOnHoldMs or 0) + (tonumber(dt) or 0)
        else
            spec.turnedOnHoldMs = 0
        end
        if ok and value == true and (spec.turnedOnHoldMs or 0) >= 250 then
            spec.pendingTurnOn = false
            spec.pendingTurnOnTimer = 0
            spec.sawMotorStart = false
            -- Turn-on is now the leave-stop shield; clear crank intent.
            spec.walkUpMotorIntent = false
            -- Print on the transition only. Per-frame it was pure log spam.
            if spec.loggedGateOpen ~= true then
                spec.loggedGateOpen = true
                print("[CropStress] ScsPumpHose: pump turned on, reel gate is open")
            end
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
            spec.turnedOnHoldMs = 0
            spec.loggedGateOpen = false
            if ScsPumpWalkUpIntentEvent ~= nil and ScsPumpWalkUpIntentEvent.send ~= nil and pump.isServer then
                ScsPumpWalkUpIntentEvent.send(pump, false)
            end
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
        if ScsPumpWalkUpIntentEvent ~= nil and ScsPumpWalkUpIntentEvent.send ~= nil and pump.isServer then
            ScsPumpWalkUpIntentEvent.send(pump, false)
        end
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

    -- Ahead of the range check, because a sold partner is not an out-of-range partner and
    -- the distance helper now answers nil for it either way.
    ScsPumpHoseConnection.invalidateDeadPeer(self)

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

    -- Mirror Rainstar BUILD 22:29: keep pump in the update loop while turned on.
    if self.isServer and phIsPumpRunning(self) and self.raiseActive ~= nil then
        pcall(self.raiseActive, self)
    end

    if spec.walkUpMotorIntent and not spec.pendingTurnOn and not phIsPumpRunning(self) then
        local motorOff = true
        if self.getMotorState ~= nil and MotorState ~= nil then
            local ok, state = pcall(self.getMotorState, self)
            if ok and (state == MotorState.STARTING or state == MotorState.ON) then
                motorOff = false
            end
        end
        -- BUILD 06:22: same one-frame problem from the other side. A single off read
        -- between STARTING ticks used to drop the intent mid-crank.
        if motorOff then
            spec.motorOffHoldMs = (spec.motorOffHoldMs or 0) + (tonumber(dt) or 0)
        else
            spec.motorOffHoldMs = 0
        end
        if motorOff and (spec.motorOffHoldMs or 0) >= 500 then
            spec.walkUpMotorIntent = false
            spec.sawMotorStart = false
            spec.motorOffHoldMs = 0
        end
    else
        spec.motorOffHoldMs = 0
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

    -- Before the candidate refresh and before shouldOffer: while connected, candidate is
    -- copied from partner below, so a dead partner would otherwise be promoted straight back
    -- into candidate and keep the prompt alive.
    ScsPumpHoseConnection.invalidateDeadPeer(self)

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

print("[CropStress] ScsPumpHoseConnection loaded (BUILD 17:07 dead-peer guards + sticky turn-on + pump keep-awake + K pump only)")

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

    -- BUILD 17:07: AOS polls this every frame while the object is registered, so it is the
    -- first place a sold peer shows up. Clearing here rather than only on the tick is what
    -- makes the prompt disappear on the same frame the flood would have started.
    ScsPumpHoseConnection.invalidateDeadPeer(vehicle)

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
    -- No clearing from here: getDistance is a query AOS may call in the middle of its own
    -- iteration. A dead peer just stops contributing to the midpoint, and getIsActivatable
    -- above does the actual dropping.
    if partner ~= nil and not phVehicleAlive(partner) then
        partner = nil
    end
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

