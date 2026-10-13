--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/events/CropStressSettingsSyncEvent.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 268: the moisture store's Time Guard version-skew guard fires on a Time Guard without the
-- simulation flow class.
--
-- WHY. SoilMoistureSystem:registerDailyAccrual refused a Time Guard without the simulation class by reading
-- tg.flowClasses, a field Time Guard never publishes, and the bare global TimeGuardScheduler, which Time
-- Guard defines in its own mod environment (mods.lua:482-505). Both were nil in a game, so on Time Guard
-- v1.0.0.0 (fa74ff8, FLOW_CLASSES calendar, usage, event: TimeGuardScheduler.lua:29), which shipped, the
-- daily settle registered and Time Guard filed it under calendar (TimeGuardScheduler.lua:66-69). The
-- simulation class first shipped in v1.0.1.0. The store now reads the class list through the instance,
-- tg.scheduler.FLOW_CLASSES, nil-safe: TimeGuard.lua:38 sets self.scheduler in every version, and the
-- instance's metatable comes from Class(TimeGuardScheduler), whose __index is the class table.
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs (maint165_main_world.lua): Mission00.load creates the
-- manager, loadMission00Finished runs initialize(), which installs the field-ready updater through the
-- mission's addUpdateable. The updater then runs as the engine runs it, once the mission has started and the
-- map has a field, and registers the daily settle on the server. Time Guard is reachable only as the mission's
-- handle, modelled to its real shape: registerAccrual files through a scheduler whose class table it reaches
-- through its metatable, and coerces an unknown class to calendar. Each case reinstalls the updater through
-- the manager's own installer, as initialize() does, on a store whose registration flag is clear.
--
--   E0  [reached] SCS's environment has no TimeGuardScheduler; the updater reached Time Guard
--   E1  a current Time Guard: the settle registers under simulation
--   E2  a v1.0.0.0 Time Guard: no registration, nothing coerced, the fallback day hook stays
--   E3  a Time Guard with no scheduler table: the settle registers as before (the read is nil-safe)

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
end
local function quiet(fn)
    local realPrint = print
    print = function() end
    local ok, err = pcall(fn)
    print = realPrint
    if not ok then error(err, 0) end
end

Logging = Logging or { info = function() end, warning = function() end, error = function() end, devInfo = function() end }

local V100 = { calendar = true, usage = true, event = true }
local CURRENT = { calendar = true, usage = true, event = true, simulation = true }

local function timeGuard(classes)
    local filed = {}
    local SchedulerClass = { FLOW_CLASSES = classes }
    local scheduler = nil
    if classes ~= nil then
        scheduler = setmetatable({ accruals = {} }, { __index = SchedulerClass })   -- Class(): __index = members
    end
    return {
        scheduler = scheduler,
        registerAccrual = function(_self, id, spec)
            local known = classes or CURRENT
            local fc = spec.flowClass or "calendar"
            if not known[fc] then fc = "calendar" end                              -- TimeGuardScheduler.lua:66-69
            filed[#filed + 1] = tostring(id) .. "=" .. fc
            return true
        end,
        unregisterAccrual = function() return true end,
    }, filed
end

local mission = g_currentMission
local UPDATERS = {}
mission.addUpdateable = function(_self, u) UPDATERS[#UPDATERS + 1] = u end
g_fieldManager = { fields = { { farmland = { id = 7 }, posX = 100, posZ = 100 } } }
g_farmlandManager = g_farmlandManager or { getFarmlandOwner = function() return 1 end,
    getFarmlandAtWorldPosition = function() return { id = 7 } end }

local mgr
--- Run the field-ready updater the manager installed, as the engine's updateable loop would.
local function runUpdaters()
    local n = #UPDATERS
    for i = 1, n do
        local u = UPDATERS[i]
        -- An updater that raises stays registered, as in the engine's loop; the case's rows then see no
        -- registration rather than a crashed group.
        if u ~= nil and not u._done then pcall(quiet, function() u:update(16) end) end
    end
end

--- One case: a fresh registration against the given Time Guard, through the manager's own installer.
local function case(classes)
    local tg, filed = timeGuard(classes)
    mission.timeGuard = tg
    g_timeGuard = nil
    mgr.soilSystem._tgAccrualRegistered = nil
    mgr._fieldReadyUpdaterInstalled = false
    quiet(function() mgr:installFieldReadyUpdater() end)
    runUpdaters()
    return filed, mgr.soilSystem._tgAccrualRegistered == true
end

group("E", function()
    g_server, g_client = {}, nil
    quiet(function() Mission00.load(mission) end)
    mission.isMissionStarted = true
    quiet(function() Mission00.loadMission00Finished(mission) end)
    mgr = mission.cropStressManager
    T.eq("E0 SCS's environment has no TimeGuardScheduler (it is Time Guard's own global)", rawget(_G, "TimeGuardScheduler"), nil)

    local filed, flag = case(CURRENT)
    T.ok("E0 [reached] main.lua built the manager and its field-ready updater ran and reached Time Guard", #filed == 1, tostring(#filed))
    T.eq("E1 a current Time Guard: the daily settle registers under simulation", table.concat(filed, ",") .. " " .. tostring(flag),
        SoilMoistureSystem.DAILY_ACCURAL_ID .. "=simulation true")

    filed, flag = case(V100)
    T.eq("E2 [entry point] NAMED (row 268): a v1.0.0.0 Time Guard gets no registration, so nothing is coerced to calendar, and the store keeps its fallback day hook",
        #filed .. " " .. tostring(flag), "0 false")

    filed, flag = case(nil)
    T.eq("E3 a Time Guard with no scheduler table: the settle registers as before (the read is nil-safe)",
        table.concat(filed, ",") .. " " .. tostring(flag), SoilMoistureSystem.DAILY_ACCURAL_ID .. "=simulation true")
end)

g_server, g_client = nil, nil
