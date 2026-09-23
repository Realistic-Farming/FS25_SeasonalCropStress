-- scs041_parcel_union_raster_test.lua
-- SCS-041 owner-ratified field-boundary correction, the native-map half (Iris's
-- Design return of 2026-09-09, section 2): on a parcel of several cultivated
-- polygons, paint, additive delta, the derived mean, the relief seed and the daily
-- drainage act on the SET UNION of covered provider cells. Each cell once, the gaps
-- never, and the mean is the sum over the unique written cells divided by their
-- count, never an average of polygon averages. The engine is the F245 pixel-grid
-- harness under the REAL CropStressValueMap; the union work set is a second grid
-- the real map builds through the harness's createBitVectorMap.
--
-- THE ENTRY-POINT BAR IS GROUP E (and D): the real field enumeration from
-- g_fieldManager (two engine fields sharing farmland 1), the real geometry
-- collector, and production's own doors: seedMapFromStore, hourlyUpdate,
-- refreshForPublication, setMoisture (the csSetMoisture and sprayer door) and
-- settleDaily. Nothing seeds _fieldVerts, a pixel, a block or a mean by hand.
--
-- Groups:
--   R  the union ops on the real map: once per cell, the gap, the example mean,
--      one polygon unchanged, refusals, a stale work set, a thrown add
--   E  the entry-point bar over a two-field parcel
--   D  relief and drainage per polygon on a sloped parcel
--!load: src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua

local SQ = F245H.square
local DEF = CropStressValueMap.LAYER_DEF
local UPR = CropStressValueMap._unitsPerRaw(DEF)
local rawOf = F245H.rawOf
local function decode(r) return CropStressValueMap._decode(r, DEF) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The harness pixel whose centre is (wx, wz).
local function key(grid, wx, wz)
    local half = grid.size / 2
    return (wx + half - 0.5) * grid.size + (wz + half - 0.5) + 1
end
local function raw(grid, wx, wz) return grid.raw[key(grid, wx, wz)] or 0 end

local function pointInPoly(px, pz, p)
    local inside, j = false, p.n
    for i = 1, p.n do
        if ((p.vz[i] > pz) ~= (p.vz[j] > pz)) and
           (px < (p.vx[j] - p.vx[i]) * (pz - p.vz[i]) / (p.vz[j] - p.vz[i]) + p.vx[i]) then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- Every pixel centre inside any polygon of the collection, once.
local function unionCells(grid, polys)
    local out, half = {}, grid.size / 2
    for px = 0, grid.size - 1 do
        for pz = 0, grid.size - 1 do
            local wx, wz = px - half + 0.5, pz - half + 0.5
            for pi = 1, #polys do
                if pointInPoly(wx, wz, polys[pi]) then
                    out[#out + 1] = { wx = wx, wz = wz }
                    break
                end
            end
        end
    end
    return out
end

--- The mean of the decoded values over the written cells of the union.
local function unionMean(grid, polys)
    local sum, n = 0, 0
    for _, c in ipairs(unionCells(grid, polys)) do
        local r = raw(grid, c.wx, c.wz)
        if r > 0 then sum = sum + decode(r); n = n + 1 end
    end
    if n == 0 then return nil end
    return sum / n
end

local function maskOnes(vm)
    local n = 0
    if vm.maskBvm ~= nil then
        for _, v in pairs(vm.maskBvm.raw) do if v == 1 then n = n + 1 end end
    end
    return n
end

local A = SQ(0, 0, 10, 10)      -- 100 cells, centres 0.5..9.5
local B = SQ(8, 0, 18, 10)      -- 100 cells; overlaps A on x 8..10, the 20 cells at 8.5 and 9.5
local C = SQ(20, 0, 30, 10)     -- 100 cells; the deed gap 10..20 lies between A and C

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE UNION OPS ON THE REAL MAP
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local vm, grid = F245H.newValueMap(64)
    local ok = vm:paintPolygons({ A, B }, 0.5)
    T.eq("R1 painting a two-polygon parcel is accepted", ok, true)
    T.eq("R2 and covers the union once: 100 + 100 - 20 cells at the value", F245H.count(grid, rawOf(0.5)), 180)
    T.eq("R3 with one native set over the union, not one per polygon", vm.modifier.calls.set, 1)
    T.eq("R4 the work set is released afterwards", maskOnes(vm), 0)
    local moved = vm:applyDeltaToPolygons({ A, B }, 3 * UPR)
    T.near("R5 a whole-step delta over the parcel reports what it applied", moved, 3 * UPR, 1e-12)
    T.eq("R6 an A-only, an overlap and a B-only cell all moved by exactly three steps",
        (raw(grid, 1.5, 5.5) - rawOf(0.5)) .. ":" .. (raw(grid, 8.5, 5.5) - rawOf(0.5)) .. ":" .. (raw(grid, 15.5, 5.5) - rawOf(0.5)), "3:3:3")
    T.eq("R7 every union cell moved, none twice", F245H.count(grid, rawOf(0.5) + 3), 180)
    T.eq("R8 the work set is released after the delta too", maskOnes(vm), 0)

    -- The Design return's example: A covers cells 1 and 2, B covers 2 and 3, with
    -- values 0.2, 0.4 and 0.9. Q also holds an unwritten fourth cell.
    local vm2, grid2 = F245H.newValueMap(64)
    local P, Q = SQ(0, 0, 2, 1), SQ(1, 0, 4, 1)
    F245H.paint(grid2, 0, 0, 1, 1, rawOf(0.2))
    F245H.paint(grid2, 1, 0, 2, 1, rawOf(0.4))
    F245H.paint(grid2, 2, 0, 3, 1, rawOf(0.9))
    local outcome, mean = vm2:readAverageOfPolygons({ P, Q })
    T.eq("R9 the union mean is OK", outcome, "OK")
    T.near("R10 and is the sum over the three unique cells divided by three, 0.5", mean, 0.5, 0.004)
    T.ok("R11 never the average of the two polygon averages, 0.475", math.abs(mean - 0.475) > 0.01)
    T.ok("R12 and the unwritten fourth cell of the union is no sample (0.375 if it were)", math.abs(mean - 0.375) > 0.01)
    T.eq("R13 the work set is released after the read", maskOnes(vm2), 0)

    local vm3, grid3 = F245H.newValueMap(64)
    T.eq("R14 a one-polygon parcel paints through the one-polygon op and builds no work set",
        tostring(vm3:paintPolygons({ A }, 0.5)) .. ":" .. F245H.count(grid3, rawOf(0.5)) .. ":" .. tostring(vm3.maskBvm), "true:100:nil")

    local bad = { vx = { 0, 1 }, vz = { 0, 1 }, n = 2 }
    local vm4, grid4 = F245H.newValueMap(64)
    T.eq("R15 a malformed polygon in the collection refuses paint, delta and read, writing nothing",
        tostring(vm4:paintPolygons({ A, bad }, 0.5)) .. ":" .. tostring(vm4:applyDeltaToPolygons({ A, bad }, 3 * UPR))
        .. ":" .. tostring((vm4:readAverageOfPolygons({ A, bad }))) .. ":" .. F245H.count(grid4), "false:0:INVALID_FIELD_GEOMETRY:0")

    local savedCreate = createBitVectorMap
    createBitVectorMap = function() return nil end
    local vm5, grid5 = F245H.newValueMap(64)
    T.eq("R16 with no work set on this engine a two-polygon parcel refuses and paints nothing, never its first field",
        tostring(vm5:paintPolygons({ A, B }, 0.5)) .. ":" .. tostring((vm5:readAverageOfPolygons({ A, B }))) .. ":" .. F245H.count(grid5), "false:PROVIDER_REFUSAL:0")
    createBitVectorMap = savedCreate

    local vm6, grid6 = F245H.newValueMap(64)
    vm6:paintPolygons({ A, C }, 0.5)
    T.eq("R17 the deed gap between two fields is never painted", F245H.count(grid6, rawOf(0.5)) .. ":" .. raw(grid6, 15.5, 5.5), "200:0")
    -- Two more fields west of the origin, with a stale work-set cell in the gap between them.
    local W1, W2 = SQ(-30, 0, -20, 10), SQ(-10, 0, 0, 10)
    vm6.maskBvm.raw[key(grid6, -15.5, 5.5)] = 1
    vm6:paintPolygons({ W1, W2 }, 0.7)
    T.eq("R18 a stale work-set cell inside the next parcel's box is cleared before that parcel is painted",
        raw(grid6, -15.5, 5.5) .. ":" .. F245H.count(grid6, rawOf(0.7)), "0:200")

    local vm7 = F245H.newValueMap(64)
    vm7:paintPolygons({ A, B }, 0.5)
    vm7.modifier.executeAdd = function() error("fake executeAdd threw") end
    T.eq("R19 a thrown union add applies nothing, disables the add path and releases the work set",
        tostring(vm7:applyDeltaToPolygons({ A, B }, 3 * UPR)) .. ":" .. tostring(vm7.hasExecuteAdd) .. ":" .. maskOnes(vm7), "0:false:0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: a two-field parcel through production's own doors
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    g_fieldManager = { fields = { F245H.engineField(1, A), F245H.engineField(1, B) } }
    g_server = {}
    local sys, vm, grid = F245H.newSystem({ ready = false })
    local n = sys:enumerateFields()
    T.eq("E1 [reached] the real enumeration keyed one parcel from two engine fields",
        n .. ":" .. tostring(sys.fieldData[1] ~= nil) .. ":" .. tostring(sys.fieldData[2]), "1:true:nil")
    T.eq("E2 [reached] the real collector retained both cultivated polygons", #sys:_getFieldPolygons(1), 2)
    local seeded = sys:seedMapFromStore()
    T.eq("E3 seedMapFromStore paints the union once and never the deed gap",
        seeded .. ":" .. F245H.count(grid) .. ":" .. raw(grid, 19.5, 5.5), "1:180:0")

    local before = raw(grid, 1.5, 5.5)
    -- 0.05 of rain on loamy ground is twelve raw steps: enough to move, inside
    -- the written range (a delta that would push a cell past the top is filtered
    -- out by the one-polygon rule the union keeps).
    local weather = setmetatable({
        getHourlyEvapMultiplier = function() return 0 end,
        getHourlyRainAmount = function() return 0.05 end,
    }, { __index = function() return function() return 0 end end })
    sys:hourlyUpdate(weather, 1)
    local a, o, b = raw(grid, 1.5, 5.5), raw(grid, 8.5, 5.5), raw(grid, 15.5, 5.5)
    T.ok("E4 the hourly rain reached the map as whole raw steps", a > before)
    T.eq("E5 an A-only, an overlap and a B-only cell rose by the same steps: the overlap never twice",
        (a - before) .. ":" .. (o - before) .. ":" .. (b - before), string.format("%d:%d:%d", a - before, a - before, a - before))

    F245H.paint(grid, 10, 0, 18, 10, rawOf(0.9))
    sys.fieldData[1].aggregateDirty = true
    sys:refreshForPublication()
    local expected = unionMean(grid, { A, B })
    local avgOfAvgs = (unionMean(grid, { A }) + unionMean(grid, { B })) / 2
    T.near("E6 refreshForPublication publishes the mean over the unique union cells", sys.fieldData[1].moisture, expected, 1e-9)
    T.ok("E7 never the average of the two field averages", math.abs(sys.fieldData[1].moisture - avgOfAvgs) > 1e-3)

    local receipt = sys:setMoisture(1, 0.3)
    T.eq("E8 setMoisture repaints the whole parcel once and leaves the gap",
        tostring(receipt) .. ":" .. F245H.count(grid, rawOf(0.3)) .. ":" .. raw(grid, 19.5, 5.5), "true:180:0")

    F245H.paint(grid, 10, 0, 18, 10, rawOf(0.9))
    sys:settleDaily(1)
    T.near("E9 settleDaily re-derives the scalar over the unique union cells", sys.fieldData[1].moisture, unionMean(grid, { A, B }), 1e-9)
    g_fieldManager = nil
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. RELIEF AND DRAINAGE PER POLYGON ON A SLOPED PARCEL
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    -- A3 spans x -60..-8; C3 spans x -30..6 and overlaps A3 on x -30..-8. The
    -- ground is 20 m high west of x -40 and 8 m elsewhere.
    local A3 = SQ(-60, -60, -8, -24)
    local C3 = SQ(-30, -60, 6, -24)
    g_fieldManager = { fields = { F245H.engineField(1, A3), F245H.engineField(1, C3) } }
    g_server = {}
    local savedNode, savedHeight = g_terrainNode, getTerrainHeightAtWorldPos
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function(_node, x, _y, _z) if x < -40 then return 20 end return 8 end
    local sys, vm, grid = F245H.newSystem({ ready = false, size = 128 })
    sys:enumerateFields()

    -- The relief seed: one 8 m block grid over the union's box, 8 columns (x -56
    -- to 0) by 4 rows, each block sampled once whichever polygons hold it, and one
    -- mean height (11 m) over all 32; every offset is non-zero, so 32 writes.
    local setsBefore = vm.modifier.calls.set
    sys:seedMapFromStore()
    T.eq("D1 the relief seed samples the union's 32 blocks once: one paint plus 32 relief writes",
        vm.modifier.calls.set - setsBefore, 33)

    -- Flatten, then drain: 16 m blocks. A3 holds 3 columns by 2 rows; C3's block
    -- column at x -22 lies inside A3 and is sampled by A3 only, so C3 keeps the
    -- one column at x -6: 8 blocks for the parcel.
    -- Each block writes a 16 m square around its centre; the pixels read below sit
    -- inside one block's square and no other's.
    sys:setMoisture(1, 0.5)
    local high, low, flat = raw(grid, -51.5, -51.5), raw(grid, -35.5, -51.5), raw(grid, -5.5, -51.5)
    sys:settleDaily(1)
    T.eq("D2 the parcel drained polygon by polygon, each block centre sampled once", sys._lastFieldBlocks, 8)
    T.ok("D3 inside A3 the high ground gave and the low ground gained",
        raw(grid, -51.5, -51.5) < high and raw(grid, -35.5, -51.5) > low)
    T.eq("D4 and no water crossed into C3, which is flat and keeps its own level", raw(grid, -5.5, -51.5), flat)

    getTerrainHeightAtWorldPos = savedHeight
    g_terrainNode = savedNode
    g_fieldManager = nil
end)
