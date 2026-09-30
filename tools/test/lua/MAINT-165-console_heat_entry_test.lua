--!load: src/WeatherIntegration.lua, src/SoilFineSnapshot.lua, src/CropStressModifier.lua, src/HUDOverlay.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/FinanceIntegration.lua, src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/IrrigationManager.lua, src/RunoffSystem.lua, src/settings/CropStressSettings.lua, src/settings/CropStressSettingsPanel.lua, src/settings/SettingsHubBridge.lua, src/integrations/CropStressStateLedgerBridge.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/integrations/CropStressMasterHUDBridge.lua, src/events/CropStressMoistureInitEvent.lua, src/events/CropStressHeatRequestEvent.lua, src/events/CropStressHeatResultEvent.lua, src/SaveLoadHandler.lua, src/gui/CsDialogLoader.lua, src/CropStressManager.lua, tools/test/lua/maint165_main_world.lua, main.lua
-- MAINTENANCE row 165: csSimulateHeat prints its own line and returns nothing, like
-- the mod's other ten console commands, so the console has no status word to echo.
--
-- THE ENTRY-POINT BAR (R-18). main.lua itself runs. Its Mission00.load hook creates
-- the manager through the real CropStressManager.new(), and its loadMission00Finished
-- hook runs the real initialize() and registers the console commands (main.lua:341).
-- The command is then run the way the engine runs a console handler: by the
-- registered function name, on the registered target (maint165_main_world.lua).
-- Nothing here builds a manager, a subsystem or a registration by hand; the modules
-- main.lua would source() are --!loaded instead.
--
-- Groups: E the registration, H a host, C a pure client, R a refused day count.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
end

--- Run fn with print captured; returns the printed lines.
local function capturePrints(fn)
    local lines, realPrint = {}, print
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    local ok, err = pcall(fn)
    print = realPrint
    if not ok then error(err, 0) end
    return lines
end

local function countOf(lines, text)
    local n = 0
    for _, l in ipairs(lines) do if l == text then n = n + 1 end end
    return n
end

local mission = g_currentMission
local mgr

group("E registration", function()
    capturePrints(function() Mission00.load(mission) end)
    mgr = mission.cropStressManager
    T.ok("E1 main.lua's Mission00.load creates the manager (CropStressManager.new)", mgr ~= nil)
    capturePrints(function() Mission00.loadMission00Finished(mission) end)
    local cmd = MAINT165Console.commands.csSimulateHeat
    T.ok("E2 its loadMission00Finished registers csSimulateHeat (main.lua:341)", cmd ~= nil)
    T.eq("E3 under the handler name consoleSimulateHeat", cmd and cmd.functionName, "consoleSimulateHeat")
    T.ok("E4 on the manager Mission00.load created", cmd ~= nil and mgr ~= nil and cmd.target == mgr)
end)

group("H host", function()
    g_server = { broadcastEvent = function() end }
    g_client = nil
    local result
    local lines = capturePrints(function() result = MAINT165Console.run("csSimulateHeat", "1") end)
    local ran = "Simulated 1-day heat wave. Check field moisture: stress may have increased."
    T.eq("H1 on a host the handler returns no value", result and result.returned, 0)
    T.eq("H2 so the console has nothing to echo", result and #result.echoed, 0)
    T.eq("H3 and the player sees the heat-wave line once", countOf(lines, ran), 1)
end)

group("C client", function()
    local sent = {}
    g_server = nil
    g_client = { getServerConnection = function()
        return { sendEvent = function(_, event) sent[#sent + 1] = event end }
    end }
    local result
    local lines = capturePrints(function() result = MAINT165Console.run("csSimulateHeat", "3") end)
    T.eq("C1 on a pure client the handler returns no value", result and result.returned, 0)
    T.eq("C2 so the console has nothing to echo", result and #result.echoed, 0)
    T.eq("C3 it sends exactly one request", #sent, 1)
    T.eq("C4 for 3 days", sent[1] and sent[1].days, 3)
    T.eq("C5 and the player sees that it was sent, once", countOf(lines, "Heat wave request sent to the server."), 1)
end)

group("R refused", function()
    g_server = { broadcastEvent = function() end }
    g_client = nil
    local result
    local lines = capturePrints(function() result = MAINT165Console.run("csSimulateHeat", "0") end)
    T.eq("R1 a refused day count returns no value", result and result.returned, 0)
    T.eq("R2 so the console has nothing to echo", result and #result.echoed, 0)
    T.eq("R3 and the player sees the usage line once", countOf(lines, "Usage: csSimulateHeat <1-30>"), 1)
end)
