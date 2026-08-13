-- ============================================================
-- ScsPumpWalkUpIntentEvent.lua
-- BUILD 22:53: server-sticky walk-up pump intent for leave-stop shield.
-- Client pendingTurnOn alone is not enough on dedicated (~250 ms kill).
-- This bit makes getRequiresPower true on the authority for the crank window.
-- ============================================================

ScsPumpWalkUpIntentEvent = {}
local ScsPumpWalkUpIntentEvent_mt = Class(ScsPumpWalkUpIntentEvent, Event)

-- BUILD 06:22 (George): InitEventClass, not InitStaticEventClass. The static form
-- does not give this a registered class the connection can resolve on the far side.
InitEventClass(ScsPumpWalkUpIntentEvent, "ScsPumpWalkUpIntentEvent")

function ScsPumpWalkUpIntentEvent.emptyNew()
    return Event.new(ScsPumpWalkUpIntentEvent_mt)
end

function ScsPumpWalkUpIntentEvent.new(vehicle, intent)
    local self = ScsPumpWalkUpIntentEvent.emptyNew()
    self.vehicle = vehicle
    self.intent = intent == true
    return self
end

function ScsPumpWalkUpIntentEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.intent == true)
end

function ScsPumpWalkUpIntentEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.intent = streamReadBool(streamId)
    self:run(connection)
end

function ScsPumpWalkUpIntentEvent:run(connection)
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.getIsSynchronized == nil or not vehicle:getIsSynchronized() then
        return
    end
    local spec = vehicle.spec_scsPumpHose
    if spec == nil then
        return
    end

    if self.intent then
        spec.pendingTurnOn = true
        spec.pendingTurnOnTimer = 0
        spec.sawMotorStart = false
        spec.walkUpMotorIntent = true
        if vehicle.raiseActive ~= nil then
            pcall(vehicle.raiseActive, vehicle)
        end
        if Motorized ~= nil and type(Motorized.tryStartMotor) == "function" then
            pcall(Motorized.tryStartMotor, vehicle)
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
        if ScsPumpHoseConnection ~= nil and ScsPumpHoseConnection.updatePendingTurnOn ~= nil then
            ScsPumpHoseConnection.updatePendingTurnOn(vehicle, 0)
        end
    else
        spec.pendingTurnOn = false
        spec.pendingTurnOnTimer = 0
        spec.sawMotorStart = false
        spec.walkUpMotorIntent = false
    end

    if not connection:getIsServer() and g_server ~= nil then
        g_server:broadcastEvent(self, false, connection, vehicle)
    end
end

function ScsPumpWalkUpIntentEvent.send(vehicle, intent)
    if vehicle == nil then
        return
    end
    intent = intent == true
    if g_server ~= nil then
        -- Listen/SP: flags already applied by caller; still broadcast for peers.
        g_server:broadcastEvent(ScsPumpWalkUpIntentEvent.new(vehicle, intent), nil, nil, vehicle)
        return
    end
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local conn = g_client:getServerConnection()
        if conn ~= nil then
            conn:sendEvent(ScsPumpWalkUpIntentEvent.new(vehicle, intent))
        end
    end
end
