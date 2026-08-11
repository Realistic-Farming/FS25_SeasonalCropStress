-- Vendored from FS25_RealisticWaterSoilManagement (Sherman / original HoFFi)
-- for SeasonalCropStress BUILD 21:13 Phase 1. Unmodified except where marked
-- 'SCS vendor note'. Moisture stays on the SCS door: this file does not write
-- soil moisture, and RWSM53WaterControl is deliberately not shipped.
-- Bauer Rainstar T32 LS25
-- Confirmed FS19 reel mechanism with transport-lock synchronization
-- Author: Sherman
-- Version: 1.38.39
--
-- Physical reel mechanism remains the confirmed v0.31 implementation:
-- the native animation reduces component-joint translation limits from
-- 220 m to 0 m. No addForce, no setLinearVelocity and no joint motor.
--
-- v0.33 coordinates this animation with the folding state:
-- transport mode = locked at the reel
-- work mode      = full hose length released

RWSM53AutoReel = {}

local ANIMATION_NAME = "hoseReelLS19"
local MAX_HOSE_LENGTH = 220
local PARK_DISTANCE = 4.5
local STOP_DISTANCE = PARK_DISTANCE
local COMPLETE_DISTANCE = PARK_DISTANCE + 0.25
local TRANSPORT_CAPTURE_DISTANCE = 8.0
local TRANSPORT_LOCK_DISTANCE = COMPLETE_DISTANCE + 0.50
local TRANSPORT_RETRY_INTERVAL_MS = 250
local BASE_REEL_SPEED_M_PER_HOUR = 30
local MAX_TIME_SCALE = 12
local FINAL_APPROACH_START_DISTANCE = 12
local FINAL_APPROACH_MIN_FACTOR = 0.50
local LOAD_STABILIZATION_MS = 12000
local ASSEMBLY_TIPPED_UP_DOT = 0.55
local TIP_SAFETY_SPRING = 0
local TIP_SAFETY_DAMPING = 0
local PULLOUT_SOFT_START = 210
local PULLOUT_HARD_START = 218
local PULLOUT_LIMIT = 220
local PULLOUT_LIMIT_UPDATE_MS = 100
local PULLOUT_SOFT_SPRING = 180000
local PULLOUT_HARD_SPRING = 850000
local PULLOUT_SOFT_DAMPING = 90
local PULLOUT_HARD_DAMPING = 220
local PULLOUT_AXIS_SLACK = 0.20

-- Adaptive pull assistance. The hose-limit animation remains unchanged;
-- only the component-joint spring is adjusted from measured field resistance.
local NORMAL_SPRING = 24000
local NORMAL_DAMPING = 44
-- 1.38.39: outside automatic retraction the ground hose must behave like a
-- slack hose, not like a permanently tensioned rigid rod. The visual hose has
-- no collision; these zero values remove only passive component-joint tension.
local IDLE_SPRING = 0
local IDLE_DAMPING = 0
-- 1.38.23: stronger distance-dependent pull assistance. Long hose lengths
-- need substantially more tension because rolling/soil resistance accumulates.
-- High spring values are still used ONLY while automatic retraction is active;
-- savegame loading, parked work mode and transport mode remain on NORMAL_SPRING.
local SPRING_LEVELS = {100000, 130000, 165000, 205000}
local DAMPING_LEVELS = {64, 76, 90, 104}
local MAX_ACTIVE_SPRING = 320000
local MAX_ACTIVE_DAMPING = 138
-- 1.38.25: The winch no longer drops spring force immediately when the cart
-- starts moving. Target force still follows resistance/distance analysis, but
-- the actually applied force is ramped. Force may build comparatively quickly,
-- while release is deliberately slow so the cart is pulled smoothly.
local PULL_SMOOTH_UPDATE_MS = 100
local PULL_SPRING_RISE_PER_SEC = 120000
local PULL_SPRING_FALL_PER_SEC = 24000
local PULL_DAMPING_RISE_PER_SEC = 48
local PULL_DAMPING_FALL_PER_SEC = 10
local ANALYSIS_INTERVAL_MS = 1000
local OBSTACLE_PAUSE_MS = 999999999

-- Forward declarations: the adaptive analysis calls these helpers
-- before their implementations later in this file.
local rarGetDistance
local rarGetTimeScale

local function rarGetComponentNode(vehicle, componentIndex)
    if vehicle == nil or vehicle.components == nil or vehicle.components[componentIndex] == nil then return nil end
    local node = vehicle.components[componentIndex].node
    if node == nil or node == 0 then return nil end
    if entityExists ~= nil and not entityExists(node) then return nil end
    return node
end

local function rarIsNodeTipped(node)
    if node == nil or localDirectionToWorld == nil then return false end
    local ok, _, upY, _ = pcall(localDirectionToWorld, node, 0, 1, 0)
    return ok and tonumber(upY) ~= nil and upY < ASSEMBLY_TIPPED_UP_DOT
end

local function rarIsAssemblyTipped(vehicle)
    return rarIsNodeTipped(rarGetComponentNode(vehicle, 1))
        or rarIsNodeTipped(rarGetComponentNode(vehicle, 2))
end
local rarIsTractorAttachedToCart
local rarIsWorkMode

local function rarSetJointSpring(vehicle, spring, damping)
    if vehicle == nil
        or vehicle.componentJoints == nil
        or vehicle.componentJoints[1] == nil
        or setJointTranslationLimitSpring == nil then
        return
    end

    local jointIndex = vehicle.componentJoints[1].jointIndex
    if jointIndex == nil then
        return
    end

    -- Only horizontal axes are strengthened. Vertical terrain following remains free.
    setJointTranslationLimitSpring(jointIndex, 0, spring, damping)
    setJointTranslationLimitSpring(jointIndex, 2, spring, damping)
end

local function rarResolveMappedNode(vehicle, mappingName)
    if vehicle == nil or I3DUtil == nil or I3DUtil.indexToObject == nil then return nil end
    local node = I3DUtil.indexToObject(vehicle.components, mappingName, vehicle.i3dMappings)
    if node ~= nil and node ~= 0 and (entityExists == nil or entityExists(node)) then return node end
    return nil
end

local function rarSetComponentAxisLimit(vehicle, axis, limit)
    if vehicle == nil or vehicle.componentJoints == nil or vehicle.componentJoints[1] == nil then return end
    local joint = vehicle.componentJoints[1]
    limit = math.max(0.25, tonumber(limit) or MAX_HOSE_LENGTH)
    if vehicle.setComponentJointTransLimit ~= nil then
        pcall(vehicle.setComponentJointTransLimit, vehicle, joint, axis, -limit, limit)
    elseif setJointTranslationLimit ~= nil and joint.jointIndex ~= nil then
        pcall(setJointTranslationLimit, joint.jointIndex, axis - 1, true, -limit, limit)
    end
end

local function rarReleasePulloutLimiter(vehicle)
    local data = vehicle ~= nil and vehicle.RAR or nil
    if data == nil or data.pulloutLimiterActive ~= true then return end
    -- Only restore the full 220 m box while the Rainstar remains in work mode.
    -- Transport/folding animations own the limits outside work mode.
    if rarIsWorkMode ~= nil and rarIsWorkMode(vehicle) then
        rarSetComponentAxisLimit(vehicle, 1, MAX_HOSE_LENGTH)
        rarSetComponentAxisLimit(vehicle, 3, MAX_HOSE_LENGTH)
        if vehicle.isServer and data.reelCommandActive ~= true then
            rarSetJointSpring(vehicle, IDLE_SPRING, IDLE_DAMPING)
        end
    end
    data.pulloutLimiterActive = false
    data.pulloutLimitX = nil
    data.pulloutLimitZ = nil
end

local function rarUpdatePulloutLimiter(vehicle, dt)
    local data = vehicle ~= nil and vehicle.RAR or nil
    if data == nil or not vehicle.isServer then return end

    data.pulloutLimitTimer = (data.pulloutLimitTimer or 0) + (tonumber(dt) or 0)
    if data.pulloutLimitTimer < PULLOUT_LIMIT_UPDATE_MS then return end
    data.pulloutLimitTimer = data.pulloutLimitTimer - PULLOUT_LIMIT_UPDATE_MS

    -- Never touch the joint while GIANTS is reconstructing a savegame, while
    -- the automatic reel is running, or outside the cart-pull work setup.
    local now = tonumber(g_time) or 0
    if now < (tonumber(data.loadStabilizeUntil) or 0)
        or data.reelCommandActive == true
        or rarIsWorkMode == nil or not rarIsWorkMode(vehicle)
        or rarIsTractorAttachedToCart == nil or not rarIsTractorAttachedToCart(vehicle) then
        rarReleasePulloutLimiter(vehicle)
        return
    end

    local distance = math.max(0, tonumber(rarGetDistance(vehicle)) or 0)
    if distance < PULLOUT_SOFT_START then
        rarReleasePulloutLimiter(vehicle)
        return
    end

    local hoseStart = vehicle.COBD ~= nil and vehicle.COBD.roll ~= nil and vehicle.COBD.roll.CheckNode or nil
    local hoseEnd = vehicle.COBD ~= nil and vehicle.COBD.roll ~= nil and vehicle.COBD.roll.CheckNodeRef or nil
    local jointFrame = rarResolveMappedNode(vehicle, "compJoint")
    if hoseStart == nil or hoseEnd == nil or jointFrame == nil or worldDirectionToLocal == nil then return end

    local sx, _, sz = getWorldTranslation(hoseStart)
    local ex, _, ez = getWorldTranslation(hoseEnd)
    local dx, dz = ex - sx, ez - sz
    local worldLen = math.sqrt(dx * dx + dz * dz)
    if worldLen < 0.01 then return end
    dx, dz = dx / worldLen, dz / worldLen

    local ok, lx, _, lz = pcall(worldDirectionToLocal, jointFrame, dx, 0, dz)
    if not ok then return end
    local localLen = math.sqrt(lx * lx + lz * lz)
    if localLen < 0.001 then return end
    lx, lz = lx / localLen, lz / localLen

    local blend = math.max(0, math.min(1, (distance - PULLOUT_SOFT_START) / (PULLOUT_LIMIT - PULLOUT_SOFT_START)))
    -- Ease in so there is no sudden constraint step at 210 m.
    blend = blend * blend * (3 - 2 * blend)

    local targetX = math.max(1.0, math.abs(lx) * PULLOUT_LIMIT + PULLOUT_AXIS_SLACK)
    local targetZ = math.max(1.0, math.abs(lz) * PULLOUT_LIMIT + PULLOUT_AXIS_SLACK)
    local limitX = MAX_HOSE_LENGTH * (1 - blend) + targetX * blend
    local limitZ = MAX_HOSE_LENGTH * (1 - blend) + targetZ * blend

    rarSetComponentAxisLimit(vehicle, 1, limitX)
    rarSetComponentAxisLimit(vehicle, 3, limitZ)

    local hardBlend = math.max(0, math.min(1, (distance - PULLOUT_HARD_START) / (PULLOUT_LIMIT - PULLOUT_HARD_START)))
    hardBlend = hardBlend * hardBlend * (3 - 2 * hardBlend)
    local spring = PULLOUT_SOFT_SPRING + (PULLOUT_HARD_SPRING - PULLOUT_SOFT_SPRING) * hardBlend
    local damping = PULLOUT_SOFT_DAMPING + (PULLOUT_HARD_DAMPING - PULLOUT_SOFT_DAMPING) * hardBlend
    rarSetJointSpring(vehicle, spring, damping)

    data.pulloutLimiterActive = true
    data.pulloutLimitX = limitX
    data.pulloutLimitZ = limitZ
end

local function rarGetDistancePullMultiplier(distance)
    distance = math.max(0, math.min(MAX_HOSE_LENGTH, tonumber(distance) or 0))
    if distance <= 50 then
        return 1.0
    elseif distance <= 100 then
        return 1.0 + ((distance - 50) / 50) * 0.20
    elseif distance <= 160 then
        return 1.20 + ((distance - 100) / 60) * 0.30
    end
    return 1.50 + ((distance - 160) / 60) * 0.25
end

local function rarGetActivePullSettings(level, distance)
    level = math.max(0, math.min(3, tonumber(level) or 0))
    local multiplier = rarGetDistancePullMultiplier(distance)
    local baseSpring = SPRING_LEVELS[level + 1] or SPRING_LEVELS[#SPRING_LEVELS]
    local baseDamping = DAMPING_LEVELS[level + 1] or DAMPING_LEVELS[#DAMPING_LEVELS]
    local spring = math.min(MAX_ACTIVE_SPRING, baseSpring * multiplier)
    -- Increase damping more gently than spring to avoid oscillation at long hose lengths.
    local dampingMultiplier = 1 + (multiplier - 1) * 0.35
    local damping = math.min(MAX_ACTIVE_DAMPING, baseDamping * dampingMultiplier)
    return spring, damping, multiplier
end

local function rarApplyActivePull(vehicle, level, distance)
    local data = vehicle ~= nil and vehicle.RAR or nil
    if data == nil or data.reelCommandActive ~= true then
        return
    end
    local spring, damping, multiplier = rarGetActivePullSettings(level, distance)
    -- Store only the new target. The joint itself is adjusted by
    -- rarUpdatePullSmoothing so a good movement sample cannot suddenly remove
    -- most of the pulling force in one analysis tick.
    data.targetPullSpring = spring
    data.targetPullDamping = damping
    data.distancePullMultiplier = multiplier
end

local function rarMoveTowards(current, target, maxDelta)
    current = tonumber(current) or 0
    target = tonumber(target) or current
    maxDelta = math.max(0, tonumber(maxDelta) or 0)
    if current < target then
        return math.min(target, current + maxDelta)
    elseif current > target then
        return math.max(target, current - maxDelta)
    end
    return current
end

local function rarUpdatePullSmoothing(vehicle, dt)
    local data = vehicle ~= nil and vehicle.RAR or nil
    if data == nil or data.reelCommandActive ~= true or not vehicle.isServer then
        return
    end

    data.pullSmoothTimer = (data.pullSmoothTimer or 0) + (tonumber(dt) or 0)
    if data.pullSmoothTimer < PULL_SMOOTH_UPDATE_MS then
        return
    end

    local elapsedMs = data.pullSmoothTimer
    data.pullSmoothTimer = 0
    local elapsedSec = math.max(0.001, elapsedMs / 1000)

    local targetSpring = tonumber(data.targetPullSpring) or NORMAL_SPRING
    local targetDamping = tonumber(data.targetPullDamping) or NORMAL_DAMPING
    local currentSpring = tonumber(data.currentPullSpring) or NORMAL_SPRING
    local currentDamping = tonumber(data.currentPullDamping) or NORMAL_DAMPING

    local springRate = targetSpring >= currentSpring
        and PULL_SPRING_RISE_PER_SEC or PULL_SPRING_FALL_PER_SEC
    local dampingRate = targetDamping >= currentDamping
        and PULL_DAMPING_RISE_PER_SEC or PULL_DAMPING_FALL_PER_SEC

    currentSpring = rarMoveTowards(currentSpring, targetSpring, springRate * elapsedSec)
    currentDamping = rarMoveTowards(currentDamping, targetDamping, dampingRate * elapsedSec)

    data.currentPullSpring = currentSpring
    data.currentPullDamping = currentDamping
    -- Keep the existing HUD/debug values meaningful: they now show the force
    -- actually being applied, not a target that may still be ramping down.
    data.analysisSpring = currentSpring
    data.analysisDamping = currentDamping

    rarSetJointSpring(vehicle, currentSpring, currentDamping)
end

local function rarCalculateSlope(vehicle)
    if vehicle == nil
        or vehicle.COBD == nil
        or vehicle.COBD.roll == nil
        or vehicle.COBD.roll.CheckNode == nil
        or vehicle.COBD.roll.CheckNodeRef == nil then
        return 0
    end

    local reelX, reelY, reelZ = getWorldTranslation(vehicle.COBD.roll.CheckNode)
    local cartX, cartY, cartZ = getWorldTranslation(vehicle.COBD.roll.CheckNodeRef)
    local dx = reelX - cartX
    local dz = reelZ - cartZ
    local horizontal = math.sqrt(dx * dx + dz * dz)

    if horizontal < 0.25 then
        return 0
    end

    -- Positive value means the cart is pulled uphill toward the reel.
    return (reelY - cartY) / horizontal * 100
end

local function rarResetAnalysis(vehicle)
    local data = vehicle ~= nil and vehicle.RAR or nil
    if data == nil then
        return
    end

    data.analysisTimer = 0
    data.analysisLastDistance = nil
    data.analysisNoProgressMs = 0
    data.analysisSlope = 0
    data.analysisProgressRatio = 1
    data.analysisLevel = 0
    data.analysisSpring = NORMAL_SPRING
    data.analysisDamping = NORMAL_DAMPING
    data.currentPullSpring = NORMAL_SPRING
    data.currentPullDamping = NORMAL_DAMPING
    data.targetPullSpring = NORMAL_SPRING
    data.targetPullDamping = NORMAL_DAMPING
    data.pullSmoothTimer = 0
    data.distancePullMultiplier = 1.0
    data.analysisStatusKey = "siteAnalysisNormal"
    data.analysisPaused = false

    -- Outside active automatic retraction, always restore the harmless baseline
    -- spring. This is important during savegame loading and normal work mode.
    if vehicle.isServer then
        rarSetJointSpring(vehicle, NORMAL_SPRING, NORMAL_DAMPING)
    end
end

local function rarUpdateSiteAnalysis(vehicle, dt)
    local data = vehicle.RAR
    if data == nil or not data.reelCommandActive then
        return
    end

    data.analysisTimer = (data.analysisTimer or 0) + dt
    if data.analysisTimer < ANALYSIS_INTERVAL_MS then
        return
    end

    local elapsedMs = data.analysisTimer
    data.analysisTimer = 0

    local distance = rarGetDistance(vehicle)
    local previous = data.analysisLastDistance or distance
    local actualProgress = math.max(0, previous - distance)
    data.analysisLastDistance = distance

    local expectedProgress =
        (BASE_REEL_SPEED_M_PER_HOUR / 3600)
        * rarGetTimeScale()
        * (elapsedMs / 1000)

    local ratio = 1
    if expectedProgress > 0.0001 then
        ratio = actualProgress / expectedProgress
    end

    local slope = rarCalculateSlope(vehicle)
    data.analysisSlope = slope
    data.analysisProgressRatio = ratio

    if actualProgress < 0.001 then
        data.analysisNoProgressMs =
            (data.analysisNoProgressMs or 0) + elapsedMs
    else
        data.analysisNoProgressMs = 0
    end

    local level = 0
    if slope > 2.5 or ratio < 0.88 then
        level = 1
    end
    if slope > 5 or ratio < 0.66 or data.analysisNoProgressMs > 2200 then
        level = 2
    end
    if slope > 8 or ratio < 0.40 or data.analysisNoProgressMs > 5000 then
        level = 3
    end

    data.analysisLevel = level
    rarApplyActivePull(vehicle, level, distance)

    if level == 0 then
        data.analysisStatusKey = "siteAnalysisNormal"
    elseif level == 1 then
        data.analysisStatusKey = "siteAnalysisIncreased"
    elseif level == 2 then
        data.analysisStatusKey = "siteAnalysisStrong"
    else
        data.analysisStatusKey = "siteAnalysisMaximum"
    end

    -- If maximum assistance still produces no movement, pause further
    -- shortening of the hose limit. The static tension remains active and
    -- prevents the animation from accumulating dangerous excess force.
    if data.analysisNoProgressMs >= OBSTACLE_PAUSE_MS then
        data.analysisPaused = true
        data.analysisStatusKey = "siteAnalysisObstacle"
    elseif data.analysisPaused and actualProgress > 0.003 then
        data.analysisPaused = false
    end
end

local function rarShowWarning(textKey)
    if g_currentMission ~= nil
        and g_currentMission.showBlinkingWarning ~= nil then
        g_currentMission:showBlinkingWarning(
            g_i18n:getText(textKey),
            3500
        )
    end
end

rarGetDistance = function(vehicle)
    if vehicle ~= nil and vehicle.COBD ~= nil then
        return tonumber(vehicle.COBD.distance) or 0
    end
    return 0
end

rarGetTimeScale = function()
    if g_currentMission ~= nil
        and g_currentMission.missionInfo ~= nil then
        return math.max(
            1,
            math.min(
                MAX_TIME_SCALE,
                tonumber(g_currentMission.missionInfo.timeScale) or 1
            )
        )
    end
    return 1
end

local function rarGetFinalApproachFactor(vehicle)
    local distance = rarGetDistance(vehicle)
    if distance >= FINAL_APPROACH_START_DISTANCE then
        return 1
    end

    local usableRange = math.max(0.1, FINAL_APPROACH_START_DISTANCE - COMPLETE_DISTANCE)
    local progress = math.max(0, math.min(1, (distance - COMPLETE_DISTANCE) / usableRange))
    return FINAL_APPROACH_MIN_FACTOR + (1 - FINAL_APPROACH_MIN_FACTOR) * progress
end

local function rarGetCurrentReelSpeedScale(vehicle)
    return rarGetTimeScale()
        * (BASE_REEL_SPEED_M_PER_HOUR / 30)
        * rarGetFinalApproachFactor(vehicle)
end

local function rarGetConnectedPump(vehicle)
    if vehicle == nil then return nil end

    -- Hose-only connection (>=1.38.26): this is the authoritative, immediate
    -- back-reference and does not depend on the slower COBD status refresh.
    local pump = vehicle.rwsmVirtualPump
    if pump ~= nil and pump.RPC ~= nil
        and pump.RPC.virtualHoseConnected == true
        and pump.RPC.virtualRainstar == vehicle then
        return pump
    end

    if RWSMPumpConnectionState ~= nil
        and RWSMPumpConnectionState.findVirtualPumpForRainstar ~= nil then
        local ok, found = pcall(RWSMPumpConnectionState.findVirtualPumpForRainstar, vehicle)
        if ok and found ~= nil then return found end
    end

    if vehicle.COBD ~= nil then
        return vehicle.COBD.connectedPump
    end
    return nil
end

local function rarIsPumpConnected(vehicle)
    return rarGetConnectedPump(vehicle) ~= nil
end

local function rarIsPumpRunning(vehicle)
    local pump = rarGetConnectedPump(vehicle)
    if pump == nil then return false end
    if pump.getIsTurnedOn ~= nil then
        local ok, running = pcall(pump.getIsTurnedOn, pump)
        if ok then return running == true end
    end
    if pump.spec_turnOnVehicle ~= nil then
        return pump.spec_turnOnVehicle.isTurnedOn == true
    end
    return vehicle ~= nil and vehicle.COBD ~= nil and vehicle.COBD.isPumpRunning == true
end

local function rarGetActiveInputJointIndex(vehicle)
    if vehicle == nil then
        return nil
    end

    if vehicle.getActiveInputAttacherJointDescIndex ~= nil then
        local ok, value = pcall(
            vehicle.getActiveInputAttacherJointDescIndex,
            vehicle
        )
        if ok then
            return value
        end
    end

    if vehicle.spec_attachable ~= nil then
        return vehicle.spec_attachable.inputAttacherJointDescIndex
    end

    return nil
end

local function rarGetAttacherVehicle(vehicle)
    if vehicle == nil then
        return nil
    end

    if vehicle.getAttacherVehicle ~= nil then
        local ok, attacherVehicle = pcall(vehicle.getAttacherVehicle, vehicle)
        if ok and attacherVehicle ~= nil then
            return attacherVehicle
        end
    end

    if vehicle.spec_attachable ~= nil then
        return vehicle.spec_attachable.attacherVehicle
    end

    return nil
end

rarIsTractorAttachedToCart = function(vehicle)
    -- 1 = hose-reel transport hitch, 2 = sprinkler cart/tractor, 3 = motor pump.
    -- The active input-joint index can remain at 2 after a detach or after
    -- Manual Attach selection changes. Therefore index 2 alone is not proof
    -- of a physical connection and must never block transport docking.
    return rarGetActiveInputJointIndex(vehicle) == 2
        and rarGetAttacherVehicle(vehicle) ~= nil
end

local function rarGetFoldTime(vehicle)
    if vehicle ~= nil and vehicle.getFoldAnimTime ~= nil then
        local ok, value = pcall(vehicle.getFoldAnimTime, vehicle)
        if ok and value ~= nil then
            return value
        end
    end

    if vehicle ~= nil and vehicle.spec_foldable ~= nil then
        return vehicle.spec_foldable.foldAnimTime or 1
    end

    return 1
end

rarIsWorkMode = function(vehicle)
    return rarGetFoldTime(vehicle) < 0.5
end

local function rarAnimationExists(vehicle)
    return vehicle ~= nil
        and vehicle.getAnimationExists ~= nil
        and vehicle:getAnimationExists(ANIMATION_NAME)
end

local function rarIsAnimationPlaying(vehicle)
    return vehicle ~= nil
        and vehicle.getIsAnimationPlaying ~= nil
        and vehicle:getIsAnimationPlaying(ANIMATION_NAME)
end

local function rarGetAnimationTime(vehicle)
    if vehicle ~= nil and vehicle.getAnimationTime ~= nil and rarAnimationExists(vehicle) then
        local ok, value = pcall(vehicle.getAnimationTime, vehicle, ANIMATION_NAME)
        if ok and tonumber(value) ~= nil then
            return math.max(0, math.min(1, tonumber(value)))
        end
    end
    return nil
end

local function rarSetHoseAnimationTime(vehicle, animationTime)
    if not rarAnimationExists(vehicle) then
        return
    end

    if rarIsAnimationPlaying(vehicle)
        and vehicle.stopAnimation ~= nil then
        vehicle:stopAnimation(ANIMATION_NAME, false)
    end

    vehicle:setAnimationTime(
        ANIMATION_NAME,
        animationTime,
        true,
        false
    )
end

local function rarReleaseFullHose(vehicle)
    -- Animation time 0 = 220 m joint translation limit.
    rarSetHoseAnimationTime(vehicle, 0)

    if vehicle.RAR ~= nil then
        vehicle.RAR.reelCommandActive = false
    end
end

local function rarGetAnimationTimeForDistance(distance)
    local clampedDistance = math.max(0, math.min(MAX_HOSE_LENGTH, distance or 0))
    return math.max(0, math.min(1, 1 - clampedDistance / MAX_HOSE_LENGTH))
end

local function rarSetCartParkPosition(vehicle)
    -- Keep a small safe hose remainder so the sprinkler cart stops a bit in
    -- front of the reel and does not tip over into the machine at the very end.
    rarSetHoseAnimationTime(vehicle, rarGetAnimationTimeForDistance(PARK_DISTANCE))

    if vehicle.RAR ~= nil then
        vehicle.RAR.reelCommandActive = false
    end
end

local function rarSetCartTransportPosition(vehicle)
    -- Animation time 1 = native component-joint translation limit 0 m.
    -- This is the original physical transport coupling; no node or component
    -- is teleported.
    rarSetHoseAnimationTime(vehicle, 1)

    if vehicle.RAR ~= nil then
        vehicle.RAR.reelCommandActive = false
    end
end

local function rarLockCartAtReel(vehicle)
    -- Manual Attach is not required for transport coupling. The internal
    -- component joint captures the free sprinkler cart in two gentle stages:
    -- first pull it to the normal 4.5 m parking position, then apply the exact
    -- native transport lock once both parts are aligned closely enough.
    local distance = rarGetDistance(vehicle)

    if distance <= TRANSPORT_LOCK_DISTANCE then
        rarSetCartTransportPosition(vehicle)
        return true
    end

    if distance <= TRANSPORT_CAPTURE_DISTANCE then
        rarSetCartParkPosition(vehicle)
    end

    return false
end

local function rarGetStartAnimationTime(vehicle)
    local distance = math.max(
        STOP_DISTANCE,
        math.min(
            MAX_HOSE_LENGTH,
            rarGetDistance(vehicle)
        )
    )

    return math.max(
        0,
        math.min(
            0.999,
            rarGetAnimationTimeForDistance(distance)
        )
    )
end

local function rarStop(vehicle, clearCommand)
    if vehicle ~= nil
        and vehicle.stopAnimation ~= nil
        and rarIsAnimationPlaying(vehicle) then

        vehicle:stopAnimation(
            ANIMATION_NAME,
            false
        )
    end

    if clearCommand
        and vehicle ~= nil
        and vehicle.RAR ~= nil then
        vehicle.RAR.reelCommandActive = false
    end

    -- Stopping N must also stop the physical pull. A stopped reel no longer
    -- keeps the joint envelope at the last shortened animation position; release
    -- it back to the full 220 m work envelope and remove spring tension.
    if vehicle ~= nil and rarIsWorkMode(vehicle) then
        rarReleaseFullHose(vehicle)
        if vehicle.isServer then
            rarSetJointSpring(vehicle, IDLE_SPRING, IDLE_DAMPING)
        end
    end

    rarResetAnalysis(vehicle)
end

local function rarShutdownPump(vehicle)
    local pump = rarGetConnectedPump(vehicle)

    if vehicle.setIsTurnedOn ~= nil
        and vehicle.getIsTurnedOn ~= nil
        and vehicle:getIsTurnedOn() then
        vehicle:setIsTurnedOn(false)
    end

    if pump ~= nil then
        if pump.setIsTurnedOn ~= nil
            and pump.getIsTurnedOn ~= nil
            and pump:getIsTurnedOn() then
            pump:setIsTurnedOn(false)
        end

        if pump.stopMotor ~= nil then
            pump:stopMotor(false)
        end
    end
end

local function rarComplete(vehicle)
    local data = vehicle.RAR

    if data == nil or data.shutdownCompleted then
        return
    end

    data.shutdownCompleted = true
    data.reelCommandActive = false

    rarStop(vehicle, false)
    rarSetCartParkPosition(vehicle)
    rarShutdownPump(vehicle)

    data.completeMessageTimer = 5000

    print(
        "[RWSM v0.56] Reel complete: "
        .. "cart locked, sprinkler and motor pump switched off"
    )
end

local function rarStart(vehicle)
    local data = vehicle.RAR

    if data == nil
        or not data.animationAvailable then
        return false
    end

    local distance = rarGetDistance(vehicle)

    -- 1.38.38: use the actual rollover helper. The old rarIsCartTipped name
    -- no longer existed after the passive-rollover rewrite, which made the
    -- pump-side N action abort with a nil-function error before the reel could start.
    if rarIsAssemblyTipped(vehicle) then
        data.tipSafetyActive = true
        if vehicle.isServer then
            rarSetJointSpring(vehicle, TIP_SAFETY_SPRING, TIP_SAFETY_DAMPING)
        end
        return false
    end

    if not rarIsWorkMode(vehicle) then
        if vehicle.isClient then
            rarShowWarning("warning_RAINSTAR_SELECT_WORKMODE")
        end
        return false
    end

    if distance <= STOP_DISTANCE + 0.2 then
        if vehicle.isClient then
            rarShowWarning("warning_RAINSTAR_HOSE_NOT_EXTENDED")
        end
        return false
    end

    if rarIsTractorAttachedToCart(vehicle) then
        if vehicle.isClient then
            rarShowWarning("warning_RAINSTAR_CART_ATTACHED")
        end
        return false
    end

    if not rarIsPumpConnected(vehicle) then
        if vehicle.isClient then
            rarShowWarning("warning_RAINSTAR_PUMP_NOT_CONNECTED")
        end
        return false
    end

    if not rarIsPumpRunning(vehicle) then
        if vehicle.isClient then
            rarShowWarning("warning_RAINSTAR_PUMP_NOT_RUNNING")
        end
        return false
    end

    local startTime = rarGetStartAnimationTime(vehicle)
    local speed = rarGetCurrentReelSpeedScale(vehicle)

    vehicle:setAnimationTime(
        ANIMATION_NAME,
        startTime,
        true,
        false
    )

    vehicle:setAnimationStopTime(
        ANIMATION_NAME,
        1
    )

    data.reelCommandActive = true
    -- Keep the Rainstar scheduled while the automatic reel is running, even if
    -- no player is nearby. This changes no reel speed or animation logic.
    if vehicle.raiseActive ~= nil then
        vehicle:raiseActive()
    end
    data.shutdownCompleted = false
    data.completeMessageTimer = 0
    rarResetAnalysis(vehicle)
    data.analysisLastDistance = distance
    -- Apply distance compensation immediately when retraction starts. It is
    -- never armed merely by loading a savegame or selecting work mode.
    rarApplyActivePull(vehicle, 0, distance)

    vehicle:playAnimation(
        ANIMATION_NAME,
        speed,
        startTime,
        false,
        false
    )

    print(string.format(
        "[RWSM v1.38.25] FS19 reel started: "
        .. "distance=%.1f m, animTime=%.4f, speedScale=%.1f",
        distance,
        startTime,
        speed
    ))

    return true
end

-- Public proxy helpers used by the hose-only motor pump. Keeping the actual
-- reel logic here prevents a second implementation from drifting out of sync.
function RWSM53AutoReel.startReel(vehicle)
    return rarStart(vehicle)
end

function RWSM53AutoReel.stopReel(vehicle)
    rarStop(vehicle, true)
    return true
end

function RWSM53AutoReel.toggleReel(vehicle)
    if vehicle == nil or vehicle.RAR == nil then return false end
    if vehicle.RAR.reelCommandActive then
        return RWSM53AutoReel.stopReel(vehicle)
    end
    return RWSM53AutoReel.startReel(vehicle)
end

function RWSM53AutoReel.initSpecialization()
    local schema = Vehicle ~= nil and Vehicle.xmlSchemaSavegame or nil
    if schema ~= nil and schema.register ~= nil and XMLValueType ~= nil then
        schema:register(XMLValueType.FLOAT, "vehicles.vehicle(?).rwsmAutoReel#animationTime", "Saved hose reel limit position")
    end
end

function RWSM53AutoReel.prerequisitesPresent(specializations)
    return true
end

function RWSM53AutoReel.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(
        vehicleType,
        "onLoad",
        RWSM53AutoReel
    )
    SpecializationUtil.registerEventListener(
        vehicleType,
        "onUpdate",
        RWSM53AutoReel
    )
    SpecializationUtil.registerEventListener(
        vehicleType,
        "saveToXMLFile",
        RWSM53AutoReel
    )
    SpecializationUtil.registerEventListener(
        vehicleType,
        "onRegisterActionEvents",
        RWSM53AutoReel
    )
    SpecializationUtil.registerEventListener(
        vehicleType,
        "onDraw",
        RWSM53AutoReel
    )
end

function RWSM53AutoReel:onLoad(savegame)
    self.RAR = {
        actionEvents = {},
        animationAvailable = rarAnimationExists(self),
        reelCommandActive = false,
        shutdownCompleted = false,
        completeMessageTimer = 0,
        transportStateInitialized = false,
        lastWorkMode = nil,
        analysisTimer = 0,
        analysisLastDistance = nil,
        analysisNoProgressMs = 0,
        analysisSlope = 0,
        analysisProgressRatio = 1,
        analysisLevel = 0,
        analysisSpring = NORMAL_SPRING,
        analysisDamping = NORMAL_DAMPING,
        currentPullSpring = NORMAL_SPRING,
        currentPullDamping = NORMAL_DAMPING,
        targetPullSpring = NORMAL_SPRING,
        targetPullDamping = NORMAL_DAMPING,
        pullSmoothTimer = 0,
        tipSafetyActive = false,
        distancePullMultiplier = 1.0,
        analysisStatusKey = "siteAnalysisNormal",
        analysisPaused = false,
        loadedAnimationTime = nil,
        transportRetryTimer = 0,
        transportDocked = false,
        pulloutLimitTimer = 0,
        pulloutLimiterActive = false,
        pulloutLimitX = nil,
        pulloutLimitZ = nil,
        hoseWarningLevel = nil,
        loadStabilizeUntil = (tonumber(g_time) or 0) + LOAD_STABILIZATION_MS
    }

    if savegame ~= nil and not savegame.resetVehicles and savegame.xmlFile ~= nil and savegame.key ~= nil then
        local value = savegame.xmlFile:getValue(savegame.key .. ".rwsmAutoReel#animationTime")
        if tonumber(value) ~= nil then
            self.RAR.loadedAnimationTime = math.max(0, math.min(1, tonumber(value)))
        end
    end

    if self.RAR.animationAvailable then
        print(
            "[RWSM v0.56] FS19 reel v0.33 ready "
            .. "with transport-lock synchronization"
        )
    else
        print(
            "[RWSM v0.56] Error: hoseReelLS19 animation missing"
        )
    end
end

function RWSM53AutoReel:saveToXMLFile(xmlFile, key, usedModNames)
    if xmlFile == nil or key == nil or self.RAR == nil or not self.RAR.animationAvailable then return end
    local animationTime = rarGetAnimationTime(self)
    if animationTime ~= nil then
        xmlFile:setValue(key .. ".rwsmAutoReel#animationTime", animationTime)
    end
end

function RWSM53AutoReel:onUpdate(
    dt,
    isActiveForInput,
    isActiveForInputIgnoreSelection,
    isSelected
)
    local data = self.RAR

    if data == nil or not data.animationAvailable then
        return
    end

    -- Savegame startup guard: GIANTS restores vehicle components, input joints
    -- and attached implements over several update passes. Do not change the
    -- internal hose joint limit during that phase; doing so can create a large
    -- constraint impulse while the Rainstar/pump combination is still settling.
    local now = tonumber(g_time) or 0
    if now < (tonumber(data.loadStabilizeUntil) or 0) then
        -- GIANTS owns component reconstruction completely during startup.
        -- Do not change spring, damping or translation limits in this window.
        return
    end

    -- 1.38.28 rollover safety: neither the hose-reel chassis nor the sprinkler
    -- cart may be driven by passive hose-joint force while tipped. This applies
    -- even when pump and automatic reel are completely switched off.
    local assemblyTippedNow = rarIsAssemblyTipped(self)
    if assemblyTippedNow then
        data.tipSafetyActive = true
        if data.reelCommandActive == true or rarIsAnimationPlaying(self) then
            rarStop(self, true)
        end
        rarReleasePulloutLimiter(self)
        if self.isServer then
            rarSetJointSpring(self, TIP_SAFETY_SPRING, TIP_SAFETY_DAMPING)
        end
        return
    elseif data.tipSafetyActive == true then
        data.tipSafetyActive = false
    end

    if data.tipSafetyActive == false and self.isServer and data.reelCommandActive ~= true
        and data.pulloutLimiterActive ~= true then
        -- Safe baseline is restored only while upright and not actively pulling.
        rarSetJointSpring(self, IDLE_SPRING, IDLE_DAMPING)
    end

    if data.reelCommandActive and self.raiseActive ~= nil then
        self:raiseActive()
    end

    local workMode = rarIsWorkMode(self)

    -- 1.38.24: while a tractor pulls the sprinkler cart out, progressively
    -- tighten the component-joint envelope from 210 m onward. This prevents
    -- driving beyond the physical 220 m hose while leaving automatic retraction
    -- and savegame reconstruction untouched.
    rarUpdatePulloutLimiter(self, dt)

    -- Hose length warnings are edge-triggered so the player is not spammed.
    if self.isClient and rarIsTractorAttachedToCart(self) then
        local remaining = math.max(0, MAX_HOSE_LENGTH - math.min(MAX_HOSE_LENGTH, rarGetDistance(self)))
        local level = remaining <= 0.5 and 3 or (remaining <= 10 and 2 or (remaining <= 30 and 1 or 0))
        if data.hoseWarningLevel == nil then
            data.hoseWarningLevel = level
        elseif level > data.hoseWarningLevel then
            if level == 1 then rarShowWarning("warning_RAINSTAR_HOSE_30M")
            elseif level == 2 then rarShowWarning("warning_RAINSTAR_HOSE_10M")
            elseif level == 3 then rarShowWarning("warning_RAINSTAR_HOSE_MAX") end
            data.hoseWarningLevel = level
        elseif level < data.hoseWarningLevel then
            data.hoseWarningLevel = level
        end
    else
        data.hoseWarningLevel = nil
    end

    -- The reel animation and the folding animation both control the same
    -- component joint. Synchronize them only when the operating mode changes.
    if not data.transportStateInitialized then
        data.transportStateInitialized = true
        data.lastWorkMode = workMode

        if workMode then
            -- The real saved component positions already define the hose length.
            -- Releasing the joint to 220 m avoids restoring a preloaded constraint
            -- that can flip the reel immediately after loading. The drum visual is
            -- calculated from the real distance, so no visual hose length is lost.
            rarReleaseFullHose(self)
            data.loadedAnimationTime = nil
            if self.isServer then
                rarSetJointSpring(self, IDLE_SPRING, IDLE_DAMPING)
            end
            data.transportDocked = false
        else
            data.transportDocked = rarLockCartAtReel(self)
            data.loadedAnimationTime = nil
        end
    elseif workMode ~= data.lastWorkMode then
        data.lastWorkMode = workMode

        if workMode then
            -- Work mode explicitly releases the cart for pulling out.
            rarReleaseFullHose(self)
            data.transportDocked = false
            data.transportRetryTimer = 0
        else
            -- Try immediately and keep retrying below until the cart enters
            -- the capture range. This also repairs old savegame states.
            data.transportDocked = rarLockCartAtReel(self)
            data.transportRetryTimer = 0
        end
    end

    -- In transport mode the cart may be driven or pushed to the reel after
    -- the mode was selected. Retry the native joint lock at low frequency so
    -- the coupling cannot be missed because of one frame or an old save state.
    if not workMode and not rarIsTractorAttachedToCart(self) then
        data.transportRetryTimer = (data.transportRetryTimer or 0) + (tonumber(dt) or 0)
        if data.transportRetryTimer >= TRANSPORT_RETRY_INTERVAL_MS then
            data.transportRetryTimer = data.transportRetryTimer - TRANSPORT_RETRY_INTERVAL_MS
            if not data.transportDocked then
                data.transportDocked = rarLockCartAtReel(self)
                if data.transportDocked then
                    print(string.format(
                        "[RWSM v1.36.79] Rainstar transport coupling captured at %.2f m",
                        rarGetDistance(self)
                    ))
                end
            end
        end
    elseif workMode then
        data.transportDocked = false
        data.transportRetryTimer = 0
    end

    if data.completeMessageTimer > 0 then
        data.completeMessageTimer = math.max(
            0,
            data.completeMessageTimer - dt
        )
    end

    if data.reelCommandActive then
        if not workMode
            or rarIsTractorAttachedToCart(self)
            or not rarIsPumpConnected(self)
            or not rarIsPumpRunning(self) then

            rarStop(self, true)
        else
            local distance = rarGetDistance(self)

            if distance <= COMPLETE_DISTANCE then
                rarComplete(self)
            else
                rarUpdateSiteAnalysis(self, dt)
                rarUpdatePullSmoothing(self, dt)

                if rarIsAnimationPlaying(self) then
                    self:setAnimationSpeed(
                        ANIMATION_NAME,
                        rarGetCurrentReelSpeedScale(self)
                    )
                end
            end
        end
    end

    if self.isClient and data.actionEvents ~= nil then
        local action =
            data.actionEvents[
                InputAction.RWSM53_REEL_TOGGLE
            ]

        if action ~= nil then
            g_inputBinding:setActionEventText(
                action.actionEventId,
                g_i18n:getText(
                    data.reelCommandActive
                        and "action_RAINSTAR_REEL_STOP"
                        or "action_RAINSTAR_REEL_START"
                )
            )

            g_inputBinding:setActionEventActive(
                action.actionEventId,
                data.reelCommandActive
                    or (
                        workMode
                        and rarGetDistance(self)
                            > STOP_DISTANCE + 0.2
                    )
            )
        end
    end
end

function RWSM53AutoReel:onRegisterActionEvents(
    isActiveForInput,
    isActiveForInputIgnoreSelection
)
    local data = self.RAR

    if not self.isClient
        or data == nil
        or not data.animationAvailable then
        return
    end

    self:clearActionEventsTable(
        data.actionEvents
    )

    -- With the hose-only pump connection, N belongs exclusively to the pump.
    -- Registering the same action on both independent vehicles can toggle twice
    -- in one key press (start + immediate stop), which looks like no reaction.
    local virtualPump = self.rwsmVirtualPump
    if virtualPump ~= nil and virtualPump.RPC ~= nil
        and virtualPump.RPC.virtualHoseConnected == true
        and virtualPump.RPC.virtualRainstar == self then
        return
    end

    if isActiveForInputIgnoreSelection then
        local _, actionEventId =
            self:addActionEvent(
                data.actionEvents,
                InputAction.RWSM53_REEL_TOGGLE,
                self,
                RWSM53AutoReel.actionEventToggle,
                false,
                true,
                false,
                true,
                nil
            )

        if actionEventId ~= nil then
            g_inputBinding:setActionEventTextPriority(
                actionEventId,
                GS_PRIO_NORMAL
            )
        end
    end
end

function RWSM53AutoReel.actionEventToggle(
    self,
    actionName,
    inputValue,
    callbackState,
    isAnalog
)
    if self.RAR == nil then
        return
    end

    if self.RAR.reelCommandActive then
        rarStop(self, true)
    else
        rarStart(self)
    end
end

function RWSM53AutoReel:onDraw(
    isActiveForInput,
    isActiveForInputIgnoreSelection,
    isSelected
)
    local data = self.RAR

    if not self.isClient
        or data == nil
        or not data.animationAvailable
        or g_currentMission == nil
        or g_currentMission.addExtraPrintText == nil then
        return
    end

    local tractorOnCart = rarIsTractorAttachedToCart(self)
    if not isActiveForInputIgnoreSelection and not tractorOnCart then return end

    local distance = rarGetDistance(self)
    if tractorOnCart then
        local extended = math.max(0, math.min(MAX_HOSE_LENGTH, distance))
        local remaining = math.max(0, MAX_HOSE_LENGTH - extended)
        g_currentMission:addExtraPrintText(string.format(
            "%s: %.0f / %d m",
            g_i18n:getText("rwsm_hoseExtended"),
            extended,
            MAX_HOSE_LENGTH
        ))
        g_currentMission:addExtraPrintText(string.format(
            "%s: %.0f m",
            g_i18n:getText("rwsm_hoseOnDrum"),
            remaining
        ))
        if remaining <= 10 then
            g_currentMission:addExtraPrintText(g_i18n:getText(
                remaining <= 0.5 and "warning_RAINSTAR_HOSE_MAX" or "rwsm_hoseAlmostEmpty"
            ))
        end
    end
    local remainingHours =
        math.max(
            0,
            distance - STOP_DISTANCE
        ) / BASE_REEL_SPEED_M_PER_HOUR

    local hours = math.floor(remainingHours)
    local minutes = math.floor(
        (remainingHours - hours) * 60 + 0.5
    )

    g_currentMission:addExtraPrintText(
        string.format(
            "%s: %s | %.0f m/h | %d h %02d min",
            g_i18n:getText("autoReel"),
            g_i18n:getText(
                data.reelCommandActive
                    and "status_RAINSTAR_REEL_ACTIVE"
                    or "status_RAINSTAR_REEL_READY"
            ),
            BASE_REEL_SPEED_M_PER_HOUR,
            hours,
            minutes
        )
    )

    if data.completeMessageTimer > 0 then
        g_currentMission:addExtraPrintText(
            g_i18n:getText(
                "status_RAINSTAR_REEL_COMPLETE_SHUTDOWN"
            )
        )
    end
end
