-- ============================================================
-- CropStressHeatResultEvent.lua
-- SCS #191 follow-up: the server's answer to one CropStressHeatRequestEvent, sent
-- to the requesting connection only. Stream: Bool accepted, String code, UInt8 days.
-- Codes: OK, NOT_ADMIN, BAD_DAYS. readStream ends by calling run (the engine never
-- calls run for an incoming event, Server.lua:435-437).
-- ============================================================

CropStressHeatResultEvent = CropStressHeatResultEvent or {}
CropStressHeatResultEvent_mt = Class(CropStressHeatResultEvent, Event)

InitEventClass(CropStressHeatResultEvent, "CropStressHeatResultEvent")

function CropStressHeatResultEvent.emptyNew()
    return Event.new(CropStressHeatResultEvent_mt)
end

function CropStressHeatResultEvent.new(accepted, code, days)
    local self = CropStressHeatResultEvent.emptyNew()
    self.accepted = accepted == true
    self.code     = code or "OK"
    self.days     = days or 0
    return self
end

function CropStressHeatResultEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.accepted == true)
    streamWriteString(streamId, self.code or "OK")
    streamWriteUInt8(streamId, math.max(0, math.min(255, math.floor(tonumber(self.days) or 0))))
end

function CropStressHeatResultEvent:readStream(streamId, connection)
    self.accepted = streamReadBool(streamId)
    self.code     = streamReadString(streamId)
    self.days     = streamReadUInt8(streamId)
    self:run(connection)
end

function CropStressHeatResultEvent:run(connection)
    if g_cropStressManager ~= nil then
        g_cropStressManager:onHeatResult(self.accepted, self.code, self.days)
    end
end
