-- SCS-039 One Ground provider-conformance bar v10.
--
-- GROUP A loads the real current SCS provider and proves the correction is not
-- built at source tip 55da7b8f87de2d9e6d77751e548be2833e9a95aa. When the
-- implementation lands, Group A is expected to go red and instruct Stage 6A to
-- re-point the bar at the shipped surfaces.
--
-- GROUPS B through P model the pure contract fixed by SCS-039-SDS.md v2.1.
-- They cannot prove engine bit-vector behavior, save-file atomicity, rendering,
-- multiplayer delivery, frame time, memory, or runtime event ordering.
--
-- All decimal values, field IDs, pixel keys, row counts and work budgets below
-- are synthetic branch-distinguishing probes, not production constants. The
-- governing invariants are cited to the SDS beside each group.
--!load: src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua

local function currentStubMap(grain)
    local m = {
        available = true,
        grain = grain,
        painted = {},
        deleted = 0,
    }
    function m:getGrainMetres() return self.grain end
    function m:paintPolygon(_vx, _vz, _n, value)
        self.painted[#self.painted + 1] = value
        return true
    end
    function m:readValueAtWorld(_x, _z)
        -- SCS-039 v2.1 typed contract: a resolvable pixel with nothing written
        -- is EMPTY (benign), never a provider refusal.
        return nil, self.grain, "EMPTY"
    end
    function m:worldToPixel(_x, _z) return 1, 1 end
    function m:writeValueAtWorld(_x, _z, _value, _radius) return true, "OK" end
    function m:delete()
        self.deleted = self.deleted + 1
        self.available = false
    end
    return m
end

local function currentSystem()
    local sys = SoilMoistureSystem.new({})
    sys.isInitialized = true
    sys.fieldData[1] = {
        fieldId = 1,
        moisture = 0.60,
        soilType = "loamy",
        cells = {},
        cellSum = 0,
        cellCount = 0,
        reliefScan = true,
    }
    sys._fieldVerts[1] = {
        vx = {0, 100, 100, 0},
        vz = {0, 0, 100, 100},
        n = 4,
    }
    sys._mapSeeded[1] = true
    return sys
end

-- GROUP A: PROVIDER CONFORMANCE TRIPWIRE (re-pointed as slices land).
-- Slices 1-7 (Fred): every Group A assertion A1-A16 is now re-pointed from
-- absence to PRESENCE against the built SCS-039 surfaces. Slice 4 lands the
-- polygon-aggregate fail-closed path (A12); slice 6 the point-read fail-closed
-- path (A15); slice 7 the region-write fail-closed path (A16). No Group A
-- tripwire remains on absence. (The member is not complete: SDS 3.5-3.9 live
-- wiring, atomic save generations, daily plan + Time Guard subscribeTick,
-- snapshot/delta events, NetworkSync compat and the overlay gate, are still
-- later slices, modelled by the pure-contract Groups B-P.)
-- Source coordinates: SoilMoistureSystem.lua:69, 178-190, 680-712, 748-768,
-- 893-943, 1038-1064, 1364-1366. Design corrections: SDS 3.2-3.11.
do
    local sys = currentSystem()
    T.eq("A1 BUILT: provider persists a moistureRevision starting at 1", sys.moistureRevision, 1)

    sys.valueMap = currentStubMap(2)
    sys._mapWaterPending[1] = { [4097] = 0.001 }
    T.eq("A2 current whole-field replacement is accepted", sys:setMoisture(1, 0.80), true)
    T.eq("A3 BUILT: whole-field replacement clears the positional pending store",
        sys._mapWaterPending[1], nil)

    local readSys = currentSystem()
    readSys.valueMap = currentStubMap(2)
    local v, grain = readSys:getMoisture(1, 10, 10)
    T.near("A4 current unwritten map point falls back to aggregate", v, 0.60, 1e-12)
    T.eq("A5 BUILT: unwritten map pixel falls back to aggregate at nil grain", grain, nil)

    local aggregateSys = currentSystem()
    aggregateSys.valueMap = currentStubMap(2)
    aggregateSys.fieldData[1].moisture = 0.80
    aggregateSys.fieldData[1].cells = { [0] = { [0] = { moisture = 0.20 } } }
    aggregateSys.fieldData[1].cellSum = 0.20
    aggregateSys.fieldData[1].cellCount = 1
    T.near("A6 BUILT: active-map field read uses the native aggregate, not retained cells",
        aggregateSys:getMoisture(1), 0.80, 1e-12)

    local deleteSys = currentSystem()
    deleteSys.valueMap = currentStubMap(2)
    deleteSys:delete()
    T.eq("A7 BUILT: teardown releases the native map", deleteSys.valueMap.deleted, 1)

    local capSys = currentSystem()
    capSys.fieldData[1].cellCount = SoilMoistureSystem.CELL_BACKSTOP_CAP
    capSys.fieldData[1].cellSum = SoilMoistureSystem.CELL_BACKSTOP_CAP * 0.60
    local a8accepted = capSys:applyWaterAtCell(1, 10, 10, 0.10)
    T.eq("A8 BUILT: ZONE water beyond the cap is accepted, not discarded", a8accepted, true)
    T.eq("A8b the cap still limits cell materialisation",
        capSys.fieldData[1].cellCount, SoilMoistureSystem.CELL_BACKSTOP_CAP)
    T.near("A8c over-cap ZONE water is preserved as field pending",
        capSys.fieldData[1].mapPending, 0.10, 1e-12)
    T.eq("A9 BUILT: currentness getter exists and is false without a current TRUTH map",
        capSys:isMoistureMapCurrent(), false)
    T.eq("A10 current source exposes the 400-operation technical precedent",
        SoilMoistureSystem.MAP_DRAIN_MAX_BLOCKS, 400)

    -- SCS-039 slice 1 re-point: saveToSavegame now requires the engine's inner
    -- true, so a non-throwing false native return is reported as a failed save
    -- rather than silently mistaken for a written file.
    local originalNativeSave = saveBitVectorMapToFile
    saveBitVectorMapToFile = function() return false end
    local nativeSaveMap = setmetatable({ available = true, bvm = 1 }, { __index = CropStressValueMap })
    T.eq("A11 BUILT: native save reports the engine's false result rather than faking success",
        nativeSaveMap:saveToSavegame("synthetic-save-root"), false)
    saveBitVectorMapToFile = originalNativeSave

    -- SCS-039 slice 4 re-point: after TRUTH is the current authority, a native
    -- polygon-aggregate refusal on the daily settle fails the provider CLOSED
    -- (SDS 3.3) instead of silently retaining the prior field scalar as current.
    local meanSys = currentSystem()
    meanSys.valueMap = currentStubMap(2)
    meanSys.providerMode = "TRUTH"
    meanSys._drainFieldOnMap = function() return false end
    meanSys.valueMap.readAverageOfPolygon = function() return "PROVIDER_REFUSAL", nil, nil end
    meanSys.fieldData[1].moisture = 0.61
    local a12revBefore = meanSys.moistureRevision
    meanSys:settleDaily(1)
    T.eq("A12 BUILT: a native polygon-read refusal after TRUTH fails the provider closed",
        meanSys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("A12b BUILT: the failed-closed provider is no longer current",
        meanSys:isMoistureMapCurrent(), false)
    T.eq("A12c BUILT: failing closed holds the readable revision",
        meanSys.moistureRevision, a12revBefore)

    -- SCS-039 slice 6 re-point: a genuine native POINT-READ refusal at the
    -- public positional getMoisture read fails the provider closed (SDS 3.3)
    -- instead of silently serving the retained field scalar as if the pixel
    -- were merely unwritten. The typed readValueAtWorld outcome is what makes a
    -- refusal distinct from a benign EMPTY/OUT_OF_RANGE pixel (A4/A5).
    local pointSys = currentSystem()
    pointSys.valueMap = currentStubMap(2)
    pointSys.providerMode = "TRUTH"
    pointSys.valueMap.readValueAtWorld = function() return nil, nil, "PROVIDER_REFUSAL" end
    local a15revBefore = pointSys.moistureRevision
    pointSys:getMoisture(1, 10, 10)
    T.eq("A15 BUILT: a native point-read refusal after TRUTH fails the provider closed",
        pointSys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("A15b BUILT: the point-read failed-closed provider is no longer current",
        pointSys:isMoistureMapCurrent(), false)
    T.eq("A15c BUILT: point-read fail-closed holds the readable revision",
        pointSys.moistureRevision, a15revBefore)

    local acceptedSys = currentSystem()
    acceptedSys.valueMap = currentStubMap(2)
    T.eq("A13 BUILT: map-path acceptance returns a literal accept receipt",
        acceptedSys:applyWaterAtCell(1, 10, 10, 0.001), true)

    local unresolvedSys = currentSystem()
    unresolvedSys.valueMap = currentStubMap(2)
    unresolvedSys.valueMap.worldToPixel = function() return nil, nil end
    local a14revBefore = unresolvedSys.moistureRevision
    local a14accepted = unresolvedSys:applyWaterAtCell(1, 10, 10, 0.01)
    T.eq("A14 BUILT: an unresolved native pixel accepts water instead of dropping it",
        a14accepted, true)
    local a14leaf = unresolvedSys._mapWaterPending[1] and unresolvedSys._mapWaterPending[1]["WORLD:10,10"]
    T.eq("A14b BUILT: accepted water is held as an UNRESOLVED positional leaf",
        a14leaf ~= nil and a14leaf.status or nil, "UNRESOLVED")
    T.near("A14c BUILT: the unresolved leaf preserves the full accepted gain",
        a14leaf and a14leaf.amount or -1, 0.01, 1e-12)
    T.eq("A14d BUILT: the unresolved leaf records the source grain",
        a14leaf and a14leaf.sourceWidth or nil, 2)
    T.eq("A14e BUILT: unresolved pending-only water mints no readable revision",
        unresolvedSys.moistureRevision, a14revBefore)

    -- SCS-039 slice 7 re-point: a genuine native REGION-WRITE refusal at the
    -- positional spend (applyWaterAtCell destination write, SDS 3.3/3.4) fails
    -- the provider closed AND conserves the full pre-spend accepted amount.
    -- Pending is debited and the readable revision advances only after the
    -- destination read and write both succeed exactly (Group O O10/O11).
    local writeSys = currentSystem()
    writeSys.valueMap = currentStubMap(2)
    writeSys.providerMode = "TRUTH"
    writeSys.valueMap.writeValueAtWorld = function() return false, "PROVIDER_REFUSAL" end
    local a16revBefore = writeSys.moistureRevision
    local a16accepted = writeSys:applyWaterAtCell(1, 10, 10, 0.02)
    T.eq("A16 BUILT: a native region-write refusal fails the provider closed",
        writeSys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("A16b BUILT: the write failed-closed provider is no longer current",
        writeSys:isMoistureMapCurrent(), false)
    T.eq("A16c BUILT: write-refusal fail-closed holds the readable revision",
        writeSys.moistureRevision, a16revBefore)
    T.eq("A16d BUILT: water whose destination write refused is still accepted",
        a16accepted, true)
    T.near("A16e BUILT: the refused spend conserves the full pre-spend amount",
        writeSys._mapWaterPending[1][4097], 0.02, 1e-12)
end

local Ref = {}

function Ref.new(revision)
    return {
        revision = revision,
        mapPending = {},
        pixelPending = {},
        deltas = {},
        values = {},
    }
end

function Ref.pendingOnly(state, fieldId, amount)
    state.mapPending[fieldId] = (state.mapPending[fieldId] or 0) + amount
    return state.revision
end

function Ref.readableWrite(state, key, value)
    state.values[key] = value
    state.revision = state.revision + 1
    return state.revision
end

function Ref.adoptServerRevision(state, revision)
    state.revision = revision
    return state.revision
end

function Ref.read(kind, localValue, aggregateValue, grain, revision)
    if kind == "outside" or kind == "unavailable" then
        return nil, nil, revision
    elseif kind == "local" then
        return localValue, grain, revision
    end
    return aggregateValue, nil, revision
end

-- GROUP B: ADDITIVE READ AND REVISION CONTRACT.
-- SDS v2.1 sections 3.2 and 3.3.
do
    local state = Ref.new(7)
    T.eq("B1 pending-only input keeps readable revision", Ref.pendingOnly(state, 1, 0.001), 7)
    T.eq("B2 readable mutation advances once", Ref.readableWrite(state, 101, 0.42), 8)
    T.eq("B3 client receipt adopts and does not mint", Ref.adoptServerRevision(state, 23), 23)

    local v, grain, revision = Ref.read("local", 0.42, 0.60, 2, 23)
    T.near("B4 local read keeps value", v, 0.42, 1e-12)
    T.eq("B5 local read keeps positive carrier grain", grain, 2)
    T.eq("B6 local read carries provider revision", revision, 23)

    v, grain, revision = Ref.read("aggregate", nil, 0.60, 2, 23)
    T.near("B7 aggregate read keeps value", v, 0.60, 1e-12)
    T.eq("B8 aggregate read carries no false local grain", grain, nil)
    T.eq("B9 aggregate read carries provider revision", revision, 23)

    v, grain, revision = Ref.read("outside", 0.42, 0.60, 2, 23)
    T.eq("B10 outside read is unavailable value", v, nil)
    T.eq("B11 outside read is unavailable grain", grain, nil)
    T.eq("B12 unavailable read may still identify current provider revision", revision, 23)
end

local function clearForReplacement(state, fieldId, replacement)
    state.mapPending[fieldId] = nil
    state.pixelPending[fieldId] = nil
    state.deltas[fieldId] = nil
    state.values[fieldId] = replacement
    state.revision = state.revision + 1
end

local function packPixelPending(pixelPending)
    local rows = {}
    for fieldId, pixels in pairs(pixelPending) do
        for pixelKey, amount in pairs(pixels) do
            if amount ~= 0 then
                rows[#rows + 1] = { fieldId = fieldId, pixelKey = pixelKey, amount = amount }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.fieldId ~= b.fieldId then return a.fieldId < b.fieldId end
        return a.pixelKey < b.pixelKey
    end)
    return rows
end

local function unpackPixelPending(rows)
    local out = {}
    for _, row in ipairs(rows) do
        out[row.fieldId] = out[row.fieldId] or {}
        out[row.fieldId][row.pixelKey] = row.amount
    end
    return out
end

local function pendingTotal(pixelPending)
    local total = 0
    for _, pixels in pairs(pixelPending) do
        for _, amount in pairs(pixels) do total = total + amount end
    end
    return total
end

-- GROUP C: BOTH PENDING STORES SURVIVE OR CLEAR TOGETHER.
-- SDS v2.1 sections 3.5 and 3.6.
do
    local state = Ref.new(40)
    state.mapPending[3] = 0.002
    state.pixelPending[3] = { [9] = 0.001, [2] = 0.003 }
    state.deltas[3] = { old = 0.40 }
    clearForReplacement(state, 3, 0.75)
    T.eq("C1 replacement clears field-wide pending", state.mapPending[3], nil)
    T.eq("C2 replacement clears positional pending", state.pixelPending[3], nil)
    T.eq("C3 replacement publishes one revision", state.revision, 41)
    T.eq("C3b replacement supersedes queued older field deltas", state.deltas[3], nil)

    local source = {
        [2] = { [11] = 0.00125, [4] = 0.00250 },
        [1] = { [8] = -0.00075 },
    }
    local packed = packPixelPending(source)
    T.eq("C4 sparse packing keeps every non-zero entry", #packed, 3)
    T.eq("C5 sparse packing is deterministic by field", packed[1].fieldId, 1)
    T.eq("C6 sparse packing is deterministic by pixel", packed[2].pixelKey, 4)
    local restored = unpackPixelPending(packed)
    T.near("C7 sparse round trip conserves exact pending total",
        pendingTotal(restored), pendingTotal(source), 1e-12)

    local wide = { [1] = {} }
    for i = 1, 1025 do wide[1][i] = i / 10000000 end
    T.eq("C8 sparse persistence has no hidden 1024-entry ceiling",
        #packPixelPending(wide), 1025)
end

local function newSaveState(generation)
    return {
        current = {
            generation = generation, digest = "g" .. generation, nativeOk = true,
            revision = 40, lastSettledMonotonicDay = 20,
        },
        previous = {
            generation = generation - 1, digest = "g" .. (generation - 1), nativeOk = true,
            revision = 39, lastSettledMonotonicDay = 19,
        },
    }
end

local function commitGeneration(state, mapWriteOk, metadataWriteOk)
    if not mapWriteOk or not metadataWriteOk then
        return state.current.generation, state.previous.generation
    end
    state.previous = state.current
    state.current = {
        generation = state.previous.generation + 1,
        digest = "g" .. (state.previous.generation + 1),
        nativeOk = true,
        revision = state.previous.revision,
        lastSettledMonotonicDay = state.previous.lastSettledMonotonicDay,
    }
    return state.current.generation, state.previous.generation
end

local function selectGeneration(candidates)
    local byGeneration = {}
    for _, c in ipairs(candidates) do
        if c.payloadKind ~= "PENDING_ONLY" and c.compactOk and type(c.generation) == "number" then
            local g = byGeneration[c.generation] or { digests = {}, rows = {} }
            g.digests[c.digest] = true
            g.rows[#g.rows + 1] = c
            byGeneration[c.generation] = g
        end
    end
    local generations = {}
    for generation in pairs(byGeneration) do generations[#generations + 1] = generation end
    table.sort(generations, function(a, b) return a > b end)
    for _, generation in ipairs(generations) do
        local g = byGeneration[generation]
        local digestCount = 0
        for _ in pairs(g.digests) do digestCount = digestCount + 1 end
        if digestCount == 1 then
            local row = g.rows[1]
            if row.nativeOk then
                return "TRUTH", generation, row.digest,
                    row.lastSettledMonotonicDay, row.revision
            end
            return "ZONE", generation, row.digest,
                row.lastSettledMonotonicDay, row.revision
        end
    end
    return "NONE", nil, nil, nil, nil
end

local function selectPendingOnly(candidates, baseGeneration, baseRevision, baseCursor)
    local digests, rows = {}, {}
    for _, c in ipairs(candidates) do
        if c.payloadKind == "PENDING_ONLY" and c.compactOk
            and c.baseGeneration == baseGeneration then
            digests[c.digest] = true
            rows[#rows + 1] = c
        end
    end
    local digestCount = 0
    for _ in pairs(digests) do digestCount = digestCount + 1 end
    if digestCount == 0 then return nil, "NONE" end
    if digestCount > 1 then return nil, "CONFLICT" end
    local row = rows[1]
    if baseRevision ~= nil and row.baseRevision ~= baseRevision then
        return nil, "BASE_MISMATCH"
    end
    if baseCursor ~= nil and row.baseLastSettledMonotonicDay ~= baseCursor then
        return nil, "BASE_MISMATCH"
    end
    return row, "APPLIED"
end

local function selectPersistence(candidates)
    local mode, generation, digest, cursor, revision = selectGeneration(candidates)
    if mode ~= "NONE" then
        local pending, pendingStatus = selectPendingOnly(candidates, generation, revision, cursor)
        return mode, generation, digest, pending ~= nil and pending.digest or nil,
            pendingStatus, cursor, revision
    end

    local bases = {}
    for _, c in ipairs(candidates) do
        if c.payloadKind == "PENDING_ONLY" and c.compactOk and c.zoneOk
            and type(c.baseGeneration) == "number" then
            bases[c.baseGeneration] = true
        end
    end
    local ordered = {}
    for base in pairs(bases) do ordered[#ordered + 1] = base end
    table.sort(ordered, function(a, b) return a > b end)
    for _, base in ipairs(ordered) do
        local pending, pendingStatus = selectPendingOnly(candidates, base, nil, nil)
        if pending ~= nil and pending.zoneOk then
            return "ZONE", base, nil, pending.digest, pendingStatus,
                pending.baseLastSettledMonotonicDay, pending.baseRevision
        end
    end
    return "NONE", nil, nil, nil, "NONE", nil, nil
end

-- GROUP D: TWO COMPLETE SAVE GENERATIONS AND MIRROR RECONCILIATION.
-- SDS 3.7 and 5.6 after the R1 structural fold.
do
    local state = newSaveState(5)
    local current, previous = commitGeneration(state, false, false)
    T.eq("D1 failed native write keeps current pair", current, 5)
    T.eq("D2 failed native write keeps previous pair", previous, 4)

    current, previous = commitGeneration(state, true, false)
    T.eq("D3 failed compact write keeps current pair", current, 5)
    T.eq("D4 failed compact write keeps previous pair", previous, 4)

    current, previous = commitGeneration(state, true, true)
    T.eq("D5 complete pair advances current generation", current, 6)
    T.eq("D6 complete pair retains prior generation", previous, 5)

    local mode, generation, digest = selectGeneration({
        { generation = 6, digest = "six", compactOk = true, nativeOk = false },
        { generation = 5, digest = "five", compactOk = true, nativeOk = true },
    })
    T.eq("D7 newest valid compact without map degrades on its own", mode, "ZONE")
    T.eq("D8 ZONE degrade keeps newest compact generation", generation, 6)
    T.eq("D9 ZONE degrade keeps its own compact payload", digest, "six")

    mode, generation = selectGeneration({
        { generation = 6, digest = "sixA", compactOk = true, nativeOk = true },
        { generation = 6, digest = "sixB", compactOk = true, nativeOk = true },
        { generation = 5, digest = "five", compactOk = true, nativeOk = true },
    })
    T.eq("D10 conflicting mirrors at one generation are rejected", mode, "TRUTH")
    T.eq("D11 conflict falls to the next complete pair", generation, 5)

    mode, generation = selectGeneration({
        { generation = 6, digest = "six", compactOk = true, nativeOk = true },
        { generation = 6, digest = "six", compactOk = true, nativeOk = true },
    })
    T.eq("D12 identical mirror candidates deduplicate", mode, "TRUTH")
    T.eq("D13 identical mirrors retain their generation", generation, 6)

    local pendingDigest, pendingStatus
    mode, generation, digest, pendingDigest, pendingStatus = selectPersistence({
        { payloadKind = "COMPLETE", generation = 6, digest = "six", compactOk = true, nativeOk = true },
        { payloadKind = "PENDING_ONLY", baseGeneration = 6, digest = "p6", compactOk = true, zoneOk = true },
        { payloadKind = "PENDING_ONLY", baseGeneration = 6, digest = "p6", compactOk = true, zoneOk = true },
    })
    T.eq("D14 complete pair remains the selected fine authority", mode, "TRUTH")
    T.eq("D15 pending-only overlay binds to the selected base generation", generation, 6)
    T.eq("D16 identical pending-only mirrors deduplicate", pendingDigest, "p6")
    T.eq("D17 matching pending-only overlay is applied", pendingStatus, "APPLIED")

    mode, generation, digest, pendingDigest, pendingStatus = selectPersistence({
        { payloadKind = "COMPLETE", generation = 6, digest = "six", compactOk = true, nativeOk = true },
        { payloadKind = "PENDING_ONLY", baseGeneration = 6, digest = "p6a", compactOk = true, zoneOk = true },
        { payloadKind = "PENDING_ONLY", baseGeneration = 6, digest = "p6b", compactOk = true, zoneOk = true },
    })
    T.eq("D18 conflicting pending-only mirrors do not displace fine truth", mode, "TRUTH")
    T.eq("D19 conflicting pending-only mirrors are not applied", pendingDigest, nil)
    T.eq("D20 pending-only mirror conflict is explicit", pendingStatus, "CONFLICT")

    mode, generation, digest, pendingDigest, pendingStatus = selectPersistence({
        { payloadKind = "COMPLETE", generation = 6, digest = "six", compactOk = true, nativeOk = true },
        { payloadKind = "PENDING_ONLY", baseGeneration = 5, digest = "p5", compactOk = true, zoneOk = true },
    })
    T.eq("D21 mismatched pending-only base is not overlaid", pendingDigest, nil)
    T.eq("D22 mismatched pending-only base leaves selected generation unchanged", generation, 6)

    mode, generation, digest, pendingDigest, pendingStatus = selectPersistence({
        { payloadKind = "PENDING_ONLY", baseGeneration = 7, digest = "p7", compactOk = true, zoneOk = true },
    })
    T.eq("D23 pending-only recovery may supply only its explicit ZONE state", mode, "ZONE")
    T.eq("D24 ZONE recovery retains its recorded base generation", generation, 7)
    T.eq("D25 ZONE recovery retains its own pending payload", pendingDigest, "p7")

    local selectedCursor, selectedRevision
    mode, generation, digest, pendingDigest, pendingStatus, selectedCursor, selectedRevision =
        selectPersistence({
            {
                payloadKind = "COMPLETE", generation = 6, digest = "six-cursor",
                compactOk = true, nativeOk = true, revision = 60,
                lastSettledMonotonicDay = 20,
            },
            {
                payloadKind = "PENDING_ONLY", baseGeneration = 6, digest = "p6-cursor",
                compactOk = true, zoneOk = true, baseRevision = 60,
                baseLastSettledMonotonicDay = 20,
            },
        })
    T.eq("D26 matching pending overlay preserves selected carrier cursor", selectedCursor, 20)
    T.eq("D27 matching pending overlay preserves selected carrier revision", selectedRevision, 60)
    T.eq("D28 matching carrier coordinates permit pending overlay", pendingStatus, "APPLIED")

    mode, generation, digest, pendingDigest, pendingStatus, selectedCursor =
        selectPersistence({
            {
                payloadKind = "COMPLETE", generation = 6, digest = "six-cursor",
                compactOk = true, nativeOk = true, revision = 60,
                lastSettledMonotonicDay = 20,
            },
            {
                payloadKind = "PENDING_ONLY", baseGeneration = 6, digest = "p6-wrong-cursor",
                compactOk = true, zoneOk = true, baseRevision = 60,
                baseLastSettledMonotonicDay = 21,
            },
        })
    T.eq("D29 matching generation with wrong base cursor is not overlaid", pendingDigest, nil)
    T.eq("D30 wrong base cursor is an explicit mismatch", pendingStatus, "BASE_MISMATCH")
    T.eq("D31 wrong pending cursor cannot replace selected carrier cursor", selectedCursor, 20)

    mode, generation, digest, selectedCursor = selectGeneration({
        { generation = 6, digest = "sixA", compactOk = true, nativeOk = true,
            revision = 60, lastSettledMonotonicDay = 20 },
        { generation = 6, digest = "sixB", compactOk = true, nativeOk = true,
            revision = 60, lastSettledMonotonicDay = 20 },
        { generation = 5, digest = "five", compactOk = true, nativeOk = true,
            revision = 50, lastSettledMonotonicDay = 17 },
    })
    T.eq("D32 complete-pair fallback restores previous carrier", generation, 5)
    T.eq("D33 complete-pair fallback restores previous carrier cursor", selectedCursor, 17)

    mode, generation, digest, pendingDigest, pendingStatus, selectedCursor = selectPersistence({
        {
            payloadKind = "PENDING_ONLY", baseGeneration = 7, digest = "p7-zone-cursor",
            compactOk = true, zoneOk = true, baseRevision = 70,
            baseLastSettledMonotonicDay = 14,
        },
    })
    T.eq("D34 pending-only ZONE recovery uses its own copied cursor", selectedCursor, 14)
end

local function newRestoreBarrier()
    return { compact = false, fields = false, map = false, applyCount = 0 }
end

local function tryRestore(barrier)
    if barrier.compact and barrier.fields and barrier.map and barrier.applyCount == 0 then
        barrier.applyCount = 1
        return true
    end
    return false
end

-- GROUP E: POST-ENUMERATION RESTORE IS ORDER-INDEPENDENT AND EXACTLY ONCE.
-- SDS v2.1 section 3.8.
do
    local a = newRestoreBarrier()
    a.compact = true; T.eq("E1 compact alone does not restore", tryRestore(a), false)
    a.fields = true;  T.eq("E2 fields without map decision do not restore", tryRestore(a), false)
    a.map = true;     T.eq("E3 third prerequisite restores", tryRestore(a), true)
    T.eq("E4 restore applies once", a.applyCount, 1)
    T.eq("E5 repeated callback is idempotent", tryRestore(a), false)
    T.eq("E6 repeated callback keeps one application", a.applyCount, 1)

    local b = newRestoreBarrier()
    b.map = true; b.fields = true; b.compact = true
    T.eq("E7 alternate prerequisite order still restores", tryRestore(b), true)
    T.eq("E8 alternate order still applies once", b.applyCount, 1)
end

local function newSnapshot(totalRows, baseRevision, snapshotGeneration, carrierGeneration, aggregateKeys)
    return {
        totalRows = totalRows,
        baseRevision = baseRevision,
        snapshotGeneration = snapshotGeneration or (baseRevision + 1000),
        carrierGeneration = carrierGeneration or 1,
        aggregateKeys = aggregateKeys,
    }
end

local function newConnection(snapshot)
    return {
        snapshot = snapshot,
        rows = {},
        rowCount = 0,
        staging = {},
        live = {},
        deltas = {},
        compactFull = nil,
        current = false,
        currentRevision = snapshot.baseRevision,
        resnapshot = false,
        completeCount = 0,
    }
end

local SNAPSHOT_ROWS_PER_FRAME = 8
local REDISTRIBUTION_OPS_PER_FRAME = 400

local function receiveRow(connection, rowIndex, values)
    if connection.rows[rowIndex] == nil then
        connection.rows[rowIndex] = true
        connection.rowCount = connection.rowCount + 1
        for key, value in pairs(values or {}) do connection.staging[key] = value end
    end
end

local function applyValues(target, values)
    for key, value in pairs(values or {}) do target[key] = value end
end

local function valuesAgree(target, values)
    for key, value in pairs(values or {}) do
        if target[key] == nil or math.abs(target[key] - value) > 1e-12 then return false end
    end
    return true
end

local function deriveBaseAggregate(snapshot, staging)
    if type(snapshot.aggregateKeys) ~= "table" then return nil end
    local total, count = 0, 0
    for _, key in ipairs(snapshot.aggregateKeys) do
        local value = staging[key]
        if type(value) == "number" then
            total = total + value
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return total / count
end

local function receiveCompactFull(connection, generation, revision, values)
    if generation ~= connection.snapshot.snapshotGeneration then
        connection.resnapshot = true
        return false
    end
    if connection.current then
        if revision < connection.currentRevision then return true end
        if revision > connection.currentRevision then
            connection.resnapshot = true
            return false
        end
        if not valuesAgree(connection.live, values) then
            connection.resnapshot = true
            return false
        end
        return true
    end
    connection.compactFull = { generation = generation, revision = revision, values = values }
    return true
end

local function receiveDelta(connection, fromRevision, toRevision, values)
    if connection.current and toRevision <= connection.currentRevision then
        return true
    end
    if connection.current then
        if fromRevision ~= connection.currentRevision then
            connection.resnapshot = true
            return false
        end
        applyValues(connection.live, values)
        connection.currentRevision = toRevision
        return true
    end
    connection.deltas[#connection.deltas + 1] = {
        fromRevision = fromRevision,
        toRevision = toRevision,
        values = values,
    }
    return true
end

local function finishSnapshot(connection)
    if connection.resnapshot then return false end
    if connection.current then return true end
    local snapshot = connection.snapshot
    if connection.rowCount ~= snapshot.totalRows then
        connection.resnapshot = true
        return false
    end
    if connection.compactFull ~= nil
        and connection.compactFull.generation ~= snapshot.snapshotGeneration then
        connection.resnapshot = true
        return false
    end
    local compact = connection.compactFull
    local compactApplied = false
    local baseAggregate = deriveBaseAggregate(snapshot, connection.staging)
    if baseAggregate ~= nil then connection.staging.aggregate = baseAggregate end
    if compact ~= nil and compact.revision < snapshot.baseRevision then
        compactApplied = true
    elseif compact ~= nil and compact.revision == snapshot.baseRevision then
        if not valuesAgree(connection.staging, compact.values) then
            connection.resnapshot = true
            return false
        end
        compactApplied = true
    end
    table.sort(connection.deltas, function(a, b) return a.fromRevision < b.fromRevision end)
    local revision = snapshot.baseRevision
    for _, delta in ipairs(connection.deltas) do
        if delta.toRevision > revision then
            if delta.fromRevision ~= revision then
                connection.resnapshot = true
                return false
            end
            applyValues(connection.staging, delta.values)
            revision = delta.toRevision
            if compact ~= nil and not compactApplied then
                if compact.revision == revision then
                    if not valuesAgree(connection.staging, compact.values) then
                        connection.resnapshot = true
                        return false
                    end
                    compactApplied = true
                elseif compact.revision < revision then
                    connection.resnapshot = true
                    return false
                end
            end
        end
    end
    if compact ~= nil and not compactApplied then
        connection.resnapshot = true
        return false
    end
    connection.live = connection.staging
    connection.staging = {}
    connection.deltas = {}
    connection.compactFull = nil
    connection.currentRevision = revision
    connection.current = true
    connection.completeCount = 1
    return true
end

local function restartFromFreshSnapshot(connection, snapshot)
    if connection.resnapshot ~= true then return connection, false end
    return newConnection(snapshot), true
end

-- GROUP F: STAGING BARRIER, CLIENT CURRENTNESS, LIVE DELTA AND FRESH RESNAPSHOT.
-- SDS v2.0 sections 3.9 and 5.7. Reliable-ordered transport needs no ACK,
-- missing-row retransmission, acknowledged-revision table or progress lease.
do
    local snapshot = newSnapshot(2, 10, 1001, 6, { 1, 2 })
    local first = newConnection(snapshot)
    local second = newConnection(snapshot)
    T.eq("F0a transport snapshot ID is distinct from provider revision",
        snapshot.snapshotGeneration == snapshot.baseRevision, false)
    T.eq("F0b transport snapshot ID is distinct from save generation",
        snapshot.snapshotGeneration == snapshot.carrierGeneration, false)
    T.eq("F0c save generation is retained independently", snapshot.carrierGeneration, 6)
    receiveCompactFull(first, 1001, 10, { aggregate = 0.25 })
    receiveDelta(first, 10, 12, { [44] = 0.70 })
    T.eq("F1 delta before row completion remains buffered", first.current, false)
    receiveRow(first, 0, { [1] = 0.20 })
    T.eq("F2 partial row staging is not live", first.live[1], nil)
    receiveRow(first, 1, { [2] = 0.30 })
    T.eq("F3 complete rows plus contiguous delta cross barrier", finishSnapshot(first), true)
    T.eq("F4 COMPLETE publishes currentness without an ACK", first.current, true)
    T.eq("F5 completed connection reaches delta revision", first.currentRevision, 12)
    T.near("F6 absolute buffered delta installs final value", first.live[44], 0.70, 1e-12)
    T.near("F7 base compact FULL corroborates the fine-derived aggregate",
        first.live.aggregate, 0.25, 1e-12)
    T.eq("F8 one connection completing does not complete its peer", second.current, false)

    T.eq("F9 contiguous post-completion delta applies immediately",
        receiveDelta(first, 12, 13, { [44] = 0.75 }), true)
    T.eq("F10 live delta advances current revision", first.currentRevision, 13)
    T.near("F11 live delta updates the live map", first.live[44], 0.75, 1e-12)
    T.eq("F12 duplicate completion is idempotent", finishSnapshot(first), true)
    T.eq("F13 duplicate completion never reapplies", first.completeCount, 1)
    receiveDelta(first, 10, 12, { [44] = 0.70 })
    T.near("F14 duplicate old absolute delta is ignored", first.live[44], 0.75, 1e-12)
    T.eq("F15 duplicate old delta does not request a resnapshot", first.resnapshot, false)

    local missing = newSnapshot(2, 20)
    local missingConn = newConnection(missing)
    receiveRow(missingConn, 0, {})
    T.eq("F16 missing snapshot row refuses completion", finishSnapshot(missingConn), false)
    T.eq("F17 incomplete completion requests one fresh full snapshot", missingConn.resnapshot, true)

    local gap = newSnapshot(1, 30)
    local gapConn = newConnection(gap)
    receiveRow(gapConn, 0, {})
    receiveDelta(gapConn, 31, 32, { [1] = 0.25 })
    T.eq("F18 revision gap refuses currentness", finishSnapshot(gapConn), false)
    T.eq("F19 revision gap requests one fresh full snapshot", gapConn.resnapshot, true)

    local mismatch = newConnection(newSnapshot(1, 40, 4001, 9))
    receiveRow(mismatch, 0, {})
    receiveCompactFull(mismatch, 4002, 41, {})
    T.eq("F20 compact FULL from another generation refuses completion",
        finishSnapshot(mismatch), false)
    T.eq("F21 compact generation mismatch requests one fresh snapshot", mismatch.resnapshot, true)

    local ordered = newConnection(newSnapshot(1, 60, 6001, 10))
    receiveRow(ordered, 0, { [1] = 0.20 })
    receiveCompactFull(ordered, 6001, 61, { aggregate = 0.50 })
    receiveDelta(ordered, 60, 61, { [44] = 0.70, aggregate = 0.50 })
    receiveDelta(ordered, 61, 62, { [45] = 0.80 })
    T.eq("F22 later compact FULL waits for its exact fine revision",
        finishSnapshot(ordered), true)
    T.eq("F23 later compact FULL preserves the following fine revision",
        ordered.currentRevision, 62)
    T.near("F24 matching compact FULL corroborates without overwriting fine staging",
        ordered.live.aggregate, 0.50, 1e-12)
    T.near("F25 fine delta after compact FULL remains present", ordered.live[45], 0.80, 1e-12)

    local contentMismatch = newConnection(newSnapshot(1, 63, 6301, 10))
    receiveRow(contentMismatch, 0, { [1] = 0.20 })
    receiveCompactFull(contentMismatch, 6301, 64, { aggregate = 0.65 })
    receiveDelta(contentMismatch, 63, 64, { aggregate = 0.50 })
    T.eq("F26 equal-revision compact disagreement refuses currentness",
        finishSnapshot(contentMismatch), false)
    T.eq("F27 equal-revision compact disagreement requests fresh snapshot",
        contentMismatch.resnapshot, true)

    local compactGap = newConnection(newSnapshot(1, 70, 7001, 11))
    receiveRow(compactGap, 0, {})
    receiveCompactFull(compactGap, 7001, 72, { aggregate = 0.70 })
    T.eq("F28 compact FULL ahead of the fine chain refuses currentness",
        finishSnapshot(compactGap), false)
    T.eq("F29 compact FULL revision gap requests fresh snapshot", compactGap.resnapshot, true)

    local currentCompact = newConnection(newSnapshot(1, 80, 8001, 12))
    receiveRow(currentCompact, 0, { aggregate = 0.72 })
    T.eq("F30 base snapshot becomes current before live compact FULL",
        finishSnapshot(currentCompact), true)
    T.eq("F31 matching live compact FULL is accepted as a witness",
        receiveCompactFull(currentCompact, 8001, 80, { aggregate = 0.72 }), true)
    T.near("F32 matching live compact FULL leaves fine aggregate unchanged",
        currentCompact.live.aggregate, 0.72, 1e-12)
    T.eq("F33 disagreeing live compact FULL requests fresh snapshot",
        receiveCompactFull(currentCompact, 8001, 80, { aggregate = 0.73 }), false)
    T.eq("F34 disagreeing live compact FULL sets resnapshot", currentCompact.resnapshot, true)

    local aheadCompact = newConnection(newSnapshot(1, 82, 8201, 12))
    receiveRow(aheadCompact, 0, {})
    finishSnapshot(aheadCompact)
    T.eq("F35 ahead live compact FULL requests fresh snapshot",
        receiveCompactFull(aheadCompact, 8201, 84, {}), false)
    T.eq("F36 ahead live compact FULL sets resnapshot", aheadCompact.resnapshot, true)

    local baseMatch = newConnection(newSnapshot(1, 85, 8501, 12, { 1, 2 }))
    receiveRow(baseMatch, 0, { [1] = 0.20, [2] = 0.40 })
    receiveCompactFull(baseMatch, 8501, 85, { aggregate = 0.30 })
    T.eq("F37 matching base compact aggregate permits currentness",
        finishSnapshot(baseMatch), true)
    T.near("F38 base aggregate is derived from completed fine rows",
        baseMatch.live.aggregate, 0.30, 1e-12)

    local baseMismatch = newConnection(newSnapshot(1, 86, 8601, 12, { 1, 2 }))
    receiveRow(baseMismatch, 0, { [1] = 0.20, [2] = 0.40 })
    receiveCompactFull(baseMismatch, 8601, 86, { aggregate = 0.31 })
    T.eq("F39 mismatched base compact aggregate refuses currentness",
        finishSnapshot(baseMismatch), false)
    T.eq("F40 mismatched base compact aggregate requests fresh snapshot",
        baseMismatch.resnapshot, true)

    local restarted, didRestart = restartFromFreshSnapshot(missingConn,
        newSnapshot(2, 21, 2101, 14))
    T.eq("F41 semantic mismatch starts one fresh snapshot", didRestart, true)
    T.eq("F42 fresh snapshot carries none of the old partial rows", restarted.rowCount, 0)
    T.eq("F43 fresh snapshot begins non-current", restarted.current, false)
    T.eq("F44 fresh snapshot does not inherit the prior mismatch", restarted.resnapshot, false)
end

local function runBudgeted(totalItems, budget)
    if budget <= 0 then return 0, 0, 0, "PAUSED" end
    local processed, frames, maxStep = 0, 0, 0
    while processed < totalItems do
        local step = math.min(budget, totalItems - processed)
        processed = processed + step
        frames = frames + 1
        if step > maxStep then maxStep = step end
    end
    return processed, frames, maxStep, "COMPLETE"
end

-- GROUP G: FRAME BUDGET DELAYS WORK AND NEVER CAPS TOTAL WORK.
-- SDS v2.1 section 3.10.
do
    local processed, frames, maxStep = runBudgeted(23, 4)
    T.eq("G1 small queue visits every item", processed, 23)
    T.eq("G2 small queue respects per-frame budget", maxStep, 4)
    T.eq("G3 small queue takes the derived frame count", frames, math.ceil(23 / 4))

    processed, frames, maxStep = runBudgeted(230, 4)
    T.eq("G4 larger queue still visits every item", processed, 230)
    T.eq("G5 larger queue keeps the same per-frame ceiling", maxStep, 4)
    T.eq("G6 larger queue takes more frames rather than dropping work", frames, math.ceil(230 / 4))

    processed, frames, maxStep = runBudgeted(401, 4)
    T.eq("G7 work beyond the old 400-item ceiling is all visited", processed, 401)
    T.eq("G8 work beyond the old ceiling keeps the frame budget", maxStep, 4)
    T.eq("G9 work beyond the old ceiling takes derived extra frames", frames, math.ceil(401 / 4))

    local state
    processed, frames, maxStep, state = runBudgeted(10, 0)
    T.eq("G10 zero budget performs no hidden work", processed, 0)
    T.eq("G11 zero budget does not claim completion", state, "PAUSED")
end

local function applyZoneWater(zone, cellKey, gain)
    if zone.cells[cellKey] == nil then
        zone.cells[cellKey] = zone.seed
        zone.cellCount = zone.cellCount + 1
    end
    zone.cells[cellKey] = zone.cells[cellKey] + gain
    zone.totalAccepted = zone.totalAccepted + gain
end

local function revalidatePending(entries, resolver)
    local mapped, unresolved = {}, {}
    for _, entry in ipairs(entries) do
        local fieldId = resolver(entry.worldX, entry.worldZ)
        if type(fieldId) == "number" then
            mapped[fieldId] = (mapped[fieldId] or 0) + entry.amount
        else
            unresolved[#unresolved + 1] = entry
        end
    end
    return mapped, unresolved
end

-- GROUP H: EVENT WATER OUTLIVES RELIEF CAP AND FIELD CONTEXT IS REVALIDATED.
-- SDS 3.5, 3.6, 3.10 and 5.8 after the R1 structural fold.
do
    local zone = {
        seed = 0.50,
        cells = {},
        cellCount = 1000,
        totalAccepted = 0,
    }
    applyZoneWater(zone, "new-cell", 0.10)
    T.eq("H1 real ZONE water materializes beyond relief backstop", zone.cellCount, 1001)
    T.near("H2 real ZONE water is preserved", zone.cells["new-cell"], 0.60, 1e-12)
    T.near("H3 accepted ZONE total is not silently dropped", zone.totalAccepted, 0.10, 1e-12)

    local pending = {
        { worldX = 10, worldZ = 20, amount = 0.001 },
        { worldX = 30, worldZ = 40, amount = 0.002 },
    }
    local mapped, unresolved = revalidatePending(pending, function(x, _z)
        if x == 10 then return 7 end
        return nil
    end)
    T.near("H4 uniquely resolved pending rekeys to current field", mapped[7], 0.001, 1e-12)
    T.eq("H5 ambiguous pending remains unresolved", #unresolved, 1)
    T.near("H6 unresolved pending keeps its accepted amount", unresolved[1].amount, 0.002, 1e-12)
end

local EventFamily = {
    INIT = "CropStressMoistureInitEvent",
    ROW = "CropStressMoistureRowEvent",
    DELTA = "CropStressMoistureDeltaEvent",
    CONTROL = "CropStressMoistureControlEvent",
}

local function queueFieldDelta(queues, fieldId, pixelKey, fromRevision, toRevision, value)
    queues[fieldId] = queues[fieldId] or {}
    local prior = queues[fieldId][pixelKey]
    queues[fieldId][pixelKey] = {
        fieldId = fieldId,
        pixelKey = pixelKey,
        fromRevision = prior ~= nil and prior.fromRevision or fromRevision,
        toRevision = toRevision,
        value = value,
    }
end

local function clearFieldDeltaQueue(queues, fieldId)
    queues[fieldId] = nil
end

local function deltaEntryCount(queues)
    local count = 0
    for _, pixels in pairs(queues) do
        for _ in pairs(pixels) do count = count + 1 end
    end
    return count
end

local function shouldRestartSnapshot(deltaCount, fullSnapshotEntryCount)
    return deltaCount >= fullSnapshotEntryCount
end

local function fieldGeometryChanged(savedFingerprint, currentFingerprint)
    return savedFingerprint ~= currentFingerprint
end

-- GROUP I: EVENT OWNERSHIP, FIELD-PARTITIONED DELTAS AND INITIAL DEFAULTS.
-- SDS 3.6, 3.9 and 3.10 after the R2 structural fold.
do
    T.eq("I1 init and row events remain logically distinct",
        EventFamily.INIT == EventFamily.ROW, false)
    T.eq("I2 row and delta events remain logically distinct",
        EventFamily.ROW == EventFamily.DELTA, false)
    T.eq("I3 delta and control events remain logically distinct",
        EventFamily.DELTA == EventFamily.CONTROL, false)

    local queues = {}
    queueFieldDelta(queues, 3, 11, 90, 91, 0.44)
    queueFieldDelta(queues, 4, 12, 90, 91, 0.55)
    queueFieldDelta(queues, 3, 11, 91, 92, 0.46)
    T.eq("I4 repeated pixel dirties coalesce to one final entry per field pixel",
        deltaEntryCount(queues), 2)
    T.eq("I5 coalesced entry retains its field identity", queues[3][11].fieldId, 3)
    T.eq("I6 coalesced entry retains its original base revision", queues[3][11].fromRevision, 90)
    T.eq("I7 coalesced entry retains its newest provider revision", queues[3][11].toRevision, 92)
    T.near("I8 coalesced entry retains its final value", queues[3][11].value, 0.46, 1e-12)
    clearFieldDeltaQueue(queues, 3)
    T.eq("I9 field replacement clears only that field's delta partition", queues[3], nil)
    T.near("I10 another field's queued value survives", queues[4][12].value, 0.55, 1e-12)

    T.eq("I11 delta history equal to one full snapshot requests restart",
        shouldRestartSnapshot(20, 20), true)
    T.eq("I12 shorter delta history may remain attached to its base",
        shouldRestartSnapshot(19, 20), false)
    T.eq("I13 unchanged field polygon fingerprint keeps membership",
        fieldGeometryChanged("abc", "abc"), false)
    T.eq("I14 changed field polygon fingerprint requests rebuild",
        fieldGeometryChanged("abc", "def"), true)

    T.eq("I15 current source supplies the initial snapshot row budget",
        SoilMoistureSystem.SYNC_ROWS_PER_FRAME, SNAPSHOT_ROWS_PER_FRAME)
    T.eq("I16 current source supplies the initial redistribution work value",
        SoilMoistureSystem.MAP_DRAIN_MAX_BLOCKS, REDISTRIBUTION_OPS_PER_FRAME)
end

local function newDailyState(cursor, revision)
    return {
        cursor = cursor, revision = revision, liveTotal = 0, plan = nil,
        commits = 0, fieldPending = 0, positionalPending = 0, pendingFlushes = 0,
    }
end

local function dueBoundaries(cursor, currentDay)
    if type(cursor) ~= "number" or type(currentDay) ~= "number" then return 0 end
    if cursor ~= cursor or currentDay ~= currentDay then return 0 end
    if math.abs(cursor) == math.huge or math.abs(currentDay) == math.huge then return 0 end
    local due = currentDay - cursor
    if due <= 0 then return 0 end
    return math.floor(due)
end

local function wakeDaily(state, currentDay, fingerprint, totalOps)
    if type(currentDay) ~= "number" or currentDay ~= currentDay
        or math.abs(currentDay) == math.huge then return "INVALID" end
    if state.cursor == nil then
        state.cursor = currentDay
        return "SEEDED"
    end
    local due = dueBoundaries(state.cursor, currentDay)
    if due == 0 then return "IDLE" end
    if state.plan == nil then
        state.plan = {
            due = due, targetDay = currentDay, baseRevision = state.revision,
            fingerprint = fingerprint, cursor = 0, totalOps = totalOps,
            stagedTotal = 0, complete = false,
        }
        return "PENDING"
    end
    return "PENDING"
end

local function advanceDailyPlan(state, budget, currentDay, fingerprint)
    local plan = state.plan
    if plan == nil then return 0, "IDLE" end
    if plan.targetDay ~= currentDay
        or plan.baseRevision ~= state.revision
        or plan.fingerprint ~= fingerprint then
        state.plan = nil
        return 0, "ABORTED"
    end
    if budget <= 0 then return 0, "PAUSED" end
    local step = math.min(math.max(0, budget), plan.totalOps - plan.cursor)
    plan.cursor = plan.cursor + step
    plan.stagedTotal = plan.due
    plan.complete = plan.cursor == plan.totalOps
    if not plan.complete then return step, "PENDING" end
    state.liveTotal = state.liveTotal + plan.stagedTotal
    state.revision = state.revision + 1
    state.cursor = plan.targetDay
    state.plan = nil
    state.commits = state.commits + 1
    return step, "COMMITTED"
end

local function acceptAdditiveDuringDailyPlan(state, fieldGain, positionalGain)
    state.fieldPending = state.fieldPending + math.max(0, fieldGain or 0)
    state.positionalPending = state.positionalPending + math.max(0, positionalGain or 0)
    return "BUFFERED"
end

local function flushPostPlanPending(state)
    if state.plan ~= nil then return "HELD" end
    local moved = state.fieldPending + state.positionalPending
    if moved <= 0 then return "IDLE" end
    state.liveTotal = state.liveTotal + moved
    state.fieldPending = 0
    state.positionalPending = 0
    state.revision = state.revision + 1
    state.pendingFlushes = state.pendingFlushes + 1
    return "FLUSHED"
end

local function timeGuardAccrualWouldAdvance(pcallOk, _callbackReturn)
    return pcallOk == true
end

local function usableTimeGuardWake(isServer, synced, monotonicDay)
    return isServer == true and synced == true and type(monotonicDay) == "number"
        and monotonicDay == monotonicDay and math.abs(monotonicDay) < math.huge
end

-- GROUP J: SCS OWNS DAILY CURSOR, STAGING AND COMMIT; TIME GUARD ONLY WAKES IT.
-- SDS v2.1 sections 3.10 and 5.5. TimeGuardScheduler.lua:145-179 advances
-- after any non-throwing callback, while TimeGuard.lua:273-337 exposes a day tick
-- and monotonic-day context that do not claim SCS completion.
do
    local state = newDailyState(5, 20)
    T.eq("J1 first due wake opens SCS-owned staging",
        wakeDaily(state, 8, "poly-a", 900), "PENDING")
    T.eq("J2 SCS cursor stays at the last committed day", state.cursor, 5)
    T.eq("J3 first frame advances only the positive operation budget",
        select(1, advanceDailyPlan(state, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")),
        REDISTRIBUTION_OPS_PER_FRAME)
    T.eq("J4 partial staging never mutates live moisture", state.liveTotal, 0)
    T.eq("J5 second frame remains incomplete",
        select(2, advanceDailyPlan(state, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")), "PENDING")
    local finalStep, finalStatus = advanceDailyPlan(state, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")
    T.eq("J6 final frame performs only the remaining work", finalStep, 100)
    T.eq("J7 final frame commits without another calendar callback", finalStatus, "COMMITTED")
    T.eq("J8 successful commit advances the SCS cursor", state.cursor, 8)
    T.eq("J9 one complete candidate commits exactly once", state.commits, 1)
    T.eq("J10 three crossed days settle exactly once as one transaction", state.liveTotal, 3)
    T.eq("J11 one complete field act advances readable revision once", state.revision, 21)
    T.eq("J12 duplicate day wake opens no second work",
        wakeDaily(state, 8, "poly-a", 900), "IDLE")

    local savedMidPlan = newDailyState(5, 20)
    wakeDaily(savedMidPlan, 8, "poly-a", 900)
    advanceDailyPlan(savedMidPlan, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")
    local reloaded = newDailyState(savedMidPlan.cursor, savedMidPlan.revision)
    T.eq("J13 save and reload discard non-authoritative staging", reloaded.plan, nil)
    T.eq("J14 unadvanced SCS cursor reoffers the same three due days",
        dueBoundaries(reloaded.cursor, 8), 3)

    local invalidated = newDailyState(5, 20)
    wakeDaily(invalidated, 8, "poly-a", 900)
    advanceDailyPlan(invalidated, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")
    invalidated.revision = 21
    T.eq("J15 authoritative replacement invalidates the pinned daily candidate",
        select(2, advanceDailyPlan(invalidated, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")),
        "ABORTED")
    T.eq("J16 replacement-invalidated staging is discarded", invalidated.plan, nil)
    T.eq("J17 replacement invalidation leaves the SCS cursor unchanged", invalidated.cursor, 5)

    local additive = newDailyState(5, 20)
    wakeDaily(additive, 8, "poly-a", 900)
    advanceDailyPlan(additive, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")
    T.eq("J31 additive water is accepted into existing pending during daily work",
        acceptAdditiveDuringDailyPlan(additive, 0.01, 0.02), "BUFFERED")
    T.eq("J32 additive pending does not advance the pinned readable revision",
        additive.revision, 20)
    T.ok("J33 additive pending leaves the daily candidate live", additive.plan ~= nil)
    advanceDailyPlan(additive, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")
    T.eq("J34 daily work commits despite repeated foreground acceptance",
        select(2, advanceDailyPlan(additive, REDISTRIBUTION_OPS_PER_FRAME, 8, "poly-a")),
        "COMMITTED")
    T.eq("J35 daily commit advances the cursor before pending flush", additive.cursor, 8)
    T.eq("J36 post-plan pending flushes through one provider transaction",
        flushPostPlanPending(additive), "FLUSHED")
    T.near("J37 daily result and accepted foreground water both remain visible",
        additive.liveTotal, 3.03, 1e-12)
    T.eq("J38 one post-plan readable flush advances revision once", additive.revision, 22)
    T.eq("J39 flushed field pending clears", additive.fieldPending, 0)
    T.eq("J40 flushed positional pending clears", additive.positionalPending, 0)
    T.eq("J41 repeated post-plan flush is idle", flushPostPlanPending(additive), "IDLE")

    local firstInstall = newDailyState(nil, 1)
    T.eq("J18 missing cursor seeds the current day without invented history",
        wakeDaily(firstInstall, 12, "poly-a", 10), "SEEDED")
    T.eq("J19 first seed records the current monotonic day", firstInstall.cursor, 12)
    T.eq("J20 first seed performs no settlement", firstInstall.liveTotal, 0)
    T.eq("J21 rewind creates no negative or duplicate due work", dueBoundaries(8, 7), 0)

    local paused = newDailyState(5, 20)
    wakeDaily(paused, 8, "poly-a", 900)
    T.eq("J22 zero budget visibly pauses instead of completing",
        select(2, advanceDailyPlan(paused, 0, 8, "poly-a")), "PAUSED")
    T.eq("J23 zero budget leaves the due cursor unchanged", paused.cursor, 5)

    local present = newDailyState(10, 30)
    local absent = newDailyState(10, 30)
    wakeDaily(present, 12, "poly-b", 800)
    wakeDaily(absent, 12, "poly-b", 800)
    advanceDailyPlan(present, REDISTRIBUTION_OPS_PER_FRAME, 12, "poly-b")
    advanceDailyPlan(absent, REDISTRIBUTION_OPS_PER_FRAME, 12, "poly-b")
    advanceDailyPlan(present, REDISTRIBUTION_OPS_PER_FRAME, 12, "poly-b")
    advanceDailyPlan(absent, REDISTRIBUTION_OPS_PER_FRAME, 12, "poly-b")
    T.eq("J24 Time Guard present and absent paths commit the same due count",
        present.liveTotal, absent.liveTotal)
    T.eq("J25 Time Guard present and absent paths retain the same SCS cursor",
        present.cursor, absent.cursor)
    T.eq("J26 Time Guard present and absent paths retain the same revision",
        present.revision, absent.revision)

    T.eq("J27 a false callback return would still advance current Time Guard accrual",
        timeGuardAccrualWouldAdvance(true, false), true)
    T.eq("J28 client peer never opens the SCS daily transaction",
        usableTimeGuardWake(false, true, 8), false)
    T.eq("J29 unsynchronized Time Guard context is neutral absence",
        usableTimeGuardWake(true, false, 0), false)
    T.eq("J30 synchronized finite day zero remains a valid server coordinate",
        usableTimeGuardWake(true, true, 0), true)
end

local function newPersistenceState(generation, revision, fieldPending, positionalPending, cursor)
    local committedCursor = cursor or 20
    return {
        current = {
            generation = generation, revision = revision,
            fieldPending = fieldPending, positionalPending = positionalPending,
            lastSettledMonotonicDay = committedCursor,
        },
        previous = {
            generation = generation - 1, revision = revision - 1,
            fieldPending = 0, positionalPending = 0,
            lastSettledMonotonicDay = committedCursor - 1,
        },
        revision = revision,
        lastSettledMonotonicDay = committedCursor,
        fieldPending = fieldPending,
        positionalPending = positionalPending,
        pendingOnly = nil,
        framePackingSteps = 0,
    }
end

local function exactNativeSaveSuccess(pcallOk, returned)
    return pcallOk == true and returned == true
end

local function synchronousSave(state, packOk, nativePcallOk, nativeReturned, compactOk)
    local capture = {
        revision = state.revision,
        lastSettledMonotonicDay = state.lastSettledMonotonicDay,
        fieldPending = state.fieldPending,
        positionalPending = state.positionalPending,
    }
    if not packOk then return false, capture, "PACK_FAILED" end
    if not exactNativeSaveSuccess(nativePcallOk, nativeReturned) then
        if compactOk then
            state.pendingOnly = {
                payloadKind = "PENDING_ONLY",
                baseGeneration = state.current.generation,
                baseRevision = state.current.revision,
                baseLastSettledMonotonicDay = state.current.lastSettledMonotonicDay,
                fieldPending = capture.fieldPending,
                positionalPending = capture.positionalPending,
                digest = string.format("p:%d:%d:%d:%.6f:%.6f", state.current.generation,
                    state.current.revision, state.current.lastSettledMonotonicDay,
                    capture.fieldPending, capture.positionalPending),
                zoneOk = true,
            }
        end
        return false, capture, "NATIVE_FAILED"
    end
    if not compactOk then return false, capture, "COMPACT_FAILED" end
    state.previous = state.current
    state.current = {
        generation = state.current.generation + 1,
        revision = capture.revision,
        lastSettledMonotonicDay = capture.lastSettledMonotonicDay,
        fieldPending = capture.fieldPending,
        positionalPending = capture.positionalPending,
    }
    state.pendingOnly = nil
    return true, capture, "COMPLETE"
end

-- GROUP K: SAVE CAPTURE IS SYNCHRONOUS; COMPLETE PAIRS AND PENDING-ONLY RECOVERY
-- HAVE DIFFERENT COMMIT RULES. SDS v2.1 sections 3.7 and 5.6.
-- CropStressValueMap.lua:233-241 currently drops the native false return.
do
    local failed = newPersistenceState(7, 41, 0.020, 0.003)
    failed.lastSettledMonotonicDay = 23
    local oldCurrent = failed.current
    local oldPrevious = failed.previous
    T.eq("K1 failed native write refuses a new moisture generation",
        select(1, synchronousSave(failed, true, true, false, true)), false)
    T.eq("K2 failed save keeps the current complete pair", failed.current, oldCurrent)
    T.eq("K3 failed save keeps the previous complete pair", failed.previous, oldPrevious)
    T.eq("K4 native failure records one pending-only payload",
        failed.pendingOnly.payloadKind, "PENDING_ONLY")
    T.eq("K5 pending-only payload binds to the last complete generation",
        failed.pendingOnly.baseGeneration, 7)
    T.near("K6 pending-only payload keeps field-wide accepted water",
        failed.pendingOnly.fieldPending, 0.020, 1e-12)
    T.near("K7 pending-only payload keeps positional accepted water",
        failed.pendingOnly.positionalPending, 0.003, 1e-12)
    T.eq("K8 non-throwing native false is failure",
        exactNativeSaveSuccess(true, false), false)
    T.eq("K9 thrown native save is failure", exactNativeSaveSuccess(false, nil), false)
    T.eq("K9a pending-only copies the base carrier cursor, not newer RAM cursor",
        failed.pendingOnly.baseLastSettledMonotonicDay, 20)
    T.eq("K9b pending-only copies the base carrier revision",
        failed.pendingOnly.baseRevision, 41)

    local failedRecovery = newPersistenceState(7, 41, 0.020, 0.003)
    synchronousSave(failedRecovery, true, true, false, false)
    T.eq("K10 failed compact recovery claims no pending-only durability",
        failedRecovery.pendingOnly, nil)

    local saved = newPersistenceState(7, 41, 0.020, 0.003)
    saved.lastSettledMonotonicDay = 22
    local ok, capture = synchronousSave(saved, true, true, true, true)
    T.eq("K11 synchronous capture commits after every required act succeeds", ok, true)
    T.eq("K12 committed generation advances once", saved.current.generation, 8)
    T.eq("K13 committed pair carries the frozen provider revision", saved.current.revision, 41)
    T.near("K14 committed pair carries frozen field pending",
        saved.current.fieldPending, 0.020, 1e-12)
    T.near("K15 committed pair carries frozen positional pending",
        saved.current.positionalPending, 0.003, 1e-12)
    T.eq("K16 capture revision is immutable inside the save act", capture.revision, 41)
    T.eq("K17 persistence packing consumes no ordinary frame budget", saved.framePackingSteps, 0)
    T.eq("K17a committed pair carries the captured carrier cursor",
        saved.current.lastSettledMonotonicDay, 22)

    local compactFailed = newPersistenceState(7, 41, 0.020, 0.003)
    local compactOldCurrent = compactFailed.current
    local compactOldPrevious = compactFailed.previous
    T.eq("K18 compact failure refuses the candidate generation",
        select(1, synchronousSave(compactFailed, true, true, true, false)), false)
    T.eq("K19 compact failure keeps current pair byte-object stable",
        compactFailed.current, compactOldCurrent)
    T.eq("K20 compact failure keeps previous pair byte-object stable",
        compactFailed.previous, compactOldPrevious)
end

local function newProviderFailureState()
    return {
        mode = "TRUTH", current = true, revision = 12, valueMap = {},
        retainedCellsPromoted = false, fieldPending = 0, positionalPending = 0,
        aggregate = 0.55, aggregateCurrent = true, geometryInvalid = false,
    }
end

local function failNative(state)
    state.mode = "UNAVAILABLE_PENDING_RELOAD"
    state.current = false
    state.valueMap = nil
end

local function acceptUnavailable(state, fieldGain, positionalGain)
    state.fieldPending = state.fieldPending + fieldGain
    state.positionalPending = state.positionalPending + positionalGain
end

local function classifyPolygonAverage(inputValid, mapAvailable, executeGetAvailable,
    pcallOk, accumulator, numPixels)
    if not inputValid then return "INVALID_FIELD_GEOMETRY", nil end
    if not mapAvailable or not executeGetAvailable or not pcallOk then
        return "PROVIDER_REFUSAL", nil
    end
    if type(accumulator) ~= "number" or accumulator ~= accumulator
        or math.abs(accumulator) == math.huge
        or type(numPixels) ~= "number" or numPixels ~= numPixels
        or math.abs(numPixels) == math.huge or numPixels < 0 then
        return "PROVIDER_REFUSAL", nil
    end
    if numPixels == 0 then return "EMPTY", nil end
    return "OK", accumulator / numPixels
end

local function handlePolygonAverage(state, inputValid, mapAvailable, executeGetAvailable,
    pcallOk, accumulator, numPixels)
    local outcome, mean = classifyPolygonAverage(inputValid, mapAvailable,
        executeGetAvailable, pcallOk, accumulator, numPixels)
    if outcome == "INVALID_FIELD_GEOMETRY" then
        state.geometryInvalid = true
        state.aggregateCurrent = false
    elseif outcome == "EMPTY" then
        state.aggregate = nil
        state.aggregateCurrent = false
    elseif outcome == "PROVIDER_REFUSAL" then
        failNative(state)
        state.aggregateCurrent = false
    else
        state.aggregate = mean
        state.aggregateCurrent = true
    end
    return outcome, mean
end

-- GROUP L: ACTIVE NATIVE FAILURE IS ONE-WAY; INVALID, EMPTY AND REFUSAL ARE
-- DISTINCT POLYGON-MEAN OUTCOMES. SDS v2.1 sections 3.3, 3.9A and 5.8A.
-- CropStressValueMap.lua:376-391 and SoilMoistureSystem.lua:978-982 currently
-- collapse and silently retain these cases.
do
    local state = newProviderFailureState()
    failNative(state)
    T.eq("L1 native failure selects the explicit unavailable mode",
        state.mode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("L2 native failure removes fine currentness", state.current, false)
    T.eq("L3 failing native handle is detached", state.valueMap, nil)
    T.eq("L4 retained fallback evidence is not promoted", state.retainedCellsPromoted, false)
    acceptUnavailable(state, 0.02, 0.003)
    T.near("L5 field-wide accepted water remains pending", state.fieldPending, 0.02, 1e-12)
    T.near("L6 positional accepted water remains pending", state.positionalPending, 0.003, 1e-12)
    T.eq("L7 unavailable pending does not mint readable revision", state.revision, 12)

    local invalid = newProviderFailureState()
    T.eq("L8 malformed field polygon has its own outcome",
        select(1, handlePolygonAverage(invalid, false, true, true, true, 10, 5)),
        "INVALID_FIELD_GEOMETRY")
    T.eq("L9 malformed field polygon does not poison native provider", invalid.mode, "TRUTH")
    T.eq("L10 malformed field polygon requests context rebuild", invalid.geometryInvalid, true)

    local empty = newProviderFailureState()
    T.eq("L11 valid polygon with zero written pixels is EMPTY",
        select(1, handlePolygonAverage(empty, true, true, true, true, 0, 0)), "EMPTY")
    T.eq("L12 empty polygon does not poison native provider", empty.mode, "TRUTH")
    T.eq("L13 empty polygon refuses stale aggregate currentness", empty.aggregateCurrent, false)
    T.eq("L14 empty polygon does not retain the old scalar as current", empty.aggregate, nil)

    local refused = newProviderFailureState()
    T.eq("L15 valid native polygon read refusal is explicit",
        select(1, handlePolygonAverage(refused, true, true, true, false, nil, nil)),
        "PROVIDER_REFUSAL")
    T.eq("L16 valid native polygon refusal fails the provider closed",
        refused.mode, "UNAVAILABLE_PENDING_RELOAD")

    local valid = newProviderFailureState()
    local outcome, mean = handlePolygonAverage(valid, true, true, true, true, 3, 6)
    T.eq("L17 successful polygon mean is OK", outcome, "OK")
    T.near("L18 successful polygon mean publishes the derived value", mean, 0.50, 1e-12)
    T.eq("L19 successful polygon mean remains current", valid.aggregateCurrent, true)

    local persisted = newPersistenceState(7, state.revision,
        state.fieldPending, state.positionalPending)
    synchronousSave(persisted, true, true, false, true)
    local pending = persisted.pendingOnly
    local mode, generation, _digest, pendingDigest, pendingStatus, selectedCursor = selectPersistence({
        {
            payloadKind = "COMPLETE", generation = 7, digest = "g7",
            compactOk = true, nativeOk = true, revision = persisted.current.revision,
            lastSettledMonotonicDay = persisted.current.lastSettledMonotonicDay,
        },
        {
            payloadKind = pending.payloadKind,
            baseGeneration = pending.baseGeneration,
            baseRevision = pending.baseRevision,
            baseLastSettledMonotonicDay = pending.baseLastSettledMonotonicDay,
            digest = pending.digest,
            compactOk = true,
            zoneOk = pending.zoneOk,
        },
    })
    T.eq("L20 reload keeps the complete pair as fine authority", mode, "TRUTH")
    T.eq("L21 reload binds recovery only to its exact base generation", generation, 7)
    T.eq("L22 reload restores the matching pending-only payload", pendingDigest, pending.digest)
    T.eq("L23 pending-only reload disposition is explicit", pendingStatus, "APPLIED")
    T.eq("L24 matching pending-only reload preserves selected carrier cursor",
        selectedCursor, persisted.current.lastSettledMonotonicDay)
end

local function exactRegistrationActive(pcallOk, returned)
    return pcallOk == true and returned == true
end

-- GROUP M: OPTIONAL SERVICE REGISTRATION REQUIRES EXACT BOOLEAN SUCCESS.
-- StateLedger.lua:51-77 and NetworkSync.lua:92-118 return true only after
-- registration. Current SCS bridges incorrectly treat any non-throwing call as active.
do
    T.eq("M1 exact true registration activates a bridge", exactRegistrationActive(true, true), true)
    T.eq("M2 false registration is neutral absence", exactRegistrationActive(true, false), false)
    T.eq("M3 nil registration is neutral absence", exactRegistrationActive(true, nil), false)
    T.eq("M4 thrown registration is neutral absence", exactRegistrationActive(false, nil), false)
end

local function canMarkFineCurrent(carrier)
    return carrier == "SCS_EVENTS"
end

-- GROUP N: GENERATION-QUALIFIED MAP TRANSPORT REMAINS SCS-OWNED.
-- RealisticFarmingSyncEvent.lua:101-136 and NetworkSync.lua:362-391 expose no
-- generation discriminator. SDS v2.1 section 3.9 keeps fine currentness on SCS events.
do
    T.eq("N1 SCS event family may carry fine currentness", canMarkFineCurrent("SCS_EVENTS"), true)
    T.eq("N2 NetworkSync aggregate mirror cannot mark fine currentness",
        canMarkFineCurrent("NETWORKSYNC_AGGREGATE"), false)
    T.eq("N3 StateLedger persistence never marks fine transport current",
        canMarkFineCurrent("STATELEDGER"), false)
end

local function newConservationState()
    return {
        revision = 10,
        fieldPending = 0,
        positionalPending = {},
        writes = 0,
    }
end

local function positionalPendingTotal(state)
    local total = 0
    for _, row in pairs(state.positionalPending) do total = total + row.amount end
    return total
end

local function acceptPositional(state, validTarget, pixelKey, worldKey, sourceWidth,
    gain, writeOk)
    if not validTarget or type(gain) ~= "number" or gain <= 0 then
        return false, "INVALID_TARGET"
    end
    local key = pixelKey ~= nil and ("PIXEL:" .. tostring(pixelKey))
        or ("WORLD:" .. tostring(worldKey))
    local prior = state.positionalPending[key]
    local pending = (prior ~= nil and prior.amount or 0) + gain
    state.positionalPending[key] = {
        status = pixelKey ~= nil and "RESOLVED" or "UNRESOLVED",
        pixelKey = pixelKey,
        worldKey = worldKey,
        sourceWidth = sourceWidth,
        amount = pending,
    }
    if pixelKey == nil then return true, "PENDING_UNRESOLVED" end
    local applied, remainder = CropStressValueMap.quantiseDelta(pending)
    if applied == 0 then return true, "PENDING_SUBSTEP" end
    if writeOk ~= true then return true, "PENDING_WRITE_REFUSAL" end
    state.positionalPending[key].amount = remainder
    state.revision = state.revision + 1
    state.writes = state.writes + 1
    return true, "APPLIED"
end

local function revalidatePositional(state, worldKey, pixelKey)
    local oldKey = "WORLD:" .. tostring(worldKey)
    local row = state.positionalPending[oldKey]
    if row == nil or pixelKey == nil then return false end
    local newKey = "PIXEL:" .. tostring(pixelKey)
    local existing = state.positionalPending[newKey]
    state.positionalPending[newKey] = {
        status = "RESOLVED", pixelKey = pixelKey, worldKey = row.worldKey,
        sourceWidth = row.sourceWidth,
        amount = row.amount + (existing ~= nil and existing.amount or 0),
    }
    state.positionalPending[oldKey] = nil
    return true
end

local function packPositional(rows)
    local out = {}
    for key, row in pairs(rows) do
        out[#out + 1] = {
            key = key, status = row.status, pixelKey = row.pixelKey,
            worldKey = row.worldKey, sourceWidth = row.sourceWidth, amount = row.amount,
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

local function unpackPositional(rows)
    local out = {}
    for _, row in ipairs(rows) do
        out[row.key] = {
            status = row.status, pixelKey = row.pixelKey,
            worldKey = row.worldKey, sourceWidth = row.sourceWidth, amount = row.amount,
        }
    end
    return out
end

local function spendFieldPending(state, incoming, geometryValid, writeOk)
    local pending = state.fieldPending + incoming
    if not geometryValid then
        state.fieldPending = pending
        return "INVALID_FIELD_GEOMETRY"
    end
    local applied, remainder = CropStressValueMap.quantiseDelta(pending)
    if applied == 0 then
        state.fieldPending = remainder
        return "PENDING_SUBSTEP"
    end
    if writeOk ~= true then
        state.fieldPending = pending
        return "PROVIDER_REFUSAL"
    end
    state.fieldPending = remainder
    state.revision = state.revision + 1
    state.writes = state.writes + 1
    return "APPLIED"
end

-- GROUP O: ACCEPTED WATER ENTERS ONE EXISTING PENDING NAMESPACE BEFORE
-- DESTINATION SPEND. SDS v2.1 sections 3.5, 3.6, 5.2 and 5.3.
do
    local invalid = newConservationState()
    T.eq("O1 invalid positional target is not accepted",
        select(1, acceptPositional(invalid, false, nil, "10,10", 2, 0.01, false)), false)
    T.eq("O2 invalid target creates no positional pending", positionalPendingTotal(invalid), 0)

    local unresolved = newConservationState()
    T.eq("O3 valid position with unresolved pixel is accepted into pending",
        select(1, acceptPositional(unresolved, true, nil, "10,10", 2, 0.01, false)), true)
    T.near("O4 unresolved pixel preserves the full accepted gain",
        positionalPendingTotal(unresolved), 0.01, 1e-12)
    T.eq("O5 unresolved pixel mints no readable revision", unresolved.revision, 10)
    local packed = packPositional(unresolved.positionalPending)
    local restored = newConservationState()
    restored.positionalPending = unpackPositional(packed)
    T.eq("O6 unresolved positional status survives compact round trip",
        restored.positionalPending["WORLD:10,10"].status, "UNRESOLVED")
    T.eq("O7 unresolved positional source width survives compact round trip",
        restored.positionalPending["WORLD:10,10"].sourceWidth, 2)
    T.eq("O8 unique revalidation resolves the existing leaf",
        revalidatePositional(restored, "10,10", 4101), true)
    T.near("O9 revalidation conserves the exact positional total",
        positionalPendingTotal(restored), 0.01, 1e-12)

    local refused = newConservationState()
    acceptPositional(refused, true, 4101, "10,10", 2, 0.01, false)
    T.near("O10 native write refusal keeps the pre-spend positional amount",
        positionalPendingTotal(refused), 0.01, 1e-12)
    T.eq("O11 native write refusal mints no revision", refused.revision, 10)

    local field = newConservationState()
    T.eq("O12 invalid field geometry retains full pre-quantisation pending",
        spendFieldPending(field, 0.01, false, false), "INVALID_FIELD_GEOMETRY")
    T.near("O13 invalid geometry keeps the field-wide amount", field.fieldPending, 0.01, 1e-12)
    T.eq("O14 geometry retry applies once after rebuild",
        spendFieldPending(field, 0, true, true), "APPLIED")
    T.eq("O15 geometry retry advances revision once", field.revision, 11)
    T.eq("O16 field-wide refusal never enters positional pending",
        positionalPendingTotal(field), 0)
end

local function forwardHourEdge(lastKey, currentKey, cap)
    if type(currentKey) ~= "number" then return 0, lastKey, "INVALID" end
    if lastKey == nil or lastKey < 0 then return 1, currentKey, "FIRST" end
    if currentKey <= lastKey then return 0, lastKey, "REJECTED" end
    local elapsed = math.floor(currentKey - lastKey)
    if elapsed <= 0 then return 0, lastKey, "REJECTED" end
    return math.min(elapsed, cap), currentKey, "FORWARD"
end

local function scheduledDisposition(machineryAvailable, supportedType, acceptedTargets)
    if not machineryAvailable then return "LEGACY_FIELD_FALLBACK" end
    if supportedType and acceptedTargets > 0 then return "POSITIONAL_ACCEPTED" end
    return "POSITIONAL_REFUSED"
end

local function fieldFallbackGain(disposition, incumbentGain)
    if disposition == "LEGACY_FIELD_FALLBACK" then return incumbentGain end
    return 0
end

local function committedService(disposition, plannedHours)
    return plannedHours
end

-- GROUP P: SCS-037 OWNS THE FORWARD HOUR EDGE AND SCS-023 OWNS ACTUAL
-- PER-FIELD SCHEDULED DELIVERY. SDS v2.1 sections 4 and 5.2.
do
    local hours, baseline, status = forwardHourEdge(40, 43, 168)
    T.eq("P1 forward hour edge supplies the exact elapsed span", hours, 3)
    T.eq("P2 forward hour edge advances its baseline", baseline, 43)
    T.eq("P3 forward hour edge is explicit", status, "FORWARD")

    hours, baseline, status = forwardHourEdge(40, 39, 168)
    T.eq("P4 backward hour edge supplies no moisture work", hours, 0)
    T.eq("P5 backward hour edge retains the prior forward baseline", baseline, 40)
    T.eq("P6 backward hour edge is rejected before the provider", status, "REJECTED")

    hours, baseline, status = forwardHourEdge(40, 40.5, 168)
    T.eq("P6a fractional sub-hour input supplies no whole hourly work", hours, 0)
    T.eq("P6b fractional sub-hour input retains the prior frontier", baseline, 40)

    local accepted = scheduledDisposition(true, true, 4)
    local refused = scheduledDisposition(true, false, 0)
    local legacy = scheduledDisposition(false, true, 0)
    T.eq("P7 actual target acceptance selects positional delivery", accepted, "POSITIONAL_ACCEPTED")
    T.eq("P8 unsupported or empty coverage is explicit refusal", refused, "POSITIONAL_REFUSED")
    T.eq("P9 unavailable positional machinery selects incumbent fallback", legacy, "LEGACY_FIELD_FALLBACK")
    T.eq("P10 accepted positional field suppresses only its own fallback",
        fieldFallbackGain(accepted, 0.02), 0)
    T.eq("P11 refused positional coverage invents no field-wide fallback",
        fieldFallbackGain(refused, 0.02), 0)
    T.near("P12 unavailable machinery preserves incumbent field-wide fallback",
        fieldFallbackGain(legacy, 0.02), 0.02, 1e-12)
    T.eq("P13 scheduled refusal still commits the immutable planned service",
        committedService(refused, 2), 2)
    T.eq("P14 accepted targets commit the same planned service once",
        committedService(accepted, 2), 2)
    T.eq("P15 coverage refusal never reallocates a peer's planned share",
        committedService(accepted, 2), committedService(refused, 2))
    T.eq("P16 legacy fallback still commits the represented scheduled service",
        committedService(legacy, 2), 2)
end

T.summary()

