-- f245_harness.lua: RSF-F245/F247 bench harness. Loaded through --!load after
-- src/maps/CropStressValueMap.lua and before the files under test.
--
-- A PIXEL-GRID ENGINE under the REAL CropStressValueMap: a fake density-map
-- modifier and filter over a raw-value grid, 1 m per pixel, world -size/2..size/2.
--   * The filter implements the real compare types (EQUAL, BETWEEN, NOTEQUAL) over
--     each pixel's raw value, so hasWrittenPixels and fillUnwrittenPolygon run their
--     own code against real filtered counts.
--   * executeGet(filter) returns (accumulator, count, count) over the pixels whose
--     centre lies inside the bound polygon (even-odd) and match the filter.
--   * An UNFILTERED executeGet counts WRITTEN pixels only (raw > 0). What the native
--     unfiltered count means is NOT DETERMINABLE (F250 item 3); this model is chosen
--     so readAverageOfPolygon keeps its EMPTY meaning. F247's decisions never use it.
--   * An UNFILTERED executeSet writes every pixel in the region; a filtered one only
--     matching pixels. executeAdd shifts matching pixels.
--   * Call counters (get / getFiltered / getUnfiltered / set / add) let a row assert
--     how many native probes ran. A hook(kind, index, filter) can make a call throw,
--     return nil, or (for set) write nothing.
--
-- ITERATION ORDER: fengari's pairs() is insertion ordered, so the bench cannot show
-- hash-order nondeterminism. Rows that depend on order insert out of order.

F245H = F245H or {}

DensityValueCompareType = DensityValueCompareType
    or { EQUAL = "EQUAL", BETWEEN = "BETWEEN", NOTEQUAL = "NOTEQUAL" }
DensityMapFilter = DensityMapFilter or { new = function() return F245H.newFilter() end }
g_server = g_server or {}

-- UInt16 stream stubs (the prelude has none); same typed-FIFO shape.
function streamWriteUInt16(s, v) s.q[#s.q + 1] = { t = "u16", v = v } end
function streamReadUInt16(s)
    local e = s.q[s.r]
    if e == nil then s.underflows = s.underflows + 1; return nil end
    s.r = s.r + 1
    if e.t ~= "u16" then s.typeErrors = s.typeErrors + 1 end
    return e.v
end

local function pointInPoly(px, pz, xs, zs)
    local inside, j, n = false, #xs, #xs
    for i = 1, n do
        if ((zs[i] > pz) ~= (zs[j] > pz)) and
           (px < (xs[j] - xs[i]) * (pz - zs[i]) / (zs[j] - zs[i]) + xs[i]) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function F245H.newFilter()
    local f = { type = nil, a = nil, b = nil }
    function f:setValueCompareParams(t, a, b) self.type, self.a, self.b = t, a, b end
    return f
end

local function filterMatches(f, r)
    if f.type == "EQUAL" then return r == f.a end
    if f.type == "BETWEEN" then return r >= f.a and r <= f.b end
    if f.type == "NOTEQUAL" then return r ~= f.a end
    error("fake filter: no compare values set")
end

function F245H.newModifier(grid)
    local m = { grid = grid, xs = nil, zs = nil, rect = nil, hook = nil,
        calls = { get = 0, getFiltered = 0, getUnfiltered = 0, set = 0, add = 0, bind = 0 } }
    function m:clearPolygonPoints() self.xs, self.zs, self.rect = {}, {}, nil; self.calls.bind = self.calls.bind + 1 end
    function m:addPolygonPointWorldCoords(x, z) self.xs[#self.xs + 1] = x; self.zs[#self.zs + 1] = z end
    function m:setParallelogramWorldCoords(x0, z0, x1, _z1, _x2, z2) self.rect = { x0, z0, x1, z2 }; self.xs = nil end
    local function eachPixel(self, fn)
        local size = self.grid.size
        local half = size / 2
        for px = 0, size - 1 do
            for pz = 0, size - 1 do
                local wx, wz = px - half + 0.5, pz - half + 0.5
                local inside
                if self.rect ~= nil then
                    inside = wx >= self.rect[1] and wx <= self.rect[3] and wz >= self.rect[2] and wz <= self.rect[4]
                else
                    inside = self.xs ~= nil and #self.xs >= 3 and pointInPoly(wx, wz, self.xs, self.zs)
                end
                if inside then fn(px * size + pz + 1) end
            end
        end
    end
    local function action(self, kind, idx, filter)
        if self.hook ~= nil then return self.hook(kind, idx, filter) end
        return nil
    end
    function m:executeGet(filter)
        self.calls.get = self.calls.get + 1
        if filter ~= nil then self.calls.getFiltered = self.calls.getFiltered + 1
        else self.calls.getUnfiltered = self.calls.getUnfiltered + 1 end
        local a = action(self, "get", self.calls.get, filter)
        if a == "throw" then error("fake executeGet threw") end
        if a == "nil" then return nil, nil, nil end
        local acc, n = 0, 0
        eachPixel(self, function(k)
            local r = self.grid.raw[k] or 0
            local hit
            if filter ~= nil then hit = filterMatches(filter, r) else hit = r > 0 end
            if hit then acc = acc + r; n = n + 1 end
        end)
        return acc, n, n
    end
    function m:executeSet(value, filter)
        self.calls.set = self.calls.set + 1
        local a = action(self, "set", self.calls.set, filter)
        if a == "throw" then error("fake executeSet threw") end
        if a == "noop" then return end
        eachPixel(self, function(k)
            local r = self.grid.raw[k] or 0
            if filter == nil or filterMatches(filter, r) then self.grid.raw[k] = value end
        end)
    end
    function m:executeAdd(delta, filter)
        self.calls.add = self.calls.add + 1
        eachPixel(self, function(k)
            local r = self.grid.raw[k] or 0
            if filter == nil or filterMatches(filter, r) then
                self.grid.raw[k] = math.max(0, math.min(255, r + delta))
            end
        end)
    end
    return m
end

function getBitVectorMapPoint(bvm, px, pz, _c0, _n)
    return bvm.raw[px * bvm.size + pz + 1] or 0
end

--- A live value map over a fresh grid. Returns vm, grid.
function F245H.newValueMap(size)
    size = size or 64
    local grid = { size = size, raw = {} }
    local vm = CropStressValueMap.new()
    vm.initialized, vm.available = true, true
    vm.bvm = grid
    vm.resolution, vm.computedResolution, vm.toolWidth, vm.terrainSize = size, size, size, size
    vm.modifier = F245H.newModifier(grid)
    vm.filter = F245H.newFilter()
    return vm, grid
end

--- Write raw value `raw` to every pixel whose centre lies in [x0,x1] x [z0,z1].
function F245H.paint(grid, x0, z0, x1, z1, raw)
    local half = grid.size / 2
    local n = 0
    for px = 0, grid.size - 1 do
        for pz = 0, grid.size - 1 do
            local wx, wz = px - half + 0.5, pz - half + 0.5
            if wx >= x0 and wx <= x1 and wz >= z0 and wz <= z1 then
                grid.raw[px * grid.size + pz + 1] = raw
                n = n + 1
            end
        end
    end
    return n
end

--- Count written (raw > 0) pixels, optionally only those equal to `raw`.
function F245H.count(grid, raw)
    local n = 0
    for _, r in pairs(grid.raw) do
        if (raw == nil and r > 0) or (raw ~= nil and r == raw) then n = n + 1 end
    end
    return n
end

function F245H.square(x0, z0, x1, z1)
    return { vx = { x0, x1, x1, x0 }, vz = { z0, z0, z1, z1 }, n = 4 }
end

--- A TRUTH soil system on a live pixel map. opts: ready (default true), carrier
--- (default "SELECTED_PAIR"; pass false for none), size.
function F245H.newSystem(opts)
    opts = opts or {}
    local mgr = { ready = opts.ready ~= false, published = {} }
    function mgr:isMissionWaterReady() return self.ready end
    mgr.eventBus = { publish = function(name, data) mgr.published[#mgr.published + 1] = { name = name, data = data } end }
    local sys = SoilMoistureSystem.new(mgr)
    sys.isInitialized = true
    local vm, grid = F245H.newValueMap(opts.size or 64)
    sys.valueMap = vm
    sys.providerMode = "TRUTH"
    if opts.carrier == false then sys._carrierRecord = nil else sys._carrierRecord = opts.carrier or "SELECTED_PAIR" end
    return sys, vm, grid, mgr
end

--- A tracked field with a cached single-polygon outline.
function F245H.addField(sys, fid, poly, moisture)
    sys.fieldData[fid] = {
        fieldId = fid, moisture = moisture, soilType = "loamy",
        cells = {}, cellSum = 0, cellCount = 0,
        aggregateState = "CURRENT", aggregateDirty = true,
        centerX = (poly.vx[1] + poly.vx[3]) * 0.5, centerZ = (poly.vz[1] + poly.vz[3]) * 0.5,
    }
    if poly ~= nil then
        sys._fieldVerts[fid] = { vx = poly.vx, vz = poly.vz, n = poly.n }
    end
    return sys.fieldData[fid]
end

--- Raw value the map encodes for a moisture value.
function F245H.rawOf(value)
    local def = CropStressValueMap.LAYER_DEF
    local fraction = (value - def.minVal) / (def.maxVal - def.minVal)
    return CropStressValueMap.RAW_MIN + math.floor(fraction * (CropStressValueMap.RAW_MAX - CropStressValueMap.RAW_MIN) + 0.5)
end

--- Engine field objects for the collection tests. Nodes are tables {x, z, throw};
--- getWorldTranslation reads them.
function getWorldTranslation(node)
    if type(node) == "table" then
        if node.throw then error("fake node threw") end
        return node.x, 0, node.z
    end
    return 0, 0, 0
end

function F245H.engineField(farmlandId, poly, opts)
    opts = opts or {}
    local pts = {}
    if poly ~= nil then
        for i = 1, poly.n do pts[i] = { x = poly.vx[i], z = poly.vz[i] } end
    end
    local f = { farmland = { id = farmlandId }, polygonPoints = pts }
    if opts.engine ~= nil then
        local list = opts.engine
        local dmp = { getVerticesList = function() return list end }
        if opts.getter == false then
            f.densityMapPolygon = dmp
        else
            function f:getDensityMapPolygon() return dmp end
        end
    end
    return f
end
