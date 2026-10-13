-- Vendored from FS25_RealisticWaterSoilManagement (Sherman / original HoFFi)
-- for SeasonalCropStress. Updated to RWSM v1.4.0.1 (safe physics: no direct
-- velocity/position writes on articulated bodies). SCS vendor note: pump
-- detection uses the virtual hose back-reference set by ScsPumpHoseConnection.
-- Realistic Water & Soil Management
-- Automatic parking brake for the detached Bauer Rainstar hose reel
-- Author: Sherman
-- Version: 1.4.0.1

RWSM118RainstarParkingBrake = RWSM118RainstarParkingBrake or {}

local REEL_WHEEL_COUNT = 2
local REEL_SUPPORT_WHEEL_INDEX = 6
local LOAD_STABILIZATION_MS = 12000
local CART_WHEEL_START_INDEX = 3
local CART_WHEEL_END_INDEX = 5
local ASSEMBLY_TIPPED_UP_DOT = 0.55
local CART_TIP_CHECK_MS = 100
local DETACH_STABILIZATION_MS = 900

local REEL_BRAKE_SAMPLE_MS = 150
local REEL_BRAKE_MAX = 0.22

local REEL_BRAKE_RISE_PER_SEC = 0.10
local REEL_BRAKE_FALL_PER_SEC = 0.08
local REEL_BRAKE_SPEED_FILTER_ALPHA = 0.12
local REEL_BRAKE_INCREASE_RATIO = 1.05
local REEL_BRAKE_RELEASE_RATIO = 0.95
local REEL_BRAKE_STEP_UP_MAX = 0.007
local REEL_BRAKE_STEP_DOWN_MAX = 0.005

local function rpbGetFoldTime(vehicle)
    if vehicle ~= nil and vehicle.getFoldAnimTime ~= nil then
        local ok, value = pcall(vehicle.getFoldAnimTime, vehicle)
        if ok then
            local numericValue = tonumber(value)
            if numericValue ~= nil then
                return numericValue
            end
        end
    end

    if vehicle ~= nil and vehicle.spec_foldable ~= nil then
        local numericValue = tonumber(vehicle.spec_foldable.foldAnimTime)
        if numericValue ~= nil then
            return numericValue
        end
    end

    return 1
end

local function rpbIsWorkMode(vehicle)
    return (tonumber(rpbGetFoldTime(vehicle)) or 1) < 0.5
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
    if vehicle == nil then return false end
    local virtualPump = vehicle.rwsmVirtualPump
    if virtualPump ~= nil and virtualPump.RPC ~= nil
        and virtualPump.RPC.virtualHoseConnected == true
        and virtualPump.RPC.virtualRainstar == vehicle then
        return true
    end
    if RWSMPumpConnectionState ~= nil
        and RWSMPumpConnectionState.findVirtualPumpForRainstar ~= nil then
        local ok, pump = pcall(RWSMPumpConnectionState.findVirtualPumpForRainstar, vehicle)
        return ok and pump ~= nil
    end
    return false
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
    return rpbIsNodeTipped(rpbGetComponentNode(vehicle, 1))
        or rpbIsNodeTipped(rpbGetComponentNode(vehicle, 2))
end



local SUPPORT_ANIMATION_NAME = "moveSupport"

local function rpbUsesPumpInputJoint(vehicle, attacherVehicle, inputJointDescIndex)
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
    rpbSetWheelBrakeRange(vehicle, brakePedal, REEL_SUPPORT_WHEEL_INDEX, REEL_SUPPORT_WHEEL_INDEX)
end

local function rpbSetCartWheelBrakes(vehicle, brakePedal)
    rpbSetWheelBrakeRange(vehicle, brakePedal, CART_WHEEL_START_INDEX, CART_WHEEL_END_INDEX)
end

local function rpbSetAllWheelBrakes(vehicle, brakePedal)
    if vehicle == nil or vehicle.spec_wheels == nil or vehicle.spec_wheels.wheels == nil then return end
    rpbSetWheelBrakeRange(vehicle, brakePedal, 1, #vehicle.spec_wheels.wheels)
end

local function rpbClearCartAnchor(vehicle)
    local data = vehicle ~= nil and vehicle.RPB or nil
    if data == nil then return end
    data.cartAnchorValid = false
end

local function rpbCaptureCartAnchor(vehicle)
    local data = vehicle ~= nil and vehicle.RPB or nil
    local node = rpbGetComponentNode(vehicle, 2)
    if data == nil or node == nil or getWorldTranslation == nil then return false end
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or x == nil or z == nil then return false end
    data.cartAnchorX = x
    data.cartAnchorZ = z
    data.cartAnchorValid = true
    return true
end

local function rpbHoldSprinklerCart(vehicle, correctPosition)
    return
end

local function rpbGetHorizontalCartDistance(vehicle)
    local reelNode = rpbGetComponentNode(vehicle, 1)
    local cartNode = rpbGetComponentNode(vehicle, 2)
    if reelNode == nil or cartNode == nil or getWorldTranslation == nil then
        return nil
    end

    local ok1, rx, _, rz = pcall(getWorldTranslation, reelNode)
    local ok2, cx, _, cz = pcall(getWorldTranslation, cartNode)
    if not ok1 or not ok2 or rx == nil or rz == nil or cx == nil or cz == nil then
        return nil
    end

    local dx, dz = cx - rx, cz - rz
    return math.sqrt(dx * dx + dz * dz)
end

local function rpbGetReelSlopePercent(vehicle)
    local reelNode = rpbGetComponentNode(vehicle, 1)
    local cartNode = rpbGetComponentNode(vehicle, 2)
    if reelNode == nil or cartNode == nil or getWorldTranslation == nil then
        return 0
    end
    local ok1, rx, ry, rz = pcall(getWorldTranslation, reelNode)
    local ok2, cx, cy, cz = pcall(getWorldTranslation, cartNode)
    if not ok1 or not ok2 or rx == nil or ry == nil or rz == nil
        or cx == nil or cy == nil or cz == nil then
        return 0
    end
    local dx, dz = rx - cx, rz - cz
    local horizontal = math.sqrt(dx * dx + dz * dz)
    if horizontal < 0.25 then return 0 end
    return (ry - cy) / horizontal * 100
end

local function rpbGetTimeScale()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        return math.max(
            0.5,
            math.min(
                360,
                tonumber(g_currentMission.missionInfo.timeScale) or 1
            )
        )
    end
    return 1
end

local function rpbGetExpectedReelSpeedMps(vehicle, distance)
    local rar = vehicle ~= nil and vehicle.RAR or nil
    local baseMph = rar ~= nil and tonumber(rar.baseReelSpeedMPerHour) or 60

    return math.max(
        0.002,
        (baseMph * rpbGetTimeScale()) / 3600
    )
end

local function rpbResetReelBrakeController(data)
    if data == nil then return end
    data.reelBrakeTarget = 0
    data.reelBrakeApplied = 0
    data.reelBrakeSampleTimer = 0
    data.reelBrakeLastDistance = nil
    data.reelBrakeRatioFiltered = 1
end

local function rpbGetReelOverspeedBrake(vehicle, dt)
    local data = vehicle ~= nil and vehicle.RPB or nil
    local rar = vehicle ~= nil and vehicle.RAR or nil
    if data == nil or rar == nil or rar.reelCommandActive ~= true then
        rpbResetReelBrakeController(data)
        return 0
    end

    local slopePercent = rpbGetReelSlopePercent(vehicle)
    if slopePercent >= -1.0 then
        rpbResetReelBrakeController(data)
        return 0
    end

    local distance = rpbGetHorizontalCartDistance(vehicle)
    if distance == nil then
        rpbResetReelBrakeController(data)
        return 0
    end

    local dtMs = math.max(0, tonumber(dt) or 0)
    local frameSec = dtMs / 1000
    data.reelBrakeSampleTimer = (data.reelBrakeSampleTimer or 0) + dtMs

    if data.reelBrakeLastDistance == nil then
        data.reelBrakeLastDistance = distance
        data.reelBrakeSampleTimer = 0
        data.reelBrakeRatioFiltered = 1
    elseif data.reelBrakeSampleTimer >= REEL_BRAKE_SAMPLE_MS then
        local sampleSec = math.max(0.05, data.reelBrakeSampleTimer / 1000)
        local inwardSpeed = math.max(
            0,
            (data.reelBrakeLastDistance - distance) / sampleSec
        )
        local expectedSpeed = rpbGetExpectedReelSpeedMps(vehicle, distance)
        local rawRatio = inwardSpeed / math.max(0.002, expectedSpeed)

        local oldRatio = tonumber(data.reelBrakeRatioFiltered) or 1
        local ratio = oldRatio
            + (rawRatio - oldRatio) * REEL_BRAKE_SPEED_FILTER_ALPHA
        data.reelBrakeRatioFiltered = math.max(0, math.min(4, ratio))

        local target = tonumber(data.reelBrakeTarget) or 0
        if ratio > REEL_BRAKE_INCREASE_RATIO then
            local error = ratio - REEL_BRAKE_INCREASE_RATIO
            local step = math.min(
                REEL_BRAKE_STEP_UP_MAX,
                0.001 + error * 0.008
            )
            target = math.min(REEL_BRAKE_MAX, target + step)
        elseif ratio < REEL_BRAKE_RELEASE_RATIO then
            local error = REEL_BRAKE_RELEASE_RATIO - ratio
            local step = math.min(
                REEL_BRAKE_STEP_DOWN_MAX,
                0.0008 + error * 0.006
            )
            target = math.max(0, target - step)
        end

        data.reelBrakeTarget = target
        data.reelBrakeLastDistance = distance
        data.reelBrakeSampleTimer = 0
    end

    local current = tonumber(data.reelBrakeApplied) or 0
    local target = tonumber(data.reelBrakeTarget) or 0
    if target > current then
        current = math.min(
            target,
            current + REEL_BRAKE_RISE_PER_SEC * frameSec
        )
    elseif target < current then
        current = math.max(
            target,
            current - REEL_BRAKE_FALL_PER_SEC * frameSec
        )
    end

    data.reelBrakeApplied = current
    return current
end

local function rpbUpdateReelStartBrake(vehicle, reelActive)
    local data = vehicle ~= nil and vehicle.RPB or nil
    if data == nil then return false end

    data.lastReelActive = reelActive == true
    data.cartBrakeReleaseAt = 0
    return false
end

local function rpbStopTippedAssemblyMotion(vehicle)
    rpbSetAllWheelBrakes(vehicle, 1)
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

local function rpbSetReelKinematicLock(vehicle, enabled)
    local data = vehicle ~= nil and vehicle.RPB or nil
    if data ~= nil then
        data.reelKinematicLocked = false
        data.reelOriginalRigidBodyType = nil
    end
    return true
end


local function rpbClearWorkAnchor(vehicle)
    local data = vehicle ~= nil and vehicle.RPB or nil
    if data == nil then return end
    data.workAnchorValid = false
end

local function rpbCaptureWorkAnchor(vehicle)
    local data = vehicle ~= nil and vehicle.RPB or nil
    local node = rpbGetReelNode(vehicle)
    if data == nil or node == nil or getWorldTranslation == nil then return false end
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or x == nil or z == nil then return false end
    data.workAnchorX = x
    data.workAnchorZ = z
    data.workAnchorValid = true
    return true
end

local function rpbHoldReelAtWorkAnchor(vehicle)
    return
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
    return
end

local function rpbHoldPumpWorkSetup(vehicle)
    rpbKeepSupportWheelDown(vehicle)
    rpbSetReelWheelBrakes(vehicle, 1)
    rpbSetCartWheelBrakes(vehicle, 1)
end

function RWSM118RainstarParkingBrake:onPostAttach(attacherVehicle, inputJointDescIndex, jointDescIndex)
    if self.RPB ~= nil then
        self.RPB.detachStabilizeUntil = 0
        self.RPB.pumpConnectionCached = rpbIsMotorPumpConnected(self)
        self.RPB.pumpConnectionCacheUntil = 0
        rpbClearCartAnchor(self)
        if tonumber(inputJointDescIndex) == 2 then
            rpbSetCartWheelBrakes(self, 0)
            self.RPB.parkingBrakeApplied = false
        else
            rpbClearWorkAnchor(self)
        end
    end
    if rpbUsesPumpInputJoint(self, attacherVehicle, inputJointDescIndex)
        and (tonumber(g_time) or 0) >= (tonumber(self.RPB ~= nil and self.RPB.loadStabilizeUntil) or 0) then
        rpbKeepSupportWheelDown(self)
    end
end

function RWSM118RainstarParkingBrake:onPostDetach(implementIndex)
    local data = self.RPB
    if data == nil then return end

    local now = tonumber(g_time) or 0
    data.pumpConnectionCacheUntil = 0
    data.pumpConnectionCached = false
    data.detachStabilizeUntil = now + DETACH_STABILIZATION_MS
    data.parkingBrakeApplied = false
    data.anchorValid = false
    rpbClearCartAnchor(self)
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
        lastReelActive = false,
        cartBrakeReleaseAt = 0,
        cartAnchorValid = false,
        cartAnchorX = 0,
        cartAnchorZ = 0,
        reelBrakeTarget = 0,
        reelBrakeApplied = 0,
        reelBrakeSampleTimer = 0,
        reelBrakeLastDistance = nil,
        reelBrakeRatioFiltered = 1,
        reelKinematicLocked = false,
        reelOriginalRigidBodyType = nil,
        workAnchorValid = false,
        workAnchorX = 0,
        workAnchorZ = 0,
        restoringSavegame = savegame ~= nil and not savegame.resetVehicles,
        loadStabilizeUntil = (tonumber(g_time) or 0) + LOAD_STABILIZATION_MS,
        detachStabilizeUntil = 0
    }

    do end
end

function RWSM118RainstarParkingBrake:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if not self.isServer or self.RPB == nil then
        return
    end

    local startupNow = tonumber(g_time) or 0
    if self.RPB.restoringSavegame == true
        and startupNow < (tonumber(self.RPB.loadStabilizeUntil) or 0) then
        return
    end
    self.RPB.restoringSavegame = false

    if startupNow < (tonumber(self.RPB.detachStabilizeUntil) or 0) then
        return
    end

    local earlyCartTractorAttached = rpbIsTractorAttachedToCart(self)

    self.RPB.cartTipTimer = (self.RPB.cartTipTimer or 0) + (tonumber(dt) or 0)
    if self.RPB.cartTipTimer >= CART_TIP_CHECK_MS then
        self.RPB.cartTipTimer = self.RPB.cartTipTimer - CART_TIP_CHECK_MS
        if earlyCartTractorAttached then
            self.RPB.assemblyTipped = rpbIsNodeTipped(rpbGetComponentNode(self, 1))
        else
            self.RPB.assemblyTipped = rpbIsAssemblyTipped(self)
        end
    end

    if self.RPB.assemblyTipped == true then
        rpbSetReelKinematicLock(self, false)
        if self.RAR ~= nil then
            self.RAR.tipSafetyActive = true
            self.RAR.reelCommandActive = false
        end
        if self.stopAnimation ~= nil then
            pcall(self.stopAnimation, self, "hoseReelLS19", false)
        end
        if earlyCartTractorAttached then
            rpbSetReelWheelBrakes(self, 1)
            rpbSetCartWheelBrakes(self, 0)
            rpbClearCartAnchor(self)
        else
            rpbStopTippedAssemblyMotion(self)
        end
        self.RPB.parkingBrakeApplied = true
        self.RPB.anchorValid = false
        rpbClearCartAnchor(self)
        rpbClearWorkAnchor(self)
        return
    elseif self.RAR ~= nil then
        self.RAR.tipSafetyActive = false
    end

    local activeInputJointIndex = rpbGetActiveInputJointIndex(self)
    local attacherVehicle = rpbGetAttacherVehicle(self)
    local confirmedPumpConnected = rpbIsMotorPumpConnected(self)
    local pumpInputActive = confirmedPumpConnected
    local physicallyAttached = attacherVehicle ~= nil
        or (self.spec_attachable ~= nil and self.spec_attachable.attacherVehicle ~= nil)
    local cartTractorAttached = rpbIsTractorAttachedToCart(self)
    local drumPhysicallyAttached = physicallyAttached and not cartTractorAttached
    local workMode = rpbIsWorkMode(self)
    local reelActive = rpbIsReelActive(self)
    rpbUpdateReelStartBrake(self, reelActive)
    local hoseOnlyDeployed = confirmedPumpConnected and not physicallyAttached
    local shouldHoldWorkSetup = hoseOnlyDeployed and workMode and not reelActive
    local shouldHardLockDrum = workMode and not drumPhysicallyAttached

    if (tonumber(g_time) or 0) < (tonumber(self.RPB.loadStabilizeUntil) or 0) then
        rpbSetReelKinematicLock(self, false)
        rpbClearWorkAnchor(self)
        if physicallyAttached then
            rpbSetReelWheelBrakes(self, 0)
            rpbSetCartWheelBrakes(self, 0)
            self.RPB.parkingBrakeApplied = false
            self.RPB.anchorValid = false
            rpbClearCartAnchor(self)
        else
            rpbSetReelWheelBrakes(self, 1)
            rpbSetCartWheelBrakes(self, reelActive and 0 or 1)
            if not reelActive then rpbHoldSprinklerCart(self, false) end
            rpbHoldReelChassis(self, false)
            self.RPB.parkingBrakeApplied = true
        end
        return
    end

    if shouldHardLockDrum then
        if self.RPB.workAnchorValid ~= true then rpbCaptureWorkAnchor(self) end
    else
        rpbClearWorkAnchor(self)
    end
    rpbSetReelKinematicLock(self, shouldHardLockDrum)
    if shouldHardLockDrum then rpbHoldReelAtWorkAnchor(self) end

    if pumpInputActive then
        rpbKeepSupportWheelDown(self)
    end

    if cartTractorAttached then
        rpbSetCartWheelBrakes(self, 0)
        rpbClearCartAnchor(self)
        if workMode then
            rpbSetReelWheelBrakes(self, 1)
            rpbHoldReelAtWorkAnchor(self)
            self.RPB.parkingBrakeApplied = true
        else
            rpbSetReelWheelBrakes(self, 0)
            self.RPB.parkingBrakeApplied = false
        end
        self.RPB.anchorValid = false
        return
    end

    local shouldPark = not physicallyAttached
        and (activeInputJointIndex == nil or activeInputJointIndex == 2)

    if hoseOnlyDeployed and workMode then
        rpbKeepSupportWheelDown(self)
        rpbSetReelWheelBrakes(self, 1)
        local holdCart = not reelActive
        local reelBrake = reelActive and rpbGetReelOverspeedBrake(self, dt) or 0
        rpbSetCartWheelBrakes(self, holdCart and 1 or reelBrake)
        if holdCart then
            rpbHoldSprinklerCart(self, true)
        else
            rpbClearCartAnchor(self)
        end
        rpbHoldReelAtWorkAnchor(self)
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
        rpbClearCartAnchor(self)
        if drumPhysicallyAttached or not workMode then
            rpbClearWorkAnchor(self)
        end
        return
    end

    if shouldPark then
        rpbSetReelWheelBrakes(self, 1)
        rpbSetCartWheelBrakes(self, 1)
        rpbHoldSprinklerCart(self, true)
        self.RPB.parkingBrakeApplied = true
        self.RPB.anchorValid = false
    elseif self.RPB.parkingBrakeApplied then
        rpbSetReelWheelBrakes(self, 0)
        rpbSetCartWheelBrakes(self, 0)
        self.RPB.parkingBrakeApplied = false
        self.RPB.anchorValid = false
        rpbClearCartAnchor(self)
    end
end
