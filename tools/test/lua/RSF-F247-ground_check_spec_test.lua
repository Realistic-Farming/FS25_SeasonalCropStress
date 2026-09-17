--!load: src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua
-- RSF-F247 v0.5 items 1-4 on a pixel-grid engine under the REAL CropStressValueMap.
-- Groups: P probe, F fill, S shared filter, W parcel wrappers, G ground-check
-- table (every row asserts its native probe count), M migration control flow.
-- Each group runs under pcall so a Lua error fails one named row.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server = {}
end

local SQ = F245H.square(-8, -8, 8, 8)     -- 16 x 16 = 256 pixels

-- =====================================================================
-- P: hasWrittenPixels
-- =====================================================================
group("P probe", function()
    local vm, grid = F245H.newValueMap(64)
    local calls = vm.modifier.calls
    T.eq("P1a short input is INVALID_FIELD_GEOMETRY", vm:hasWrittenPixels({ 0, 1 }, { 0, 1 }, 2), "INVALID_FIELD_GEOMETRY")
    T.eq("P1b [no native call before the geometry test]", calls.get, 0)
    T.eq("P2a blank outline is NONE", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "NONE")
    T.eq("P2b one filtered get", calls.getFiltered, 1)
    F245H.paint(grid, 0, 0, 2, 2, 120)
    T.eq("P3 a written pixel is PRESENT", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PRESENT")
    T.eq("P6 the probe never uses the unfiltered count", calls.getUnfiltered, 0)
    vm.modifier.hook = function(kind) if kind == "get" then return "throw" end end
    T.eq("P5a a throwing get is PROVIDER_REFUSAL", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PROVIDER_REFUSAL")
    vm.modifier.hook = function(kind) if kind == "get" then return "nil" end end
    T.eq("P5b a get with no count is PROVIDER_REFUSAL", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PROVIDER_REFUSAL")
    vm.modifier.hook = nil
    vm.hasPolygonOps = false
    T.eq("P4 a failed bind is PROVIDER_REFUSAL", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PROVIDER_REFUSAL")
    vm.hasPolygonOps = true
    vm.available = false
    T.eq("P5c an unavailable map is PROVIDER_REFUSAL", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PROVIDER_REFUSAL")
    vm.available = true
    local savedClass = DensityMapFilter
    DensityMapFilter = nil
    vm.filter = nil
    T.eq("P7a no filter class on the engine is UNPROVEN", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "UNPROVEN")
    DensityMapFilter = savedClass
    T.eq("P7b a missing filter with the class present is PROVIDER_REFUSAL", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PROVIDER_REFUSAL")
end)

-- =====================================================================
-- F: fillUnwrittenPolygon
-- =====================================================================
group("F fill", function()
    local vm, grid = F245H.newValueMap(64)
    local calls = vm.modifier.calls
    local written = F245H.paint(grid, -8, -8, 0, 8, 200)        -- left half written
    local raw = F245H.rawOf(0.4)
    local outcome, setRan = vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)
    T.eq("F1a a half-written outline fills OK", outcome, "OK")
    T.eq("F1b the set ran", setRan, true)
    T.eq("F1c every written pixel is unchanged", F245H.count(grid, 200), written)
    T.eq("F1d every blank pixel in the outline now holds the value", F245H.count(grid, raw), 256 - written)
    T.eq("F1e the fill never uses the unfiltered count", calls.getUnfiltered, 0)

    local setsBefore = calls.set
    outcome, setRan = vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)
    T.eq("F2a a fully written outline is EMPTY_OUTLINE", outcome, "EMPTY_OUTLINE")
    T.eq("F2b the set is not called", calls.set, setsBefore)
    T.eq("F2c setRan false", setRan, false)

    vm, grid = F245H.newValueMap(64)
    vm.modifier.hook = function(kind) if kind == "set" then return "noop" end end
    outcome, setRan = vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)
    T.eq("F3a a set with no fall is NOOP", outcome, "NOOP")
    T.eq("F3b and reports the set ran", setRan, true)

    vm.modifier.hook = function(kind) if kind == "set" then return "throw" end end
    T.eq("F4a a throwing set is PROVIDER_REFUSAL", (vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)), "PROVIDER_REFUSAL")
    vm.modifier.hook = function(kind, idx) if kind == "get" then return "throw" end end
    T.eq("F4b a throwing before-count is PROVIDER_REFUSAL", (vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)), "PROVIDER_REFUSAL")
    local gets = 0
    vm.modifier.hook = function(kind) if kind == "get" then gets = gets + 1; if gets == 2 then return "nil" end end end
    T.eq("F4c an after-count with no number is PROVIDER_REFUSAL", (vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)), "PROVIDER_REFUSAL")
    vm.modifier.hook = nil
    vm.hasPolygonOps = false
    T.eq("F4d a failed bind is PROVIDER_REFUSAL", (vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)), "PROVIDER_REFUSAL")

    vm, grid = F245H.newValueMap(64)
    vm.filter = nil
    local c = vm.modifier.calls
    outcome, setRan = vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)
    T.eq("F5a no filter answers NOOP", outcome, "NOOP")
    T.eq("F5b nothing attempted", c.get + c.set, 0)
    vm.filter = F245H.newFilter()
    vm.available = false
    T.eq("F5c an unavailable map answers NOOP", (vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)), "NOOP")
end)

-- =====================================================================
-- S: the shared filter (Bob intake): a delta changes the compare values first
-- =====================================================================
group("S shared filter", function()
    local vm, grid = F245H.newValueMap(64)
    F245H.paint(grid, -8, -8, 8, 8, 255)            -- only raw-255 pixels
    vm:applyDeltaToPolygon(SQ.vx, SQ.vz, SQ.n, 0.01) -- leaves BETWEEN 1, 255 - d on the filter
    T.ok("S1a [reached: the delta left a compare that excludes raw 255]", vm.filter.type == "BETWEEN" and vm.filter.b < 255)
    T.eq("S1b the next probe still counts BETWEEN 1, 255", vm:hasWrittenPixels(SQ.vx, SQ.vz, SQ.n), "PRESENT")

    vm, grid = F245H.newValueMap(64)
    F245H.paint(grid, -8, -8, 0, 8, 255)
    vm:applyDeltaToPolygon(SQ.vx, SQ.vz, SQ.n, 0.01)
    local outcome = vm:fillUnwrittenPolygon(SQ.vx, SQ.vz, SQ.n, 0.4)
    T.eq("S2a the next fill still selects EQUAL 0", outcome, "OK")
    T.eq("S2b and never touches the raw-255 pixels", F245H.count(grid, 255), 128)
end)

-- =====================================================================
-- W: parcel wrappers over a two-polygon collection
-- =====================================================================
local A = F245H.square(-20, -8, -12, 8)   -- 8 x 16 = 128 pixels
local B = F245H.square(12, -8, 20, 8)

local function twoPolySystem()
    local sys, vm, grid = F245H.newSystem()
    F245H.addField(sys, 1, A, 0.5)
    sys._fieldVerts[1] = { polys = { A, B } }
    return sys, vm, grid
end

group("W parcel wrappers", function()
    local sys, vm, grid = twoPolySystem()
    T.eq("W1a both blank: NONE", sys:_parcelHasWrittenPixels(1), "NONE")
    T.eq("W1b [one filtered probe per polygon]", vm.modifier.calls.getFiltered, 2)
    F245H.paint(grid, 12, -8, 20, 8, 90)
    T.eq("W1c a written later polygon makes the parcel PRESENT", sys:_parcelHasWrittenPixels(1), "PRESENT")
    local n = 0
    vm.modifier.hook = function(kind) if kind == "get" then n = n + 1; if n == 2 then return "throw" end end end
    T.eq("W1d a refusal on any polygon is a refusal", sys:_parcelHasWrittenPixels(1), "PROVIDER_REFUSAL")
    vm.modifier.hook = nil

    sys, vm, grid = twoPolySystem()
    vm.hasPolygonOps = false
    T.eq("W2a preflight: disabled polygon ops is PROVIDER_REFUSAL", sys:_fillParcelUnwritten(1, 0.4), "PROVIDER_REFUSAL")
    T.eq("W2b preflight wrote nothing", vm.modifier.calls.set, 0)
    vm.hasPolygonOps = true
    vm.filter = nil
    T.eq("W2c preflight: no filter is NOOP", sys:_fillParcelUnwritten(1, 0.4), "NOOP")
    T.eq("W2d still nothing written", vm.modifier.calls.set, 0)

    sys, vm, grid = twoPolySystem()
    T.eq("W3a both blank fill OK", sys:_fillParcelUnwritten(1, 0.4), "OK")
    sys, vm, grid = twoPolySystem()
    F245H.paint(grid, 12, -8, 20, 8, 90)
    T.eq("W3b first OK, second EMPTY_OUTLINE: OK", sys:_fillParcelUnwritten(1, 0.4), "OK")
    sys, vm, grid = twoPolySystem()
    F245H.paint(grid, -20, -8, 20, 8, 90)
    T.eq("W3c every polygon EMPTY_OUTLINE: NOOP", sys:_fillParcelUnwritten(1, 0.4), "NOOP")
    sys, vm, grid = twoPolySystem()
    vm.modifier.hook = function(kind, idx) if kind == "set" and idx == 2 then return "throw" end end
    T.eq("W3d first OK then a refusal: PARTIAL", sys:_fillParcelUnwritten(1, 0.4), "PARTIAL")
    sys, vm, grid = twoPolySystem()
    vm.modifier.hook = function(kind, idx) if kind == "set" and idx == 1 then return "throw" end end
    T.eq("W3e a refusal before any OK stands", sys:_fillParcelUnwritten(1, 0.4), "PROVIDER_REFUSAL")
    sys, vm, grid = twoPolySystem()
    vm.modifier.hook = function(kind, idx) if kind == "set" and idx == 2 then return "noop" end end
    T.eq("W3f first OK then a NOOP: PARTIAL", sys:_fillParcelUnwritten(1, 0.4), "PARTIAL")
    T.ok("W3g a set with no fall logs once for the field", sys._onceLogged["fill-no-change:1"] == true)
end)

-- =====================================================================
-- G: the ground check, every table row
-- =====================================================================
local function fieldSystem(opts)
    local sys, vm, grid, mgr = F245H.newSystem(opts)
    local d = F245H.addField(sys, 1, SQ, 0.5)
    return sys, vm, grid, mgr, d
end

local function savedRow(sys, value, kind, installed)
    sys._restoreRows[1] = { valueInstalled = installed ~= false }
    if value ~= nil then sys._restoredMoisture[1] = { value = value, kind = kind or "SAVED" } end
end

group("G ground check", function()
    -- saved row, pixels present
    local sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, 0.6)
    F245H.paint(grid, -8, -8, 8, 8, 100)
    local rev = sys.moistureRevision
    T.eq("G1a saved row + PRESENT preserves", sys:_checkFieldGround(1), "PRESERVE_RESTORED")
    T.eq("G1b [one probe]", vm.modifier.calls.getFiltered, 1)
    T.eq("G1c no set", vm.modifier.calls.set, 0)
    T.eq("G1d restored entry dropped", sys._restoredMoisture[1], nil)
    T.eq("G1e decided", sys._groundChecked[1], true)
    T.eq("G1f revision unchanged", sys.moistureRevision, rev)

    -- saved row, blank, saved number
    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, 0.6)
    sys:_markAggregateUnavailable(d, "EMPTY")
    rev = sys.moistureRevision
    T.eq("G2a saved row + NONE + SAVED seeds", sys:_checkFieldGround(1), "SEEDED")
    T.eq("G2b [one probe]", vm.modifier.calls.getFiltered >= 1, true)
    T.eq("G2c the blank outline now holds the saved number", F245H.count(grid, F245H.rawOf(0.6)), 256)
    T.eq("G2d revision advanced exactly once", sys.moistureRevision, rev + 1)
    T.eq("G2e the reread made the field current", d.aggregateState, "CURRENT")
    T.near("G2f from what reads back", d.moisture, 0.6, 0.005)
    T.eq("G2g restored entry dropped", sys._restoredMoisture[1], nil)
    T.eq("G2h seeded and decided", tostring(sys._mapSeeded[1]) .. tostring(sys._groundChecked[1]), "truetrue")

    -- saved row, blank, fresh start
    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, 0.35, "FRESH_START", false)
    sys:_markAggregateUnavailable(d, "NO_CURRENT_VALUE")
    T.eq("G3a saved row + NONE + FRESH_START seeds", sys:_checkFieldGround(1), "SEEDED")
    T.near("G3b from the recorded start value", d.moisture, 0.35, 0.005)

    -- saved row, blank, no entry
    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, nil)
    sys:_markAggregateUnavailable(d, "EMPTY")
    T.eq("G4a saved row + NONE + no entry invents nothing", sys:_checkFieldGround(1), "BLANK_NO_ENTRY")
    T.eq("G4b no set", vm.modifier.calls.set, 0)
    T.eq("G4c still unavailable", d.aggregateState, "UNAVAILABLE")

    -- no row, blank, never seeded: new field from the fallback base
    sys, vm, grid, _, d = fieldSystem()
    d.moisture = 0.45
    T.eq("G5a new blank field seeds", sys:_checkFieldGround(1), "SEEDED")
    T.near("G5b from its fallback base", d.moisture, 0.45, 0.005)
    sys, vm, grid, _, d = fieldSystem()
    d.moisture = 0.42
    sys:_markAggregateUnavailable(d, "EMPTY")
    T.eq("G5c an earlier unavailable read does not block the seed", sys:_checkFieldGround(1), "SEEDED")
    T.near("G5d the last-known start is the base", d.moisture, 0.42, 0.005)

    -- no row, blank, seeded earlier
    sys, vm, grid, _, d = fieldSystem()
    sys._mapSeeded[1] = true
    T.eq("G6a no row + NONE + seeded earlier: no second seed", sys:_checkFieldGround(1), "BLANK_SEEDED_EARLIER")
    T.eq("G6b no set", vm.modifier.calls.set, 0)
    T.eq("G6c unavailable NO_CURRENT_VALUE", tostring(d.aggregateState) .. ":" .. tostring(d.aggregateUnavailableReason), "UNAVAILABLE:NO_CURRENT_VALUE")

    -- no row, present, seeded earlier
    sys, vm, grid, _, d = fieldSystem()
    sys._mapSeeded[1] = true
    F245H.paint(grid, -8, -8, 8, 8, 100)
    T.eq("G7a no row + PRESENT + seeded earlier preserves", sys:_checkFieldGround(1), "PRESERVE_SEEDED_EARLIER")
    T.eq("G7b state untouched", d.aggregateState, "CURRENT")
    T.eq("G7c slot untouched", d.moisture, 0.5)

    -- no row, present, never seeded: renumbered ground
    sys, vm, grid, _, d = fieldSystem()
    F245H.paint(grid, -8, -8, 8, 8, 100)
    T.eq("G8a renumbered ground preserved", sys:_checkFieldGround(1), "PRESERVE_RENUMBERED")
    T.eq("G8b no set", vm.modifier.calls.set, 0)
    T.eq("G8c unavailable until its read", d.aggregateState, "UNAVAILABLE")
    T.eq("G8d seeded flag set", sys._mapSeeded[1], true)

    -- refused and partial outlines
    sys, vm, grid, _, d = fieldSystem()
    sys._fieldVerts[1] = { n = 0, refusedAt = g_currentMission.time }
    T.eq("G9a refused outline: no decision", sys:_checkFieldGround(1), "GEOMETRY_NOT_COMPLETE")
    T.eq("G9b [no probe]", vm.modifier.calls.get, 0)
    T.eq("G9c no flag", sys._groundChecked[1], nil)
    sys._fieldVerts[1] = { polys = { SQ }, partial = true, refusedAt = g_currentMission.time }
    T.eq("G10a partial outline: no decision", sys:_checkFieldGround(1), "GEOMETRY_NOT_COMPLETE")
    T.eq("G10b [no probe]", vm.modifier.calls.get, 0)

    -- probe refusal
    sys, vm, grid, _, d = fieldSystem()
    vm.modifier.hook = function(kind) if kind == "get" then return "throw" end end
    T.eq("G11a probe refusal", sys:_checkFieldGround(1), "PROBE_REFUSAL")
    T.eq("G11b fails the provider closed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")

    -- UNPROVEN
    sys, vm, grid, _, d = fieldSystem()
    local savedClass = DensityMapFilter
    DensityMapFilter = nil
    vm.filter = nil
    T.eq("G12a UNPROVEN preserves", sys:_checkFieldGround(1), "PRESERVE_UNPROVEN")
    DensityMapFilter = savedClass
    T.eq("G12b decided, nothing painted", tostring(sys._groundChecked[1]) .. tostring(vm.modifier.calls.set), "true0")

    -- carrier gate
    sys, vm, grid, _, d = fieldSystem({ carrier = false })
    savedRow(sys, 0.6)
    T.eq("G13a no carrier: a seed row paints nothing", sys:_checkFieldGround(1), "SEED_REFUSED_CARRIER")
    T.eq("G13b no set", vm.modifier.calls.set, 0)
    T.eq("G13c decided", sys._groundChecked[1], true)
    T.ok("G13d logged once", sys._onceLogged["carrier-unproven:1"] == true)
    sys, vm, grid, _, d = fieldSystem({ carrier = false })
    savedRow(sys, 0.6)
    F245H.paint(grid, -8, -8, 8, 8, 100)
    T.eq("G13e no carrier: a preserve row still preserves", sys:_checkFieldGround(1), "PRESERVE_RESTORED")
    sys, vm, grid, _, d = fieldSystem()
    sys.providerMode = "ZONE"
    savedRow(sys, 0.6)
    T.eq("G14 a provider that is not TRUTH seeds nothing", sys:_checkFieldGround(1), "SEED_REFUSED_CARRIER")

    -- fill outcomes
    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, 0.6)
    vm.modifier.hook = function(kind) if kind == "set" then return "noop" end end
    rev = sys.moistureRevision
    T.eq("G15a a fill with no fall preserves", sys:_checkFieldGround(1), "SEED_NOOP_PRESERVED")
    T.eq("G15b revision unchanged", sys.moistureRevision, rev)
    T.eq("G15c decided", sys._groundChecked[1], true)

    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, 0.6)
    vm.modifier.hook = function(kind) if kind == "set" then return "throw" end end
    rev = sys.moistureRevision
    T.eq("G16a a seed refusal", sys:_checkFieldGround(1), "SEED_REFUSAL")
    T.eq("G16b fails closed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("G16c no flags", tostring(sys._mapSeeded[1]) .. tostring(sys._groundChecked[1]), "nilnil")
    T.eq("G16d restored entry kept", sys._restoredMoisture[1] ~= nil, true)
    T.eq("G16e revision unchanged", sys.moistureRevision, rev)

    sys, vm, grid, _, d = fieldSystem()
    sys._fieldVerts[1] = { polys = { A, B } }
    savedRow(sys, 0.6)
    vm.modifier.hook = function(kind, idx) if kind == "set" and idx == 2 then return "throw" end end
    rev = sys.moistureRevision
    T.eq("G17a a part-way fill", sys:_checkFieldGround(1), "SEED_PARTIAL")
    T.eq("G17b revision advanced once", sys.moistureRevision, rev + 1)
    T.eq("G17c dirty", d.aggregateDirty, true)
    T.eq("G17d fails closed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("G17e never reported done", tostring(sys._mapSeeded[1]) .. tostring(sys._groundChecked[1]), "nilnil")
    T.eq("G17f restored entry kept", sys._restoredMoisture[1] ~= nil, true)

    -- no base
    sys, vm, grid, _, d = fieldSystem()
    d.moisture = nil
    T.eq("G22a a new field with no base is not painted", sys:_checkFieldGround(1), "SEED_NO_BASE")
    T.eq("G22b unavailable NO_CURRENT_VALUE", d.aggregateUnavailableReason, "NO_CURRENT_VALUE")
    T.eq("G22c no set", vm.modifier.calls.set, 0)

    -- timing and client
    sys, vm, grid, _, d = fieldSystem({ ready = false })
    savedRow(sys, 0.6)
    T.eq("G20a before the barrier the check does nothing", sys:_checkFieldGround(1), nil)
    T.eq("G20b [no native call, no flag]", tostring(vm.modifier.calls.get) .. tostring(sys._groundChecked[1]), "0nil")
    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, 0.6)
    g_server = nil
    T.eq("G21a a client never runs the check", sys:_checkFieldGround(1), nil)
    T.eq("G21b [no native call]", vm.modifier.calls.get, 0)
    g_server = {}

    -- no repetition: a decided field is never probed again by repeated EMPTY reads
    sys, vm, grid, _, d = fieldSystem()
    savedRow(sys, nil)
    sys:_markAggregateUnavailable(d, "EMPTY")
    sys:_checkFieldGround(1)
    local probes = vm.modifier.calls.getFiltered
    for _ = 1, 3 do sys:refreshForPublication() end
    T.eq("G19a [reached: the field stays unavailable and dirty]", tostring(d.aggregateState) .. tostring(d.aggregateDirty), "UNAVAILABLEtrue")
    T.eq("G19b repeated EMPTY reads run no second probe", vm.modifier.calls.getFiltered, probes)
    T.eq("G19c and no seed", vm.modifier.calls.set, 0)
end)

-- =====================================================================
-- M: migration control flow
-- =====================================================================
group("M migration", function()
    local sys, vm, grid, mgr, d = fieldSystem()
    local paints, stamps = 0, 0
    local realPaint, realWrite = vm.paintPolygon, vm.writeValueAtWorld
    vm.paintPolygon = function(self, ...) paints = paints + 1; return realPaint(self, ...) end
    vm.writeValueAtWorld = function(self, ...) stamps = stamps + 1; return realWrite(self, ...) end
    d.cells = { [0] = { [0] = { moisture = 0.9 } } }
    d.cellCount, d.cellSum = 1, 0.9
    sys:migrateFieldToMap(1)
    T.eq("M1a [reached: post-ready migration decided the field]", sys._groundChecked[1], true)
    T.eq("M1b post-ready migration never calls the unfiltered paint", paints, 0)
    T.eq("M1c and never stamps cells", stamps, 0)

    sys, vm, grid, mgr, d = fieldSystem()
    paints = 0
    vm.paintPolygon = function(self, ...) paints = paints + 1; return true end
    sys._fieldVerts[1] = { n = 0, refusedAt = g_currentMission.time }
    T.eq("M2a a refused outline: migration returns false", sys:migrateFieldToMap(1), false)
    T.eq("M2b and paints nothing", paints, 0)

    sys, vm, grid, mgr, d = fieldSystem({ ready = false })
    paints = 0
    vm.paintPolygon = function(self, ...) paints = paints + 1; return true end
    d.moisture = 0.55
    T.eq("M3a before ready the barrier seed paints", sys:migrateFieldToMap(1), true)
    T.eq("M3b one paint", paints, 0 + 1)
    sys, vm, grid, mgr, d = fieldSystem({ ready = false })
    paints = 0
    vm.paintPolygon = function(self, ...) paints = paints + 1; return true end
    d.moisture = nil
    T.eq("M3c before ready with no base: not painted", sys:migrateFieldToMap(1), false)
    T.eq("M3d no 0.5 paint", paints, 0)
    T.eq("M3e no current value", d.aggregateState, "UNAVAILABLE")

    -- fresh farm: the barrier seed, then ready, then the first doors keep the reading
    sys, vm, grid, mgr, d = fieldSystem({ ready = false, carrier = "FRESH" })
    d.moisture = 0.5
    sys:seedMapFromStore()
    mgr.ready = true
    sys:refreshForPublication()
    local before = d.moisture
    T.eq("M4a [reached: the fresh seed is readable]", d.aggregateState, "CURRENT")
    sys:migrateFieldToMap(1)
    T.eq("M4b the first post-ready door preserves the barrier seed", sys._groundChecked[1], true)
    T.near("M4c the reading is kept", d.moisture, before, 1e-9)

    -- call site b: an EMPTY refresh on a new blank field reaches the check and seeds
    sys, vm, grid, mgr, d = fieldSystem()
    d.moisture = 0.47
    sys:refreshForPublication()
    T.eq("M5a call site b seeded the field", sys._groundChecked[1], true)
    T.eq("M5b current from what reads back", d.aggregateState, "CURRENT")
    T.near("M5c at its start value", d.moisture, 0.47, 0.005)
end)
