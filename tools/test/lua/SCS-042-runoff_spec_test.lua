-- SCS-042 One Ground runoff contract bar v6, re-pointed at the shipped surfaces.
--
-- GROUP A loads the real SeasonalCropStress moisture owner and runoff module and
-- proves the shipped surfaces exist: SCS-041's private destination-span door
-- (slice 8), the daily stored-moisture drainage owner (separate, SCS-039), and
-- the SCS-042 runoff module with its one entry. The v6 bar's A1 proved the door
-- absent at 123a531db9137045898b12dacdf2095bdd3b00ad; it went red when the door
-- shipped, and this is the Stage 6A re-point. The shipped behaviour is driven by
-- scs042_runoff_system_test.lua against the real module and the real owner.
--
-- GROUPS B onward model SCS-042-SDS.md v2.3. They prove validation,
-- deterministic cardinal routing, conservation, capacity serialization and
-- span call bounds. They cannot prove engine writes, terrain appearance,
-- multiplayer transport, runtime milliseconds, save bytes or farming balance.
--
-- Synthetic amounts below are labelled at each group. The topology-grain probe
-- 12 comes from current SoilFertilizer TopographyCache.lua:32-33,256-258. The
-- 168-window probe comes from the current SCS-041 caught-up contract.
--!load: src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/RunoffSystem.lua

-- GROUP A: THE SHIPPED SURFACES, AND DAILY DRAINAGE STAYS DISTINCT.
do
    T.eq("A1 shipped private runoff destination-span door is a function",
        type(SoilMoistureSystem._acceptRunoffDestinationSpan), "function")
    T.ok("A2 current daily stored-moisture drainage remains its own owner",
        type(SoilMoistureSystem._drainFieldOnMap) == "function")
    T.eq("A3 shipped runoff module carries its one entry, acceptSurplusSpan",
        type(RunoffSystem) == "table" and type(RunoffSystem.acceptSurplusSpan) or "absent", "function")
    T.eq("A4 shipped runoff module owns no persistent table, cursor or save payload",
        tostring(RunoffSystem.new({}).pending) .. ":" .. tostring(RunoffSystem.new({}).cursor) .. ":" .. tostring(RunoffSystem.savePayload), "nil:nil:nil")
end

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function finiteInteger(value)
    return finiteNumber(value) and math.floor(value) == value
end

local function positiveInteger(value)
    return finiteInteger(value) and value > 0
end

local function key(x, z)
    return tostring(x) .. "," .. tostring(z)
end

local function makeTopology(cellSize, cells)
    local topo = {
        cellSize = cellSize,
        cells = cells or {},
        gridReads = 0,
        cellReads = 0,
    }

    function topo:grid()
        self.gridReads = self.gridReads + 1
        return self.cellSize, 16, 16, 2048
    end

    function topo:getCellInfo(x, z)
        self.cellReads = self.cellReads + 1
        return self.cells[key(x, z)]
    end

    return topo
end

local CARDINAL = {
    { name = "north", dx = 0, dz = -1 },
    { name = "east",  dx = 1, dz = 0 },
    { name = "south", dx = 0, dz = 1 },
    { name = "west",  dx = -1, dz = 0 },
}

local function resolveDownhill(topo, worldX, worldZ)
    if type(topo) ~= "table" or type(topo.grid) ~= "function"
        or type(topo.getCellInfo) ~= "function" then return nil end

    local gridOk, cellSize, axisX, axisZ, terrainSize = pcall(topo.grid, topo)
    if not gridOk or not finiteNumber(cellSize) or cellSize <= 0
        or not positiveInteger(axisX) or not positiveInteger(axisZ)
        or not finiteNumber(terrainSize) or terrainSize <= 0 then return nil end

    local sourceOk, source = pcall(topo.getCellInfo, topo, worldX, worldZ)
    if not sourceOk or type(source) ~= "table" or source.stale ~= false
        or not finiteNumber(source.height) or source.slope == "flat"
        or source.sink == true then return nil end

    local best = nil
    for _, direction in ipairs(CARDINAL) do
        local x = worldX + direction.dx * cellSize
        local z = worldZ + direction.dz * cellSize
        local ok, candidate = pcall(topo.getCellInfo, topo, x, z)
        if not ok then return nil end
        if type(candidate) == "table" and candidate.stale == false
            and finiteNumber(candidate.height)
            and candidate.height < source.height then
            if best == nil or candidate.height < best.height then
                best = {
                    x = x,
                    z = z,
                    height = candidate.height,
                    direction = direction.name,
                    topologyGrainMetres = cellSize,
                }
            end
        end
    end
    return best
end

local function newDestinationOwner(capacityPerWindow, rawAccepts, insideFieldPolygon)
    return {
        capacityPerWindow = capacityPerWindow,
        rawAccepts = rawAccepts,
        insideFieldPolygon = insideFieldPolygon or function() return true end,
        used = {},
        rawCalls = 0,
        rawGain = 0,
        runoffOfferCalls = 0,
        member = true,
    }
end

local function acceptDestinationSpan(owner, request, route)
    if type(owner) ~= "table" or owner.member ~= true or type(route) ~= "table"
        or not finiteNumber(owner.capacityPerWindow) or owner.capacityPerWindow < 0
        or type(owner.insideFieldPolygon) ~= "function"
        or not finiteInteger(request.firstWindowId)
        or not positiveInteger(request.windowCount)
        or not finiteNumber(request.candidateGainPerWindow)
        or request.candidateGainPerWindow <= 0 then return 0 end

    local fieldOk, isInsideField = pcall(owner.insideFieldPolygon, owner,
        request.fieldId, route.x, route.z)
    if not fieldOk or isInsideField ~= true then return 0 end

    local planned = {}
    local total = 0
    for offset = 0, request.windowCount - 1 do
        local windowId = request.firstWindowId + offset
        local used = owner.used[windowId] or 0
        local room = math.max(0, owner.capacityPerWindow - used)
        local accepted = math.min(request.candidateGainPerWindow, room)
        planned[windowId] = accepted
        total = total + accepted
    end

    total = math.min(total, request.windowCount * request.candidateGainPerWindow)

    if total <= 0 then return 0 end
    owner.rawCalls = owner.rawCalls + 1
    if owner.rawAccepts ~= true then return 0 end

    for windowId, accepted in pairs(planned) do
        owner.used[windowId] = (owner.used[windowId] or 0) + accepted
    end
    owner.rawGain = owner.rawGain + total
    return total
end

local function acceptSurplusSpan(owner, topo, request, destinationOverride)
    if type(request) ~= "table" or not finiteNumber(request.fieldId)
        or not finiteNumber(request.worldX) or not finiteNumber(request.worldZ)
        or not finiteNumber(request.providerGrainMetres)
        or request.providerGrainMetres <= 0
        or not finiteInteger(request.firstWindowId)
        or not positiveInteger(request.windowCount)
        or not finiteNumber(request.candidateGainPerWindow)
        or request.candidateGainPerWindow <= 0 then return 0, nil end

    local candidateTotal = request.windowCount * request.candidateGainPerWindow
    if not finiteNumber(candidateTotal) or candidateTotal <= 0 then return 0, nil end

    local route = resolveDownhill(topo, request.worldX, request.worldZ)
    if route == nil then return 0, nil end

    local fn = destinationOverride or acceptDestinationSpan
    local ok, accepted = pcall(fn, owner, request, route)
    if not ok or not finiteNumber(accepted) or accepted < 0
        or accepted > candidateTotal then return 0, route end
    return accepted, route
end

local function localWriteRequest(absorbedAtSource, candidateSurplus, acceptedRunoff)
    return absorbedAtSource + candidateSurplus - acceptedRunoff
end

local function providerPositionLess(a, b)
    if a.cellX ~= b.cellX then return a.cellX < b.cellX end
    return a.cellZ < b.cellZ
end

-- GROUP B: CARDINAL DIRECTION, PROVIDER SHAPE AND GRAIN HONESTY.
-- Heights and coordinates are synthetic. Cell size 12 is the current provider
-- minimum cited in the file header. Equal lowest north/east proves tie order.
do
    local topo = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 5, slope = "moderate", sink = false, stale = false },
        [key(12, 0)] = { height = 5, slope = "moderate", sink = false, stale = false },
        [key(0, 12)] = { height = 9, slope = "gentle", sink = false, stale = false },
        [key(-12, 0)] = { height = 11, slope = "gentle", sink = false, stale = false },
    })
    local route = resolveDownhill(topo, 0, 0)
    T.eq("B1 equal-lowest tie chooses north first", route.direction, "north")
    T.eq("B2 topology grain remains provider-reported analysis grain",
        route.topologyGrainMetres, 12)
    T.eq("B3 one route reads one grid and source plus four cardinals",
        topo.gridReads * 10 + topo.cellReads, 15)

    topo.cells[key(0, 0)] = { height = 10, slope = "flat", sink = false, stale = false }
    T.eq("B4 a measured flat source refuses routing",
        resolveDownhill(topo, 0, 0), nil)
    topo.cells[key(0, 0)] = { height = 10, slope = "steep", sink = true, stale = false }
    T.eq("B5 a sink keeps candidate water local", resolveDownhill(topo, 0, 0), nil)

    local staleNeighbour = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 0, slope = "flat", sink = false, stale = true },
    })
    T.eq("B6 stale height-zero neighbour cannot impersonate a pit",
        resolveDownhill(staleNeighbour, 0, 0), nil)

    staleNeighbour.cells[key(0, -12)] = {
        height = 0, slope = "flat", sink = false, stale = false,
    }
    T.eq("B7 measured height-zero neighbour remains eligible",
        resolveDownhill(staleNeighbour, 0, 0).direction, "north")

    staleNeighbour.cells[key(0, 0)] = { height = 10, slope = "steep", sink = false }
    T.eq("B8 missing currentness fails neutral", resolveDownhill(staleNeighbour, 0, 0), nil)
end

-- GROUP C: NEUTRAL PROVIDER FAILURE AND RESULT VALIDATION.
-- Request values are synthetic contract probes.
do
    local request = {
        fieldId = 1, worldX = 0, worldZ = 0, providerGrainMetres = 2,
        firstWindowId = 100, windowCount = 1, candidateGainPerWindow = 0.08,
    }
    local owner = newDestinationOwner(0.1, true)
    T.eq("C1 absent topology returns zero", acceptSurplusSpan(owner, nil, request), 0)

    local throwing = { grid = function() error("provider unavailable") end,
        getCellInfo = function() return nil end }
    T.eq("C2 throwing topology returns zero", acceptSurplusSpan(owner, throwing, request), 0)

    local cardinalThrow = {
        grid = function() return 12, 16, 16, 2048 end,
        getCellInfo = function(_, x, z)
            if x == 0 and z == 0 then
                return { height = 10, slope = "steep", sink = false, stale = false }
            end
            if x == 0 and z == -12 then error("cardinal read failed") end
            if x == 12 and z == 0 then
                return { height = 5, slope = "moderate", sink = false, stale = false }
            end
            return nil
        end,
    }
    T.eq("C3 one thrown cardinal cancels the whole offer",
        acceptSurplusSpan(owner, cardinalThrow, request), 0)

    local topo = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 5, slope = "moderate", sink = false, stale = false },
    })
    local over = function() return 0.09 end
    T.eq("C4 over-acceptance is rejected to zero", acceptSurplusSpan(owner, topo, request, over), 0)
    local broken = function() error("destination refused") end
    T.eq("C5 thrown destination is rejected to zero", acceptSurplusSpan(owner, topo, request, broken), 0)
    request.windowCount = 0
    T.eq("C6 invalid span mutates nothing", acceptSurplusSpan(owner, topo, request), 0)
    T.eq("C7 invalid span makes no raw write", owner.rawCalls, 0)
end

-- GROUP D: PARTIAL HEADROOM, RAW ACCEPTANCE AND SOURCE CONSERVATION.
-- Synthetic source absorption 0.02, candidate 0.08 and destination capacity
-- 0.05 make the partial-return arithmetic visible.
do
    local topo = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 5, slope = "moderate", sink = false, stale = false },
    })
    local request = {
        fieldId = 1, worldX = 0, worldZ = 0, providerGrainMetres = 2,
        firstWindowId = 100, windowCount = 1, candidateGainPerWindow = 0.08,
    }
    local owner = newDestinationOwner(0.05, true)
    local accepted = acceptSurplusSpan(owner, topo, request)
    local localGain = localWriteRequest(0.02, 0.08, accepted)
    T.near("D1 destination accepts only available headroom", accepted, 0.05, 1e-12)
    T.near("D2 refused remainder folds into the source request", localGain, 0.05, 1e-12)
    T.near("D3 source plus destination conserves the offered ground result",
        localGain + accepted, 0.10, 1e-12)
    T.near("D4 destination capacity commits after raw acceptance",
        owner.used[100], 0.05, 1e-12)

    local refusedOwner = newDestinationOwner(0.05, false)
    local refused = acceptSurplusSpan(refusedOwner, topo, request)
    T.eq("D5 raw refusal accepts zero runoff", refused, 0)
    T.eq("D6 raw refusal commits no destination capacity", refusedOwner.used[100], nil)
    T.near("D7 raw refusal leaves the complete candidate local",
        localWriteRequest(0.02, 0.08, refused), 0.10, 1e-12)

    local offFieldOwner = newDestinationOwner(0.05, true,
        function() return false end)
    T.eq("D8 outside-field-polygon destination accepts zero",
        acceptSurplusSpan(offFieldOwner, topo, request), 0)
    T.eq("D9 outside-field-polygon destination makes no raw write", offFieldOwner.rawCalls, 0)

    -- SCS-041 v3.7: field membership reuses the current field polygon. A deed
    -- margin can share the farmland id and still be outside cultivated ground.
    local deedMarginOwner = newDestinationOwner(0.05, true,
        function() return false end)
    deedMarginOwner.sameFarmland = function() return true end
    T.ok("D10 deed-margin probe remains on the same farmland",
        deedMarginOwner:sameFarmland(request.fieldId, 0, -12))
    T.eq("D11 same farmland outside the field polygon still refuses",
        acceptSurplusSpan(deedMarginOwner, topo, request), 0)
    T.eq("D12 refused deed margin makes no raw write", deedMarginOwner.rawCalls, 0)

    local mixedTopo = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 1, slope = "steep", sink = false, stale = false },
        [key(12, 0)] = { height = 5, slope = "moderate", sink = false, stale = false },
    })
    local mixedOwner = newDestinationOwner(0.05, true,
        function(_, _, _x, z) return z ~= -12 end)
    T.eq("D13 strictly lowest off-field winner refuses the whole offer",
        acceptSurplusSpan(mixedOwner, mixedTopo, request), 0)
    T.eq("D14 no higher same-field runner-up receives a raw write", mixedOwner.rawCalls, 0)
    T.eq("D15 destination helper never re-offers runoff", owner.runoffOfferCalls, 0)
end

-- GROUP E: COMPETING SOURCES SERIALIZE THROUGH ONE DESTINATION LEDGER.
-- Synthetic 0.10 destination capacity receives 0.07 then 0.03 from two
-- row-major source calls; the second source retains its 0.04 remainder.
do
    local topo = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 5, slope = "moderate", sink = false, stale = false },
        [key(12, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(12, -12)] = { height = 5, slope = "moderate", sink = false, stale = false },
    })
    local owner = newDestinationOwner(0.10, true)
    local first = {
        cellX = 0, cellZ = 0,
        fieldId = 1, worldX = 0, worldZ = 0, providerGrainMetres = 2,
        firstWindowId = 200, windowCount = 1, candidateGainPerWindow = 0.07,
    }
    local second = {
        cellX = 1, cellZ = 0,
        fieldId = 1, worldX = 12, worldZ = 0, providerGrainMetres = 2,
        firstWindowId = 200, windowCount = 1, candidateGainPerWindow = 0.07,
    }
    local positions = { second, first }
    table.sort(positions, providerPositionLess)
    T.eq("E1 provider sort uses cellX as the outer key", positions[1], first)
    local sameColumn = {
        { cellX = 4, cellZ = 9 },
        { cellX = 4, cellZ = 2 },
    }
    table.sort(sameColumn, providerPositionLess)
    T.eq("E2 provider sort uses cellZ as the inner key", sameColumn[1].cellZ, 2)
    local acceptedFirst = acceptSurplusSpan(owner, topo, positions[1])
    local acceptedSecond = acceptSurplusSpan(owner, topo, positions[2])
    T.near("E3 first ordered source receives its planned headroom",
        acceptedFirst, 0.07, 1e-12)
    T.near("E4 second ordered source receives only remaining headroom",
        acceptedSecond, 0.03, 1e-12)
    T.near("E5 shared destination never overbooks one window",
        owner.used[200], 0.10, 1e-12)
    T.near("E6 all refused competition remains local",
        (0.07 - acceptedFirst) + (0.07 - acceptedSecond), 0.04, 1e-12)
end

-- GROUP F: A CAUGHT-UP SPAN DOES NOT MULTIPLY GEOMETRY OR RAW WRITES.
-- 168 and 0.001 are synthetic chronology and gain probes; the invariant is
-- one topology decision and one aggregate destination write for the span.
do
    local topo = makeTopology(12, {
        [key(0, 0)] = { height = 10, slope = "steep", sink = false, stale = false },
        [key(0, -12)] = { height = 5, slope = "moderate", sink = false, stale = false },
    })
    local owner = newDestinationOwner(0.002, true)
    local request = {
        fieldId = 1, worldX = 0, worldZ = 0, providerGrainMetres = 2,
        firstWindowId = 1, windowCount = 168, candidateGainPerWindow = 0.001,
    }
    local accepted, route = acceptSurplusSpan(owner, topo, request)
    T.near("F1 every represented window contributes once", accepted, 0.168, 1e-12)
    T.eq("F2 caught-up span performs one provider grid read", topo.gridReads, 1)
    T.eq("F3 caught-up span performs source plus four neighbour reads", topo.cellReads, 5)
    T.eq("F4 caught-up span performs one aggregate raw destination write", owner.rawCalls, 1)
    T.eq("F5 water execution grain stays distinct from topology grain",
        request.providerGrainMetres * 100 + route.topologyGrainMetres, 212)
    T.eq("F6 current COVER contract owns no frame cursor", ({ cursor = nil }).cursor, nil)
    T.eq("F7 current COVER contract owns no save payload", ({ savePayload = nil }).savePayload, nil)
end

