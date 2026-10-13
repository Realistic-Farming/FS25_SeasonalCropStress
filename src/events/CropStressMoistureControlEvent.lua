-- ============================================================
-- CropStressMoistureControlEvent.lua  (SCS-039 / GRID-1, SDS 3.7)
--
-- The SNAPSHOT CONTROL envelope of the fine-map delivery. START opens one
-- immutable snapshot generation on the client's staging; COMPLETE is the
-- last-row barrier after which staging publishes once; RESNAPSHOT_REQUEST is
-- the one legal reply to a named semantic mismatch.
--
-- Wire format:
--   kind             : UInt8   "S" START | "C" COMPLETE | "R" RESNAPSHOT_REQUEST
--   snapshotGeneration : Int32
--   baseRevision     : Int32   (revision the snapshot freezes)
--   totalRows        : Int32   (0 for COMPLETE/RESNAPSHOT_REQUEST)
--   mapWidth         : Int32
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

CropStressMoistureControlEvent = CropStressMoistureControlEvent or {}
CropStressMoistureControlEvent_mt = Class(CropStressMoistureControlEvent, Event)

InitEventClass(CropStressMoistureControlEvent, "CropStressMoistureControlEvent")

CropStressMoistureControlEvent.KIND_START = "S"
CropStressMoistureControlEvent.KIND_COMPLETE = "C"
CropStressMoistureControlEvent.KIND_RESNAPSHOT_REQUEST = "R"

function CropStressMoistureControlEvent.emptyNew()
    return Event.new(CropStressMoistureControlEvent_mt)
end

function CropStressMoistureControlEvent.new(kind, snapshotGeneration, baseRevision, totalRows, mapWidth)
    local self = Event.new(CropStressMoistureControlEvent_mt)
    self.kind = kind or CropStressMoistureControlEvent.KIND_START
    self.snapshotGeneration = snapshotGeneration or 0
    self.baseRevision = baseRevision or 0
    self.totalRows = totalRows or 0
    self.mapWidth = mapWidth or 0
    return self
end

function CropStressMoistureControlEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, string.byte(self.kind))
    streamWriteInt32(streamId, self.snapshotGeneration)
    streamWriteInt32(streamId, self.baseRevision)
    streamWriteInt32(streamId, self.totalRows)
    streamWriteInt32(streamId, self.mapWidth)
end

function CropStressMoistureControlEvent:readStream(streamId, connection)
    self.kind = string.char(streamReadUInt8(streamId))
    self.snapshotGeneration = streamReadInt32(streamId)
    self.baseRevision = streamReadInt32(streamId)
    self.totalRows = streamReadInt32(streamId)
    self.mapWidth = streamReadInt32(streamId)
    self:run(connection)
end

function CropStressMoistureControlEvent:run(connection)
    if g_server ~= nil then return end   -- the server never stages its own map

    local mgr = g_cropStressManager
    local soilSystem = mgr and mgr.soilSystem
    local fine = soilSystem and soilSystem.fineSnapshot
    if fine == nil then return end

    if self.kind == CropStressMoistureControlEvent.KIND_START then
        fine:beginSnapshot(self.snapshotGeneration, self.totalRows, self.baseRevision, self.mapWidth)
    elseif self.kind == CropStressMoistureControlEvent.KIND_COMPLETE then
        fine:finishSnapshot(function(snapshot)
            soilSystem:_publishFineSnapshot(snapshot)
        end)
    elseif self.kind == CropStressMoistureControlEvent.KIND_RESNAPSHOT_REQUEST then
        fine:requestResnapshot()
        csLog("Moisture map: client requested a fresh full snapshot")
    end
end
