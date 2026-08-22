-- ============================================================
-- CropStressIrrigateNowEvent.lua
-- Server-authoritative "Irrigate Now" request. The dialog button chain was
-- ungated end to end: on a multiplayer client it wrote local state, showed
-- success, and the next server broadcast erased it (a ghost action). This
-- event routes the request to the server, which applies the water through the
-- single per-cell write path. Host behaviour is unchanged (server applies
-- directly). SCS-018 brief 3.6.
-- ============================================================

CropStressIrrigateNowEvent = CropStressIrrigateNowEvent or {}
CropStressIrrigateNowEvent_mt = Class(CropStressIrrigateNowEvent, Event)

InitEventClass(CropStressIrrigateNowEvent, "CropStressIrrigateNowEvent")

function CropStressIrrigateNowEvent.emptyNew()
    return CropStressIrrigateNowEvent:new()
end

function CropStressIrrigateNowEvent:new(systemId)
    local self = setmetatable({}, CropStressIrrigateNowEvent_mt)
    self.systemId = systemId
    return self
end

function CropStressIrrigateNowEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
end

function CropStressIrrigateNowEvent:readStream(streamId, connection)
    self.systemId = streamReadInt32(streamId)
end

-- Server applies the water (server-only; clients never run applyOneTimeIrrigation).
function CropStressIrrigateNowEvent:run(connection)
    if g_cropStressManager == nil or g_cropStressManager.irrigationManager == nil then
        return
    end
    if g_server == nil then
        return
    end
    g_cropStressManager.irrigationManager:applyOneTimeIrrigation(self.systemId)
end

-- Client helper: send the request to the server.
function CropStressIrrigateNowEvent.sendToServer(systemId)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    g_client:getServerConnection():sendEvent(CropStressIrrigateNowEvent.new(systemId))
    return true
end
