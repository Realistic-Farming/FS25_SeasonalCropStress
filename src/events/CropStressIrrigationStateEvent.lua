-- ============================================================
-- CropStressIrrigationStateEvent.lua  (SCS-023 / F200, SDS 8)
--
-- One farm's COMPLETE private irrigation snapshot, farm-targeted. A pure client
-- applies it atomically (system rows + source rows together) and marks internal
-- `_clientFarmCurrent[farmId] = true`, which makes BOTH positive-farm getters
-- current together. Invalid/spectator/not-yet-current farms stay nil on the
-- client. The mirror is transient, never persisted, and is not another API or
-- authority.
--
-- Wire format (typed, deterministic):
--   farmId             : Int32
--   sourceCount        : Int32
--   per source: id, ownerFarmId, hasWater Bool, isUnlimited Bool,
--               waterCapacity Float32 (-1 when unlimited), waterRemaining Float32,
--               connectedCount Int32, then connected ids Int32 each
--   systemCount        : Int32
--   per system: id, type String, isActive Bool, ownerFarmId, waterSourceId,
--               stopReason String, flowRatePerHour Float32,
--               operationalCostPerHour Float32, coveredCount Int32, field ids Int32
-- ============================================================

CropStressIrrigationStateEvent = CropStressIrrigationStateEvent or {}
CropStressIrrigationStateEvent_mt = Class(CropStressIrrigationStateEvent, Event)

InitEventClass(CropStressIrrigationStateEvent, "CropStressIrrigationStateEvent")

function CropStressIrrigationStateEvent.emptyNew()
    return Event.new(CropStressIrrigationStateEvent_mt)
end

---@param farmId number
---@param systemRows table  copied private system rows (copyIrrigationSystemRow)
---@param sourceRows table  copied source rows (getIrrigationWaterSources(farmId))
function CropStressIrrigationStateEvent.new(farmId, systemRows, sourceRows)
    local self = Event.new(CropStressIrrigationStateEvent_mt)
    self.farmId = farmId or 0
    self.systemRows = systemRows or {}
    self.sourceRows = sourceRows or {}
    return self
end

function CropStressIrrigationStateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)

    local sources = self.sourceRows or {}
    streamWriteInt32(streamId, #sources)
    for i = 1, #sources do
        local s = sources[i]
        streamWriteInt32(streamId, s.id or 0)
        streamWriteInt32(streamId, s.ownerFarmId or 0)
        streamWriteBool(streamId, s.hasWater == true)
        streamWriteBool(streamId, s.isUnlimited == true)
        streamWriteFloat32(streamId, s.isUnlimited and -1 or (s.waterCapacity or 0))
        streamWriteFloat32(streamId, s.isUnlimited and 0 or (s.waterRemaining or 0))
        local connected = s.connectedSystemIds or {}
        streamWriteInt32(streamId, #connected)
        for j = 1, #connected do
            streamWriteInt32(streamId, connected[j] or 0)
        end
    end

    local systems = self.systemRows or {}
    streamWriteInt32(streamId, #systems)
    for i = 1, #systems do
        local r = systems[i]
        streamWriteInt32(streamId, r.id or 0)
        streamWriteString(streamId, tostring(r.type or ""))
        streamWriteBool(streamId, r.isActive == true)
        streamWriteInt32(streamId, r.ownerFarmId or 0)
        streamWriteInt32(streamId, r.waterSourceId or -1)
        streamWriteString(streamId, tostring(r.stopReason or ""))
        streamWriteFloat32(streamId, r.flowRatePerHour or 0)
        streamWriteFloat32(streamId, r.operationalCostPerHour or 0)
        local covered = r.coveredFields or {}
        streamWriteInt32(streamId, #covered)
        for j = 1, #covered do
            streamWriteInt32(streamId, covered[j] or 0)
        end
    end
end

function CropStressIrrigationStateEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)

    local sourceCount = streamReadInt32(streamId)
    self.sourceRows = {}
    for _ = 1, sourceCount do
        local id = streamReadInt32(streamId)
        local ownerFarmId = streamReadInt32(streamId)
        local hasWater = streamReadBool(streamId)
        local isUnlimited = streamReadBool(streamId)
        local waterCapacity = streamReadFloat32(streamId)
        local waterRemaining = streamReadFloat32(streamId)
        local connected = {}
        local n = streamReadInt32(streamId)
        for j = 1, n do connected[j] = streamReadInt32(streamId) end
        self.sourceRows[#self.sourceRows + 1] = {
            id = id,
            ownerFarmId = ownerFarmId,
            hasWater = hasWater,
            isUnlimited = isUnlimited,
            waterCapacity = isUnlimited and nil or waterCapacity,
            waterRemaining = isUnlimited and nil or waterRemaining,
            connectedSystemIds = connected,
        }
    end

    local systemCount = streamReadInt32(streamId)
    self.systemRows = {}
    for _ = 1, systemCount do
        local row = {
            id = streamReadInt32(streamId),
            type = streamReadString(streamId),
            isActive = streamReadBool(streamId),
            ownerFarmId = streamReadInt32(streamId),
            waterSourceId = streamReadInt32(streamId),
            stopReason = streamReadString(streamId),
            flowRatePerHour = streamReadFloat32(streamId),
            operationalCostPerHour = streamReadFloat32(streamId),
        }
        local covered = {}
        local n = streamReadInt32(streamId)
        for j = 1, n do covered[j] = streamReadInt32(streamId) end
        row.coveredFields = covered
        if row.waterSourceId < 0 then row.waterSourceId = nil end
        if row.stopReason == "" then row.stopReason = nil end
        self.systemRows[#self.systemRows + 1] = row
    end
    self:run(connection)
end

function CropStressIrrigationStateEvent:run(connection)
    if g_server ~= nil then return end   -- the server owns the live getters
    local mgr = g_cropStressManager
    if mgr == nil or mgr.irrigationManager == nil then return end
    local irr = mgr.irrigationManager
    if irr.applyFarmPrivateSnapshot ~= nil then
        irr:applyFarmPrivateSnapshot(self.farmId, self.systemRows, self.sourceRows)
    end
end
