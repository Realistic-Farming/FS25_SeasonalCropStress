-- ============================================================
-- CropStressMoistureInitEvent.lua
-- Network event for syncing field moisture and stress data to
-- multiplayer clients.
--
-- Used in two ways:
--   1. Initial join: server sends full snapshot to the new client
--      inside CropStressManager:sendInitialClientState().
--   2. Hourly broadcast: server pushes updated snapshot to all
--      clients after each simulation tick in onHourlyTick().
--
-- Wire format (per field):
--   farmlandId : UInt16
--   moisture   : Float32  (0.0–1.0)
--   stress     : Float32  (0.0–1.0)
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

CropStressMoistureInitEvent = {}
CropStressMoistureInitEvent_mt = Class(CropStressMoistureInitEvent, Event)

InitEventClass(CropStressMoistureInitEvent, "CropStressMoistureInitEvent")

-- fieldData   : soilSystem.fieldData   (farmlandId -> {moisture=float, ...})
-- fieldStress : stressModifier.fieldStress (farmlandId -> float)
function CropStressMoistureInitEvent.new(fieldData, fieldStress)
    local self = Event.new(CropStressMoistureInitEvent_mt)
    self.fieldData   = fieldData   or {}
    self.fieldStress = fieldStress or {}
    return self
end

-- ── Serialisation ─────────────────────────────────────────

function CropStressMoistureInitEvent:writeStream(streamId, connection)
    -- Collect field IDs into a list so we know the count before writing
    local ids = {}
    for fid in pairs(self.fieldData) do
        table.insert(ids, fid)
    end

    streamWriteUInt16(streamId, #ids)
    for _, fid in ipairs(ids) do
        local entry  = self.fieldData[fid]
        local stress = self.fieldStress[fid] or 0.0
        streamWriteUInt16(streamId, fid)
        streamWriteFloat32(streamId, entry.moisture or 0.0)
        streamWriteFloat32(streamId, stress)
    end
end

function CropStressMoistureInitEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    self.fieldData   = {}
    self.fieldStress = {}
    for _ = 1, count do
        local fid      = streamReadUInt16(streamId)
        local moisture = streamReadFloat32(streamId)
        local stress   = streamReadFloat32(streamId)
        self.fieldData[fid]   = { moisture = moisture }
        self.fieldStress[fid] = stress
    end
    self:run(connection)
end

-- ── Execution (runs on the receiving side) ────────────────

function CropStressMoistureInitEvent:run(connection)
    -- Server never processes events it sent itself
    if g_server ~= nil then return end

    local mgr = g_cropStressManager
    if mgr == nil or mgr.soilSystem == nil or mgr.stressModifier == nil then
        csLog("MP: moisture sync received but manager not ready — ignored")
        return
    end

    local applied = 0
    for fid, entry in pairs(self.fieldData) do
        local existing = mgr.soilSystem.fieldData[fid]
        if existing ~= nil then
            -- Preserve soilType and other local data; update only simulation values
            existing.moisture = entry.moisture
        else
            -- Field not yet enumerated locally — create a minimal entry.
            -- soilType will be corrected when enumerateFields() runs.
            mgr.soilSystem.fieldData[fid] = { moisture = entry.moisture, soilType = "loamy" }
        end
        mgr.stressModifier.fieldStress[fid] = self.fieldStress[fid] or 0.0
        applied = applied + 1
    end

    -- Rebuild fieldById map so the PDA screen can look up field objects
    mgr:buildFieldMap()

    csLog(string.format("MP: moisture sync applied for %d fields", applied))
end
