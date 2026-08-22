-- ============================================================
-- ScsPumpHoseConnection.lua
-- Suite-owned visible EMP (Aggregat) <-> Rainstar supply hose.
--
-- BUILD 19:27 FAILFIX: walk-up Connect/Disconnect, spawn short hose from
-- rwsmPumpHoseTemplate.i3d between hoseJoints, server WATER transfer
-- Aggregat FU1 -> Rainstar FU1 while connected + pump on.
-- Does NOT touch COBD ground-hose pool, ConnectionHoses, ISI moisture,
-- or SPS/LSFM. SP-first: dedicated MP connect Event unpaid.
-- ============================================================

ScsPumpHoseConnection = ScsPumpHoseConnection or {}

ScsPumpHoseConnection.modDir = (SeasonalCropStressModDirectory or g_currentModDirectory)
ScsPumpHoseConnection.currentModName = (SeasonalCropStressModName or g_currentModName)

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

--- Is this vehicle still backed by live engine nodes? A sold vehicle's Lua table outlives its
--- component entities, so a non-nil partner proves nothing; the component root is the honest
--- question, because if it is gone every child under it is gone too.
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
--- This is the ONE place the guard lives: every getWorldTranslation on a hose joint in this
--- file takes its node from here, so guarding the call sites instead would leave the next one
--- unguarded. The liveness gate runs BEFORE indexToObject, because that walk reads components
--- and steps through child nodes itself and is not safe on a destroyed vehicle.
local function phResolveHoseJoint(vehicle)
    if not phVehicleAlive(vehicle) then
        return nil
    end
    local node = I3DUtil.indexToObject(vehicle.components, "hoseJoint", vehicle.i3dMappings)
    if node ~= nil and node ~= 0 and entityExists(node) then
        return node
    end
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
    -- A running diesel engine is NOT a running pump. The old motor-started fallback
    -- here rested on a note that the Aggregat shipped with its turnOnVehicle block
    -- commented out; it does not (Aggregat.xml:217). The fallback made the walk-up
    -- prompt read "Stop pump" the moment the engine caught, so the player saw a pump
    -- that claimed to be running while getIsTurnedOn stayed false, the reel gate kept
    -- refusing, and pressing the prompt killed the engine instead of stopping a pump
    -- that had never started. The reel gate and the water transfer both mean this
    -- state, so this helper has to mean it too.
    return false
end

-- The connected Rainstar, but only when it actually carries the reel spec.
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

--- BUILD 22:25: phIsPumpRunning is a file local, and ScsRainstarPumpPower needs the
--- same answer to decide whether the reel is powered. Exposed rather than duplicated, so
--- there is one definition of "the pump is running" for the whole kit. Transfer logic
--- untouched.
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

function ScsPumpHoseConnection.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", ScsPumpHoseConnection)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", ScsPumpHoseConnection)
end

function ScsPumpHoseConnection:onLoad(savegame)
    local spec = {}
    self.spec_scsPumpHose = spec
    spec.hoseJoint = phResolveHoseJoint(self)
    spec.connected = false
    spec.partner = nil
    spec.activatable = ScsPumpHoseActivatable.new(self)
    spec.activatableRegistered = false
    -- BUILD 20:43: second walk-up surface, Start/Stop the pump on foot.
    spec.startActivatable = ScsPumpStartActivatable.new(self)
    spec.startActivatableRegistered = false
    spec.updateTimer = 0
    spec.transferTimer = 0
    spec.hoseRoot = nil
    spec.hoseSharedRequestId = nil
    spec.hoseTemplate = nil
    spec.hoseSegments = {}
    spec.candidate = nil
    spec.reelActionEvents = {}
    -- Motor start is asynchronous: getIsPowered() is still false in the frame
    -- tryStartMotor is called, so the turn-on has to be retried until it takes.
    spec.pendingTurnOn = false
    spec.pendingTurnOnTimer = 0

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
    -- Unconditional and idempotent: the old version only disconnected when connected was
    -- true and only unregistered when the flag said so, which leaves a stale candidate and a
    -- live prompt in exactly the case that matters.
    self:setScsHoseConnected(false, true)
    spec.partner = nil
    spec.candidate = nil
    spec.connected = false
    ScsPumpHoseConnection.releaseHoseActivatable(self)
    if spec.activatableRegistered and g_currentMission ~= nil
            and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
        spec.activatableRegistered = false
    end
    if spec.startActivatableRegistered and g_currentMission ~= nil
            and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.startActivatable)
        spec.startActivatableRegistered = false
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

        -- One Rainstar per Aggregat; clear any prior link on the partner.
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

--- Drop the hose activatable. Unconditional, matching vanilla Dog:delete and
--- AnimalLoadingTrigger, which call removeActivatable with no registration flag.
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

--- Forget a peer whose nodes the engine has destroyed. Guarding the joint reads stops the log
--- flood; this is the other half, or the pump stays connected to a vehicle that no longer
--- exists and keeps offering a hose prompt. The disconnect is forced because spec.connected
--- can already read false while partner is still set.
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
        -- Soft mid sag so the short supply hose does not read as a rigid rod.
        local sagFactor = 4 * t * (1 - t)
        y = y - ScsPumpHoseConnection.SAG_M * sagFactor
        -- A sagging hose lies on the ground, it does not sink through it. Only the
        -- interior points are lifted: the two ends stay exactly on their couplings,
        -- so a joint that sits below the sampled terrain height on a slope cannot
        -- tear the hose visual off the machine it is plugged into.
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
--
-- The vendored RWSM53AutoReel used to hand N to "the pump" whenever the hose was
-- connected, but nothing on this side ever claimed it, so connecting the hose
-- just deleted the binding. The Rainstar keeps its own N now; this is the second
-- surface, so the reel can also be started from the machine the player is
-- standing at when the hose goes on.
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
        -- Hidden until a Rainstar is actually on the hose.
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

-- Vanilla tryStartMotor only brings the motor to STARTING, and getCanBeTurnedOn
-- resolves to getIsPowered(), which stays false until the motor has finished
-- cranking. Turning on in the same frame therefore always declined silently: the
-- walk-up prompt flipped to "Stop pump" while getIsTurnedOn() stayed false, so
-- both the reel gate and the spray effect still read the pump as off.
function ScsPumpHoseConnection.updatePendingTurnOn(pump, dt)
    local spec = pump ~= nil and pump.spec_scsPumpHose or nil
    if spec == nil or not spec.pendingTurnOn then
        return
    end

    -- Give up if the player stopped the motor again while the start was pending.
    local motorStarted = true
    if pump.getIsMotorStarted ~= nil then
        local ok, value = pcall(pump.getIsMotorStarted, pump)
        motorStarted = (not ok) or (value == true)
    end
    if not motorStarted then
        spec.pendingTurnOn = false
        spec.pendingTurnOnTimer = 0
        return
    end

    if pump.getIsTurnedOn ~= nil then
        local ok, value = pcall(pump.getIsTurnedOn, pump)
        if ok and value == true then
            spec.pendingTurnOn = false
            spec.pendingTurnOnTimer = 0
            print("[CropStress] ScsPumpHose: pump turned on, reel gate is open")
            return
        end
    end

    -- The retry only runs while the pump is getting update ticks, and a pump
    -- nobody is standing in can drop out of the active list mid-crank.
    if pump.raiseActive ~= nil then
        pcall(pump.raiseActive, pump)
    end

    spec.pendingTurnOnTimer = (spec.pendingTurnOnTimer or 0) + (tonumber(dt) or 0)
    if spec.pendingTurnOnTimer > 15000 then
        spec.pendingTurnOn = false
        spec.pendingTurnOnTimer = 0
        print("[CropStress] ScsPumpHose: pump turn-on timed out, motor never finished starting")
        return
    end

    -- Wait for the motor to finish cranking, then set the state directly. This is
    -- the walk-up equivalent of what the player does by hand: start the engine,
    -- then press the turn-on binding. TurnOnVehicle:setIsTurnedOn carries no
    -- precondition of its own (TurnOnVehicle.lua:282); getCanBeTurnedOn is a guard
    -- the vanilla ACTION handler applies, and it resolves to getIsPowered, which is
    -- still false mid-crank. Gating the retry on it was what kept the pump off.
    local motorFinished = false
    if pump.getIsMotorStarted ~= nil then
        local ok, value = pcall(pump.getIsMotorStarted, pump)
        motorFinished = ok and value == true
    end
    if motorFinished and pump.setIsTurnedOn ~= nil then
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
    local elapsed = spec.updateTimer
    spec.updateTimer = 0

    -- Ahead of the range check: a sold partner is not an out-of-range partner.
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

    if self.isClient then
        ScsPumpHoseConnection.updateReelActionEvent(self)
    end

    if self.isServer and spec.connected then
        ScsPumpHoseConnection.transferWater(self, dt)
    end

    -- Walk-up activatable: offer Connect/Disconnect when a Rainstar is in range.
    if g_currentMission == nil or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    -- Before the candidate refresh: while connected, candidate is copied from partner
    -- below, so a dead partner would be promoted straight back and keep the prompt.
    ScsPumpHoseConnection.invalidateDeadPeer(self)

    if not spec.connected then
        spec.candidate = ScsPumpHoseConnection.findNearestRainstar(self)
    else
        spec.candidate = spec.partner
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

    -- Start/Stop is offered on proximity to the pump itself, not to a hose partner:
    -- the player has to be able to start it BEFORE a hose exists, which is the whole
    -- point of the walk-up path.
    if spec.startActivatable ~= nil then
        if not spec.startActivatableRegistered then
            g_currentMission.activatableObjectsSystem:addActivatable(spec.startActivatable)
            spec.startActivatableRegistered = true
        end
        spec.startActivatable:updateActivateText()
    end
end

-- ------------------------------------------------------------
-- Walk-up activatable (vanilla use prompt)
-- ------------------------------------------------------------

ScsPumpHoseActivatable = ScsPumpHoseActivatable or {}
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
end

function ScsPumpHoseActivatable:getIsActivatable()
    local vehicle = self.vehicle
    local spec = vehicle ~= nil and vehicle.spec_scsPumpHose or nil
    if spec == nil then
        return false
    end

    -- Walk-up only: hide while the local player is inside a vehicle.
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local ok, current = pcall(g_localPlayer.getCurrentVehicle, g_localPlayer)
        if ok and current ~= nil then
            return false
        end
    end

    -- AOS polls this every frame while registered, so it is the first place a sold peer
    -- shows up, and clearing here is what makes the prompt go on the same frame.
    ScsPumpHoseConnection.invalidateDeadPeer(vehicle)

    local partner = spec.connected and spec.partner or spec.candidate
    if partner == nil then
        return false
    end
    local dist = ScsPumpHoseConnection.getJointDistance(vehicle, partner)
    if dist == nil or dist > ScsPumpHoseConnection.MAX_RANGE_M then
        return false
    end

    -- Player must be near the midpoint (getDistance math.huge alone is not enough:
    -- a lone activatable with infinite distance still becomes current).
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
    -- No clearing here: getDistance is a query AOS may call mid-iteration. A dead peer just
    -- stops contributing to the midpoint; getIsActivatable above does the dropping.
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
    -- SP-first: connect state is local/server only. Dedicated MP hose Event unpaid.
    if not vehicle.isServer then
        return
    end
    if spec.connected then
        vehicle:setScsHoseConnected(false)
    else
        vehicle:setScsHoseConnected(true)
    end
    self:updateActivateText()
    if self.actionEventId ~= nil then
        g_inputBinding:setActionEventText(self.actionEventId, self.activateText)
    end
end

-- ------------------------------------------------------------
-- BUILD 20:43 walk-up pump Start/Stop
--
-- George offered two shapes. His option 2 (externalVehicleControl trigger) is the more
-- vanilla one, but it needs a trigger node carrying a PLAYER collision filter authored
-- into Aggregat.i3d, and a trigger needs real collision geometry, which lives in the
-- .i3d.shapes binary I cannot author. His option 3 is this: one Activatable driving the
-- same vanilla events. No new geometry, no new motor API, one UX surface rather than three.
-- ------------------------------------------------------------

ScsPumpStartActivatable = ScsPumpStartActivatable or {}
local ScsPumpStartActivatable_mt = Class(ScsPumpStartActivatable)

ScsPumpStartActivatable.RANGE_M = 5

function ScsPumpStartActivatable.new(vehicle)
    local self = setmetatable({}, ScsPumpStartActivatable_mt)
    self.vehicle = vehicle
    self.activateText = phTr("action_SCS_START_PUMP", "Start pump")
    return self
end

function ScsPumpStartActivatable:updateActivateText()
    if phIsPumpRunning(self.vehicle) then
        self.activateText = phTr("action_SCS_STOP_PUMP", "Stop pump")
    else
        self.activateText = phTr("action_SCS_START_PUMP", "Start pump")
    end
    if self.actionEventId ~= nil then
        g_inputBinding:setActionEventText(self.actionEventId, self.activateText)
    end
end

function ScsPumpStartActivatable:getIsActivatable()
    local vehicle = self.vehicle
    if vehicle == nil then
        return false
    end
    -- Walk-up only. Inside the cab the vanilla ignition is the surface, not this.
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local ok, current = pcall(g_localPlayer.getCurrentVehicle, g_localPlayer)
        if ok and current ~= nil then
            return false
        end
    end
    local mission = g_currentMission
    local aos = mission ~= nil and mission.activatableObjectsSystem or nil
    if aos ~= nil and aos.posX ~= nil then
        if self:getDistance(aos.posX, aos.posY or 0, aos.posZ) >= math.huge then
            return false
        end
    end
    self:updateActivateText()
    return true
end

function ScsPumpStartActivatable:getDistance(x, y, z)
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.rootNode == nil then
        return math.huge
    end
    local ok, vx, vy, vz = pcall(getWorldTranslation, vehicle.rootNode)
    if not ok or vx == nil then
        return math.huge
    end
    local d = phWorldDistance(x, y, z, vx, vy, vz)
    if d > ScsPumpStartActivatable.RANGE_M then
        return math.huge
    end
    return d
end

function ScsPumpStartActivatable:registerCustomInput(inputContext)
    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_OBJECT, self, self.run, false, true, false, true, nil, true, false)
    g_inputBinding:setActionEventText(actionEventId, self.activateText)
    g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
    g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    self.actionEventId = actionEventId
end

function ScsPumpStartActivatable:removeCustomInput()
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
end

function ScsPumpStartActivatable:run()
    local vehicle = self.vehicle
    if vehicle == nil then
        return
    end
    local spec = vehicle.spec_scsPumpHose
    local running = phIsPumpRunning(vehicle)
    if running then
        -- Turn-on off first, then stop the motor, so the hose spec sees a clean stop
        -- rather than a turned-on pump with a dead engine.
        if spec ~= nil then
            spec.pendingTurnOn = false
            spec.pendingTurnOnTimer = 0
        end
        if vehicle.setIsTurnedOn ~= nil then
            pcall(vehicle.setIsTurnedOn, vehicle, false)
        end
        if vehicle.stopMotor ~= nil then
            pcall(vehicle.stopMotor, vehicle)
        end
    else
        -- Vanilla start path. tryStartMotor is the same call the vanilla walk-up
        -- ExternalVehicleControl handler makes, so fuel and motor contracts hold and the
        -- MotorSetTurnedOnEvent goes out for us.
        if Motorized ~= nil and type(Motorized.tryStartMotor) == "function" then
            pcall(Motorized.tryStartMotor, vehicle)
        end
        -- getCanBeTurnedOn resolves to getIsPowered, which is still false while the
        -- motor is only STARTING. Arm the retry instead of firing one attempt that
        -- always declines; ScsPumpHoseConnection.updatePendingTurnOn finishes the job
        -- once the motor reports powered.
        if spec ~= nil then
            spec.pendingTurnOn = true
            spec.pendingTurnOnTimer = 0
        end
        -- Keep the pump scheduled so the retry actually gets update ticks while the
        -- player is still standing outside it.
        if vehicle.raiseActive ~= nil then
            pcall(vehicle.raiseActive, vehicle)
        end
        ScsPumpHoseConnection.updatePendingTurnOn(vehicle, 0)
    end
    self:updateActivateText()
end
