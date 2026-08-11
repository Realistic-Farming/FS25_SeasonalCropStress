-- ============================================================
-- CropStressPivotRemoteEvent.lua
-- Server-authoritative Esc PIVOT remote ops for farm-owned Reinke.
-- Proximity bypass only; door → power → ops tier honesty kept.
-- George ENGINE ACK 2026-08-09 GO WITH CONSTRAINTS.
-- ============================================================

CropStressPivotRemoteEvent = {}
CropStressPivotRemoteEvent_mt = Class(CropStressPivotRemoteEvent, Event)

InitEventClass(CropStressPivotRemoteEvent, "CropStressPivotRemoteEvent")

CropStressPivotRemoteEvent.ACTION = {
    DOOR_TOGGLE     = 1,
    POWER_TOGGLE    = 2,
    SPRAY_TOGGLE    = 3,
    END_GUN_TOGGLE  = 4,
    SPEED_CYCLE     = 5,
    AUTO_START      = 6,
    AUTO_STOP       = 7,
    SWEEP_MIN_UP    = 8,
    SWEEP_MIN_DN    = 9,
    SWEEP_MAX_UP    = 10,
    SWEEP_MAX_DN    = 11,
    ARM_STEP_PLUS   = 12,
    ARM_STEP_MINUS  = 13,
}

local function resolvePlaceable(systemId)
    if systemId == nil or g_currentMission == nil then
        return nil
    end
    local ps = g_currentMission.placeableSystem
    if ps == nil or ps.placeables == nil then
        return nil
    end
    for _, p in pairs(ps.placeables) do
        if p ~= nil and p.id == systemId then
            return p
        end
    end
    return nil
end

local function isReinkePlaceable(placeable)
    if placeable == nil then
        return false
    end
    return type(placeable.toggleMasterPower) == "function"
        or type(placeable.toggleSprayActive) == "function"
        or type(placeable.toggleDoor) == "function"
end

--- BUILD 16:44: this used to lead with connection:getFarmId(), which does not
--- exist anywhere in FS25 (zero definitions in the decompile), so on a real client
--- connection the first branch was dead and ownership fell through to the local
--- farm. Vanilla resolves the farm with getPlayerByConnection then player.farmId -
--- FarmlandStateEvent, RequestMoneyChangeEvent and SellHandToolEvent all do this.
local function farmIdFromConnection(connection)
    if connection ~= nil and type(connection.getIsServer) == "function" and not connection:getIsServer() then
        if g_currentMission ~= nil and type(g_currentMission.getPlayerByConnection) == "function" then
            local player = g_currentMission:getPlayerByConnection(connection)
            if player ~= nil then
                if type(player.getFarmId) == "function" then
                    local id = player:getFarmId()
                    if type(id) == "number" and id > 0 then
                        return id
                    end
                end
                if type(player.farmId) == "number" and player.farmId > 0 then
                    return player.farmId
                end
            end
        end
        -- Kept as a second chance only; the player lookup above is the real path.
        if g_currentMission ~= nil and g_currentMission.userManager ~= nil
            and type(g_currentMission.userManager.getUserByConnection) == "function" then
            local user = g_currentMission.userManager:getUserByConnection(connection)
            if user ~= nil and type(user.farmId) == "number" and user.farmId > 0 then
                return user.farmId
            end
        end
    end
    local mgr = g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
    if mgr ~= nil and type(mgr.getLocalFarmId) == "function" then
        local id = mgr.getLocalFarmId()
        if type(id) == "number" and id > 0 then
            return id
        end
    end
    if g_currentMission ~= nil and g_currentMission.player ~= nil then
        local id = g_currentMission.player.farmId
        if type(id) == "number" and id > 0 then
            return id
        end
    end
    return nil
end

--- BUILD 16:44: this returned nil whenever ReinkeIrrigationPivot was not visible
--- in the Event's environment, and that nil is not harmless. applyAction derives
--- doorOpen and powered from this spec, so a nil spec makes both false, which sends
--- POWER_TOGGLE and every ops remote straight into the `not doorOpen or not powered`
--- guard. Only DOOR_TOGGLE could ever fire. The guest already carried the soft-detect
--- scan for exactly this reason; the Event never got it. Same shape as the guest now.
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

local function applyAction(placeable, action)
    local A = CropStressPivotRemoteEvent.ACTION
    local spec = getReinkeSpec(placeable)

    if action == A.DOOR_TOGGLE then
        if type(placeable.toggleDoor) == "function" then
            placeable:toggleDoor()
        end
        return
    end

    local doorOpen = spec ~= nil and spec.doorOpen == true
    local powered = spec ~= nil and spec.masterPower == true

    if action == A.POWER_TOGGLE then
        if doorOpen and type(placeable.toggleMasterPower) == "function" then
            placeable:toggleMasterPower()
        end
        return
    end

    if not doorOpen or not powered then
        return
    end

    if action == A.SPRAY_TOGGLE then
        if type(placeable.toggleSprayActive) == "function" then
            placeable:toggleSprayActive()
        end
        return
    end
    if action == A.END_GUN_TOGGLE then
        if type(placeable.toggleEndGun) == "function" then
            placeable:toggleEndGun()
        end
        return
    end
    if action == A.SPEED_CYCLE then
        if type(placeable.cycleSpeed) == "function" then
            placeable:cycleSpeed()
        end
        return
    end

    if action == A.AUTO_START or action == A.AUTO_STOP then
        local mgr = g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
        local irr = mgr ~= nil and mgr.irrigationManager or nil
        local scsRow = irr ~= nil and irr.systems ~= nil and irr.systems[placeable.id] or nil
        if scsRow ~= nil then
            if action == A.AUTO_START and type(irr.activateSystem) == "function" then
                irr:activateSystem(placeable.id)
            elseif action == A.AUTO_STOP and type(irr.deactivateSystem) == "function" then
                irr:deactivateSystem(placeable.id)
            end
            return
        end
        if action == A.AUTO_START and type(placeable.remoteAutoStart) == "function" then
            placeable:remoteAutoStart()
        elseif action == A.AUTO_STOP and type(placeable.remoteAutoStop) == "function" then
            placeable:remoteAutoStop()
        elseif spec ~= nil then
            if action == A.AUTO_START then
                spec.autoRotate = true
                spec.isActive = true
                spec.targetAngle = nil
            else
                spec.autoRotate = false
                spec.isActive = false
                spec.targetAngle = nil
            end
            if type(placeable.raiseDirtyFlags) == "function" and spec.dirtyFlag ~= nil then
                placeable:raiseDirtyFlags(spec.dirtyFlag)
            end
        end
        return
    end

    if action == A.SWEEP_MIN_UP then
        if type(placeable.adjustSweepMin) == "function" then
            placeable:adjustSweepMin(10)
        end
        return
    end
    if action == A.SWEEP_MIN_DN then
        if type(placeable.adjustSweepMin) == "function" then
            placeable:adjustSweepMin(-10)
        end
        return
    end
    if action == A.SWEEP_MAX_UP then
        if type(placeable.adjustSweepMax) == "function" then
            placeable:adjustSweepMax(10)
        end
        return
    end
    if action == A.SWEEP_MAX_DN then
        if type(placeable.adjustSweepMax) == "function" then
            placeable:adjustSweepMax(-10)
        end
        return
    end

    if action == A.ARM_STEP_PLUS or action == A.ARM_STEP_MINUS then
        if spec ~= nil and spec.autoRotate then
            return
        end
        if type(placeable.stepTargetAngle) == "function" then
            placeable:stepTargetAngle(action == A.ARM_STEP_PLUS and 1 or -1)
        end
    end
end

function CropStressPivotRemoteEvent.emptyNew()
    local self = Event.new(CropStressPivotRemoteEvent_mt)
    return self
end

--- Vanilla Event shape (RequestMoneyChangeEvent): emptyNew via Event.new(mt);
--- constructor is a **dot** new(systemId, action). Colon :new + call-site .new
--- swapped args (self became systemId) -> DENIED systemId=1 action=nil.
function CropStressPivotRemoteEvent.new(systemId, action)
    local self = CropStressPivotRemoteEvent.emptyNew()
    self.systemId = systemId
    self.action = action
    return self
end

function CropStressPivotRemoteEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteUInt8(streamId, self.action or 0)
end

function CropStressPivotRemoteEvent:readStream(streamId, connection)
    self.systemId = streamReadInt32(streamId)
    self.action = streamReadUInt8(streamId)
end

function CropStressPivotRemoteEvent:run(connection)
    if g_server == nil then
        return
    end
    local systemId = self.systemId
    local action = self.action
    -- BUILD 16:44 prove prints. Every early return below used to be silent, so a
    -- remote that did nothing was indistinguishable from one that never arrived.
    -- These fire once per player click on the server, never on a tick.
    local function deny(why, ...)
        print("[CropStress] pivot Event DENIED (" .. tostring(why) .. "): " .. string.format(...))
    end
    if systemId == nil or systemId == 0 or action == nil or action < 1 or action > 13 then
        deny("bad payload", "systemId=%s action=%s", tostring(systemId), tostring(action))
        return
    end
    local A = CropStressPivotRemoteEvent.ACTION
    local placeable = resolvePlaceable(systemId)
    local farmId = farmIdFromConnection(connection)
    if farmId == nil or farmId == 0 then
        deny("no farmId", "systemId=%s action=%s connection=%s",
            tostring(systemId), tostring(action), tostring(connection))
        return
    end

    -- AUTO_START/STOP may target any SCS irrigation system (pivot or drip).
    if action == A.AUTO_START or action == A.AUTO_STOP then
        local mgr = g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
        local irr = mgr ~= nil and mgr.irrigationManager or nil
        local sys = irr ~= nil and irr.systems ~= nil and irr.systems[systemId] or nil
        if sys ~= nil then
            if placeable ~= nil and type(placeable.getOwnerFarmId) == "function" then
                local ownerId = placeable:getOwnerFarmId()
                if ownerId == nil or ownerId ~= farmId then
                    return
                end
            end
            if action == A.AUTO_START and type(irr.activateSystem) == "function" then
                irr:activateSystem(systemId)
            elseif action == A.AUTO_STOP and type(irr.deactivateSystem) == "function" then
                irr:deactivateSystem(systemId)
            end
            return
        end
        -- Standalone Reinke (no SCS row): placeable mutators.
        if placeable == nil or not isReinkePlaceable(placeable) then
            return
        end
        local ownerId = type(placeable.getOwnerFarmId) == "function" and placeable:getOwnerFarmId() or nil
        if ownerId == nil or ownerId ~= farmId then
            return
        end
        applyAction(placeable, action)
        return
    end

    if placeable == nil or not isReinkePlaceable(placeable) then
        deny("not a Reinke pivot", "systemId=%s placeable=%s action=%s",
            tostring(systemId), tostring(placeable), tostring(action))
        return
    end
    local ownerId = nil
    if type(placeable.getOwnerFarmId) == "function" then
        ownerId = placeable:getOwnerFarmId()
    end
    if ownerId == nil or ownerId ~= farmId then
        deny("ownership", "owner=%s farmId=%s systemId=%s",
            tostring(ownerId), tostring(farmId), tostring(systemId))
        return
    end
    local spec = getReinkeSpec(placeable)
    print(string.format(
        "[CropStress] pivot Event APPLY action=%s systemId=%s farmId=%s doorOpen=%s powered=%s spec=%s",
        tostring(action), tostring(systemId), tostring(farmId),
        tostring(spec ~= nil and spec.doorOpen), tostring(spec ~= nil and spec.masterPower),
        tostring(spec ~= nil)))
    applyAction(placeable, action)
end

function CropStressPivotRemoteEvent.sendToServer(systemId, action)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    if systemId == nil or action == nil then
        return false
    end
    g_client:getServerConnection():sendEvent(CropStressPivotRemoteEvent.new(systemId, action))
    return true
end
