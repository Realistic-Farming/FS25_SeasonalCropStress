-- ============================================================
-- CropStressRainKeyResultEvent.lua
-- SCS-046 server result for a rain-key command. Stable codes:
--   OK, RAIN_KEY_TRIPPED, NOT_AUTHORIZED, STALE_CONFIRMATION,
--   INVALID_TRIP_MM, UNKNOWN_SYSTEM, UNKNOWN_ACTION, FAILED
-- ============================================================

CropStressRainKeyResultEvent = CropStressRainKeyResultEvent or {}
CropStressRainKeyResultEvent_mt = Class(CropStressRainKeyResultEvent, Event)

InitEventClass(CropStressRainKeyResultEvent, "CropStressRainKeyResultEvent")

function CropStressRainKeyResultEvent.emptyNew()
    return Event.new(CropStressRainKeyResultEvent_mt)
end

function CropStressRainKeyResultEvent.new(systemId, accepted, resultCode)
    local self = CropStressRainKeyResultEvent.emptyNew()
    self.systemId   = systemId or 0
    self.accepted   = accepted == true
    self.resultCode = resultCode or "OK"
    return self
end

function CropStressRainKeyResultEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteBool(streamId, self.accepted == true)
    streamWriteString(streamId, self.resultCode or "OK")
end

function CropStressRainKeyResultEvent:readStream(streamId, connection)
    self.systemId   = streamReadInt32(streamId)
    self.accepted   = streamReadBool(streamId)
    self.resultCode = streamReadString(streamId)
end

function CropStressRainKeyResultEvent:run(connection)
    -- Result delivery: nothing to apply client-side beyond logging for now.
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]",
            string.format("rain-key result system=%d accepted=%s code=%s",
                self.systemId or 0, tostring(self.accepted), self.resultCode or "?"))
    end
end
