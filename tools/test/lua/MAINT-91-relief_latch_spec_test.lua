-- MAINT-91-relief_latch_spec_test.lua
--
-- MAINTENANCE row 91 (SCS-018 relief, Bob's batch intake 2026-09-24 item 14): the relief
-- pass latched reliefScan BEFORE it collected the parcel, and collected with the partial
-- lookup, so a field whose first polygon walk failed was latched for the mission with no
-- relief. The pass now takes the COMPLETE collection, latches only once it has it, and a
-- pass asked for while the collection was refused or partial stays pending and runs, once,
-- when that machine's collection completes.
--
-- THE MP QUESTION, settled before building (the intake asked): every machine runs its own
-- field-ready updater (main.lua installs it from Mission00.loadMission00Finished and
-- Mission00.onStartMission, no server guard) and its own relief pass; the cells never
-- travel (CropStressMoistureInitEvent carries each field's scalar and stress, not cells).
-- Door C (the hourly retry) runs only on the server, but it only DROPS a refused entry; the
-- re-collect is _getFieldPolygons (door B), which runs on any machine, and a client's
-- positional read proves membership through it before it reads a cell. So the pending pass
-- completes on each machine from its own collection; group S drives the server through
-- door C, group C a client through its own read. No sync is needed and none is built.
--
-- THE ENTRY POINT IS THE FIELD-READY UPDATER (CropStressManager:installFieldReadyUpdater,
-- the one caller of materialiseRelief): the real updater registered with the mission and
-- ticked, the real enumeration and field map, the 2 m map declining as it does by default
-- (the release gate keeps cs_grid_concordance off unless experimental systems are on, the
-- one state in which relief runs). The manager is a bare instance of the real class,
-- marked initialized as CropStressManager:initialize leaves it (its constructor builds
-- weather and settings subsystems the updater never touches).
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua, src/CropStressManager.lua

local function group(tag, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(tag .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- Nodes are tables carrying their world position; a node marked throw makes the engine
-- translation raise, which fails that field's node walk (SoilMoistureSystem.lua
-- getFieldPolygonWorld protects each translation).
function getWorldTranslation(node)
    if type(node) ~= "table" then return 0, 0, 0 end
    if node.throw then error("node translation refused") end
    return node.x, 0, node.z
end
local function square(x0, z0, x1, z1, throwFirst)
    return { { x = x0, z = z0, throw = throwFirst }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } }
end
-- A steep slope, so relief materialises cells (SCS-018's threshold).
g_terrainNode = 1
getTerrainHeightAtWorldPos = function(_node, x, _y, _z) return x * 0.5 end

local W = {}
--- The world: one farmland (1) holding two engine fields, A (x 0..40) and B (x 60..100).
--- B's node walk throws when opts.brokenB, and B has no engine polygon, so the parcel's
--- collection is PARTIAL until B's walk recovers. opts.server says which side this is.
local function world(opts)
    W.B = { farmland = { id = 1 }, posX = 80, posZ = 20, polygonPoints = square(60, 0, 100, 40, opts.brokenB) }
    g_fieldManager = { fields = { { farmland = { id = 1 }, posX = 20, posZ = 20, polygonPoints = square(0, 0, 40, 40) }, W.B } }
    g_server = opts.server and {} or nil
    -- The release gate reads the player's opt-in from the manager's settings: off, the
    -- shipped default, so the 2 m map declines and relief is the path.
    g_cropStressManager = { settings = { allowsExperimentalSystems = function() return false end } }
    W.updater = nil
    g_currentMission = {
        isMissionStarted = true, time = 1000,
        environment = { currentHour = 2, currentMonotonicDay = 2, currentDay = 2, currentSeason = 1, daysPerPeriod = 1 },
        missionInfo = {},
        addUpdateable = function(_, u) W.updater = u end,
    }
    -- isInitialized: the state CropStressManager:initialize leaves before main.lua
    -- installs the updater (the install returns without it).
    local mgr = setmetatable({ fieldById = {}, isInitialized = true, eventBus = { subscribe = function() end, publish = function() end } },
        { __index = CropStressManager })
    mgr.soilSystem = SoilMoistureSystem.new(mgr)
    -- CropStressManager:initialize (:281) initializes the moisture owner before main.lua
    -- installs the updater; the real call, not a flag.
    mgr.soilSystem:initialize()
    W.mgr, W.sys = mgr, mgr.soilSystem
    -- Count the passes that actually ran (latched), without changing what they do.
    W.passes = 0
    local real = SoilMoistureSystem.materialiseRelief
    W.sys.materialiseRelief = function(self, fid)
        local before = self.fieldData[fid] and self.fieldData[fid].reliefScan
        real(self, fid)
        if not before and self.fieldData[fid] and self.fieldData[fid].reliefScan then W.passes = W.passes + 1 end
    end
    mgr:installFieldReadyUpdater()
    return W.updater ~= nil and W.updater:update(16) == true
end
local function cells(fid)
    local n = 0
    local d = W.sys.fieldData[fid]
    for _, row in pairs(d and d.cells or {}) do for _ in pairs(row) do n = n + 1 end end
    return n
end
local weather = setmetatable({
    getHourlyEvapMultiplier = function() return 0 end,
    getHourlyRainAmount = function() return 0 end,
}, { __index = function() return function() return 0 end end })

-- ════════════════════════════════════════════════════════════
-- S. THE SERVER: a failed walk at field-ready latches nothing; door C completes it
-- ════════════════════════════════════════════════════════════
group("S", function()
    T.ok("S0 [world] the field-ready updater ran and removed itself, with the map declined", world({ server = true, brokenB = true }))
    local d = W.sys.fieldData[1]
    T.eq("S1 with one of the deed's two walks failing at field-ready, the relief pass latches nothing and writes no cell (it waits for the whole parcel)",
        tostring(W.sys:mapActive()) .. ":" .. tostring(d.reliefScan) .. ":" .. tostring(W.sys._reliefScanned[1]) .. ":" .. cells(1) .. ":" .. W.passes,
        "false:false:nil:0:0")
    -- B's walk recovers. The hourly update runs door C (server only), which drops the
    -- partial entry, and its publication refresh re-collects the parcel: now complete.
    W.B.polygonPoints[1].throw = nil
    W.sys:hourlyUpdate(weather, 1)
    T.eq("S2 once the collection completes through door C, the pending relief runs exactly once over the whole parcel",
        tostring(d.reliefScan) .. ":" .. tostring(cells(1) > 0) .. ":" .. W.passes .. ":" .. tostring(W.sys._reliefPending[1]),
        "true:true:1:nil")
    local after = cells(1)
    g_currentMission.environment.currentHour = 3
    W.sys:hourlyUpdate(weather, 1)
    T.eq("S3 and never again: the next hour re-runs nothing", cells(1) .. ":" .. W.passes, after .. ":1")
end)

-- ════════════════════════════════════════════════════════════
-- C. A CLIENT: no door C, its own positional read completes its own relief
-- ════════════════════════════════════════════════════════════
group("C", function()
    T.ok("C0 [world] a client's field-ready updater ran", world({ server = false, brokenB = true }))
    local d = W.sys.fieldData[1]
    T.eq("C1 on a client the failed walk latches nothing either", tostring(d.reliefScan) .. ":" .. cells(1), "false:0")
    -- B recovers; the client never runs door C (hourlyUpdate is the server's), so the
    -- entry expires by its own retry window and the client's next positional read (the
    -- moisture overlay's) proves membership first, which re-collects.
    W.B.polygonPoints[1].throw = nil
    g_currentMission.time = 1000 + SoilMoistureSystem.GEOMETRY_RETRY_MS
    local v = W.sys:getMoisture(1, 10, 10)
    T.eq("C2 the client's own read completes its collection and its relief runs once, before the read looks up a cell",
        tostring(d.reliefScan) .. ":" .. tostring(cells(1) > 0) .. ":" .. W.passes .. ":" .. tostring(type(v) == "number"),
        "true:true:1:true")
end)

-- ════════════════════════════════════════════════════════════
-- K. A COMPLETE PARCEL AT FIELD-READY: relief at once, as before
-- ════════════════════════════════════════════════════════════
group("K", function()
    T.ok("K0 [world] armed", world({ server = true, brokenB = false }))
    T.eq("K1 a parcel whose walks both succeed gets its relief at field-ready, once",
        tostring(W.sys.fieldData[1].reliefScan) .. ":" .. tostring(cells(1) > 0) .. ":" .. W.passes, "true:true:1")
end)

g_fieldManager, g_cropStressManager, g_server = nil, nil, nil
