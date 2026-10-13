-- ============================================================
-- CropStressIrrigateNowResultEvent.lua  (SCS-023 / F200, SDS 6)
--
-- The DIRECT result of one Irrigate Now act, sent once on the same ready
-- connection that delivered the request. The lower-case result family is
-- success | partial | no_ground | dry_source | no_source | wrong_farm |
-- stale_confirmation | master_disabled | system_locked.
--
-- Wire format:
--   systemId           : Int32
--   accepted           : Bool
--   resultCode         : String
--   servedFraction     : Float32
--   acceptedTargetCount: Int32
--   committedHours     : Float32
--   stateRevision      : Int32
-- ============================================================

CropStressIrrigateNowResultEvent = CropStressIrrigateNowResultEvent or {}
CropStressIrrigateNowResultEvent_mt = Class(CropStressIrrigateNowResultEvent, Event)

InitEventClass(CropStressIrrigateNowResultEvent, "CropStressIrrigateNowResultEvent")

function CropStressIrrigateNowResultEvent.emptyNew()
    return Event.new(CropStressIrrigateNowResultEvent_mt)
end

---@param systemId number
---@param result table  {accepted, resultCode, servedFraction, acceptedTargetCount,
---  committedHours, stateRevision}
function CropStressIrrigateNowResultEvent.new(systemId, result)
    local self = Event.new(CropStressIrrigateNowResultEvent_mt)
    self.systemId = systemId or 0
    self.accepted = (result ~= nil and result.accepted == true) or false
    self.resultCode = (result ~= nil and result.resultCode) or "no_source"
    self.servedFraction = (result ~= nil and result.servedFraction) or 0
    self.acceptedTargetCount = (result ~= nil and result.acceptedTargetCount) or 0
    self.committedHours = (result ~= nil and result.committedHours) or 0
    self.stateRevision = (result ~= nil and result.stateRevision) or 0
    return self
end

function CropStressIrrigateNowResultEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId)
    streamWriteBool(streamId, self.accepted)
    streamWriteString(streamId, self.resultCode)
    streamWriteFloat32(streamId, self.servedFraction)
    streamWriteInt32(streamId, self.acceptedTargetCount)
    streamWriteFloat32(streamId, self.committedHours)
    streamWriteInt32(streamId, self.stateRevision)
end

function CropStressIrrigateNowResultEvent:readStream(streamId, connection)
    self.systemId = streamReadInt32(streamId)
    self.accepted = streamReadBool(streamId)
    self.resultCode = streamReadString(streamId)
    self.servedFraction = streamReadFloat32(streamId)
    self.acceptedTargetCount = streamReadInt32(streamId)
    self.committedHours = streamReadFloat32(streamId)
    self.stateRevision = streamReadInt32(streamId)
    self:run(connection)
end

function CropStressIrrigateNowResultEvent:run(connection)
    -- The server never handles a result it produced itself.
    if g_server ~= nil then return end
    if g_cropStressManager == nil then return end
    g_cropStressManager.lastIrrigateNowResult = {
        systemId = self.systemId,
        accepted = self.accepted,
        resultCode = self.resultCode,
        servedFraction = self.servedFraction,
        acceptedTargetCount = self.acceptedTargetCount,
        committedHours = self.committedHours,
        stateRevision = self.stateRevision,
    }
end
