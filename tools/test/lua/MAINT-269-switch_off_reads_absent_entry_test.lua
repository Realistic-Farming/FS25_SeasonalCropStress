--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/events/CropStressSettingsSyncEvent.lua, src/CropStressManager.lua, src/ui/CsRfPdaGuest.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 269: with SCS switched off, its companion reads answer as SCS absent, its harvest hook
-- takes no cut, and its own screens show no reading.
--
-- WHY. The master switch stops the hourly simulation (CropStressManager:onHourlyTick returns at its first
-- line), so moisture, stress and the weather reads freeze. Before this row the companion facade never
-- read the switch: every reader (Soil's compaction and traffic drag once Soil #1109 lands, the drilling
-- advisory, FarmTablet, SCS's own HUD and PDA) kept acting on the frozen state, and the harvest hook kept
-- cutting yield from the stress it froze at. Bob's R-15 on row 269 (2026-10-08) set the shape: the facade's
-- simulated and weather getters answer nil while off, the harvest hook stands down with them, and SCS's
-- own screens gate their direct store reads to their existing no-reading states.
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs (maint165_main_world.lua): Mission00.load creates the
-- manager, loadMission00Finished runs initialize() and registers the SettingsHub bridge, reachable only as
-- the mission's handle, and Mission00.onStartMission installs the harvest hook on the engine's
-- Cutter.processCutterArea. The world: one map field the store enumerates through its own
-- enumerateFields, the engine's cutter, which adds 10 multiplier units per pass, and farmland 7 under the
-- cut. Stress enters through the csForceStress console command main.lua registers. The switch flips where
-- production flips it: SettingsHub calling the registered onChange("enabled", false) on the server, which
-- routes through the one settings owner (applyAuthoritativeSettingChange).
--
--   E0  [reached] main.lua built the manager, the bridge registered, the hook installed, the field tracked
--   N   switched on: the getters answer, a stressed cut is reduced, the PDA and the HUD list show a reading
--   F   switched off: every gated getter answers nil, a stressed cut yields in full, the PDA counts no
--       reading and the HUD list shows field 7 with none
--   R   switched back on: the getters answer again (the gate reads the live setting)

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
Permission = Permission or { MASTER_USER = 1 }

-- The engine's Utils.overwrittenFunction (Utils.lua): the new function receives the old one as superFunc.
Utils.overwrittenFunction = Utils.overwrittenFunction or function(oldFunc, newFunc)
    return function(self, ...) return newFunc(self, oldFunc, ...) end
end

-- The map: one field on farmland 7, and the farmland under any cut.
g_fieldManager = { fields = { { farmland = { id = 7 }, posX = 100, posZ = 100 } } }
g_farmlandManager = {
    getFarmlandAtWorldPosition = function(_, _x, _z) return { id = 7 } end,
    getFarmlandOwner = function(_, _id) return 1 end,
}
g_vehicleTypeManager = { types = {} }

-- The engine's cutter: each pass adds 10 multiplier units, the grain the combine then receives.
Cutter = { processCutterArea = function(vehicle, _workArea, _dt)
    local p = vehicle.spec_cutter.workAreaParameters
    p.lastMultiplierArea = p.lastMultiplierArea + 10
    return 10, 10
end }
local function cut()
    local vehicle = { spec_cutter = { workAreaParameters = { lastMultiplierArea = 0 } } }
    Cutter.processCutterArea(vehicle, { start = 1 }, 16)
    return vehicle.spec_cutter.workAreaParameters.lastMultiplierArea
end

local mgr
-- SCS's HUD list: the row for field 7 after the HUD rebuilds its rows, as its update does.
local function hudRow7()
    mgr.hudOverlay:rebuildDisplayRows()
    for _, r in ipairs(mgr.hudOverlay.displayRows or {}) do
        if r.fieldId == 7 then return r end
    end
    return nil
end

local mission = g_currentMission
local REG = {}
g_settingsHub = nil
mission.settingsHub = { registerModule = function(_, modId, spec) REG[modId] = spec return true end }
local SERVER = { broadcastEvent = function() end }

local GETTERS = {
    -- The field read only: a spot read also needs the field's outline (SoilMoistureSystem:_pointInParcel),
    -- which this world does not give it, so a spot row would read nil with or without the gate. The gate
    -- is the getter's first line, above its arguments.
    { "getMoisture",          function(m) return m:getMoisture(7) end },
    { "getStress",            function(m) return m:getStress(7) end },
    { "getYieldKeepFactor",   function(m) return m:getYieldKeepFactor(7) end },
    { "getRainOutlook",       function(m) return m:getRainOutlook(3) end },
    { "getTemperature",       function(m) return m:getTemperature() end },
    { "getEvaporativeDemand", function(m) return m:getEvaporativeDemand() end },
}

group("E0 entry", function()
    g_server, g_client = SERVER, nil
    quiet(function() Mission00.load(mission) end)
    quiet(function() Mission00.loadMission00Finished(mission) end)
    quiet(function() Mission00.onStartMission(mission) end)
    mgr = mission.cropStressManager
    quiet(function() mgr.soilSystem:enumerateFields() end)
    quiet(function()
        local c = MAINT165Console.commands["csForceStress"]
        c.target[c.functionName](c.target, "7")
    end)
    T.ok("E0 [reached] main.lua built the manager, registered the bridge with the mission's SettingsHub, installed the harvest hook, and the store tracks field 7",
        mgr ~= nil and REG["SeasonalCropStress"] ~= nil and CropStressModifier.harvestHookInstalled == true
        and mgr.soilSystem.fieldData[7] ~= nil and mgr.settings.enabled == true)
end)

group("N on", function()
    for _, g in ipairs(GETTERS) do
        local ok, v = pcall(g[2], mgr)
        T.ok("N " .. g[1] .. " answers while SCS is on", ok and v ~= nil)
    end
    T.eq("N the facade's moisture is the store's own", mgr:getMoisture(7), mgr.soilSystem:getMoisture(7))
    T.eq("N stress forced through csForceStress reads 1.0", mgr:getStress(7), 1.0)
    T.ok("N a stressed cut is reduced (10 units in, fewer out)", cut() < 10)
    local s = CsRfPdaGuest.computeGlanceStats()
    T.ok("N the PDA glance counts field 7 with a reading and its stress", s ~= nil and s.avgMoisture ~= nil and s.avgStress > 0)
    local r = hudRow7()
    T.ok("N the HUD list shows field 7 with its moisture", r ~= nil and type(r.moisture) == "number")
end)

group("F off", function()
    quiet(function() REG["SeasonalCropStress"].onChange("enabled", false, nil) end)
    T.eq("F [entry point] SettingsHub's onChange on the server switched SCS off through the settings owner", mgr.settings.enabled, false)
    for _, g in ipairs(GETTERS) do
        local ok, v = pcall(g[2], mgr)
        T.ok("F " .. g[1] .. " answers nil while SCS is off", ok and v == nil)
    end
    -- getCriticalAlertHint is gated too but has no row: with no AutoDrive in this world it answers nil
    -- with or without the gate, so a row could not fail.
    local okC, errC = pcall(function()
        local c = MAINT165Console.commands["csStatus"]
        quiet(function() c.target[c.functionName](c.target) end)
    end)
    T.ok("F csStatus (main.lua's console command) prints its driest fields with SCS off, without error", okC, tostring(errC))
    -- Soil's read, as SoilFertilityManager:_blendedWetness01 makes it: pcall, and a non-number means SCS
    -- absent, which takes the rain scalar (Soil #1109's bench row E2 pins that half).
    local okS, m = pcall(function() return mission.cropStressManager:getMoisture(7) end)
    T.ok("F Soil's pcall'd moisture read gets no number, so its compaction blend takes the rain scalar", okS and type(m) ~= "number")
    T.eq("F the store itself still holds the frozen moisture (nothing was cleared)", type(mgr.soilSystem:getMoisture(7)), "number")
    T.eq("F NAMED (Bob's R-15, Desk's ruling): a stressed cut with SCS off yields in full", cut(), 10)
    local s = CsRfPdaGuest.computeGlanceStats()
    T.ok("F the PDA glance still tracks field 7 but counts no reading, no band and no stress",
        s ~= nil and s.totalTracked == 1 and s.avgMoisture == nil and s.healthy + s.warning + s.critical == 0
        and s.avgStress == 0 and s.yieldLoss == 0)
    local r = hudRow7()
    T.ok("F the HUD list still shows field 7, with no reading and no stress", r ~= nil and r.moisture == nil and r.stress == 0)
end)

group("R back on", function()
    quiet(function() REG["SeasonalCropStress"].onChange("enabled", true, nil) end)
    T.eq("R the facade's moisture answers again when SCS is switched back on", mgr:getMoisture(7), mgr.soilSystem:getMoisture(7))
    T.ok("R a stressed cut is reduced again", cut() < 10)
end)

g_server, g_client = nil, nil
