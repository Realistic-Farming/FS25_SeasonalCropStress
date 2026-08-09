-- ============================================================
-- CropStressMoistureRowEvent.lua  (SCS-039 / GRID-1)
--
-- Carries ONE ROW of the 2 m moisture value map from server to client.
--
-- WHY A ROW AND NOT A SNAPSHOT: at 2 m/px a 4096 m map is 2048x2048 pixels,
-- which is 4 MB of raw bytes. No single event carries that, and trying would
-- stall the join. The server walks the map a row at a time, frame-budgeted, and
-- the client fills in behind it.
--
-- Rows travel as RAW values, run-length packed. Raw means nothing is
-- re-quantised in flight, so a client's pixels end up bit-identical to the
-- server's rather than a rounding generation behind. Run-length matters because
-- a moisture map is overwhelmingly long runs: a field at a uniform level, and
-- the entire off-field remainder sitting at the raw-0 sentinel.
--
-- Wire format:
--   rowIndex : UInt16
--   runCount : UInt16
--   per run:  length UInt16, value UInt8
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

CropStressMoistureRowEvent = {}
CropStressMoistureRowEvent_mt = Class(CropStressMoistureRowEvent, Event)

InitEventClass(CropStressMoistureRowEvent, "CropStressMoistureRowEvent")

--- @param rowIndex number  map row (0-based)
--- @param packed table     run-length pairs from CropStressValueMap.packRow
function CropStressMoistureRowEvent.new(rowIndex, packed)
    local self = Event.new(CropStressMoistureRowEvent_mt)
    self.rowIndex = rowIndex or 0
    self.packed   = packed or {}
    return self
end

function CropStressMoistureRowEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, self.rowIndex)
    local runs = math.floor(#self.packed / 2)
    streamWriteUInt16(streamId, runs)
    for i = 1, runs do
        local length = self.packed[(i - 1) * 2 + 1] or 0
        local value  = self.packed[(i - 1) * 2 + 2] or 0
        streamWriteUInt16(streamId, math.max(0, math.min(65535, length)))
        streamWriteUInt8(streamId, math.max(0, math.min(255, value)))
    end
end

function CropStressMoistureRowEvent:readStream(streamId, connection)
    self.rowIndex = streamReadUInt16(streamId)
    local runs = streamReadUInt16(streamId)
    self.packed = {}
    for _ = 1, runs do
        local length = streamReadUInt16(streamId)
        local value  = streamReadUInt8(streamId)
        self.packed[#self.packed + 1] = length
        self.packed[#self.packed + 1] = value
    end
    self:run(connection)
end

function CropStressMoistureRowEvent:run(connection)
    -- The server is the authority and never applies a row it sent itself.
    if g_server ~= nil then return end

    local mgr = g_cropStressManager
    local soilSystem = mgr and mgr.soilSystem
    if soilSystem == nil or soilSystem.valueMap == nil then return end
    local vm = soilSystem.valueMap
    if not vm.available then return end

    local row = CropStressValueMap.unpackRow(self.packed, vm.resolution)
    vm:applySyncRow(self.rowIndex, row)
end
