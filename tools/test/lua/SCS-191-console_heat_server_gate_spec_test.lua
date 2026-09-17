--!load: src/SoilMoistureSystem.lua, src/CropStressManager.lua, src/settings/CropStressSettingsPanel.lua
-- SCS #191: csSimulateHeat and the settings panel's Simulate Heat Wave button never
-- run the hourly moisture and stress simulation on a pure multiplayer client. The
-- engine creates g_server only for singleplayer and a hosted game
-- (MPLoadingScreen:startLocal :416, :startServer :436); a joining client has
-- g_client only. The soil hourly update is the REAL SoilMoistureSystem one, counted.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server = {}
    g_cropStressManager = nil
end

--- A manager with a real ZONE soil system (field 1 at 0.6), a counted stress
--- modifier and a weather double whose evaporation follows the temperature.
local function heatManager()
    -- A bare instance: CropStressManager.new() constructs every subsystem; this
    -- spec needs only consoleSimulateHeat and the three members it reads.
    local mgr = setmetatable({}, CropStressManager)
    local soil = SoilMoistureSystem.new(mgr)
    soil.isInitialized = true
    soil.providerMode = "ZONE"
    soil.fieldData[1] = { fieldId = 1, moisture = 0.6, soilType = "loamy", cells = {}, cellSum = 0, cellCount = 0 }
    local counts = { soil = 0, stress = 0 }
    local realHourly = soil.hourlyUpdate
    soil.hourlyUpdate = function(self, ...) counts.soil = counts.soil + 1; return realHourly(self, ...) end
    mgr.soilSystem = soil
    mgr.stressModifier = { hourlyUpdate = function() counts.stress = counts.stress + 1 end }
    mgr.weatherIntegration = {
        currentTemp = 20.0, hourlyRainAmount = 0.2,
        getHourlyEvapMultiplier = function(self) return self.currentTemp > 30 and 2.0 or 1.0 end,
        getHourlyRainAmount = function(self) return self.hourlyRainAmount end,
    }
    return mgr, soil, counts
end

local function panelFor(mgr)
    g_cropStressManager = mgr
    local popups = {}
    local panel = setmetatable({}, { __index = CropStressSettingsPanel })
    panel.showPopup = function(self, msg) popups[#popups + 1] = msg end
    return panel, popups
end

group("C client", function()
    local mgr, soil, counts = heatManager()
    g_server = nil
    local ret = mgr:consoleSimulateHeat("3")
    T.eq("C1a a client's csSimulateHeat answers false", ret, false)
    T.eq("C1b and runs no soil hourly update", counts.soil, 0)
    T.eq("C1c nor any stress hourly update", counts.stress, 0)
    T.eq("C1d the client's field moisture is untouched", soil.fieldData[1].moisture, 0.6)
    T.eq("C1e the weather is never overridden", mgr.weatherIntegration.currentTemp, 20.0)

    local panel, popups = panelFor(mgr)
    panel:handleClick("admin_action_admin_heat", { actionId = "admin_heat" })
    T.eq("C2a a client admin's panel button runs no hourly update", counts.soil + counts.stress, 0)
    T.eq("C2b and says it runs on the host only", popups[#popups], "Heat wave simulation runs on the host only.")
end)

group("H host", function()
    local mgr, soil, counts = heatManager()
    g_server = {}
    local ret = mgr:consoleSimulateHeat("1")
    T.ok("H1a [reached: the host runs the simulation]", ret ~= false)
    T.eq("H1b one day is 24 soil hourly updates", counts.soil, 24)
    T.eq("H1c and 24 stress hourly updates", counts.stress, 24)
    T.ok("H1d the host's field dried", soil.fieldData[1].moisture < 0.6)
    T.eq("H1e the weather is restored", tostring(mgr.weatherIntegration.currentTemp) .. ":" .. tostring(mgr.weatherIntegration.hourlyRainAmount), "20.0:0.2")

    counts.soil, counts.stress = 0, 0
    local panel, popups = panelFor(mgr)
    panel:handleClick("admin_action_admin_heat", { actionId = "admin_heat" })
    T.eq("H2a the host panel button runs three days", counts.soil, 72)
    T.ok("H2b and reports the simulation", type(popups[#popups]) == "string" and popups[#popups]:find("3-day heat wave simulated", 1, true) ~= nil)
end)
