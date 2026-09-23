-- scs042_runoff_system_test.lua
-- SCS-042 One-Hop Runoff (brief v1.1, owner-ratified field-boundary correction
-- 2026-09-05): the REAL module, the REAL SCS-041 seam and destination helper and
-- the REAL manager construction. The certified bar (SCS-042-runoff_spec_test.lua)
-- models the contract with its own functions; this file drives the shipped code
-- from where production enters it.
--
-- THE ENTRY-POINT BAR IS GROUP E: CropStressManager.new() constructs the runoff
-- sibling beside the moisture owner (the registration path); the parcel comes from
-- the real field enumeration over g_fieldManager; water enters through the public
-- controlled-water door applyWaterAtCell; the offer, the route, the fence and the
-- destination write are the shipped code's own. The only stand-ins are the world:
-- SoilFertilizer's topology (shaped on TopographyCache's grid() and getCellInfo(),
-- TopographyCache.lua:260-262 and :362-380, stale on its default :50-56), the
-- mission handle, and the manager's unrelated subsystems (weather, HUD, consultant,
-- NPC, finance, stress), which the constructor builds and this bar never reads.
-- Group P drives the SCS-023 coverage act through the real
-- IrrigationManager:applyGainToSystemCoverage. Nothing seeds a route, a capacity
-- row, a write or a cell list by hand.
--
-- Groups:
--   E  the entry-point bar: one hop, conservation, a full destination, the fence,
--      no Soil, stale, flat, sink, a thrown cardinal, a client, teardown
--   V  the shipped route and entry validated directly
--   P  the parcel's provider cells: once each, cellX then cellZ, through the act
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/SaveLoadHandler.lua, src/CropStressManager.lua

local SQ = F245H.square

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
    g_server = { broadcastEvent = function() end }
end

-- The manager's unrelated subsystems: the constructor builds them, this bar never
-- reads them. Each answers delete and initialize; the weather double answers what
-- the hourly path asks, which this bar does not run.
local function stubClass(extra)
    return { new = function()
        local o = { delete = function() end, initialize = function() end }
        for k, v in pairs(extra or {}) do o[k] = v end
        return o
    end }
end
WeatherIntegration = WeatherIntegration or stubClass({
    getHourlyEvapMultiplier = function() return 1 end,
    getHourlyRainAmount = function() return 0 end,
})
CropStressModifier = CropStressModifier or stubClass()
HUDOverlay = HUDOverlay or stubClass()
CropConsultant = CropConsultant or stubClass()
NPCIntegration = NPCIntegration or stubClass()
FinanceIntegration = FinanceIntegration or stubClass()
CropStressSettings = CropStressSettings or { new = function() return {} end }

g_server = { broadcastEvent = function() end }
g_currentMission = {
    time = 1000,
    environment = { currentHour = 5, currentMonotonicDay = 3, currentDay = 3, daysPerPeriod = 1 },
    missionInfo = {},
}

--- SoilFertilizer's topology, shaped on TopographyCache: grid() answers the cell
--- size and axes, getCellInfo answers a measured cell or the shaped stale default.
local function topology(cells)
    local t = { cells = cells or {}, gridReads = 0, cellReads = 0 }
    function t:grid() self.gridReads = self.gridReads + 1; return 12, 16, 16, 2048 end
    function t:getCellInfo(x, z)
        self.cellReads = self.cellReads + 1
        local c = self.cells[string.format("%d,%d", x, z)]
        if c == "throw" then error("cardinal read failed") end
        if c == nil then return { height = 0, slope = "flat", sink = false, waterDist = nil, stale = true } end
        return c
    end
    return t
end
local function measured(h, slope, sink)
    return { height = h, slope = slope or "steep", sink = sink == true, waterDist = 10, stale = false }
end

-- One farmland, two cultivated fields touching at x = 40.
local P1, P2 = SQ(0, 0, 40, 40), SQ(40, 0, 80, 40)

--- The world: the real manager over the real parcel, CAPPED absorption, ZONE
--- provider, and a spy on the raw door that records every write and passes it on.
local function newWorld(cells, fields)
    g_fieldManager = { fields = fields or { F245H.engineField(1, P1), F245H.engineField(1, P2) } }
    local topo = cells and topology(cells) or nil
    g_currentMission.soilFertilityManager = topo and { topography = topo } or nil
    local mgr = CropStressManager.new()
    local soil = mgr.soilSystem
    soil.isInitialized = true
    soil.providerMode = "ZONE"
    soil.valueMap = nil
    soil._cellSize = 10
    soil.absorptionMode = "CAPPED"
    soil.agronomyRestriction = 1.0
    soil:enumerateFields()
    local writes = {}
    local realRaw = soil._applyRawWaterAtCell
    soil._applyRawWaterAtCell = function(self, fid, x, z, lw)
        writes[#writes + 1] = { fid = fid, x = x, z = z, gain = lw }
        return realRaw(self, fid, x, z, lw)
    end
    return mgr, soil, writes, topo
end

local function writesFrom(writes, from)
    local out = {}
    for i = (from or 0) + 1, #writes do
        local w = writes[i]
        out[#out + 1] = string.format("%d:%d:%d:%.4f", w.fid, w.x, w.z, w.gain)
    end
    return table.concat(out, ";")
end
local function totalFrom(writes, from)
    local t = 0
    for i = (from or 0) + 1, #writes do t = t + writes[i].gain end
    return t
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    -- Source (20,20) at 10 m, steep; north (20,8) at 5 m is the lowest neighbour.
    local cells = {
        ["20,20"] = measured(10), ["20,8"] = measured(5), ["32,20"] = measured(9),
        ["20,32"] = measured(11), ["8,20"] = measured(12),
    }
    local mgr, soil, writes, topo = newWorld(cells)
    T.eq("E1 [reached] CropStressManager.new built the runoff sibling beside the moisture owner",
        type(mgr.runoffSystem) == "table" and mgr.runoffSystem.manager == mgr and soil ~= nil, true)
    T.eq("E2 [reached] the real enumeration keyed the parcel from two engine fields", #soil:_getFieldPolygons(1), 2)
    local ok = soil:applyWaterAtCell(1, 20, 20, 0.05)
    T.eq("E3 the controlled-water door accepted the request", ok, true)
    T.eq("E4 the lowest neighbour took its own hourly capacity (0.018), the source kept its capacity plus the refused remainder",
        writesFrom(writes), "1:20:8:0.0180;1:20:20:0.0320")
    T.near("E5 nothing disappeared and nothing travelled twice: source plus destination is the request", totalFrom(writes), 0.05, 1e-12)
    T.eq("E6 one offer reads the grid once and the source plus four cardinals", topo.gridReads .. ":" .. topo.cellReads, "1:5")
    T.eq("E7 the destination helper never offers runoff again (one offer, one route, one hop)",
        mgr.runoffSystem.stats.offers .. ":" .. mgr.runoffSystem.stats.routed, "1:1")

    local n1 = #writes
    soil:applyWaterAtCell(1, 20, 20, 0.05)
    T.eq("E8 the same source again in the window: the destination is full, the whole candidate stays local in one write",
        writesFrom(writes, n1), "1:20:20:0.0500")

    -- The fence: a source in the second field whose lowest neighbour lies in the first.
    cells["46,20"] = measured(10); cells["34,20"] = measured(2)
    cells["46,8"] = measured(9); cells["58,20"] = measured(9); cells["46,32"] = measured(9)
    local n2 = #writes
    soil:applyWaterAtCell(1, 46, 20, 0.05)
    T.eq("E9 a shared farmland is not permission to cross: the lowest neighbour in the other field refuses the whole offer, no runner-up, all local",
        writesFrom(writes, n2), "1:46:20:0.0500")

    -- No SoilFertilizer at all: the offer stays local.
    g_currentMission.soilFertilityManager = nil
    local n3 = #writes
    soil:applyWaterAtCell(1, 20, 32, 0.05)
    T.eq("E10 with no Soil topology the water stays at its source", writesFrom(writes, n3), "1:20:32:0.0500")
    g_currentMission.soilFertilityManager = { topography = topo }

    -- Stale, flat and sink sources, each through the door.
    cells["8,8"] = { height = 0, slope = "flat", sink = false, waterDist = nil, stale = true }; cells["8,-4"] = measured(-5)
    local n4 = #writes
    soil:applyWaterAtCell(1, 8, 8, 0.05)
    T.eq("E11 a stale source (the shaped default) routes nowhere", writesFrom(writes, n4), "1:8:8:0.0500")
    cells["8,32"] = measured(10, "flat"); cells["8,20"] = measured(1)
    local n5 = #writes
    soil:applyWaterAtCell(1, 8, 32, 0.05)
    T.eq("E12 a measured flat source routes nowhere", writesFrom(writes, n5), "1:8:32:0.0500")
    cells["32,32"] = measured(10, "steep", true); cells["32,20"] = measured(1)
    local n6 = #writes
    soil:applyWaterAtCell(1, 32, 32, 0.05)
    T.eq("E13 a sink keeps its water", writesFrom(writes, n6), "1:32:32:0.0500")
    cells["32,8"] = measured(10); cells["32,-4"] = "throw"; cells["44,8"] = measured(1)
    local n7 = #writes
    soil:applyWaterAtCell(1, 32, 8, 0.05)
    T.eq("E14 one thrown cardinal read refuses the whole offer, even with a lower neighbour elsewhere", writesFrom(writes, n7), "1:32:8:0.0500")

    -- A pure client has no server: the entry answers zero before any read.
    local reads = topo.cellReads
    g_server = nil
    T.eq("E15 on a client the entry answers zero and reads nothing",
        mgr.runoffSystem:acceptSurplusSpan(1, 20, 20, 2, 77, 1, 0.03) .. ":" .. (topo.cellReads - reads), "0:0")
    g_server = { broadcastEvent = function() end }

    mgr:delete()
    T.eq("E16 teardown clears the local runoff object", mgr.runoffSystem, nil)
    g_fieldManager = nil
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE SHIPPED ROUTE AND ENTRY, DIRECTLY
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local R = RunoffSystem.resolveDownhill
    local topo = topology({
        ["0,0"] = measured(10), ["0,-12"] = measured(5, "moderate"), ["12,0"] = measured(5, "moderate"),
        ["0,12"] = measured(9, "gentle"), ["-12,0"] = measured(11, "gentle"),
    })
    local route = R(topo, 0, 0)
    T.eq("V1 equal-lowest north and east: north first, the read order decides", route.direction .. ":" .. route.x .. ":" .. route.z, "north:0:-12")
    T.eq("V2 the route carries the topology grain, never the provider grain", route.topologyGrainMetres, 12)
    topo.cells["0,-12"] = measured(12); topo.cells["12,0"] = measured(12); topo.cells["0,12"] = measured(12); topo.cells["-12,0"] = measured(12)
    local none, why = R(topo, 0, 0)
    T.eq("V3 with every neighbour higher there is no route", tostring(none) .. ":" .. tostring(why), "nil:NO_LOWER_NEIGHBOUR")
    topo.cells["0,-12"] = { height = 0, slope = "flat", sink = false, stale = true }
    T.eq("V4 a stale height-zero neighbour cannot impersonate a pit", (R(topo, 0, 0)), nil)
    topo.cells["0,-12"] = measured(0, "flat")
    T.eq("V5 a measured height-zero neighbour is eligible", R(topo, 0, 0).direction, "north")
    topo.cells["0,0"] = { height = 10, slope = "steep", sink = false }
    local n2, why2 = R(topo, 0, 0)
    T.eq("V6 a source without explicit currentness fails neutral", tostring(n2) .. ":" .. tostring(why2), "nil:SOURCE_STALE")
    T.eq("V7 a topology whose grid throws routes nowhere",
        select(2, R({ grid = function() error("provider unavailable") end, getCellInfo = function() return nil end }, 0, 0)), "NO_GRID")
    -- One thrown cardinal read cancels the whole offer (section 4): the other three are
    -- lower, and none of them may be taken.
    local cardinalThrow = topology({ ["0,0"] = measured(10), ["12,0"] = measured(5, "moderate"), ["0,12"] = measured(5, "moderate"), ["-12,0"] = measured(5, "moderate") })
    local realGet = cardinalThrow.getCellInfo
    cardinalThrow.getCellInfo = function(self, x, z) if x == 0 and z == -12 then error("cardinal read failed") end return realGet(self, x, z) end
    local nT, whyT = R(cardinalThrow, 0, 0)
    T.eq("V7b one thrown cardinal cancels the whole offer, the three lower ones included", tostring(nT) .. ":" .. tostring(whyT), "nil:CARDINAL_THREW")
    -- A grid that answers but with nothing usable (a zero cell size, zero axes, zero
    -- terrain) is no grid: nothing is routed on a made-up size.
    local badGrid = topology({ ["0,0"] = measured(10), ["0,-12"] = measured(5, "moderate") })
    badGrid.grid = function() return 0, 0, 0, 0 end
    local nG, whyG = R(badGrid, 0, 0)
    T.eq("V7c a grid that answers nothing usable routes nowhere, with the grid's own reason", tostring(nG) .. ":" .. tostring(whyG), "nil:NO_GRID")
    T.eq("V8 no topology routes nowhere", select(2, R(nil, 0, 0)), "NO_TOPOLOGY")

    -- The entry's validation and its answer checks, with a spied destination helper.
    local calls = {}
    local mgr = { answer = 0 }
    mgr.soilSystem = { _acceptRunoffDestinationSpan = function(_self, fid, dx, dz, grain, first, count, gain, sx, sz)
        calls[#calls + 1] = { dx = dx, dz = dz, sx = sx, sz = sz }
        return mgr.answer
    end }
    local rs = RunoffSystem.new(mgr)
    g_currentMission.soilFertilityManager = { topography = topology({ ["0,0"] = measured(10), ["0,-12"] = measured(5) }) }
    mgr.answer = 0.04
    T.near("V9 a valid span routes and returns the helper's answer", rs:acceptSurplusSpan(1, 0, 0, 2, 100, 1, 0.08), 0.04, 1e-12)
    T.eq("V10 the helper receives the ONE chosen destination and the retained SOURCE position",
        calls[1].dx .. ":" .. calls[1].dz .. ":" .. calls[1].sx .. ":" .. calls[1].sz, "0:-12:0:0")
    mgr.answer = 0.09
    T.eq("V11 over-acceptance beyond the candidate total is rejected to zero", rs:acceptSurplusSpan(1, 0, 0, 2, 100, 1, 0.08), 0)
    mgr.answer = -0.01
    T.eq("V12 a negative answer is rejected to zero", rs:acceptSurplusSpan(1, 0, 0, 2, 100, 1, 0.08), 0)
    local invalidBefore = rs.stats.refused.DESTINATION_INVALID or 0
    mgr.soilSystem._acceptRunoffDestinationSpan = function() error("destination refused") end
    T.eq("V13 a thrown destination is zero and counted as invalid, like the over-acceptance and the negative answer before it",
        rs:acceptSurplusSpan(1, 0, 0, 2, 100, 1, 0.08) .. ":" .. (rs.stats.refused.DESTINATION_INVALID - invalidBefore) .. ":" .. invalidBefore, "0:1:2")
    local before = #calls
    T.eq("V14 an invalid span (zero windows, negative gain, non-integer window, missing coordinate) is zero and reaches no helper",
        rs:acceptSurplusSpan(1, 0, 0, 2, 100, 0, 0.08) + rs:acceptSurplusSpan(1, 0, 0, 2, 100, 1, -1)
        + rs:acceptSurplusSpan(1, 0, 0, 2, 100.5, 1, 0.08) + rs:acceptSurplusSpan(1, nil, 0, 2, 100, 1, 0.08) .. ":" .. (#calls - before), "0:0")
    g_currentMission.soilFertilityManager = nil
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PARCEL'S PROVIDER CELLS THROUGH THE COVERAGE ACT (SCS-023 COVER)
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    -- Q2 listed first, so the raw enumeration is out of order, and Q2 overlaps Q1 on
    -- x 30..40 so the column of cells centred at x 35 is reached from both fields.
    local Q1, Q2 = SQ(0, 0, 40, 40), SQ(30, 0, 80, 40)
    local mgr, soil, writes = newWorld(nil, { F245H.engineField(1, Q2), F245H.engineField(1, Q1) })
    local im = mgr.irrigationManager
    local cells = im:_parcelCells(1, 10)
    T.eq("P1 the parcel's provider cells: 4x4 from Q1, 5x4 from Q2, the 4 shared ones once: 32", #cells, 32)
    local sorted, first = true, cells[1].cellX .. ":" .. cells[1].cellZ
    for i = 2, #cells do
        local a, b = cells[i - 1], cells[i]
        if a.cellX > b.cellX or (a.cellX == b.cellX and a.cellZ >= b.cellZ) then sorted = false end
    end
    T.eq("P2 sorted by cellX ascending then cellZ ascending, starting at the first cell", tostring(sorted) .. ":" .. first, "true:0:0")

    -- A parcel whose raw enumeration is UNSORTED whichever field the engine lists first: a
    -- second field BELOW the first at the same columns, so the cell walk (x then z within
    -- a polygon) leaves the second field's lower rows after the first field's higher ones.
    -- Read through production's own helpers, in the engine's order, then through the sort.
    do
        local Q3, Q4 = SQ(0, 0, 40, 40), SQ(0, -40, 40, 0)
        local mgr2 = newWorld(nil, { F245H.engineField(1, Q3), F245H.engineField(1, Q4) })
        local im2 = mgr2.irrigationManager
        local raw = {}
        for _, field in ipairs(im2:_fieldsForId(1)) do
            local vx, vz, n = im2:getFieldPolygonWorld(field)
            for _, e in ipairs(im2:_cellsInPolygon(vx, vz, n, 10)) do raw[#raw + 1] = e end
        end
        local rawSorted = true
        for i = 2, #raw do
            local a, b = raw[i - 1], raw[i]
            if a.cellX > b.cellX or (a.cellX == b.cellX and a.cellZ >= b.cellZ) then rawSorted = false end
        end
        local cells2 = im2:_parcelCells(1, 10)
        local sorted2 = true
        for i = 2, #cells2 do
            local a, b = cells2[i - 1], cells2[i]
            if a.cellX > b.cellX or (a.cellX == b.cellX and a.cellZ >= b.cellZ) then sorted2 = false end
        end
        T.eq("P2b [world] two stacked fields enumerate unsorted in the engine's order (32 cells, the lower field's rows after the upper's), and the parcel order sorts them, starting at the lowest row of the first column",
            #raw .. ":" .. tostring(rawSorted) .. "/" .. #cells2 .. ":" .. tostring(sorted2) .. ":" .. cells2[1].cellX .. ":" .. cells2[1].cellZ, "32:false/32:true:0:-4")
    end

    -- The coverage act: a pivot over the whole parcel, the plain raw door, one write per cell.
    g_farmlandManager = { farmlandMapping = { [1] = 1 } }
    soil.absorptionMode = "UNCAPPED"
    local n0 = #writes
    local evidence = im:applyGainToSystemCoverage({ ownerFarmId = 1, coveredFields = { 1 }, x = 40, z = 20, radius = 500, type = "pivot" }, 0.001)
    local ordered = true
    for i = n0 + 2, #writes do
        local a, b = writes[i - 1], writes[i]
        if a.x > b.x or (a.x == b.x and a.z >= b.z) then ordered = false end
    end
    T.eq("P3 the act writes each provider cell once, in that order", (#writes - n0) .. ":" .. tostring(evidence.fields[1]) .. ":" .. tostring(ordered), "32:ACCEPTED:true")
    g_farmlandManager = nil
    g_fieldManager = nil
    mgr:delete()
end)
