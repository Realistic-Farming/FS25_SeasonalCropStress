-- f357_host_world.lua
--
-- The NPCFavor HOST's world for the RSF-F357 SCS caller spec: the engine surface
-- the vendored host files (tools/test/fixtures/npcfavor_host, see PIN.md) touch when
-- a real NPCSystem boots through production's own entry point (NPCSystem.new,
-- onMissionLoaded, the first-frame init updater), saves through saveToXMLFile
-- into an in-memory file and reloads through loadFromXMLFile. Lifted from the
-- host's own RSF-F357-host_core_spec_test.lua world section so the caller is
-- driven against the host's real roster load, claim and getter, never a stand-in.
--
-- Nothing here hand-fills a person, a number or a token: the town comes from the
-- fixture's houses through the host's own creators; the consultant only ever comes
-- from the host's claim.
F357Host = {}

TimeHelper = TimeHelper or { getGameTimeMs = function() return (g_currentMission and g_currentMission.time) or 0 end }
VectorHelper = VectorHelper or { distance2D = function(x1, z1, x2, z2) local dx, dz = x1 - x2, z1 - z2 return math.sqrt(dx * dx + dz * dz) end }
FSBaseMission = FSBaseMission or { INGAME_NOTIFICATION_INFO = 1, INGAME_NOTIFICATION_OK = 2 }
FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, MAX_FARM_ID = 8, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15 }
MoneyType = MoneyType or { OTHER = 3 }
Logging = Logging or { info = function() end, warning = function() end, error = function() end }
local LIVE_FARMS = { [1] = { farmId = 1, name = "Farm 1", money = 100000 }, [2] = { farmId = 2, name = "Farm 2", money = 100000 } }
g_farmManager = g_farmManager or {
    getFarmById = function(_, id) return LIVE_FARMS[id] end,
    getFarms = function(_) local l = {} for _, f in pairs(LIVE_FARMS) do l[#l + 1] = f end table.sort(l, function(a, b) return a.farmId < b.farmId end) return l end,
}
g_modManager = g_modManager or { getModByName = function() return nil end }
addConsoleCommand = addConsoleCommand or function() end
if g_i18n == nil then g_i18n = {} end
g_i18n.getText = g_i18n.getText or function(_, key) return key end
g_i18n.hasText = g_i18n.hasText or function() return false end

-- Nodes: world positions by node id.
local NODES = {}
function getWorldTranslation(node)
    local p = NODES[node]
    if p == nil then return 0, 0, 0 end
    return p.x, p.y, p.z
end
function getTerrainHeightAtWorldPos(_, x, _y, z) return 5 end

-- Subsystems NPCSystem.new instantiates that are not under test here.
NPCEntity = { new = function(sys)
    return {
        npcSystem = sys, npcEntities = {}, created = {}, removed = {},
        initialize = function() end,
        createNPCEntity = function(self, npc) self.npcEntities[npc.id] = { npcId = npc.id } self.created[#self.created + 1] = npc.id return true end,
        removeNPCEntity = function(self, npc) if self.npcEntities[npc.id] then self.npcEntities[npc.id] = nil self.removed[#self.removed + 1] = npc.id end end,
        updateNPCEntity = function() end,
        drawMapLabels = function() end,
    }
end }
NPCScheduler = { new = function()
    return { getCurrentHour = function() return 12 end, getCurrentMinute = function() return 0 end,
        getCurrentDay = function() return 1 end, getWeatherFactor = function() return 1 end,
        update = function() end, scheduledNPCInteractions = {} }
end }
NPCInteractionUI = { new = function() return { update = function() end, delete = function() end, updateFavorList = function() end } end }
NPCFavorHUD = { new = function() return { loadFromSettings = function() end, flashFavor = function() end, update = function() end, delete = function() end } end }
NPCSettingsIntegration = { new = function() return { initialize = function() end } end }
NPCSettingsPanel = { new = function() return { initialize = function() end, update = function() end, delete = function() end } end }
NPCFavorGUI = { new = function() return { registerConsoleCommands = function() end } end }

-- In-memory XML file store: the host's production writer and reader meet here.
local DISK = {}
local function xmlMock(store)
    local m = { store = store }
    m.setInt = function(_, k, v) store[k] = v end
    m.setFloat = function(_, k, v) store[k] = v end
    m.setString = function(_, k, v) store[k] = v end
    m.setBool = function(_, k, v) store[k] = v end
    local function get(_, k, default) if store[k] ~= nil then return store[k] end return default end
    m.getInt, m.getFloat, m.getString, m.getBool = get, get, get, get
    m.hasProperty = function(_, k) return store[k] ~= nil end
    m.iterate = function(_, prefix, fn)
        local i = 0
        while true do
            local key = prefix .. "(" .. i .. ")"
            local found = false
            for k in pairs(store) do
                if k:sub(1, #key + 1) == key .. "#" or k:sub(1, #key + 1) == key .. "." then found = true break end
            end
            if not found then return end
            fn(i, key)
            i = i + 1
        end
    end
    m.delete = function() end
    m.save = function(self) DISK[self.path] = self.store end
    return m
end
XMLFile = {
    create = function(_, path, _root) local m = xmlMock({}) m.path = path return m end,
    loadIfExists = function(_, path, _root)
        local store = DISK[path]
        if store == nil then return nil end
        local copy = {}
        for k, v in pairs(store) do copy[k] = v end
        local m = xmlMock(copy) m.path = path
        return m
    end,
}
function F357Host.fileAt(dir) return DISK[dir .. "/npc_favor.xml"] end

-- Placeables: a house is a table with a root node, a unique id and an owner.
local NODE_SEQ = 100
local function house(uid, x, z, ownerFarmId)
    NODE_SEQ = NODE_SEQ + 1
    NODES[NODE_SEQ] = { x = x, y = 5, z = z }
    return { rootNode = NODE_SEQ, typeName = "farmhouse", spec_farmhouse = {}, ownerFarmId = ownerFarmId or 0,
        getName = function() return "House " .. uid end, getUniqueId = function() return uid end }
end
function F357Host.town(n)
    local list = {}
    for i = 1, n do list[i] = house("house_" .. i, i * 100, i * 100, 0) end
    return list
end

local function newMission(opts)
    return {
        time = 1000, environment = { currentDay = 1, daysPerPeriod = 1 },
        missionInfo = { savegameDirectory = opts.dir or "sg" },
        isMissionStarted = true, terrainRootNode = 1, terrainSize = 2048,
        placeableSystem = { placeables = opts.placeables or {} },
        updateables = {},
        addUpdateable = function(self, u) self.updateables[#self.updateables + 1] = u end,
        getFarmId = function() return 1 end,
        addIngameNotification = function(self, kind, text) self.notices = self.notices or {} self.notices[#self.notices + 1] = text end,
        addMoney = function() end,
        getIsServer = function() return g_server ~= nil end,
    }
end

--- Boot the host through production's own entry point. Returns the system and
--- its mission; the init updater is ticked once. Exposes the system on the
--- mission as the host's main.lua does (mission.npcFavorSystem), which is the
--- door the SCS caller detects and reads.
function F357Host.boot(opts)
    opts = opts or {}
    g_server = (opts.server ~= false) and { broadcastEvent = function() end } or nil
    g_client = nil
    g_localPlayer = nil
    g_currentMission = newMission(opts)
    NPCStateLedgerBridge.active, NPCStateLedgerBridge.delivered, NPCStateLedgerBridge.pendingState = false, false, nil
    local sys = NPCSystem.new(g_currentMission, "mod/", "FS25_NPCFavor")
    g_NPCSystem = sys
    if opts.ledger then
        g_currentMission.stateLedger = opts.ledger
        NPCStateLedgerBridge.register()
    end
    sys:onMissionLoaded()
    sys.settings.maxNPCs = opts.maxNPCs or 3
    sys.settings.npcDriveVehicles = false
    sys.settings.enableFavors = false
    sys.settings.showNotifications = false
    sys.settings.debugMode = false
    if not opts.noTick then
        sys._initResult = g_currentMission.updateables[1]:update(16)
    end
    g_currentMission.npcFavorSystem = sys
    return sys, g_currentMission
end

-- Stub ledger: stores hooks, delivers its block on parse (or when told to).
function F357Host.newLedger(block, hold)
    local L = { modules = {}, block = block, hasParsed = false, hold = hold == true }
    function L:registerModule(name, hooks) self.modules[name] = hooks if self.hasParsed then hooks.deserialize(self.block) end return true end
    function L:parseFile() if self.hasParsed or self.hold then return end self:deliver() end
    function L:deliver() self.hasParsed = true for _, h in pairs(self.modules) do h.deserialize(self.block) end end
    function L:serialize(name) return self.modules[name].serialize() end
    return L
end

--- One snapshot page from a server to a pure client through the host's own
--- event stream round trip (the client becomes READY from a complete snapshot).
function F357Host.deliverSnapshot(server, client)
    local saved = { g_server, g_NPCSystem, g_currentMission }
    g_server, g_NPCSystem = { broadcastEvent = function() end }, server
    local snapshot = server:publishSnapshot()
    local pages = {}
    for i = 1, snapshot.pageCount do pages[i] = NPCPersonRoster.pageOf(snapshot, i) end
    g_server, g_NPCSystem = nil, client
    for _, page in ipairs(pages) do
        local ev = NPCStateSyncEvent.new(page)
        local s = _sfMockStream()
        ev:writeStream(s, nil)
        NPCStateSyncEvent.emptyNew():readStream(s, nil)
    end
    g_server, g_NPCSystem, g_currentMission = saved[1], saved[2], saved[3]
    return snapshot
end
