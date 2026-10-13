--!load: src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/SaveLoadHandler.lua, src/events/CropStressMoistureInitEvent.lua, src/integrations/CropStressNetworkSyncBridge.lua
-- RSF-F245 v0.7 item 5 and RSF-F247 v0.5 items 3 and 6 through the REAL
-- SaveLoadHandler restore barrier, XML reader and writers, and both transport
-- paths. Groups: X row installs and the per-load record, Y envelope and carrier
-- record, Z ZONE settle after the decline step, Q XML presence, O own XML and
-- ledger omission, N transport. Each group runs under pcall.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server = {}
    g_cropStressManager = nil
end

local SQ = F245H.square(-8, -8, 8, 8)
local SQ2 = F245H.square(12, -8, 20, 8)
local SQ3 = F245H.square(-20, -20, -12, -12)

local function state(d)
    return tostring(d.aggregateState) .. ":" .. tostring(d.aggregateUnavailableReason)
end

local function manager(sys)
    return { soilSystem = sys, stressModifier = { fieldStress = {}, getStress = function() return 0 end } }
end

--- A TRUTH system with three enumerated-looking fields at the season start 0.6.
local function threeFields(opts)
    local sys, vm, grid = F245H.newSystem(opts)
    local ds = {}
    for id, poly in ipairs({ SQ, SQ2, SQ3 }) do
        ds[id] = F245H.addField(sys, id, poly, 0.6)
        ds[id].aggregateDirty = false
    end
    return sys, vm, grid, ds
end

-- =====================================================================
-- X: row installs and the per-load record
-- =====================================================================
group("X row installs", function()
    local sys, vm, grid, ds = threeFields()
    sys:_markAggregateUnavailable(ds[1], "EMPTY")
    sys._restoredMoisture[9] = { value = 0.1, kind = "SAVED" }
    sys._restoreRows[9] = { valueInstalled = true }
    sys._carrierRecord = "SELECTED_PAIR"
    local sh = SaveLoadHandler.new(manager(sys))
    sh._staged = { XML = { fields = {
        [1] = { moisture = 1.4, stress = 0 },
        [2] = { stress = 0 },
        [77] = { moisture = 0.3, stress = 0 },
    } } }
    local r = sh:restoreMissionWater({})
    T.eq("X1a a row value installs, clamped", ds[1].moisture, 1)
    T.eq("X1b and marks the field current", state(ds[1]), "CURRENT:nil")
    T.eq("X1c and dirty", ds[1].aggregateDirty, true)
    T.eq("X1d recorded as a saved row that installed a value", sys._restoreRows[1] and sys._restoreRows[1].valueInstalled, true)
    T.ok("X1e its restored value is SAVED, after the clamp",
        sys._restoredMoisture[1] ~= nil and sys._restoredMoisture[1].kind == "SAVED" and sys._restoredMoisture[1].value == 1)
    T.eq("X2a a row with no value installs nothing: the enumeration value stays", ds[2].moisture, 0.6)
    T.eq("X2b recorded as a saved row with no value", sys._restoreRows[2] and sys._restoreRows[2].valueInstalled, false)
    T.eq("X2c its start value is FRESH_START context",
        sys._restoredMoisture[2] and (sys._restoredMoisture[2].kind .. ":" .. sys._restoredMoisture[2].value), "FRESH_START:0.6")
    T.eq("X3 a field with no row has no record", tostring(sys._restoreRows[3]) .. tostring(sys._restoredMoisture[3]), "nilnil")
    T.eq("X4 the previous load's record is cleared", tostring(sys._restoreRows[9]) .. tostring(sys._restoredMoisture[9]), "nilnil")
    T.eq("X5 the restore pre-sets no seeded flag", next(sys._mapSeeded), nil)
    T.eq("X6 a live TRUTH map not loaded from a save records FRESH", tostring(r.carrier) .. ":" .. tostring(sys._carrierRecord), "FRESH:FRESH")
    T.eq("X7 a row for a field not on the map is ignored", r.fieldsIgnored, 1)
end)

-- =====================================================================
-- Y: envelope install and the carrier record
-- =====================================================================
local function completeEnvelope(sh, aggregates, revision)
    local env = {
        schema = 3, payloadKind = "COMPLETE", generation = 4, filename = "csMoistureMap_a.grle",
        mapWidth = 64, moistureRevision = revision or 9, lastSettledMonotonicDay = 3,
        aggregates = aggregates, fieldPending = {}, positionalRows = {},
    }
    env.digest = sh:compactDigest(env)
    return env
end

group("Y envelope and carrier", function()
    local sys, vm, grid, ds = threeFields()
    local sh = SaveLoadHandler.new(manager(sys))
    local env = completeEnvelope(sh, { [1] = 0.7 }, 9)
    sh._staged = { XML = {
        fields = { [1] = { moisture = 0.2, stress = 0 }, [2] = { stress = 0 }, [3] = { stress = 0, cells = "0,0:9000;0,1:7000" } },
        moistureEnvelope = { complete = { env } },
    } }
    local r = sh:restoreMissionWater({ nativeProbe = function() vm.loadedFromSave = true; return true end })
    T.eq("Y1a [reached: the selected pair was applied]", r.declined, nil)
    T.near("Y1b the envelope overwrites the row", ds[1].moisture, 0.7, 1e-12)
    T.eq("Y1c its number is the SAVED restored value",
        sys._restoredMoisture[1] and (sys._restoredMoisture[1].kind .. ":" .. sys._restoredMoisture[1].value), "SAVED:0.7")
    T.eq("Y1d the carrier record is SELECTED_PAIR", sys._carrierRecord, "SELECTED_PAIR")
    T.eq("Y1e the revision is the envelope's", sys.moistureRevision, 9)
    T.eq("Y2a under TRUTH restored cells are evidence only: the slot keeps its value", ds[3].moisture, 0.6)
    T.eq("Y2b [reached: the cells were unpacked]", ds[3].cellCount, 2)
    T.eq("Y2c cells with no envelope row record FRESH_START", sys._restoredMoisture[3] and sys._restoredMoisture[3].kind, "FRESH_START")

    -- then the F245 marking pass on the loaded map
    local paints = 0
    local realPaint = vm.paintPolygon
    vm.paintPolygon = function(self, ...) paints = paints + 1; return realPaint(self, ...) end
    sys:seedMapFromStore()
    T.eq("Y3a the marking pass paints nothing", paints, 0)
    T.eq("Y3b a restored value: seeded, current, dirty", tostring(sys._mapSeeded[1]) .. ":" .. state(ds[1]) .. ":" .. tostring(ds[1].aggregateDirty), "true:CURRENT:nil:true")
    T.eq("Y3c a row with no value: unavailable NO_CURRENT_VALUE", state(ds[2]), "UNAVAILABLE:NO_CURRENT_VALUE")

    -- legacy import
    sys, vm, grid, ds = threeFields()
    sh = SaveLoadHandler.new(manager(sys))
    sh._staged = { XML = { fields = { [1] = { moisture = 0.4, stress = 0 } } } }
    r = sh:restoreMissionWater({ legacyProbe = function() vm.loadedFromSave = true; return true end })
    T.eq("Y4 a legacy import records LEGACY_IMPORT", sys._carrierRecord, "LEGACY_IMPORT")

    -- a loaded map the barrier did not make current
    sys, vm, grid, ds = threeFields()
    vm.loadedFromSave = true
    sh = SaveLoadHandler.new(manager(sys))
    sh._staged = { XML = { fields = { [1] = { moisture = 0.4, stress = 0 } } } }
    r = sh:restoreMissionWater({})
    T.eq("Y5 a map loaded from a save with no selected pair or import records no carrier", sys._carrierRecord, nil)
end)

-- =====================================================================
-- Z: ZONE settle after the decline step
-- =====================================================================
group("Z ZONE settle", function()
    local z = SoilMoistureSystem.new({})
    z.isInitialized = true
    z.providerMode = "ZONE"
    local d = F245H.addField(z, 1, SQ, 0.6)
    local sh = SaveLoadHandler.new(manager(z))
    sh._staged = { XML = { fields = { [1] = { moisture = 0.5, stress = 0, cells = "0,0:9000;0,1:7000" } } } }
    local r = sh:restoreMissionWater({})
    T.near("Z1a ZONE: restored cells settle the slot to their mean", d.moisture, 0.8, 1e-9)
    T.eq("Z1b current", state(d), "CURRENT:nil")
    T.eq("Z1c no carrier record under ZONE", z._carrierRecord, nil)

    -- a generation-era save with no usable envelope declines the live map after unpack
    local sys, vm, grid, ds = threeFields()
    sh = SaveLoadHandler.new(manager(sys))
    sh._staged = { XML = { saveGeneration = 2, fields = { [1] = { moisture = 0.5, stress = 0, cells = "0,0:9000;0,1:7000" } } } }
    r = sh:restoreMissionWater({})
    T.ok("Z2a [reached: the live map was declined after the rows unpacked]", r.declined ~= nil and sys.valueMap == nil)
    T.near("Z2b the declined mission settles the field to its cell mean", ds[1].moisture, 0.8, 1e-9)
    T.eq("Z2c no carrier record", sys._carrierRecord, nil)

    z = SoilMoistureSystem.new({})
    z.providerMode = "ZONE"
    d = F245H.addField(z, 1, SQ, 0.6)
    z:_markAggregateUnavailable(d, "NO_CURRENT_VALUE")
    d.cells, d.cellCount, d.cellSum = { [0] = { [0] = { moisture = 0.3 } } }, 1, 0.3
    sh = SaveLoadHandler.new(manager(z))
    sh._staged = { XML = { fields = {} } }
    sh:restoreMissionWater({})
    T.eq("Z3 an unavailable ZONE field is not settled current", state(d), "UNAVAILABLE:NO_CURRENT_VALUE")
end)

-- =====================================================================
-- Q: the own-XML reader tests presence
-- =====================================================================
local function xmlObject(data, opts)
    opts = opts or {}
    local x = { data = data }
    function x:getInt(key) return self.data[key] end
    function x:getBool(key) return self.data[key] end
    function x:getString(key) return self.data[key] end
    function x:getFloat(key)
        local v = self.data[key]
        if v == nil and opts.missingFloatIsZero and key:match("#moisture$") then return 0 end
        return v
    end
    if opts.hasProperty ~= false then
        function x:hasProperty(key) return self.data[key] ~= nil end
    end
    return x
end

group("Q XML presence", function()
    local root = "careerSavegame.cropStress.fields.field"
    local sh = SaveLoadHandler.new({ soilSystem = SoilMoistureSystem.new({}) })
    sh.isInitialized = true
    local data = {
        [root .. "(0)#id"] = 5, [root .. "(0)#stress"] = 0.1,
        [root .. "(1)#id"] = 6, [root .. "(1)#moisture"] = 0.37,
    }
    sh:loadFromXMLFile(xmlObject(data, { missingFloatIsZero = true }))
    local f = sh._staged and sh._staged.XML and sh._staged.XML.fields or {}
    T.ok("Q1a [reached: both rows staged]", f[5] ~= nil and f[6] ~= nil)
    T.eq("Q1b a missing value stays absent even when the engine answers 0", f[5] and f[5].moisture, nil)
    T.near("Q1c a present value reads", f[6] and f[6].moisture, 0.37, 1e-12)

    sh = SaveLoadHandler.new({ soilSystem = SoilMoistureSystem.new({}) })
    sh.isInitialized = true
    sh:loadFromXMLFile(xmlObject(data, { hasProperty = false }))
    f = sh._staged.XML.fields
    T.eq("Q2 with no presence API a missing value still reads as absent, never 0.50", f[5].moisture, nil)
end)

-- =====================================================================
-- O: own XML and ledger rows omit an unavailable field
-- =====================================================================
group("O save omission", function()
    local z = SoilMoistureSystem.new({})
    z.providerMode = "ZONE"
    F245H.addField(z, 1, SQ, 0.4)
    local d2 = F245H.addField(z, 2, SQ2, 0.6)
    z:_markAggregateUnavailable(d2, "NO_CURRENT_VALUE")
    local mgr = manager(z)
    mgr.ensureMissionWaterSaveCut = function() return { mode = "ZONE" } end
    local sh = SaveLoadHandler.new(mgr)
    sh.isInitialized = true
    local out = sh:buildStateTable()
    T.near("O1a [reached: the ledger row carries a current field]", out.fields[1] and out.fields[1].moisture, 0.4, 1e-12)
    T.ok("O1b the ledger row keeps an unavailable field", out.fields[2] ~= nil)
    T.eq("O1c without a moisture key", out.fields[2] and out.fields[2].moisture, nil)

    local handle = {}
    local ok = pcall(function() sh:saveToXMLFile(handle) end)
    local ids, moist = {}, {}
    for i = 0, 4 do
        local key = string.format("careerSavegame.cropStress.fields.field(%d)", i)
        if handle[key .. "#id"] ~= nil then
            ids[handle[key .. "#id"]] = true
            moist[handle[key .. "#id"]] = handle[key .. "#moisture"]
        end
    end
    T.ok("O2a [reached: the own XML wrote both field rows]", ids[1] and ids[2])
    T.near("O2b a current field saves its number", moist[1], 0.4, 1e-12)
    T.eq("O2c an unavailable field saves no number", moist[2], nil)
    T.eq("O2d last-known is never saved", handle["careerSavegame.cropStress.fields.field(1)#moistureLastKnown"], nil)
end)

-- =====================================================================
-- N: transport omits an unavailable field and never writes a non-number
-- =====================================================================
group("N transport", function()
    local fieldData = {
        [1] = { moisture = 0.4, aggregateState = "CURRENT" },
        [2] = { moisture = nil, aggregateState = "UNAVAILABLE" },
        [3] = { moisture = nil },
    }
    local arr = CropStressNetworkSyncBridge.serializeFields(fieldData, { [1] = 0.2, [2] = 0.3 })
    T.eq("N1a serialize counts only rows with a current number", arr[1], 1)
    T.eq("N1b and writes only those rows (no 0.0 sent)", #arr, 4)
    local got = CropStressNetworkSyncBridge.deserializeFields(arr)
    T.eq("N1c the round trip carries field 1 only", tostring(got[1] ~= nil) .. tostring(got[2]) .. tostring(got[3]), "truenilnil")

    local s = _sfMockStream()
    local ev = CropStressMoistureInitEvent.new(fieldData, { [1] = 0.2 })
    ev:writeStream(s)
    T.eq("N2a the init event writes one row", s.q[1] and s.q[1].v, 1)
    T.eq("N2b and nothing else beyond it", #s.q, 4)
    T.near("N2c the row's number", s.q[3] and s.q[3].v, 0.4, 1e-12)

    g_server = nil
    local clientSoil = SoilMoistureSystem.new({})
    clientSoil.fieldData[1] = { moisture = 0.9 }
    clientSoil.fieldData[2] = { moisture = 0.55 }
    g_cropStressManager = { soilSystem = clientSoil, stressModifier = { fieldStress = {} } }
    local rx = CropStressMoistureInitEvent.emptyNew()
    pcall(function() rx:readStream(s) end)
    T.eq("N2d [the stream drains exactly]", tostring(s.r) .. ":" .. s.typeErrors .. ":" .. s.underflows, "5:0:0")
    T.near("N2e the client adopts the sent row", clientSoil.fieldData[1].moisture, 0.4, 1e-12)

    local run = CropStressMoistureInitEvent.emptyNew()
    run.fieldData = { [2] = { moisture = nil }, [7] = { moisture = nil } }
    run.fieldStress = {}
    pcall(function() run:run(nil) end)
    T.eq("N3a an init receive never writes a non-number over a value", clientSoil.fieldData[2].moisture, 0.55)
    T.eq("N3b nor creates a field from one", clientSoil.fieldData[7], nil)
end)

-- =====================================================================
-- C: a pure client keeps the host's number (Bob #192 BLOCKER)
-- Shape: g_server nil, a live streamed map with no pixels, a dirty field, the
-- HUD's once-a-second rebuild before and after the host value is delivered.
-- =====================================================================
local function liveClient(providerMode)
    local sys, vm = F245H.newSystem({ ready = false })
    sys.providerMode = providerMode
    local d = F245H.addField(sys, 1, SQ, 0.6)
    local box = { reads = 0 }
    local realRead = vm.readAverageOfPolygon
    vm.readAverageOfPolygon = function(self, ...) box.reads = box.reads + 1; return realRead(self, ...) end
    g_cropStressManager = { soilSystem = sys, stressModifier = { fieldStress = {} } }
    return sys, vm, d, box
end

group("C pure client", function()
    g_server = nil
    local sys, vm, d, box = liveClient("TRUTH")
    sys:getFieldsSortedByMoisture()
    local ev = CropStressMoistureInitEvent.emptyNew()
    ev.fieldData = { [1] = { moisture = 0.55 } }
    ev.fieldStress = { [1] = 0.1 }
    ev:run(nil)
    local list = sys:getFieldsSortedByMoisture()
    T.near("C1a NAMED (Bob #192 BLOCKER): init event: a pure client lists the host's number after its HUD rebuild",
        list[1] and list[1].moisture, 0.55, 1e-12)
    T.eq("C1b the client never marks the field unavailable", state(d), "CURRENT:nil")
    T.eq("C1c the client's publication walk reads nothing native", box.reads, 0)
    T.near("C1d a field read on the client answers the host's number", (sys:getMoisture(1)), 0.55, 1e-12)
    T.eq("C1e and still leaves the field current", state(d), "CURRENT:nil")

    -- the NetworkSync mirror applies while the client's map is live but not current
    g_server = nil
    sys, vm, d, box = liveClient(nil)
    T.ok("C2a [reached: the map is live and the mirror applies]", sys:mapActive() and not sys:isMoistureMapCurrent())
    sys:getFieldsSortedByMoisture()
    CropStressNetworkSyncBridge._onReadState(CropStressNetworkSyncBridge.serializeFields(
        { [1] = { moisture = 0.55, aggregateState = "CURRENT" } }, { [1] = 0.1 }))
    list = sys:getFieldsSortedByMoisture()
    T.near("C2b NAMED (Bob #192 BLOCKER): NetworkSync mirror: a pure client lists the host's number after its HUD rebuild",
        list[1] and list[1].moisture, 0.55, 1e-12)
    T.eq("C2c the client never marks the field unavailable", state(d), "CURRENT:nil")
    T.eq("C2d the client's publication walk reads nothing native", box.reads, 0)

    -- the host still marks the same shape unavailable
    g_server = {}
    sys, vm, d, box = liveClient("TRUTH")
    sys:getFieldsSortedByMoisture()
    T.eq("C3 [reached: the host marks a blank dirty field unavailable]", state(d), "UNAVAILABLE:EMPTY")

    -- a native refusal on a pure client fails its provider closed, as before F245,
    -- but never blanks the host's number in the client's list
    g_server = nil
    sys, vm, d, box = liveClient("TRUTH")
    vm.readAverageOfPolygon = function() return "PROVIDER_REFUSAL", nil, nil end
    sys:getMoisture(1)
    T.eq("C4a [reached: the client's provider failed closed]", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
    T.eq("C4b a refusal on a pure client never marks the field unavailable", state(d), "CURRENT:nil")
    list = sys:getFieldsSortedByMoisture()
    T.near("C4c the client's list keeps the host's number", list[1] and list[1].moisture, 0.6, 1e-12)
end)
