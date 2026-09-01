-- ============================================================
-- CropStressRainKeyCommandEvent.lua
-- SCS-046 server-authoritative rain-key command. Actions:
--   FIT, REMOVE, SET_TRIP_MM.
-- The server validates ownership, applies the command through the one
-- applyRainKeyCommand path, and returns a stable result. Clients never
-- mutate a rain key locally; they send the request and await the result.
-- ============================================================

CropStressRainKeyCommandEvent = CropStressRainKeyCommandEvent or {}
CropStressRainKeyCommandEvent_mt = Class(CropStressRainKeyCommandEvent, Event)

InitEventClass(CropStressRainKeyCommandEvent, "CropStressRainKeyCommandEvent")

function CropStressRainKeyCommandEvent.emptyNew()
    return CropStressRainKeyCommandEvent:new()
end

function CropStressRainKeyCommandEvent:new(systemId, action, value)
    local self = setmetatable({}, CropStressRainKeyCommandEvent_mt)
    self.systemId = systemId or 0
    self.action   = action or ""
    self.value    = value
    return self
end

function CropStressRainKeyCommandEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteString(streamId, self.action or "")
    local hasValue = self.value ~= nil
    streamWriteBool(streamId, hasValue)
    if hasValue then streamWriteFloat32(streamId, self.value) end
end

function CropStressRainKeyCommandEvent:readStream(streamId, connection)
    self.systemId = streamReadInt32(streamId)
    self.action   = streamReadString(streamId)
    local hasValue = streamReadBool(streamId)
    self.value = hasValue and streamReadFloat32(streamId) or nil
end

-- Server applies the command (server-only; clients never mutate locally).
function CropStressRainKeyCommandEvent:run(connection)
    if g_cropStressManager == nil or g_cropStressManager.irrigationManager == nil then
        return
    end
    if g_server == nil then return end
    local irr = g_cropStressManager.irrigationManager
    local system = irr.systems[self.systemId]

    -- Ownership: server derives requester farm from the connection and compares it
    -- with the registered owner farm.
    local requesterFarmId = nil
    if connection ~= nil then
        local user = connection.user
        if user ~= nil and user.farmId ~= nil then requesterFarmId = user.farmId end
    end
    if requesterFarmId == nil and g_currentMission ~= nil and g_localPlayer ~= nil then
        requesterFarmId = g_localPlayer:getFarmId()
    end
    local ownerFarmId = system ~= nil and system.ownerFarmId or nil
    if system == nil then
        if g_client ~= nil then
            g_client:getServerConnection():sendEvent(CropStressRainKeyResultEvent.new(self.systemId, false, "UNKNOWN_SYSTEM"))
        end
        return
    end
    if ownerFarmId == nil or ownerFarmId <= 0 or requesterFarmId ~= ownerFarmId then
        if connection ~= nil then
            connection:sendEvent(CropStressRainKeyResultEvent.new(self.systemId, false, "NOT_AUTHORIZED"))
        elseif g_client ~= nil and g_client:getServerConnection() ~= nil then
            g_client:getServerConnection():sendEvent(CropStressRainKeyResultEvent.new(self.systemId, false, "NOT_AUTHORIZED"))
        end
        return
    end

    local ok, reason = irr:applyRainKeyCommand(self.systemId, self.action, self.value)
    local code = reason or (ok and "OK" or "FAILED")
    if connection ~= nil then
        connection:sendEvent(CropStressRainKeyResultEvent.new(self.systemId, ok, code))
    elseif g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(CropStressRainKeyResultEvent.new(self.systemId, ok, code))
    end
end

-- Client helper: send the command to the server.
function CropStressRainKeyCommandEvent.sendToServer(systemId, action, value)
    if g_client == nil or g_client:getServerConnection() == nil then return false end
    g_client:getServerConnection():sendEvent(CropStressRainKeyCommandEvent.new(systemId, action, value))
    return true
end
