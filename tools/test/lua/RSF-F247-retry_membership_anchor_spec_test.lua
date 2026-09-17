--!load: src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/SaveLoadHandler.lua, src/IrrigationManager.lua
-- RSF-F247 v0.5 items 2, 5, 7, 8 and 9 on the pixel-grid engine.
-- Groups: C two-source collection and partial entries, R retry doors B and C and
-- the fingerprint reopen, B membership doors, A member anchor (with the irrigation
-- caller), V capture revision after a capture-time seed, T teardown.
-- Each group runs under pcall so a Lua error fails one named row.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server = {}
    g_fieldManager = nil
    g_currentMission.time = 1000
    g_currentMission.environment = { currentDay = 1, daysPerPeriod = 1 }
end

local SQ = F245H.square(-8, -8, 8, 8)
local A = F245H.square(-20, -8, -12, 8)
local B = F245H.square(12, -8, 20, 8)

local function flat(poly)
    local list = {}
    for i = 1, poly.n do list[#list + 1] = poly.vx[i]; list[#list + 1] = poly.vz[i] end
    return list
end

local function isEmpty(t) return type(t) == "table" and next(t) == nil end

-- =====================================================================
-- C: two-source parcel collection (item 2)
-- =====================================================================
group("C collection", function()
    local sys = F245H.newSystem()
    g_fieldManager = { fields = { F245H.engineField(1, SQ, { engine = flat(SQ) }) } }
    local polys, partial = sys:_collectParcelPolygons(1)
    T.eq("C1a a valid node walk is stored", polys ~= nil and #polys, 1)
    T.eq("C1b not partial", partial, false)
    T.eq("C1c an agreeing engine polygon logs nothing", sys._onceLogged["engine-polygon-differs:1"], nil)

    local moved = flat(SQ)
    moved[1] = moved[1] + 0.5
    g_fieldManager = { fields = { F245H.engineField(1, SQ, { engine = moved }) } }
    polys = sys:_collectParcelPolygons(1)
    T.eq("C2a a differing engine polygon: the node walk is kept", polys[1].vx[1], SQ.vx[1])
    T.eq("C2b and logged once for the field", sys._onceLogged["engine-polygon-differs:1"], true)
    T.eq("C2c within 0.01 m is not a difference",
        SoilMoistureSystem.polygonsDiffer(SQ.vx, SQ.vz, 4, { SQ.vx[1] + 0.009, SQ.vx[2], SQ.vx[3], SQ.vx[4] }, SQ.vz, 4), false)
    T.eq("C2d a point-count difference is a difference",
        SoilMoistureSystem.polygonsDiffer(SQ.vx, SQ.vz, 4, SQ.vx, SQ.vz, 3), true)

    -- node walk fails, engine polygon through the getter
    local f = F245H.engineField(1, SQ, { engine = flat(A) })
    f.polygonPoints[2].throw = true
    g_fieldManager = { fields = { f } }
    polys = sys:_collectParcelPolygons(1)
    T.eq("C3a a throwing node fails the walk; the getter polygon is stored", polys ~= nil and polys[1].vx[1], A.vx[1])

    -- node walk fails, engine polygon through the instance field
    f = F245H.engineField(1, SQ, { engine = flat(B), getter = false })
    f.polygonPoints[3] = 0
    g_fieldManager = { fields = { f } }
    polys = sys:_collectParcelPolygons(1)
    T.eq("C3b a zero node fails the walk; the densityMapPolygon field is read", polys ~= nil and polys[1].vx[1], B.vx[1])

    f = F245H.engineField(1, SQ, { engine = flat(B) })
    f.polygonPoints[1].x = 0 / 0
    g_fieldManager = { fields = { f } }
    polys = sys:_collectParcelPolygons(1)
    T.eq("C3c a non-finite node fails the walk", polys ~= nil and polys[1].vx[1], B.vx[1])

    f = F245H.engineField(1, F245H.square(0, 0, 1, 1), { engine = flat(B) })
    f.polygonPoints = { f.polygonPoints[1], f.polygonPoints[2] }
    g_fieldManager = { fields = { f } }
    polys = sys:_collectParcelPolygons(1)
    T.eq("C3d fewer than three nodes fails the walk", polys ~= nil and polys[1].vx[1], B.vx[1])

    -- both fail
    local function walkBroken(engine, getter)
        local e = F245H.engineField(1, SQ, { engine = engine, getter = getter })
        e.polygonPoints[1].throw = true
        return e
    end
    local badEngines = {
        { "C4a an odd-length engine list", { 0, 0, 1, 0, 1 } },
        { "C4b fewer than three engine points", { 0, 0, 1, 0 } },
        { "C4c a non-finite engine coordinate", { 0, 0, 1 / 0, 0, 1, 1 } },
        { "C4d a non-number engine coordinate", { 0, 0, "1", 0, 1, 1 } },
    }
    for _, row in ipairs(badEngines) do
        g_fieldManager = { fields = { walkBroken(row[2]) } }
        T.eq(row[1] .. " with a failed walk collects nothing", (sys:_collectParcelPolygons(1)), nil)
    end
    local throwing = walkBroken(nil)
    function throwing:getDensityMapPolygon() error("fake getter threw") end
    g_fieldManager = { fields = { throwing } }
    T.eq("C4e a throwing getter with a failed walk collects nothing", (sys:_collectParcelPolygons(1)), nil)
    local noEngine = walkBroken(nil)
    g_fieldManager = { fields = { noEngine } }
    T.eq("C4f no engine polygon with a failed walk collects nothing", (sys:_collectParcelPolygons(1)), nil)

    -- partial: one field ok, one field fails both; other farmlands ignored
    g_fieldManager = { fields = {
        F245H.engineField(1, A),
        walkBroken(nil),
        F245H.engineField(2, B),
    } }
    polys, partial = sys:_collectParcelPolygons(1)
    T.eq("C5a a parcel with one failed field keeps the good polygon", polys ~= nil and #polys, 1)
    T.eq("C5b and is partial", partial, true)
    T.eq("C5c another farmland's field never joins", polys[1].vx[1], A.vx[1])

    g_currentMission.time = 4242
    sys._fieldVerts = {}
    sys:_getFieldPolygons(1)
    local entry = sys._fieldVerts[1]
    T.eq("C6a a partial collection caches a partial entry", entry.partial, true)
    T.eq("C6b stamped with its refusedAt", entry.refusedAt, 4242)
    g_fieldManager = { fields = { walkBroken(nil) } }
    sys._fieldVerts = {}
    sys:_getFieldPolygons(1)
    entry = sys._fieldVerts[1]
    T.eq("C6c a refused collection caches n = 0 with its refusedAt", tostring(entry.n) .. "@" .. tostring(entry.refusedAt), "0@4242")
end)

-- =====================================================================
-- R: retry doors B and C, fingerprint reopen (item 5)
-- =====================================================================
group("R retry doors", function()
    local sys = F245H.newSystem()
    F245H.addField(sys, 1, SQ, 0.5)
    sys._fieldVerts = {}
    local walks = 0
    local realCollect = sys._collectParcelPolygons
    sys._collectParcelPolygons = function(self, id) walks = walks + 1; return realCollect(self, id) end

    g_fieldManager = { fields = {} }
    g_currentMission.time = 1000
    T.eq("R1a no geometry: nil", sys:_getFieldPolygons(1), nil)
    T.eq("R1b [one collection]", walks, 1)
    g_fieldManager = { fields = { F245H.engineField(1, SQ) } }
    g_currentMission.time = 1000 + 4999
    T.eq("R1c before expiry the refusal answers nil", sys:_getFieldPolygons(1), nil)
    T.eq("R1d and runs no second collection", walks, 1)
    g_currentMission.time = 1000 + 5000
    T.ok("R1e at expiry door B re-collects", sys:_getFieldPolygons(1) ~= nil)
    T.eq("R1f exactly once", walks, 2)
    sys:_getFieldPolygons(1)
    T.eq("R1g a complete entry is never re-collected", walks, 2)

    -- a refused replacement restarts the wait
    sys._fieldVerts = {}
    walks = 0
    g_fieldManager = { fields = {} }
    g_currentMission.time = 1000
    sys:_getFieldPolygons(1)
    g_currentMission.time = 6000
    sys:_getFieldPolygons(1)
    T.eq("R2a [expired refusal re-collected into a refusal]", walks, 2)
    T.eq("R2b the replacement stamps its own refusedAt", sys._fieldVerts[1].refusedAt, 6000)
    g_currentMission.time = 10999
    sys:_getFieldPolygons(1)
    T.eq("R2c the wait restarts from the replacement", walks, 2)
    g_currentMission.time = 11000
    sys:_getFieldPolygons(1)
    T.eq("R2d and expires 5000 ms after it", walks, 3)

    -- no clock: door B never expires
    sys._fieldVerts = { [1] = { n = 0, refusedAt = 1000 } }
    walks = 0
    g_currentMission.time = nil
    g_fieldManager = { fields = { F245H.engineField(1, SQ) } }
    T.eq("R3a with no mission clock a refusal stays", sys:_getFieldPolygons(1), nil)
    T.eq("R3b [no collection]", walks, 0)
    sys._fieldVerts = { [1] = { n = 0 } }
    g_currentMission.time = 999999
    T.eq("R3c a refusal with no refusedAt never expires", sys:_getFieldPolygons(1), nil)

    -- partial entries run door B too
    sys._fieldVerts = { [1] = { polys = { A }, partial = true, refusedAt = 1000 } }
    walks = 0
    g_currentMission.time = 2000
    local got = sys:_getFieldPolygons(1)
    T.eq("R4a before expiry a partial entry answers its polygons", got ~= nil and got[1].vx[1], A.vx[1])
    T.eq("R4b [no collection]", walks, 0)
    g_currentMission.time = 6000
    got = sys:_getFieldPolygons(1)
    T.eq("R4c at expiry it re-collects", walks, 1)
    T.eq("R4d and a complete collection replaces it", sys._fieldVerts[1].partial, nil)

    -- door C
    g_currentMission.time = 1000
    sys._fieldVerts = {
        [70] = { n = 0, refusedAt = 1 },
        [30] = { polys = { A }, partial = true, refusedAt = 1 },
        [50] = { n = 0, refusedAt = 1 },
        [10] = { vx = SQ.vx, vz = SQ.vz, n = 4 },
    }
    sys._geometryRetryHour = {}
    T.eq("R5a door C drops every refused and partial entry", sys:_retryRefusedGeometry(53), 3)
    T.eq("R5b complete entries stay", sys._fieldVerts[10] ~= nil, true)
    T.eq("R5c dropped entries are gone", tostring(sys._fieldVerts[70]) .. tostring(sys._fieldVerts[30]) .. tostring(sys._fieldVerts[50]), "nilnilnil")
    local order = {}
    for id in pairs(sys._geometryRetryHour) do order[#order + 1] = id end
    T.eq("R5d [bench-visible only: fengari pairs is insertion ordered] the drop walks sorted ids", table.concat(order, ","), "30,50,70")
    sys._fieldVerts[70] = { n = 0, refusedAt = 2 }
    T.eq("R5e once per hour key: a re-refusal in the same hour stays", sys:_retryRefusedGeometry(53), 0)
    T.eq("R5f a new hour key drops it again", sys:_retryRefusedGeometry(54), 1)

    sys._fieldVerts = { [7] = { n = 0, refusedAt = 1 } }
    sys._geometryRetryHour = {}
    g_server = nil
    T.eq("R6a door C on a client drops nothing", sys:_retryRefusedGeometry(53), 0)
    T.eq("R6b the entry stays", sys._fieldVerts[7] ~= nil, true)
    local weather = { getHourlyEvapMultiplier = function() return 0 end, getHourlyRainAmount = function() return 0 end }
    local hsys = F245H.newSystem()
    hsys._fieldVerts = { [7] = { n = 0, refusedAt = 1 } }
    g_currentMission.environment = { currentDay = 3, currentMonotonicDay = 2, currentHour = 5, daysPerPeriod = 1 }
    hsys:hourlyUpdate(weather, 1, 0)
    T.eq("R6c an hourly update on a client runs no door C", hsys._fieldVerts[7] ~= nil, true)
    g_server = {}
    hsys:hourlyUpdate(weather, 1, 0)
    T.eq("R6d an hourly update on the server runs door C before the loop", hsys._fieldVerts[7], nil)
    T.eq("R6e recording hour key 2*24+5", hsys._geometryRetryHour[7], 53)

    -- fingerprint reopen
    local fsys = F245H.newSystem()
    F245H.addField(fsys, 1, SQ, 0.5)
    fsys._fieldVerts = {}
    fsys._mapSeeded[1] = true
    fsys._groundChecked[1] = true
    g_fieldManager = { fields = { F245H.engineField(1, SQ) } }
    fsys:_getFieldPolygons(1)
    T.ok("R7a a first complete collection stores the fingerprint", fsys._lastGoodFingerprint[1] ~= nil)
    T.eq("R7b and reopens the ground check", fsys._groundChecked[1], nil)
    T.eq("R7c never the seeded flag", fsys._mapSeeded[1], true)
    fsys._groundChecked[1] = true
    fsys._fieldVerts = {}
    fsys:_getFieldPolygons(1)
    T.eq("R7d the same outline re-collected keeps the decision", fsys._groundChecked[1], true)
    g_fieldManager = { fields = { F245H.engineField(1, F245H.square(-8, -8, 9, 8)) } }
    fsys._fieldVerts = {}
    fsys:_getFieldPolygons(1)
    T.eq("R7e a changed outline reopens it", fsys._groundChecked[1], nil)
    T.eq("R7f still never the seeded flag", fsys._mapSeeded[1], true)
    fsys._groundChecked[1] = true
    local fpBefore = fsys._lastGoodFingerprint[1]
    local broken = F245H.engineField(1, B)
    broken.polygonPoints[1].throw = true
    g_fieldManager = { fields = { F245H.engineField(1, A), broken } }
    fsys._fieldVerts = {}
    fsys:_getFieldPolygons(1)
    T.eq("R7g [reached: a partial entry]", fsys._fieldVerts[1].partial, true)
    T.eq("R7h a partial collection never reopens", fsys._groundChecked[1], true)
    T.eq("R7i nor replaces the last good fingerprint", fsys._lastGoodFingerprint[1], fpBefore)

    -- door A unchanged
    fsys._fieldVerts = { [1] = { vx = SQ.vx, vz = SQ.vz, n = 4 } }
    fsys:onFarmlandOwnerChanged(1, 1, true)
    T.ok("R8 door A: an ownership change clears the geometry cache", isEmpty(fsys._fieldVerts))
end)

-- =====================================================================
-- B: membership doors (item 7)
-- =====================================================================
group("B membership", function()
    -- TRUTH positional read
    local sys, vm, grid = F245H.newSystem()
    local d = F245H.addField(sys, 1, SQ, 0.5)
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.6))
    local v, grain, rev = sys:getMoisture(1, 20, 20)
    T.eq("B1a TRUTH: a point outside the outline answers nothing", v, nil)
    T.eq("B1b with the revision", rev, sys.moistureRevision)
    v = sys:getMoisture(1, 2, 2)
    T.near("B1c [reached: a member point reads its pixel]", v, 0.6, 0.005)

    -- ZONE positional read
    local z = SoilMoistureSystem.new({})
    z.isInitialized = true
    z.providerMode = "ZONE"
    local zd = F245H.addField(z, 1, SQ, 0.4)
    T.eq("B2a ZONE: a point outside the outline answers nothing", (z:getMoisture(1, 20, 20)), nil)
    T.near("B2b [reached: a member point answers the field]", (z:getMoisture(1, 2, 2)), 0.4, 1e-9)

    -- before the fail-closed test
    local probes = 0
    local realIn = z._pointInParcel
    z._pointInParcel = function(self, ...) probes = probes + 1; return realIn(self, ...) end
    z.providerMode = "UNAVAILABLE_PENDING_RELOAD"
    z:getMoisture(1, 2, 2)
    T.eq("B3 membership is proven before the fail-closed answer", probes, 1)
    z._pointInParcel = nil

    -- refused outline
    z.providerMode = "ZONE"
    z._fieldVerts[1] = { n = 0, refusedAt = g_currentMission.time }
    T.eq("B4a a refused outline proves no member point", (z:getMoisture(1, 2, 2)), nil)
    T.eq("B4b and accepts no water", z:applyWaterAtCell(1, 2, 2, 0.05), false)

    -- applyWaterAtCell
    z._fieldVerts[1] = { vx = SQ.vx, vz = SQ.vz, n = 4 }
    T.eq("B5a an unknown field accepts no water", z:applyWaterAtCell(99, 2, 2, 0.05), false)
    T.eq("B5b a non-finite x accepts no water", z:applyWaterAtCell(1, 0 / 0, 2, 0.05), false)
    T.eq("B5c a missing z accepts no water", z:applyWaterAtCell(1, 2, nil, 0.05), false)
    z.providerMode = "UNAVAILABLE_PENDING_RELOAD"
    T.eq("B6a a point outside the outline accepts no water", z:applyWaterAtCell(1, 20, 20, 0.05), false)
    T.eq("B6b and nothing enters the field pending store", zd.mapPending, nil)
    T.eq("B6c [reached: a member point on the closed provider joins pending]", z:applyWaterAtCell(1, 2, 2, 0.05), true)
    T.near("B6d the pending store holds it", zd.mapPending, 0.05, 1e-12)

    sys, vm, grid = F245H.newSystem()
    d = F245H.addField(sys, 1, SQ, 0.5)
    F245H.paint(grid, -8, -8, 8, 8, F245H.rawOf(0.5))
    T.eq("B7a TRUTH: outside accepts no water", sys:applyWaterAtCell(1, 20, 20, 0.0001), false)
    T.eq("B7b and no positional pending entry", sys._mapWaterPending[1], nil)
    T.eq("B7c [reached: a member sub-step joins positional pending]", sys:applyWaterAtCell(1, 2, 2, 0.0001), true)
    T.ok("B7d the positional pending store holds it", sys._mapWaterPending[1] ~= nil)
end)

-- =====================================================================
-- A: member anchor (item 8) and the irrigation caller
-- =====================================================================
group("A member anchor", function()
    local sys = F245H.newSystem()
    local d = F245H.addField(sys, 1, SQ, 0.5)
    d.centerX, d.centerZ = 1, 2
    local x, z = sys:_memberAnchor(1)
    T.eq("A1 a member display centre is the anchor", tostring(x) .. "," .. tostring(z), "1,2")

    d.centerX, d.centerZ = 0, 0
    sys._fieldVerts[1] = { polys = { A, B } }
    x, z = sys:_memberAnchor(1)
    T.ok("A2 a centre in the gap: the first member midpoint of v1 and v3", x == -16 and z == 0, tostring(x) .. "," .. tostring(z))

    local calls = 0
    local realIn = sys._pointInParcel
    sys._pointInParcel = function(self, ...) calls = calls + 1; return realIn(self, ...) end
    sys:_memberAnchor(1)
    T.eq("A3a cached beside the geometry entry", calls, 0)
    T.eq("A3b [cache fields]", tostring(sys._fieldVerts[1].anchorResolved), "true")
    sys._fieldVerts[1] = { polys = { B, A } }
    x = sys:_memberAnchor(1)
    T.eq("A3c dropped with its entry: a new entry recomputes", x, 16)
    sys._pointInParcel = nil

    -- no member point: a crossed outline whose v_i, v_i+2 midpoints and centre lie outside
    local X = { vx = { -10, 10, 10, -10 }, vz = { -10, 10, -10, 10 }, n = 4 }
    sys._fieldVerts[1] = { vx = X.vx, vz = X.vz, n = 4 }
    d.centerX, d.centerZ = 0, 5
    x, z = sys:_memberAnchor(1)
    T.eq("A4a no member point: no anchor", x, nil)
    T.eq("A4b the unresolved answer is cached too", sys._fieldVerts[1].anchorResolved, true)
    sys._fieldVerts[1] = { n = 0, refusedAt = g_currentMission.time }
    T.eq("A4c a refused outline has no anchor", (sys:_memberAnchor(1)), nil)
    T.eq("A4d and caches nothing on the refusal", sys._fieldVerts[1].anchorResolved, nil)

    -- the irrigation caller
    local applied = {}
    sys.applyWaterAtCell = function(self, id, ax, az, gain) applied[#applied + 1] = { id, ax, az, gain }; return true end
    sys._fieldVerts[1] = { polys = { A, B } }
    d.centerX, d.centerZ = 0, 0
    T.eq("A5a the caller waters at the anchor", IrrigationManager:_waterAtMemberAnchor(sys, 1, d, 0.02), true)
    T.ok("A5b at the member point, never the gap centre", applied[1] ~= nil and applied[1][2] == -16 and applied[1][3] == 0 and applied[1][4] == 0.02)
    sys._fieldVerts[1] = { vx = X.vx, vz = X.vz, n = 4 }
    d.centerX, d.centerZ = 0, 5
    T.eq("A6a no anchor: the call is skipped", IrrigationManager:_waterAtMemberAnchor(sys, 1, d, 0.02), false)
    T.eq("A6b nothing watered", #applied, 1)
    T.eq("A6c logged once for the field", sys._onceLogged["anchor-skip:1"], true)
    T.eq("A6d a second skip logs nothing new", sys:_logOnce(1, "anchor-skip", "x"), false)
end)

-- =====================================================================
-- V: capture revision after a capture-time seed (item 9)
-- =====================================================================
group("V capture revision", function()
    local sys, vm, grid = F245H.newSystem({ carrier = "FRESH" })
    local d = F245H.addField(sys, 1, SQ, 0.47)
    local rev = sys.moistureRevision
    local sh = SaveLoadHandler.new({ soilSystem = sys })
    local env = sh:captureMoistureEnvelope()
    T.eq("V1a [reached: the capture refresh reached the check and seeded]", sys._groundChecked[1], true)
    T.eq("V1b the seed advanced the live revision once", sys.moistureRevision, rev + 1)
    T.eq("V1c the envelope carries the revision read after the refresh", env.moistureRevision, rev + 1)
    T.near("V1d beside the seeded aggregate", env.aggregates[1], 0.47, 0.005)

    sys, vm, grid = F245H.newSystem()
    d = F245H.addField(sys, 1, SQ, 0.47)
    sys._restoreRows[1] = { valueInstalled = true }
    env = SaveLoadHandler.new({ soilSystem = sys }):captureMoistureEnvelope()
    T.eq("V2a a saved row with no restored value: the field stays blank", sys._groundChecked[1], true)
    T.eq("V2b and is left out of the aggregates", env.aggregates[1], nil)
    T.eq("V2c at an unchanged revision", env.moistureRevision, sys.moistureRevision)
end)

-- =====================================================================
-- T: teardown (item 9)
-- =====================================================================
group("T teardown", function()
    local sys, vm, grid = F245H.newSystem()
    F245H.addField(sys, 1, SQ, 0.5)
    sys._fieldVerts[2] = { n = 0, refusedAt = 1, anchorResolved = true }
    sys._mapSeeded[1] = true
    sys._restoreRows[1] = { valueInstalled = true }
    sys._restoredMoisture[1] = { value = 0.5, kind = "SAVED" }
    sys._groundChecked[1] = true
    sys._lastGoodFingerprint[1] = "fp"
    sys._geometryRetryHour[2] = 53
    sys._onceLogged["anchor-skip:1"] = true
    sys:delete()
    T.ok("T1 geometry cache and its anchors empty", isEmpty(sys._fieldVerts))
    T.ok("T2 seeded flags empty", isEmpty(sys._mapSeeded))
    T.ok("T3 restore rows empty", isEmpty(sys._restoreRows))
    T.ok("T4 restored values empty", isEmpty(sys._restoredMoisture))
    T.eq("T5 carrier record cleared", sys._carrierRecord, nil)
    T.ok("T6 ground-check flags empty", isEmpty(sys._groundChecked))
    T.ok("T7 last good fingerprints empty", isEmpty(sys._lastGoodFingerprint))
    T.ok("T8 retry hours empty", isEmpty(sys._geometryRetryHour))
    T.ok("T9 once-log flags empty", isEmpty(sys._onceLogged))
    T.eq("T10 the carrier is released", vm.available, false)
end)
