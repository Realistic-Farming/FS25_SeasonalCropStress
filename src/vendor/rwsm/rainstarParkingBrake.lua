-- Vendored from FS25_RealisticWaterSoilManagement (Sherman / original HoFFi)
-- for SeasonalCropStress BUILD 21:13 Phase 1. Unmodified except where marked
-- 'SCS vendor note'. Moisture stays on the SCS door: this file does not write
-- soil moisture, and RWSM53WaterControl is deliberately not shipped.
-- Realistic Water & Soil Management
-- Automatic parking brake for the detached Bauer Rainstar hose reel
-- Author: Sherman
-- Version: 1.38.36

RWSM118RainstarParkingBrake = {}

local REEL_WHEEL_COUNT = 2
local LOAD_STABILIZATION_MS = 12000
local CART_WHEEL_START_INDEX = 3
local CART_WHEEL_END_INDEX = 5
local ASSEMBLY_TIPPED_UP_DOT = 0.55
local CART_TIP_CHECK_MS = 100

local function rpbGetFoldTime(vehicle)
    if vehicle ~= nil and vehicle.getFoldAnimTime ~= nil then
        local ok, value = pcall(vehicle.getFoldAnimTime, vehicle)
        if ok and value ~= nil then return tonumber(value) end
    end
    if vehicle ~= nil and vehicle.spec_foldable ~= nil then
        return tonumber(vehicle.spec_foldable.foldAnimTime) or 1
    end
    return 1
end

local function rpbIsWorkMode(vehicle)
    return rpbGetFoldTime(vehicle) < 0.5
end

local function rpbIsReelActive(vehicle)
    return vehicle ~= nil and vehicle.RAR ~= nil and vehicle.RAR.reelCommandActive == true
end

function RWSM118RainstarParkingBrake.initSpecialization()
end

function RWSM118RainstarParkingBrake.prerequisitesPresent(specializations)
    return true
end

function RWSM118RainstarParkingBrake.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", RWSM118RainstarParkingBrake)
    SpecializationUtil.registerEventListener(vehicleType, "onPostAttach", RWSM118RainstarParkingBrake)
    SpecializationUtil.registerEventListener(vehicleType, "onPostDetach", RWSM118RainstarParkingBrake)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", RWSM118RainstarParkingBrake)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", RWSM118RainstarParkingBrake)
end

function RWSM118RainstarParkingBrake.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(
        vehicleType,
        "getIsSupportAnimationAllowed",
        RWSM118RainstarParkingBrake.getIsSupportAnimationAllowed
    )
end

local function rpbGetAttacherVehicle(vehicle)
    if vehicle == nil then return nil end

    if vehicle.getAttacherVehicle ~= nil then
        local ok, attacherVehicle = pcall(vehicle.getAttacherVehicle, vehicle)
        if ok then return attacherVehicle end
    end

    if vehicle.spec_attachable ~= nil then
        return vehicle.spec_attachable.attacherVehicle
    end

    return nil
end



local function rpbNormalizePath(path)
    return string.lower(string.gsub(tostring(path or ""), "\\", "/"))
end

local function rpbIsMotorPump(vehicle)
    if vehicle == nil then return false end
    local path = rpbNormalizePath(vehicle.configFileName)
    return string.sub(path, -#"aggregat.xml") == "aggregat.xml"
        or string.find(path, "/data/aggregat.xml", 1, true) ~= nil
end

local function rpbIsMotorPumpConnected(vehicle)
    if vehicle ~= nil then
        local virtualPump = vehicle.rwsmVirtualPump
        if virtualPump ~= nil and virtualPump.RPC ~= nil
            and virtualPump.RPC.virtualHoseConnected == true
            and virtualPump.RPC.virtualRainstar == vehicle then
            return true
        end
        if RWSMPumpConnectionState ~= nil
            and RWSMPumpConnectionState.findVirtualPumpForRainstar ~= nil then
            local ok, pump = pcall(RWSMPumpConnectionState.findVirtualPumpForRainstar, vehicle)
            if ok and pump ~= nil then return true end
        end
    end

    local data = vehicle ~= nil and vehicle.RPB or nil
    local now = tonumber(g_time) or 0
    if data ~= nil and tonumber(data.pumpConnectionCacheUntil) ~= nil
        and now < data.pumpConnectionCacheUntil then
        return data.pumpConnectionCached == true
    end

    local connected = false
    local attacherVehicle = rpbGetAttacherVehicle(vehicle)
    if rpbIsMotorPump(attacherVehicle) then
        connected = true
    end

    -- Manual Attach can temporarily leave the active input-joint index unset
    -- even though the physical pump/Rainstar implement relation already exists.
    -- The expensive mission-wide fallback is cached for 500 ms and invalidated
    -- immediately by the normal attach/detach events.
    local spec = vehicle ~= nil and vehicle.spec_attachable or nil
    if not connected and spec ~= nil and rpbIsMotorPump(spec.attacherVehicle) then
        connected = true
    end

    if not connected and g_currentMission ~= nil then
        local vehicles = ShermanRuntimeCore ~= nil and ShermanRuntimeCore.getVehicles ~= nil
            and ShermanRuntimeCore.getVehicles("pumps")
            or (g_currentMission.vehicleSystem ~= nil
                and g_currentMission.vehicleSystem.vehicles or g_currentMission.vehicles)
        for _, candidate in pairs(vehicles or {}) do
            if rpbIsMotorPump(candidate) and candidate.spec_attacherJoints ~= nil then
                for _, implement in pairs(candidate.spec_attacherJoints.attachedImplements or {}) do
                    local object = type(implement) == "table"
                        and (implement.object or implement.vehicle) or nil
                    if object == vehicle then
                        connected = true
                        break
                    end
                end
            end
            if connected then break end
        end
    end

    if data ~= nil then
        data.pumpConnectionCached = connected
        data.pumpConnectionCacheUntil = now + 500
    end
    return connected
end

local function rpbGetActiveInputJointIndex(vehicle)
    if vehicle == nil then return nil end
    if vehicle.getActiveInputAttacherJointDescIndex ~= nil then
        local ok, index = pcall(vehicle.getActiveInputAttacherJointDescIndex, vehicle)
        if ok then return index end
    end
    if vehicle.spec_attachable ~= nil then
        return vehicle.spec_attachable.inputAttacherJointDescIndex
    end
    return nil
end

local function rpbIsTractorAttachedToCart(vehicle)
    return tonumber(rpbGetActiveInputJointIndex(vehicle)) == 2
        and rpbGetAttacherVehicle(vehicle) ~= nil
end

local function rpbGetComponentNode(vehicle, componentIndex)
    if vehicle == nil or vehicle.components == nil or vehicle.components[componentIndex] == nil then
        return nil
    end
    local node = vehicle.components[componentIndex].node
    if node == nil or node == 0 then return nil end
    if entityExists ~= nil and not entityExists(node) then return nil end
    return node
end

local function rpbIsNodeTipped(node)
    if node == nil or localDirectionToWorld == nil then return false end
    local ok, _, upY, _ = pcall(localDirectionToWorld, node, 0, 1, 0)
    return ok and tonumber(upY) ~= nil and upY < ASSEMBLY_TIPPED_UP_DOT
end

local function rpbIsAssemblyTipped(vehicle)
    -- Component 1 is the hose-reel chassis, component 2 the sprinkler cart.
    -- 1.38.27 watched only component 2, so a tipped reel chassis could still
    -- move under passive wheel/joint physics even with pump and reel switched off.
    return rpbIsNodeTipped(rpbGetComponentNode(vehicle, 1))
        or rpbIsNodeTipped(rpbGetComponentNode(vehicle, 2))
end



local SUPPORT_ANIMATION_NAME = "moveSupport"

local function rpbUsesPumpInputJoint(vehicle, attacherVehicle, inputJointDescIndex)
    local index = tonumber(inputJointDescIndex) or tonumber(rpbGetActiveInputJointIndex(vehicle))
    if index == 3 then return true end
    if rpbIsMotorPump(attacherVehicle) then return true end
    return rpbIsMotorPumpConnected(vehicle)
end

local function rpbKeepSupportWheelDown(vehicle)
    if vehicle == nil or vehicle.setAnimationTime == nil then return end
    if vehicle.getAnimationExists ~= nil then
        local okExists, exists = pcall(vehicle.getAnimationExists, vehicle, SUPPORT_ANIMATION_NAME)
        if okExists and exists ~= true then return end
    end

    local currentTime = nil
    if vehicle.getAnimationTime ~= nil then
        local okTime, value = pcall(vehicle.getAnimationTime, vehicle, SUPPORT_ANIMATION_NAME)
        if okTime then currentTime = tonumber(value) end
    end
    if currentTime ~= nil and currentTime >= 0.999 then return end

    if vehicle.stopAnimation ~= nil then
        pcall(vehicle.stopAnimation, vehicle, SUPPORT_ANIMATION_NAME, true)
    end
    pcall(vehicle.setAnimationTime, vehicle, SUPPORT_ANIMATION_NAME, 1, true, false)
end

function RWSM118RainstarParkingBrake:getIsSupportAnimationAllowed(superFunc, supportAnimation)
    -- Savegame reconstruction must be owned completely by GIANTS. Blocking the
    -- native support animation while the saved attachment chain is still being
    -- rebuilt can put the support wheel into the ground and create a physics
    -- impulse that flips or launches the whole pump/Rainstar combination.
    if self.RPB ~= nil
        and (tonumber(g_time) or 0) < (tonumber(self.RPB.loadStabilizeUntil) or 0) then
        return superFunc(self, supportAnimation)
    end

    if supportAnimation ~= nil
        and supportAnimation.animationName == SUPPORT_ANIMATION_NAME
        and rpbIsMotorPumpConnected(self) then
        return false
    end
    return superFunc(self, supportAnimation)
end

local function rpbSetWheelBrakeRange(vehicle, brakePedal, firstIndex, lastIndex)
    if vehicle == nil or vehicle.spec_wheels == nil or vehicle.spec_wheels.wheels == nil then
        return
    end
    for index, wheel in ipairs(vehicle.spec_wheels.wheels) do
        if index >= firstIndex and index <= lastIndex and wheel ~= nil and wheel.setBrakePedal ~= nil then
            pcall(wheel.setBrakePedal, wheel, brakePedal)
        end
    end
end

local function rpbSetReelWheelBrakes(vehicle, brakePedal)
    rpbSetWheelBrakeRange(vehicle, brakePedal, 1, REEL_WHEEL_COUNT)
end

local function rpbSetCartWheelBrakes(vehicle, brakePedal)
    rpbSetWheelBrakeRange(vehicle, brakePedal, CART_WHEEL_START_INDEX, CART_WHEEL_END_INDEX)
end

local function rpbSetAllWheelBrakes(vehicle, brakePedal)
    if vehicle == nil or vehicle.spec_wheels == nil or vehicle.spec_wheels.wheels == nil then return end
    rpbSetWheelBrakeRange(vehicle, brakePedal, 1, #vehicle.spec_wheels.wheels)
end

local function rpbStopTippedAssemblyMotion(vehicle)
    rpbSetAllWheelBrakes(vehicle, 1)

    -- This is passive rollover stabilization and does not depend on pump state
    -- or an active reel command. If no tractor is physically attached to the
    -- Rainstar, remove horizontal and angular residual motion from every dynamic
    -- component while gravity remains free vertically. This prevents the tipped
    -- assembly from 'driving' across the map through wheel/suspension/joint forces.
    local actualAttacher = rpbGetAttacherVehicle(vehicle)
    if actualAttacher == nil and not rpbIsTractorAttachedToCart(vehicle) then
        for componentIndex = 1, 3 do
            local node = rpbGetComponentNode(vehicle, componentIndex)
            if node ~= nil then
                if getLinearVelocity ~= nil and setLinearVelocity ~= nil then
                    local ok, _, vy, _ = pcall(getLinearVelocity, node)
                    if ok then pcall(setLinearVelocity, node, 0, tonumber(vy) or 0, 0) end
                end
                if setAngularVelocity ~= nil then
                    pcall(setAngularVelocity, node, 0, 0, 0)
                end
            end
        end
    end
end


local function rpbGetReelNode(vehicle)
    if vehicle == nil or vehicle.components == nil or vehicle.components[1] == nil then
        return nil
    end
    local node = vehicle.components[1].node
    if node == nil or node == 0 or entityExists == nil or not entityExists(node) then
        return nil
    end
    return node
end

local function rpbCaptureAnchor(vehicle)
    local data = vehicle ~= nil and vehicle.RPB or nil
    local node = rpbGetReelNode(vehicle)
    if data == nil or node == nil then return end
    local x, _, z = getWorldTranslation(node)
    data.anchorX = x
    data.anchorZ = z
    data.anchorValid = true
end

local function rpbHoldReelChassis(vehicle, correctPosition)
    local data = vehicle ~= nil and vehicle.RPB or nil
    local node = rpbGetReelNode(vehicle)
    if data == nil or node == nil then return end

    if not data.anchorValid then
        rpbCaptureAnchor(vehicle)
    end

    -- The reel chassis is the stationary end of the hose system. Keep its
    -- horizontal velocity at zero while detached so joint tension moves the
    -- sprinkler cart toward the drum instead of dragging the drum across the field.
    if getLinearVelocity ~= nil and setLinearVelocity ~= nil then
        local _, vy, _ = getLinearVelocity(node)
        setLinearVelocity(node, 0, vy, 0)
    end

    if getAngularVelocity ~= nil and setAngularVelocity ~= nil then
        setAngularVelocity(node, 0, 0, 0)
    end

    if correctPosition and data.anchorValid and setWorldTranslation ~= nil then
        local x, y, z = getWorldTranslation(node)
        local dx = x - data.anchorX
        local dz = z - data.anchorZ
        if dx * dx + dz * dz > 0.0004 then
            setWorldTranslation(node, data.anchorX, y, data.anchorZ)
        end
    end
end

local function rpbHoldPumpWorkSetup(vehicle)
    -- Only use physical wheel brakes after the native attachment chain is fully
    -- restored. Never correct world position or zero component velocities while
    -- the motor pump is attached: doing so fights the GIANTS attacher joint and
    -- was the source of the save/load teleport/rotation problem.
    rpbKeepSupportWheelDown(vehicle)
    rpbSetReelWheelBrakes(vehicle, 1)
    rpbSetCartWheelBrakes(vehicle, 1)
end

function RWSM118RainstarParkingBrake:onPostAttach(attacherVehicle, inputJointDescIndex, jointDescIndex)
    if self.RPB ~= nil then
        self.RPB.pumpConnectionCached = rpbIsMotorPump(attacherVehicle) or tonumber(inputJointDescIndex) == 3
        self.RPB.pumpConnectionCacheUntil = (tonumber(g_time) or 0) + 500
    end
    if rpbUsesPumpInputJoint(self, attacherVehicle, inputJointDescIndex)
        and (tonumber(g_time) or 0) >= (tonumber(self.RPB ~= nil and self.RPB.loadStabilizeUntil) or 0) then
        rpbKeepSupportWheelDown(self)
    end
end

function RWSM118RainstarParkingBrake:onPostDetach(implementIndex)
    if self.RPB ~= nil then
        self.RPB.pumpConnectionCacheUntil = 0
        self.RPB.pumpConnectionCached = false
    end
    -- Do not force support movement during savegame reconstruction.
    if (tonumber(g_time) or 0) >= (tonumber(self.RPB ~= nil and self.RPB.loadStabilizeUntil) or 0) then
        rpbKeepSupportWheelDown(self)
    end
end

function RWSM118RainstarParkingBrake:onLoad(savegame)
    self.RPB = {
        parkingBrakeApplied = false,
        anchorValid = false,
        anchorX = 0,
        anchorZ = 0,
        pumpConnectionCached = false,
        pumpConnectionCacheUntil = 0,
        cartTipTimer = 0,
        assemblyTipped = false,
        loadStabilizeUntil = (tonumber(g_time) or 0) + LOAD_STABILIZATION_MS
    }

    print("[RWSM v1.38.36] Hose-only deployment keeps the reel chassis physically planted")
end

function RWSM118RainstarParkingBrake:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if not self.isServer or self.RPB == nil then
        return
    end

    self.RPB.cartTipTimer = (self.RPB.cartTipTimer or 0) + (tonumber(dt) or 0)
    if self.RPB.cartTipTimer >= CART_TIP_CHECK_MS then
        self.RPB.cartTipTimer = self.RPB.cartTipTimer - CART_TIP_CHECK_MS
        self.RPB.assemblyTipped = rpbIsAssemblyTipped(self)
    end

    if self.RPB.assemblyTipped == true then
        if self.RAR ~= nil then
            self.RAR.tipSafetyActive = true
            self.RAR.reelCommandActive = false
        end
        if self.stopAnimation ~= nil then
            pcall(self.stopAnimation, self, "hoseReelLS19", false)
        end
        rpbStopTippedAssemblyMotion(self)
        self.RPB.parkingBrakeApplied = true
        self.RPB.anchorValid = false
        return
    elseif self.RAR ~= nil then
        self.RAR.tipSafetyActive = false
    end

    local activeInputJointIndex = rpbGetActiveInputJointIndex(self)
    local attacherVehicle = rpbGetAttacherVehicle(self)
    local confirmedPumpConnected = rpbIsMotorPumpConnected(self)
    local pumpInputActive = confirmedPumpConnected
    -- A virtual pump hose is NOT a mechanical vehicle attachment. Treating it as
    -- one released the reel chassis brake as soon as automatic retraction ran,
    -- which allowed the internal hose-joint pull to tip the complete drum over.
    local physicallyAttached = attacherVehicle ~= nil
        or (self.spec_attachable ~= nil and self.spec_attachable.attacherVehicle ~= nil)
    local workMode = rpbIsWorkMode(self)
    local reelActive = rpbIsReelActive(self)
    local hoseOnlyDeployed = confirmedPumpConnected and not physicallyAttached
    local shouldHoldWorkSetup = hoseOnlyDeployed and workMode and not reelActive

    -- During savegame reconstruction do not fight GIANTS physics at all. The
    -- engine restores component transforms and native attacher joints first;
    -- custom brakes/support handling starts only after the stabilization window.
    if (tonumber(g_time) or 0) < (tonumber(self.RPB.loadStabilizeUntil) or 0) then
        if physicallyAttached then
            -- Real GIANTS attachment: do not fight reconstruction physics.
            rpbSetReelWheelBrakes(self, 0)
            rpbSetCartWheelBrakes(self, 0)
            self.RPB.parkingBrakeApplied = false
            self.RPB.anchorValid = false
        else
            -- Since 1.38.26 the pump connection is hose-only. With no real
            -- attacher joint there is nothing GIANTS needs to reconstruct here,
            -- so keep the heavy drum chassis calm without changing its position.
            rpbSetReelWheelBrakes(self, 1)
            rpbSetCartWheelBrakes(self, 0)
            rpbHoldReelChassis(self, false)
            self.RPB.parkingBrakeApplied = true
        end
        return
    end

    if pumpInputActive then
        rpbKeepSupportWheelDown(self)
    end

    local shouldPark = not physicallyAttached
        and (activeInputJointIndex == nil or activeInputJointIndex == 2)

    if hoseOnlyDeployed and workMode then
        -- The drum is the fixed end of the deployed irrigation hose. Keep only
        -- component 1 stationary/level by cancelling residual motion; the cart
        -- remains free while automatic retraction is active. No teleporting and
        -- no world-position correction is used.
        rpbKeepSupportWheelDown(self)
        rpbSetReelWheelBrakes(self, 1)
        rpbSetCartWheelBrakes(self, reelActive and 0 or 1)
        rpbHoldReelChassis(self, false)
        self.RPB.parkingBrakeApplied = true
        return
    end

    if shouldHoldWorkSetup then
        rpbHoldPumpWorkSetup(self)
        self.RPB.parkingBrakeApplied = true
        return
    end

    if physicallyAttached then
        rpbSetReelWheelBrakes(self, 0)
        rpbSetCartWheelBrakes(self, 0)
        self.RPB.parkingBrakeApplied = false
        self.RPB.anchorValid = false
        return
    end

    if shouldPark then
        rpbSetReelWheelBrakes(self, 1)
        rpbSetCartWheelBrakes(self, 0)
        self.RPB.parkingBrakeApplied = true
        self.RPB.anchorValid = false
    elseif self.RPB.parkingBrakeApplied then
        rpbSetReelWheelBrakes(self, 0)
        rpbSetCartWheelBrakes(self, 0)
        self.RPB.parkingBrakeApplied = false
        self.RPB.anchorValid = false
    end
end

function RWSM118RainstarParkingBrake:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if not self.isServer or self.RPB == nil then
        return
    end
    if self.RPB.assemblyTipped == true then
        rpbStopTippedAssemblyMotion(self)
        self.RPB.parkingBrakeApplied = true
        self.RPB.anchorValid = false
        return
    end
    local activeInputJointIndex = rpbGetActiveInputJointIndex(self)
    local attacherVehicle = rpbGetAttacherVehicle(self)
    local confirmedPumpConnected = rpbIsMotorPumpConnected(self)
    local pumpInputActive = confirmedPumpConnected
    local physicallyAttached = attacherVehicle ~= nil
        or (self.spec_attachable ~= nil and self.spec_attachable.attacherVehicle ~= nil)
    local reelActive = rpbIsReelActive(self)
    local workMode = rpbIsWorkMode(self)
    local hoseOnlyDeployed = confirmedPumpConnected and not physicallyAttached
    local shouldHoldWorkSetup = hoseOnlyDeployed and workMode and not reelActive
    if (tonumber(g_time) or 0) < (tonumber(self.RPB.loadStabilizeUntil) or 0) then
        if physicallyAttached then
            rpbSetReelWheelBrakes(self, 0)
            rpbSetCartWheelBrakes(self, 0)
            self.RPB.parkingBrakeApplied = false
            self.RPB.anchorValid = false
        else
            rpbSetReelWheelBrakes(self, 1)
            rpbSetCartWheelBrakes(self, 0)
            rpbHoldReelChassis(self, false)
            self.RPB.parkingBrakeApplied = true
        end
        return
    end
    if hoseOnlyDeployed and workMode then
        rpbKeepSupportWheelDown(self)
        rpbSetReelWheelBrakes(self, 1)
        rpbSetCartWheelBrakes(self, reelActive and 0 or 1)
        rpbHoldReelChassis(self, false)
        self.RPB.parkingBrakeApplied = true
        return
    end
    if shouldHoldWorkSetup then
        rpbHoldPumpWorkSetup(self)
        self.RPB.parkingBrakeApplied = true
        return
    end
    if physicallyAttached then
        rpbSetReelWheelBrakes(self, 0)
        rpbSetCartWheelBrakes(self, 0)
        self.RPB.parkingBrakeApplied = false
        self.RPB.anchorValid = false
        return
    end
    if not self.RPB.parkingBrakeApplied then return end
    rpbSetReelWheelBrakes(self, 1)
    rpbSetCartWheelBrakes(self, 0)
    self.RPB.anchorValid = false
end
