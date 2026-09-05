-- scs039_fine_snapshot_test.lua
-- SCS-039 / GRID-1 (SDS 3.7): client fine-snapshot semantic currentness and the
-- CONTROL / DELTA event wire round trips. Rows and deltas stage behind the
-- CONTROL barrier and publish once at COMPLETE; a missing row, revision gap or
-- mismatched generation requests one fresh snapshot. Two connections never
-- share one currentness flag.
--!load: src/SoilFineSnapshot.lua, src/events/CropStressMoistureControlEvent.lua, src/events/CropStressMoistureDeltaEvent.lua

local function newFine()
  return SoilFineSnapshot.new()
end

-- 1. COMPLETE ROWS + CONTIGUOUS DELTAS CROSS THE BARRIER AND PUBLISH ONCE.
do
  local f = newFine()
  f:beginSnapshot(1001, 2, 10, 8)
  f:receiveAggregateWitness(1001, 10, { aggregate = 0.25 })
  f:receiveDelta(10, 12, 44, 0.70)
  T.eq("fine.bufferedNotLive", f.current, false)
  f:receiveRow(1001, 0, { 2, 5, 2, 0 })
  T.eq("fine.partialStagingNotLive", f.current, false)
  f:receiveRow(1001, 1, { 2, 3, 2, 0 })
  T.eq("fine.completePublishes", f:finishSnapshot(), true)
  T.eq("fine.publishedCurrent", f.current, true)
  T.eq("fine.reachesDeltaRevision", f.currentRevision, 12)
  T.near("fine.deltaInstalled", f.pixelValues[44], 0.70, 1e-12)
  T.eq("fine.completeIdempotent", f:finishSnapshot(), true)
  T.eq("fine.publishOnce", f.publishCount, 1)
end

-- 2. LIVE DELTAS AFTER CURRENT: contiguous applies, duplicates ignored, gaps
--    request a fresh snapshot.
do
  local f = newFine()
  f:beginSnapshot(1001, 1, 20, 8)
  f:receiveRow(1001, 0, { 1, 0, 1, 5 })
  f:finishSnapshot()
  T.eq("live.contiguousApplies", f:receiveDelta(20, 21, 7, 0.75), true)
  T.near("live.updatesRevision", f.pixelValues[7], 0.75, 1e-12)
  T.eq("live.revisionAdvanced", f.currentRevision, 21)
  T.eq("live.duplicateIgnored", f:receiveDelta(20, 21, 7, 0.75), true)
  T.near("live.duplicateKeepsValue", f.pixelValues[7], 0.75, 1e-12)
  T.eq("live.gapRequestsResnapshot", f:receiveDelta(22, 23, 9, 0.5), false)
  T.eq("live.resnapshotSet", f.resnapshot, true)
end

-- 3. A MISSING ROW REFUSES COMPLETION AND REQUESTS ONE FRESH SNAPSHOT.
do
  local f = newFine()
  f:beginSnapshot(1001, 2, 30, 8)
  f:receiveRow(1001, 0, { 1, 0, 1, 5 })
  T.eq("missing.refuses", f:finishSnapshot(), false)
  T.eq("missing.resnapshot", f.resnapshot, true)
  f:requestResnapshot()
  T.eq("missing.clearedStaging", f.snapshotGeneration, nil)
  T.eq("missing.currentFalse", f.current, false)
end

-- 4. A ROW FOR A FOREIGN GENERATION IS REFUSED.
do
  local f = newFine()
  f:beginSnapshot(1001, 1, 40, 8)
  T.eq("foreign.rowRefused", f:receiveRow(9999, 0, { 1, 0, 1, 5 }), false)
  T.eq("foreign.openSnapshotKept", f.snapshotGeneration, 1001)
end

-- 5. TWO CONNECTIONS NEVER SHARE ONE CURRENTNESS FLAG.
do
  local a = newFine()
  local b = newFine()
  a:beginSnapshot(1001, 1, 50, 8)
  a:receiveRow(1001, 0, { 1, 0, 1, 5 })
  a:finishSnapshot()
  T.eq("two.aCurrent", a.current, true)
  T.eq("two.bIndependent", b.current, false)
  T.eq("two.bNoSnapshot", b.snapshotGeneration, nil)
end

-- 6. CONTROL EVENT ROUND TRIP (START carries generation/revision/rows/width).
do
  local s = _sfMockStream()
  local ev = CropStressMoistureControlEvent.new(CropStressMoistureControlEvent.KIND_START, 1001, 10, 2, 8)
  ev:writeStream(s)
  local got = CropStressMoistureControlEvent.emptyNew()
  got:readStream(s)
  T.eq("control.kind", got.kind, "S")
  T.eq("control.generation", got.snapshotGeneration, 1001)
  T.eq("control.baseRevision", got.baseRevision, 10)
  T.eq("control.totalRows", got.totalRows, 2)
  T.eq("control.mapWidth", got.mapWidth, 8)
  T.eq("control.streamClean", s.typeErrors + s.underflows, 0)
end

-- 7. DELTA EVENT ROUND TRIP.
do
  local s = _sfMockStream()
  local ev = CropStressMoistureDeltaEvent.new(1001, 12, 13, 3, 4097, 0.72)
  ev:writeStream(s)
  local got = CropStressMoistureDeltaEvent.emptyNew()
  got:readStream(s)
  T.eq("delta.generation", got.snapshotGeneration, 1001)
  T.eq("delta.fromRevision", got.fromRevision, 12)
  T.eq("delta.toRevision", got.toRevision, 13)
  T.eq("delta.fieldId", got.fieldId, 3)
  T.eq("delta.pixelKey", got.pixelKey, 4097)
  T.near("delta.value", got.value, 0.72, 1e-9)
  T.eq("delta.streamClean", s.typeErrors + s.underflows, 0)
end

T.summary()
