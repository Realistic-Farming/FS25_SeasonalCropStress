-- ============================================================
-- CropStressIrrigateNowEvent.lua
-- Server-authoritative "Irrigate Now" request. Every host and client entry runs
-- the one F200 chain: CropStressIrrigateNowEvent -> applyIrrigateNowTransaction
-- -> CropStressIrrigateNowResultEvent, including mode off. The requester farm is
-- resolved only through the engine's g_currentMission:getFarmId(connection); a
-- listen host passes nil. No public path calls applyOneTimeIrrigation.
-- ============================================================

CropStressIrrigateNowEvent = CropStressIrrigateNowEvent or {}
CropStressIrrigateNowEvent_mt = Class(CropStressIrrigateNowEvent, Event)

InitEventClass(CropStressIrrigateNowEvent, "CropStressIrrigateNowEvent")

function CropStressIrrigateNowEvent.emptyNew()
    return Event.new(CropStressIrrigateNowEvent_mt)
end

---@param systemId number
---@param expectedRainKeyRevision number  -1 for unfitted systems (F200)
function CropStressIrrigateNowEvent.new(systemId, expectedRainKeyRevision)
    local self = Event.new(CropStressIrrigateNowEvent_mt)
    self.systemId = systemId
    self.expectedRainKeyRevision = expectedRainKeyRevision or -1
    return self
end

function CropStressIrrigateNowEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteInt32(streamId, self.expectedRainKeyRevision or -1)
end

function CropStressIrrigateNowEvent:readStream(streamId, connection)
    self.systemId = streamReadInt32(streamId)
    self.expectedRainKeyRevision = streamReadInt32(streamId)
end

-- Server applies the water through the ONE transaction wrapper and sends the
-- direct result back on the same connection.
function CropStressIrrigateNowEvent:run(connection)
    if g_server == nil then return end
    local mgr = g_cropStressManager
    if mgr == nil or mgr.irrigationManager == nil then return end
    local irrigationManager = mgr.irrigationManager
    local farmId = irrigationManager:resolveRequesterFarmId(connection)
    local result = irrigationManager:applyIrrigateNowTransaction(
        self.systemId, farmId, self.expectedRainKeyRevision)
    irrigationManager:dispatchIrrigateNowResult(self.systemId, result, connection, farmId)
end

-- Client helper: send the request to the server.
function CropStressIrrigateNowEvent.sendToServer(systemId, expectedRainKeyRevision)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    g_client:getServerConnection():sendEvent(
        CropStressIrrigateNowEvent.new(systemId, expectedRainKeyRevision or -1))
    return true
end
