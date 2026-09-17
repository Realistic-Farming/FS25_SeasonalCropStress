--!load: src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/SaveLoadHandler.lua
-- RSF-F245 v0.7 items 1-4 and the host rules of item 6 on the pixel-grid engine.
-- Groups: E enumeration dirty (Bob's named row), H refresh outcomes, G aggregate
-- helpers, R getMoisture, P publication refresh, S map seed and marking pass,
-- W write paths, U hourly update, L sorted list, D daily settle, K unpackCells.
-- Every "no number" row asserts the readAverageOfPolygon call count. Each group
-- runs under pcall so a Lua error fails one named row.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server = {}
    g_fieldManager = nil
    g_currentMission.time = 1000
    g_currentMission.environment = { currentDay = 1, daysPerPeriod = 1 }
end

local SQ = F245H.square(-8, -8, 8, 8)       -- 256 pixels
local SQ2 = F245H.square(12, -8, 20, 8)     -- 128 pixels

--- Count readAverageOfPolygon calls on a live value map.
local function countReads(vm)
    local box = { n = 0 }
    local real = vm.readAverageOfPolygon
    vm.readAverageOfPolygon = function(self, ...) box.n = box.n + 1; return real(self, ...) end
    return box
end

local function state(d)
    return tostring(d.aggregateState) .. ":" .. tostring(d.aggregateUnavailableReason)
end

-- =====================================================================
-- E: enumerateFields creates every record dirty (Bob intake finding 2)
-- =====================================================================
group("E enumeration dirty", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    vm.loadedFromSave = true
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.82))
    local field = F245H.engineField(1, SQ)
    field.posX, field.posZ = 0, 0
    g_fieldManager = { fields = { field } }
    g_currentMission.environment = { currentDay = 1, currentSeason = 0, daysPerPeriod = 1 }
    sys:enumerateFields()
    local d = sys.fieldData[1]
    T.near("E1a [reached: the record starts at the season start]", d.moisture, 0.60, 1e-9)
    T.eq("E1b enumerateFields creates the record explicitly dirty", d.aggregateDirty, true)
    sys:seedMapFromStore()
    T.eq("E1c [a field with no saved row is left unmarked]", sys._mapSeeded[1], nil)
    local reads = countReads(vm)
    sys:refreshForPublication()
    T.near("E1d NAMED (Bob): a field created over a map loaded from its own save reads its real ground at the first door",
        d.moisture, 0.82, 0.005)
    T.eq("E1e [one polygon read]", reads.n, 1)
    T.eq("E1f clean after the read", d.aggregateDirty, false)

    -- nil dirty is clean at every door (certified contract model)
    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.4)
    d.aggregateDirty = nil
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.82))
    reads = countReads(vm)
    sys:refreshForPublication()
    sys:_refreshFieldAggregate(1, d)
    T.eq("E2a nil dirty: neither the publication walk nor the refresh reads", reads.n, 0)
    T.near("E2b the slot is untouched", d.moisture, 0.4, 1e-12)

    -- Design a2ae501 item 2: BOTH doors, for an unpainted and a painted new field.
    local function enumerated(paintValue)
        local s, v, g = F245H.newSystem({ ready = false })
        v.loadedFromSave = true
        if paintValue ~= nil then F245H.paint(g, -8, -8, 8, 8, F245H.rawOf(paintValue)) end
        local f = F245H.engineField(1, SQ)
        f.posX, f.posZ = 0, 0
        g_fieldManager = { fields = { f } }
        g_currentMission.environment = { currentDay = 1, currentSeason = 0, daysPerPeriod = 1 }
        s:enumerateFields()
        s:seedMapFromStore()
        return s, v, g, s.fieldData[1]
    end
    sys, vm, grid, d = enumerated(nil)
    reads = countReads(vm)
    sys:refreshForPublication()
    T.eq("E3a NAMED (Design): the publication door never keeps an unpainted new field's enumeration number as current",
        tostring(d.moisture) .. ":" .. state(d), "nil:UNAVAILABLE:EMPTY")
    T.eq("E3b [the door reached the native read]", reads.n, 1)

    sys, vm, grid, d = enumerated(nil)
    reads = countReads(vm)
    local env = SaveLoadHandler.new({ soilSystem = sys }):captureMoistureEnvelope()
    T.eq("E4a NAMED (Design): the capture door never saves an unpainted new field's enumeration number", env.aggregates[1], nil)
    T.eq("E4b [the capture reached the native read]", reads.n, 1)

    sys, vm, grid, d = enumerated(0.82)
    env = SaveLoadHandler.new({ soilSystem = sys }):captureMoistureEnvelope()
    T.near("E4c NAMED (Design): the capture door saves a painted new field's real ground", env.aggregates[1], 0.82, 0.005)
end)

-- =====================================================================
-- H: _refreshFieldAggregate typed outcomes (item 3)
-- =====================================================================
group("H refresh outcomes", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    local d = F245H.addField(sys, 1, SQ, 0.5)
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.3))
    local reads = countReads(vm)
    sys:_refreshFieldAggregate(1, d)
    T.near("H1a OK with a mean: the slot holds it", d.moisture, 0.3, 0.005)
    T.eq("H1b current, no reason", state(d), "CURRENT:nil")
    T.eq("H1c clean", d.aggregateDirty, false)
    T.eq("H1d [one read]", reads.n, 1)

    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.5)
    reads = countReads(vm)
    local rev = sys.moistureRevision
    sys:_refreshFieldAggregate(1, d)
    T.eq("H2a EMPTY: unavailable EMPTY", state(d), "UNAVAILABLE:EMPTY")
    T.eq("H2b the current slot is empty, never the old value", d.moisture, nil)
    T.near("H2c the old value is memory only", d.moistureLastKnown, 0.5, 1e-12)
    T.eq("H2d stays dirty so the next door reads again", d.aggregateDirty, true)
    T.eq("H2e [one read]", reads.n, 1)
    sys:_refreshFieldAggregate(1, d)
    T.eq("H2f a second EMPTY read keeps the last-known value", d.moistureLastKnown, 0.5)
    T.eq("H2g [two reads: dirty kept the door open]", reads.n, 2)

    -- recovery only by a later OK numeric; pixels arriving move no revision
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.44))
    T.eq("H3a [reached: pixels gained, revision unchanged]", sys.moistureRevision, rev)
    sys:refreshForPublication()
    T.eq("H3b a blank dirty field that gains pixels is current at the next door", state(d), "CURRENT:nil")
    T.near("H3c at what reads back", d.moisture, 0.44, 0.005)
    T.eq("H3d last-known cleared", d.moistureLastKnown, nil)

    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.5)
    local okNil = 0
    vm.readAverageOfPolygon = function() okNil = okNil + 1; return "OK", nil end
    sys:_refreshFieldAggregate(1, d)
    T.eq("H4a OK with no mean: unavailable EMPTY", state(d), "UNAVAILABLE:EMPTY")
    T.eq("H4b [one read]", okNil, 1)

    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.5)
    sys._fieldVerts[1] = { n = 0, refusedAt = g_currentMission.time }
    reads = countReads(vm)
    sys:_refreshFieldAggregate(1, d)
    T.eq("H5a no geometry: unavailable INVALID_FIELD_GEOMETRY", state(d), "UNAVAILABLE:INVALID_FIELD_GEOMETRY")
    T.eq("H5b [no read]", reads.n, 0)
    T.eq("H5c dirty", d.aggregateDirty, true)

    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.5)
    vm.readAverageOfPolygon = function() return "PROVIDER_REFUSAL", nil, nil end
    sys:_refreshFieldAggregate(1, d)
    T.eq("H6a a refusal fails the provider closed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("H6b and never keeps the old scalar as current", tostring(d.moisture) .. ":" .. state(d), "nil:UNAVAILABLE:PROVIDER_REFUSAL")
    T.eq("H6c the old value is memory only", d.moistureLastKnown, 0.5)

    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.5)
    local walks = 0
    sys._getFieldVerts = function() walks = walks + 1; return SQ.vx, SQ.vz, SQ.n end
    vm.readAverageOfPolygon = false             -- a provider with no typed polygon read
    sys:_refreshFieldAggregate(1, d)
    T.eq("H7a NAMED (Design a2ae501, Bob finding 3): a provider with no typed read is a capability refusal", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("H7b not EMPTY or INVALID_FIELD_GEOMETRY, and never the old scalar as current", tostring(d.moisture) .. ":" .. state(d), "nil:UNAVAILABLE:PROVIDER_REFUSAL")
    T.eq("H7c tested before any geometry", walks, 0)
    T.eq("H7d getMoisture answers nothing afterwards", (sys:getMoisture(1)), nil)

    -- Bob #192 MAJOR (model :97): call site b fires only on EMPTY. Ready, carrier
    -- recorded, blank outline: only the read's outcome differs between rows.
    local function probed(readFn)
        local s, v = F245H.newSystem()
        local fd = F245H.addField(s, 1, SQ, 0.5)
        s._probes = 0
        local realProbe = s._parcelHasWrittenPixels
        s._parcelHasWrittenPixels = function(self, id) self._probes = self._probes + 1; return realProbe(self, id) end
        if readFn ~= nil then v.readAverageOfPolygon = readFn end
        return s, v, fd
    end
    sys, vm, d = probed(nil)
    sys:_refreshFieldAggregate(1, d)
    T.eq("H8a [reached: an EMPTY read on the same fixture probes and seeds]", tostring(sys._probes) .. ":" .. tostring(vm.modifier.calls.set > 0), "1:true")
    sys, vm, d = probed(function() return "OK", nil end)
    sys:_refreshFieldAggregate(1, d)
    T.eq("H8b [OK with no mean is unavailable EMPTY]", state(d), "UNAVAILABLE:EMPTY")
    T.eq("H8c NAMED (Bob #192 MAJOR): OK with no mean runs no ground-check probe", sys._probes, 0)
    T.eq("H8d and no fill", vm.modifier.calls.set, 0)
    T.eq("H8e and no decision", sys._groundChecked[1], nil)
    sys, vm, d = probed(function() return "SOMETHING_ELSE", nil end)
    sys:_refreshFieldAggregate(1, d)
    T.eq("H8f an unknown outcome runs no probe either", tostring(sys._probes) .. ":" .. state(d), "0:UNAVAILABLE:EMPTY")
end)

-- =====================================================================
-- G: aggregate helpers (item 2)
-- =====================================================================
group("G aggregate helpers", function()
    local sys = F245H.newSystem({ ready = false })
    local d = F245H.addField(sys, 1, SQ, 0.5)
    d.cells = { [0] = { [0] = { moisture = 0.9 } } }
    d.cellCount, d.cellSum = 1, 0.9
    T.eq("G1 map active, current: the slot, never the retained cell mean", sys:getFieldAggregate(d), 0.5)
    sys:_markAggregateUnavailable(d, "EMPTY")
    T.eq("G2 map active, unavailable: nil, never the cell mean", sys:getFieldAggregate(d), nil)
    T.eq("G3 _currentAggregate is nil while unavailable", sys:_currentAggregate(d), nil)

    local z = SoilMoistureSystem.new({})
    z.providerMode = "ZONE"
    local zd = F245H.addField(z, 1, SQ, 0.5)
    zd.cells = { [0] = { [0] = { moisture = 0.9 }, [1] = { moisture = 0.7 } } }
    zd.cellCount, zd.cellSum = 2, 1.6
    T.near("G4a ZONE: the cell mean", z:getFieldAggregate(zd), 0.8, 1e-12)
    zd.cellCount, zd.cellSum, zd.cells = 0, 0, {}
    T.eq("G4b ZONE with no cells: the scalar", z:getFieldAggregate(zd), 0.5)
    z:_markAggregateUnavailable(zd, "NO_CURRENT_VALUE")
    T.eq("G4c ZONE, unavailable: _currentAggregate is nil", z:_currentAggregate(zd), nil)

    local e = { cellCount = 0, cellSum = 0 }
    T.eq("G5a fallback with no cells and no scalar is nil", sys:_fallbackAggregate(e), nil)
    T.eq("G5b seed base with nothing known is nil, never 0.5", sys:_seedBase(e), nil)
    e.moistureLastKnown = 0.33
    T.eq("G5c seed base falls back to the last-known value", sys:_seedBase(e), 0.33)
    e.moisture = 0.41
    T.eq("G5d a scalar beats the last-known value", sys:_seedBase(e), 0.41)
    e.cells, e.cellCount, e.cellSum = { [0] = { [0] = { moisture = 0.2 } } }, 1, 0.2
    T.eq("G5e cells beat the scalar", sys:_seedBase(e), 0.2)
end)

-- =====================================================================
-- R: getMoisture while unavailable (item 3)
-- =====================================================================
group("R getMoisture", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    local d = F245H.addField(sys, 1, SQ, 0.5)
    local reads = countReads(vm)
    local v, g, rev = sys:getMoisture(1)
    T.eq("R1a TRUTH field read on a blank field answers nothing", v, nil)
    T.eq("R1b with the revision", rev, sys.moistureRevision)
    T.eq("R1c [one read]", reads.n, 1)
    v = sys:getMoisture(1, 2, 2)
    T.eq("R2a an unwritten point on an unavailable field answers nothing", v, nil)
    T.eq("R2b [a second read: still dirty]", reads.n, 2)
    F245H.paint(grid, 0, 0, 3, 3, F245H.rawOf(0.7))
    v = sys:getMoisture(1, 2, 2)
    T.near("R3 a written pixel answers its own value", v, 0.7, 0.005)
end)

-- =====================================================================
-- P: refreshForPublication (item 6)
-- =====================================================================
group("P publication refresh", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    for _, id in ipairs({ 30, 10, 20, 40 }) do F245H.addField(sys, id, SQ, 0.5) end
    sys.fieldData[40].aggregateDirty = false
    local order = {}
    local real = sys._refreshFieldAggregate
    sys._refreshFieldAggregate = function(self, id, d) order[#order + 1] = id; return real(self, id, d) end
    T.eq("P1a returns the dirty count", sys:refreshForPublication(), 3)
    T.eq("P1b dirty fields only, ascending id order", table.concat(order, ","), "10,20,30")
    sys._refreshFieldAggregate = nil

    sys.providerMode = "ZONE"
    sys.valueMap = nil
    T.eq("P2 nothing under ZONE (the map declined)", sys:refreshForPublication(), 0)

    sys, vm, grid = F245H.newSystem({ ready = false })
    F245H.addField(sys, 1, SQ, 0.5)
    F245H.addField(sys, 2, SQ2, 0.5)
    local calls = 0
    vm.readAverageOfPolygon = function() calls = calls + 1; return "PROVIDER_REFUSAL" end
    sys:refreshForPublication()
    T.eq("P3 a refusal stops the walk", calls, 1)

    -- a restored dirty field reaches publication with no getMoisture call
    sys, vm, grid = F245H.newSystem({ ready = false })
    vm.loadedFromSave = true
    local d = F245H.addField(sys, 1, SQ, 0.5)
    d.aggregateDirty = false
    sys._restoreRows[1] = { valueInstalled = true }
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.66))
    sys:seedMapFromStore()
    T.eq("P4a [reached: the marking pass left it dirty]", d.aggregateDirty, true)
    sys:refreshForPublication()
    T.near("P4b the publication walk reads the restored ground", d.moisture, 0.66, 0.005)
end)

-- =====================================================================
-- S: seedMapFromStore (item 4)
-- =====================================================================
group("S seed and marking pass", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    vm.loadedFromSave = true
    local d1 = F245H.addField(sys, 1, SQ, 0.5)
    local d2 = F245H.addField(sys, 2, SQ2, 0.6)
    local d3 = F245H.addField(sys, 3, F245H.square(-20, -20, -12, -12), 0.7)
    d1.aggregateDirty, d2.aggregateDirty, d3.aggregateDirty = false, false, false
    sys._restoreRows[1] = { valueInstalled = true }
    sys._restoreRows[2] = { valueInstalled = false }
    local paints = 0
    local realPaint = vm.paintPolygon
    vm.paintPolygon = function(self, ...) paints = paints + 1; return realPaint(self, ...) end
    local reads = countReads(vm)
    T.eq("S1a [reached: before the pass nothing is seeded]", next(sys._mapSeeded), nil)
    T.eq("S1b the marking pass paints nothing", tostring(sys:seedMapFromStore()) .. ":" .. paints, "0:0")
    T.eq("S1c and reads nothing native", reads.n + vm.modifier.calls.get + vm.modifier.calls.set, 0)
    T.eq("S1d a row with a value: seeded", sys._mapSeeded[1], true)
    T.eq("S1e current and dirty", state(d1) .. ":" .. tostring(d1.aggregateDirty), "CURRENT:nil:true")
    T.eq("S1f a row with no value: seeded", sys._mapSeeded[2], true)
    T.eq("S1g unavailable NO_CURRENT_VALUE", state(d2), "UNAVAILABLE:NO_CURRENT_VALUE")
    T.eq("S1h no row: left for the ground check", tostring(sys._mapSeeded[3]) .. ":" .. state(d3) .. ":" .. tostring(d3.aggregateDirty), "nil:CURRENT:nil:false")

    -- fresh map: bases from the fallback helper, never 0.5
    sys, vm, grid = F245H.newSystem({ ready = false })
    d1 = F245H.addField(sys, 1, SQ, 0.3)
    d2 = F245H.addField(sys, 2, SQ2, nil)
    local d4 = F245H.addField(sys, 4, F245H.square(-20, -20, -12, -12), 0.8)
    d4.cells = { [0] = { [0] = { moisture = 0.2 } } }
    d4.cellCount, d4.cellSum = 1, 0.2
    sys:seedMapFromStore()
    T.ok("S2a a field with a scalar is painted at it", F245H.count(grid, F245H.rawOf(0.3)) > 0)
    T.eq("S2b a field with no base is not painted", F245H.count(grid, F245H.rawOf(0.5)), 0)
    T.eq("S2c and has no current value", state(d2), "UNAVAILABLE:NO_CURRENT_VALUE")
    T.eq("S2d nor a seeded flag", sys._mapSeeded[2], nil)
    T.ok("S2e a field with cells takes the cell mean as base", F245H.count(grid, F245H.rawOf(0.8)) == 0)

    sys, vm, grid = F245H.newSystem({ ready = false })
    F245H.addField(sys, 1, SQ, 0.3)
    vm.available = false
    T.eq("S3 a declined map seeds nothing", sys:seedMapFromStore(), 0)
end)

-- =====================================================================
-- W: write paths
-- =====================================================================
group("W write paths", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    local d = F245H.addField(sys, 1, SQ, 0.5)
    sys._mapSeeded[1] = true
    sys:_markAggregateUnavailable(d, "EMPTY")
    local rev = sys.moistureRevision
    sys:_writeFieldMoisture(1, 0.4)
    T.eq("W1a a field write makes an unavailable field current", state(d), "CURRENT:nil")
    T.eq("W1b clean", d.aggregateDirty, false)
    T.eq("W1c revision once", sys.moistureRevision, rev + 1)

    -- positional spend onto an unwritten pixel with no current aggregate
    sys, vm, grid = F245H.newSystem({ ready = false })
    d = F245H.addField(sys, 1, SQ, 0.5)
    sys._mapSeeded[1] = true
    sys:_markAggregateUnavailable(d, "EMPTY")
    rev = sys.moistureRevision
    local sets = vm.modifier.calls.set
    T.eq("W2a [reached: the water is accepted]", sys:applyWaterAtCell(1, 2, 2, 0.02), true)
    T.eq("W2b nothing is written: no 0 is invented", F245H.count(grid), 0)
    T.eq("W2c no set", vm.modifier.calls.set, sets)
    T.eq("W2d no revision", sys.moistureRevision, rev)
    local px, pz = vm:worldToPixel(2, 2)
    T.near("W2e the full amount stays pending", sys._mapWaterPending[1][px * 4096 + pz], 0.02, 1e-12)

    -- ZONE: a new cell starts at the fallback aggregate
    local z = SoilMoistureSystem.new({})
    z.isInitialized = true
    z.providerMode = "ZONE"
    local zd = F245H.addField(z, 1, SQ, 0.4)
    z:applyWaterAtCell(1, 2, 2, 0.05)
    local cx, cz = z:worldToCell(2, 2)
    T.near("W3 ZONE: a new cell starts from the field value, never 0", zd.cells[cx][cz].moisture, 0.45, 1e-9)

    -- Bob #192 MINOR: a ZONE field with no current value makes no cell from 0.
    local z2 = SoilMoistureSystem.new({})
    z2.isInitialized = true
    z2.providerMode = "ZONE"
    local zd2 = F245H.addField(z2, 1, SQ, nil)
    z2:_markAggregateUnavailable(zd2, "NO_CURRENT_VALUE")
    local rev2 = z2.moistureRevision
    T.eq("W4a [reached: the water is accepted]", z2:applyWaterAtCell(1, 2, 2, 0.05), true)
    T.eq("W4b NAMED (Bob #192 MINOR): no ZONE cell is made from an invented 0", zd2.cellCount, 0)
    T.near("W4c the water stays field-wide pending", zd2.mapPending, 0.05, 1e-12)
    T.eq("W4d no revision", z2.moistureRevision, rev2)
    T.eq("W4e the field still has no number", zd2.moisture, nil)
end)

-- =====================================================================
-- U: hourly update (item 6 host rules)
-- =====================================================================
group("U hourly", function()
    local weather = { getHourlyEvapMultiplier = function() return 1 end, getHourlyRainAmount = function() return 0 end }
    local sys, vm, grid, mgr = F245H.newSystem({ carrier = false })
    local d1 = F245H.addField(sys, 1, SQ, 0.5)
    local d2 = F245H.addField(sys, 2, SQ2, 0.05)
    F245H.paint(grid, 12, -8, 20, 8, F245H.rawOf(0.05))
    sys._mapSeeded[2] = true   -- the barrier's fresh seed painted it (else the renumbered row applies)
    mgr.debugMode = true
    g_currentMission.environment = { currentDay = 1, currentMonotonicDay = 1, currentHour = 1, daysPerPeriod = 1 }
    sys:hourlyUpdate(weather, 1, 0)
    local upd, crit = {}, {}
    for _, e in ipairs(mgr.published) do
        if e.name == "CS_MOISTURE_UPDATED" then upd[e.data.fieldId] = e.data end
        if e.name == "CS_CRITICAL_THRESHOLD" then crit[e.data.fieldId] = e.data end
    end
    T.eq("U1a [reached: the blank field is unavailable]", state(d1), "UNAVAILABLE:EMPTY")
    T.ok("U1b an unavailable field publishes an update", upd[1] ~= nil)
    T.eq("U1c with previous and current nil", tostring(upd[1] and upd[1].previous) .. ":" .. tostring(upd[1] and upd[1].current), "nil:nil")
    T.eq("U1d and no critical event", crit[1], nil)
    T.eq("U1e no scalar is derived", d1.moisture, nil)
    T.ok("U1f [reached: a current low field does raise the critical event]", crit[2] ~= nil)
    -- debug mode is on: a debug line formatting a nil would crash this group by name.

    -- after a fail-closed, the non-map branches skip unavailable fields
    sys, vm, grid, mgr = F245H.newSystem({ carrier = false })
    d1 = F245H.addField(sys, 1, SQ, 0.5)
    d2 = F245H.addField(sys, 2, SQ2, 0.5)
    sys:_markAggregateUnavailable(d1, "EMPTY")
    sys.providerMode = "UNAVAILABLE_PENDING_RELOAD"
    sys:hourlyUpdate(weather, 1, 0)
    T.eq("U2a no scalar arithmetic on a field with no current value", d1.moisture, nil)
    T.ok("U2b [reached: a current field still dries]", type(d2.moisture) == "number" and d2.moisture < 0.5)
end)

-- =====================================================================
-- L: getFieldsSortedByMoisture (item 6)
-- =====================================================================
group("L sorted list", function()
    local z = SoilMoistureSystem.new({})
    z.providerMode = "ZONE"
    for _, row in ipairs({ { 3, 0.4 }, { 1, nil }, { 2, 0.4 }, { 5, nil }, { 4, 0.2 } }) do
        local d = F245H.addField(z, row[1], SQ, row[2])
        if row[2] == nil then z:_markAggregateUnavailable(d, "NO_CURRENT_VALUE") end
    end
    local list = z:getFieldsSortedByMoisture()
    local ids = {}
    for i, e in ipairs(list) do ids[i] = e.fieldId end
    T.eq("L1a every field stays; numeric ascending, ties by id, unavailable last by id", table.concat(ids, ","), "4,2,3,1,5")
    T.eq("L1b an unavailable row carries moisture nil", list[4].moisture, nil)
    T.eq("L1c and unavailable true", list[4].unavailable, true)
    T.eq("L1d a numeric row is not unavailable", list[1].unavailable, false)

    local sys, vm, grid = F245H.newSystem({ ready = false })
    local d = F245H.addField(sys, 1, SQ, 0.5)
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.12))
    list = sys:getFieldsSortedByMoisture()
    T.near("L2 the list refreshes first", list[1].moisture, 0.12, 0.005)
end)

-- =====================================================================
-- D: daily settle under TRUTH (item 3)
-- =====================================================================
group("D daily settle", function()
    local sys, vm, grid = F245H.newSystem({ ready = false })
    local d1 = F245H.addField(sys, 1, SQ, 0.5)
    local d2 = F245H.addField(sys, 2, SQ2, 0.5)
    F245H.paint(grid, 12, -8, 20, 8, F245H.rawOf(0.35))
    sys._drainFieldOnMap = function() return false end
    local reads = countReads(vm)
    sys:settleDaily(1)
    T.eq("D1a a blank field settles unavailable EMPTY", state(d1), "UNAVAILABLE:EMPTY")
    T.eq("D1b never a nil in a current slot", d1.moisture, nil)
    T.eq("D1c dirty", d1.aggregateDirty, true)
    T.near("D1d a written field settles current", d2.moisture, 0.35, 0.005)
    T.eq("D1e clean", d2.aggregateDirty, false)
    T.eq("D1f [two reads]", reads.n, 2)
    sys._fieldVerts[2] = { n = 0, refusedAt = g_currentMission.time }
    sys:settleDaily(1)
    T.eq("D2 no geometry settles INVALID_FIELD_GEOMETRY", state(d2), "UNAVAILABLE:INVALID_FIELD_GEOMETRY")

    sys, vm, grid = F245H.newSystem({ ready = false })
    d1 = F245H.addField(sys, 1, SQ, 0.5)
    sys._drainFieldOnMap = function() return false end
    vm.readAverageOfPolygon = false
    sys:settleDaily(1)
    T.eq("D3a settle: a provider with no typed read fails closed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("D3b and the field keeps no old scalar as current", tostring(d1.moisture) .. ":" .. state(d1), "nil:UNAVAILABLE:PROVIDER_REFUSAL")

    -- Bob #192 MAJOR (model :97): the settle's call site b fires only on EMPTY.
    local function settled(readFn)
        local s, v = F245H.newSystem()
        local fd = F245H.addField(s, 1, SQ, 0.5)
        s._drainFieldOnMap = function() return false end
        s._probes = 0
        local realProbe = s._parcelHasWrittenPixels
        s._parcelHasWrittenPixels = function(self, id) self._probes = self._probes + 1; return realProbe(self, id) end
        if readFn ~= nil then v.readAverageOfPolygon = readFn end
        s:settleDaily(1)
        return s, v, fd
    end
    sys, vm, d1 = settled(nil)
    T.eq("D4a [reached: an EMPTY settle on the same fixture probes]", sys._probes, 1)
    sys, vm, d1 = settled(function() return "OK", nil end)
    T.eq("D4b NAMED (Bob #192 MAJOR): a settle read of OK with no mean runs no probe", sys._probes, 0)
    T.eq("D4c and no fill", vm.modifier.calls.set, 0)
    T.eq("D4d the field is unavailable EMPTY", state(d1), "UNAVAILABLE:EMPTY")
end)

-- =====================================================================
-- K: unpackCells no longer writes the scalar (item 5)
-- =====================================================================
group("K unpackCells", function()
    local z = SoilMoistureSystem.new({})
    local d = F245H.addField(z, 1, SQ, 0.55)
    z:unpackCells(1, "0,0:9000;0,1:7000")
    T.eq("K1a [reached: cells unpacked]", d.cellCount, 2)
    T.eq("K1b the scalar is untouched", d.moisture, 0.55)
end)
