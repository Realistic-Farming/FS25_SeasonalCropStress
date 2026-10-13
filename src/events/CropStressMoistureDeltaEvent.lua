-- ============================================================
-- CropStressMoistureDeltaEvent.lua  (SCS-039 / GRID-1, SDS 3.7)
--
-- One coalesced ABSOLUTE per-pixel delta of the fine map, field-partitioned.
-- It names fromRevision and toRevision (a contiguous provider chain) plus the
-- pixel key and the final semantic moisture value. A client applies it only
-- when contiguous; a gap or a stale revision is a named semantic mismatch that
-- requests one fresh full snapshot rather than repairing the tuple.
--
-- Wire format:
--   snapshotGeneration : Int32
--   fromRevision       : Int32
--   toRevision         : Int32
--   fieldId            : Int32
--   pixelKey           : Int32   (px*4096+pz)
--   value              : Float32 (absolute semantic 0..1)
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

CropStressMoistureDeltaEvent = CropStressMoistureDeltaEvent or {}
CropStressMoistureDeltaEvent_mt = Class(CropStressMoistureDeltaEvent, Event)

InitEventClass(CropStressMoistureDeltaEvent, "CropStressMoistureDeltaEvent")

function CropStressMoistureDeltaEvent.emptyNew()
    return Event.new(CropStressMoistureDeltaEvent_mt)
end

function CropStressMoistureDeltaEvent.new(snapshotGeneration, fromRevision, toRevision,
    fieldId, pixelKey, value)
    local self = Event.new(CropStressMoistureDeltaEvent_mt)
    self.snapshotGeneration = snapshotGeneration or 0
    self.fromRevision = fromRevision or 0
    self.toRevision = toRevision or 0
    self.fieldId = fieldId or 0
    self.pixelKey = pixelKey or 0
    self.value = value or 0
    return self
end

function CropStressMoistureDeltaEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.snapshotGeneration)
    streamWriteInt32(streamId, self.fromRevision)
    streamWriteInt32(streamId, self.toRevision)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteInt32(streamId, self.pixelKey)
    streamWriteFloat32(streamId, self.value)
end

function CropStressMoistureDeltaEvent:readStream(streamId, connection)
    self.snapshotGeneration = streamReadInt32(streamId)
    self.fromRevision = streamReadInt32(streamId)
    self.toRevision = streamReadInt32(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.pixelKey = streamReadInt32(streamId)
    self.value = streamReadFloat32(streamId)
    self:run(connection)
end

function CropStressMoistureDeltaEvent:run(connection)
    if g_server ~= nil then return end

    local mgr = g_cropStressManager
    local soilSystem = mgr and mgr.soilSystem
    local fine = soilSystem and soilSystem.fineSnapshot
    if fine == nil then return end

    local ok = fine:receiveDelta(self.fromRevision, self.toRevision, self.pixelKey, self.value)
    if not ok and fine.resnapshot then
        csLog("Moisture map: delta gap requests a fresh full snapshot")
    end
end
