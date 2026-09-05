-- ============================================================
-- CropStressRainKeyCommandEvent.lua
-- SCS-046 server-authoritative rain-key command. Actions:
--   FIT, REMOVE, SET_TRIP_MM.
-- The server validates ownership, applies the command through the one
-- applyRainKeyCommand path, and returns a stable result. Clients never
-- mutate a rain key locally; they send the request and await the result.
-- Request stream: Int32 systemId, String action, Bool hasValue,
-- Float32 value when hasValue, Int32 expectedRevision.
-- ============================================================

CropStressRainKeyCommandEvent = CropStressRainKeyCommandEvent or {}
CropStressRainKeyCommandEvent_mt = Class(CropStressRainKeyCommandEvent, Event)

InitEventClass(CropStressRainKeyCommandEvent, "CropStressRainKeyCommandEvent")

function CropStressRainKeyCommandEvent.emptyNew()
    return Event.new(CropStressRainKeyCommandEvent_mt)
end

---@param expectedRevision number  rain-key state revision the requester saw
function CropStressRainKeyCommandEvent.new(systemId, action, value, expectedRevision)
    local self = CropStressRainKeyCommandEvent.emptyNew()
    self.systemId = systemId or 0
    self.action   = action or ""
    self.value    = value
    self.expectedRevision = expectedRevision or -1
    return self
end

function CropStressRainKeyCommandEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteString(streamId, self.action or "")
    local hasValue = self.value ~= nil
    streamWriteBool(streamId, hasValue)
    if hasValue then streamWriteFloat32(streamId, self.value) end
    streamWriteInt32(streamId, self.expectedRevision or -1)
end

function CropStressRainKeyCommandEvent:readStream(streamId, connection)
    self.systemId = streamReadInt32(streamId)
    self.action   = streamReadString(streamId)
    local hasValue = streamReadBool(streamId)
    self.value = hasValue and streamReadFloat32(streamId) or nil
    self.expectedRevision = streamReadInt32(streamId)
end

-- Server applies the command (server-only; clients never mutate locally).
function CropStressRainKeyCommandEvent:run(connection)
    if g_cropStressManager == nil or g_cropStressManager.irrigationManager == nil then
        return
    end
    if g_server == nil then return end
    local irr = g_cropStressManager.irrigationManager
    local system = irr.systems[self.systemId]

    -- Ownership: the shared engine farm resolver only (F200). Listen-host nil
    -- connection takes the engine host branch; no connection.user, local-player
    -- or farm-1 fallback exists.
    local requesterFarmId = irr.resolveRequesterFarmId ~= nil
        and irr:resolveRequesterFarmId(connection) or nil
    if system == nil then
        if connection ~= nil then
            connection:sendEvent(CropStressRainKeyResultEvent.new(self.systemId, false, "UNKNOWN_SYSTEM"))
        end
        return
    end
    if requesterFarmId == nil or requesterFarmId <= 0
       or system.ownerFarmId == nil or system.ownerFarmId <= 0
       or requesterFarmId ~= system.ownerFarmId then
        if connection ~= nil then
            connection:sendEvent(CropStressRainKeyResultEvent.new(self.systemId, false, "NOT_AUTHORIZED"))
        end
        return
    end

    local ok, reason = irr:applyRainKeyCommand(self.systemId, self.action, self.value, self.expectedRevision)
    local code = reason or (ok and "OK" or "FAILED")
    if connection ~= nil then
        connection:sendEvent(CropStressRainKeyResultEvent.new(self.systemId, ok, code))
    end
end

-- Client helper: send the command to the server.
function CropStressRainKeyCommandEvent.sendToServer(systemId, action, value, expectedRevision)
    if g_client == nil or g_client:getServerConnection() == nil then return false end
    g_client:getServerConnection():sendEvent(
        CropStressRainKeyCommandEvent.new(systemId, action, value, expectedRevision or -1))
    return true
end
