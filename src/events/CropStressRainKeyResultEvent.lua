-- ============================================================
-- CropStressRainKeyResultEvent.lua
-- SCS-046 server result for a rain-key command. Stable codes:
--   OK, RAIN_KEY_TRIPPED, NOT_AUTHORIZED, STALE_CONFIRMATION,
--   INVALID_TRIP_MM, UNKNOWN_SYSTEM, UNKNOWN_ACTION, RELEASE_LOCKED, FAILED
-- F200 result stream: Int32 systemId, String action, Bool accepted,
-- String resultCode, Int32 stateRevision.
-- ============================================================

CropStressRainKeyResultEvent = CropStressRainKeyResultEvent or {}
CropStressRainKeyResultEvent_mt = Class(CropStressRainKeyResultEvent, Event)

InitEventClass(CropStressRainKeyResultEvent, "CropStressRainKeyResultEvent")

function CropStressRainKeyResultEvent.emptyNew()
    return Event.new(CropStressRainKeyResultEvent_mt)
end

function CropStressRainKeyResultEvent.new(systemId, accepted, resultCode, action, stateRevision)
    local self = CropStressRainKeyResultEvent.emptyNew()
    self.systemId   = systemId or 0
    self.action     = action or ""
    self.accepted   = accepted == true
    self.resultCode = resultCode or "OK"
    self.stateRevision = stateRevision or 0
    return self
end

function CropStressRainKeyResultEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteString(streamId, self.action or "")
    streamWriteBool(streamId, self.accepted == true)
    streamWriteString(streamId, self.resultCode or "OK")
    streamWriteInt32(streamId, self.stateRevision or 0)
end

function CropStressRainKeyResultEvent:readStream(streamId, connection)
    self.systemId   = streamReadInt32(streamId)
    self.action     = streamReadString(streamId)
    self.accepted   = streamReadBool(streamId)
    self.resultCode = streamReadString(streamId)
    self.stateRevision = streamReadInt32(streamId)
end

function CropStressRainKeyResultEvent:run(connection)
    -- Result delivery: nothing to apply client-side beyond logging for now.
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]",
            string.format("rain-key result system=%d action=%s accepted=%s code=%s rev=%d",
                self.systemId or 0, tostring(self.action), tostring(self.accepted),
                self.resultCode or "?", self.stateRevision or 0))
    end
end
