-- ============================================================
-- SoilFineSnapshot.lua  (SCS-039 / GRID-1, SDS 3.7)
--
-- CLIENT SEMANTIC CURRENTNESS for the fine 2 m map. Rows, the aggregate FULL
-- witness and deltas land in TRANSIENT STAGING keyed by snapshot generation;
-- they NEVER write the live map directly. After the final row the engine
-- validates base aggregates, applies any contiguous buffered deltas, then
-- publishes the native map, aggregates and revision together exactly once.
--
-- This mirrors the bar's Group F contract and is engine-free so the bench can
-- drive the full state machine. Two connections never share one currentness
-- flag (each client creates its own instance).
--
-- A RESNAPSHOT_REQUEST is legal only for a named semantic mismatch (revision
-- chain, dimensions, grain, schema, carrier or snapshot generation, compact
-- witness disagreement, or a native application refusal). It discards staging
-- and asks for one fresh full snapshot; it never resumes the old tuple.
-- ============================================================

SoilFineSnapshot = SoilFineSnapshot or {}
SoilFineSnapshot.__index = SoilFineSnapshot

function SoilFineSnapshot.new()
    local self = setmetatable({}, SoilFineSnapshot)
    self:reset()
    return self
end

function SoilFineSnapshot:reset()
    self.current          = false       -- a complete snapshot is published
    self.currentRevision  = 0
    self.snapshotGeneration = nil
    self.baseRevision     = 0
    self.totalRows        = 0
    self.mapWidth         = 0
    self.grain            = nil
    self.schema           = nil
    self.rowCount         = 0
    self.rows             = {}          -- [index] -> raw packed row
    self.aggregates       = {}          -- fieldId -> aggregate witness
    self.deltas           = {}          -- ordered buffered deltas (pre-publish)
    self.pixelValues      = {}          -- published absolute pixel values
    self.resnapshot       = false
    self.publishCount     = 0
end

-- ---------------------------------------------------------
-- Control START: open a snapshot for one generation.
-- A new generation while a snapshot is open discards staging.
-- ---------------------------------------------------------
function SoilFineSnapshot:beginSnapshot(snapshotGeneration, totalRows, baseRevision, mapWidth)
    if self.snapshotGeneration ~= nil and self.snapshotGeneration ~= snapshotGeneration then
        self:reset()
    end
    self.snapshotGeneration = snapshotGeneration
    self.totalRows  = totalRows or 0
    self.baseRevision = baseRevision or 0
    self.mapWidth   = mapWidth or 0
    self.rowCount   = 0
    self.rows       = {}
    self.deltas     = {}
    return self.snapshotGeneration
end

-- ---------------------------------------------------------
-- A raw row arrives for the open snapshot. Reliable-ordered, so a row for a
-- generation that is not open (or already complete) is refused.
-- ---------------------------------------------------------
function SoilFineSnapshot:receiveRow(snapshotGeneration, rowIndex, packed)
    if self.snapshotGeneration ~= snapshotGeneration then return false end
    if self.current then return false end
    if self.rows[rowIndex] == nil then
        self.rows[rowIndex] = packed
        self.rowCount = self.rowCount + 1
    end
    return true
end

-- The aggregate FULL witness (the compact corroboration). Accepted only when
-- it names the open snapshot generation.
function SoilFineSnapshot:receiveAggregateWitness(snapshotGeneration, revision, aggregates)
    if self.snapshotGeneration ~= snapshotGeneration then
        self.resnapshot = true
        return false
    end
    if self.current then
        if revision < self.currentRevision then return true end
        self.resnapshot = true
        return false
    end
    self.aggregates = aggregates or {}
    self._witnessRevision = revision
    return true
end

-- An absolute delta. While not current it is buffered; once current it applies
-- immediately when contiguous (fromRevision == currentRevision) and requests a
-- fresh snapshot when a gap or a stale revision arrives.
function SoilFineSnapshot:receiveDelta(fromRevision, toRevision, pixelKey, value)
    if self.current and toRevision <= self.currentRevision then
        return true          -- duplicate / old delta ignored
    end
    if self.current then
        if fromRevision ~= self.currentRevision then
            self.resnapshot = true
            return false
        end
        self.pixelValues[pixelKey] = value
        self.currentRevision = toRevision
        return true
    end
    self.deltas[#self.deltas + 1] = {
        fromRevision = fromRevision,
        toRevision   = toRevision,
        pixelKey     = pixelKey,
        value        = value,
    }
    return true
end

-- ---------------------------------------------------------
-- COMPLETE barrier: publish exactly once when every row of the open snapshot
-- has arrived and any buffered deltas form one contiguous chain from the base
-- revision. Publish is a callback so the bench can capture it without an
-- engine; the live caller passes the value map and aggregate setter.
-- Returns true when the snapshot became current this call.
-- ---------------------------------------------------------
function SoilFineSnapshot:finishSnapshot(onPublish)
    if self.resnapshot then return false end
    if self.current then return true end
    if self.snapshotGeneration == nil then return false end
    if self.rowCount ~= self.totalRows then
        self.resnapshot = true
        return false
    end

    -- Sort buffered deltas into a contiguous chain from the base revision.
    table.sort(self.deltas, function(a, b) return a.fromRevision < b.fromRevision end)
    local revision = self.baseRevision
    for i = 1, #self.deltas do
        local d = self.deltas[i]
        if d.toRevision > revision then
            if d.fromRevision ~= revision then
                self.resnapshot = true
                return false
            end
            revision = d.toRevision
        end
    end
    self.pixelValues = {}
    for i = 1, #self.deltas do
        local d = self.deltas[i]
        self.pixelValues[d.pixelKey] = d.value
    end

    self.current = true
    self.currentRevision = revision
    self.publishCount = self.publishCount + 1
    self.deltas = {}
    if onPublish ~= nil then
        onPublish(self)
    end
    return true
end

-- A semantic mismatch requests one fresh full snapshot and discards staging.
function SoilFineSnapshot:requestResnapshot()
    self.resnapshot = true
    self:reset()
    self.resnapshot = true
end
