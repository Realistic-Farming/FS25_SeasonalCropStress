--!load: src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/WeatherIntegration.lua, src/CropStressModifier.lua, src/CropConsultant.lua, src/ui/CsPDAScreen.lua, src/ui/CsRfPdaGuest.lua, gui/CropConsultantDialog.lua
-- RSF-F245 v0.7 item 6: the host consumer floor. A field with no current moisture
-- is never compared, ranked, averaged, formatted or alerted on as a number, and each
-- door refreshes first. Groups: M stress modifier, C consultant handlers, W weather
-- forecast, G guest PDA, P PDA stats, D consultant dialog recommendation.
-- NOT covered here (named in the PR): HUDOverlay drawing and grouped sort,
-- IrrigationScheduleDialog labels, the settings driest list, the consultant dialog
-- list rows and the guest PDA field rows, topRiskFields and detail band: each is a
-- render or a local function the bench cannot reach without a GUI double.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
    g_server = {}
    g_cropStressManager = nil
    g_currentMission.cropStressManager = nil
    g_currentMission.fieldManager = nil
end

local SQ = F245H.square(-8, -8, 8, 8)

--- A ZONE system: field 1 current at `a`, field 2 unavailable, field 3 current at `c`.
--- refreshForPublication is counted.
local function zoneFields(a, c)
    local z = SoilMoistureSystem.new({})
    z.isInitialized = true
    z.providerMode = "ZONE"
    F245H.addField(z, 1, SQ, a)
    local d2 = F245H.addField(z, 2, SQ, 0.9)
    z:_markAggregateUnavailable(d2, "NO_CURRENT_VALUE")
    if c ~= nil then F245H.addField(z, 3, SQ, c) end
    local box = { refreshes = 0 }
    local real = z.refreshForPublication
    z.refreshForPublication = function(self) box.refreshes = box.refreshes + 1; return real(self) end
    return z, box
end

local function managerFor(soil)
    local mgr = {
        soilSystem = soil,
        stressModifier = { fieldStress = { [1] = 0.2, [2] = 0.2, [3] = 0.2 } },
        fieldById = {},
    }
    function mgr:getMoisture(fid) return (soil:getMoisture(fid)) end
    function mgr:getStress(fid) return 0.5 end
    function mgr.getLocalFarmId() return 1 end
    return mgr
end

-- =====================================================================
-- M: CropStressModifier hourly
-- =====================================================================
group("M stress modifier", function()
    local z, box = zoneFields(0.3, 0.5)
    local mgr = managerFor(z)
    mgr.fieldById = { [1] = {}, [2] = {}, [3] = {} }
    local mod = CropStressModifier.new(mgr)
    mod.isInitialized = true
    g_currentMission.fieldManager = {}
    local seen = {}
    mod.processFieldStress = function(self, field, fid, moisture) seen[#seen + 1] = fid .. "=" .. tostring(moisture) end
    mod:hourlyUpdate(1)
    table.sort(seen)
    T.eq("M1a the modifier refreshes first", box.refreshes, 1)
    T.eq("M1b a field with no current value is skipped; the others process", table.concat(seen, ","), "1=0.3,3=0.5")
end)

-- =====================================================================
-- C: CropConsultant handlers
-- =====================================================================
group("C consultant", function()
    local z, box = zoneFields(0.45, nil)
    local mgr = managerFor(z)
    local c = CropConsultant.new(mgr)
    c.isInitialized = true
    local alerts = {}
    c.isOwnedByLocalPlayer = function() return true end
    c.getCropName = function() return "wheat" end
    c.showAlert = function(self, fid, moisture, severity) alerts[#alerts + 1] = fid .. ":" .. severity end

    c:onMoistureUpdated({ fieldId = 2, previous = nil, current = 0.3 })
    c:onMoistureUpdated({ fieldId = 2, previous = 0.5, current = nil })
    T.eq("C1a a missing previous or current is no crossing", #alerts, 0)
    c:onMoistureUpdated({ fieldId = 1, previous = 0.5, current = 0.3 })
    T.eq("C1b [reached: a numeric crossing alerts]", alerts[1], "1:WARNING")

    alerts = {}
    c:onCriticalThreshold({ fieldId = 5, moistureLevel = nil })
    T.eq("C2a a critical event with no number raises no alert", #alerts, 0)
    T.eq("C2b and never uses up the field's cooldown", c.alertCooldowns["5_critical"], nil)
    c:onCriticalThreshold({ fieldId = 5, moistureLevel = 0.1 })
    T.eq("C2c [reached: a numeric critical event alerts]", alerts[1], "5:CRITICAL")

    alerts = {}
    c:hourlyEvaluate()
    T.eq("C3a the band check refreshes first", box.refreshes, 1)
    T.eq("C3b a field with no current value is never evaluated; a current INFO field is", table.concat(alerts, ","), "1:INFO")
end)

-- =====================================================================
-- W: weather forecast
-- =====================================================================
group("W forecast", function()
    local z = zoneFields(0.45, nil)
    local w = WeatherIntegration.new(managerFor(z))
    T.eq("W1 a field with no current value gets no projections, never a 0.5 start", w:getMoistureForecast(2, 3), nil)
    local p = w:getMoistureForecast(1, 3)
    T.ok("W2 [reached: a current field is projected]", type(p) == "table" and #p == 3)
end)

-- =====================================================================
-- G: guest PDA glance stats and next-step line
-- =====================================================================
group("G guest PDA", function()
    local z, box = zoneFields(0.3, 0.5)
    g_currentMission.cropStressManager = managerFor(z)
    local stats = CsRfPdaGuest.computeGlanceStats()
    T.eq("G1a the glance refreshes first", box.refreshes, 1)
    T.eq("G1b every field stays tracked", stats and stats.totalTracked, 3)
    T.near("G1c the average is over fields with a reading only", stats and stats.avgMoisture, 0.4, 1e-12)

    local none = SoilMoistureSystem.new({})
    none.providerMode = "ZONE"
    none:_markAggregateUnavailable(F245H.addField(none, 1, SQ, 0.2), "NO_CURRENT_VALUE")
    g_currentMission.cropStressManager = managerFor(none)
    stats = CsRfPdaGuest.computeGlanceStats()
    T.eq("G2 no field with a reading: no average, never 0", stats and stats.avgMoisture, nil)

    local cropMgr = managerFor(z)
    cropMgr.fieldById = { [1] = { fieldState = { fruitTypeIndex = 5 } }, [2] = { fieldState = { fruitTypeIndex = 5 } } }
    g_currentMission.cropStressManager = cropMgr
    local body, color = CsRfPdaGuest.buildNextStepLine(2)
    T.eq("G3a a cropped field with no reading gets no moisture advice line", tostring(body) .. tostring(color), "nilnil")
    body = CsRfPdaGuest.buildNextStepLine(1)
    T.ok("G3b [reached: a current field gets a line]", type(body) == "string" and body ~= "")
end)

-- =====================================================================
-- P: PDA stats
-- =====================================================================
group("P PDA stats", function()
    local function textStub()
        local t = { text = "?" }
        function t:setText(v) self.text = v end
        function t:setTextColor() end
        return t
    end
    local none = SoilMoistureSystem.new({})
    none.providerMode = "ZONE"
    none:_markAggregateUnavailable(F245H.addField(none, 1, SQ, 0.2), "NO_CURRENT_VALUE")
    g_currentMission.cropStressManager = managerFor(none)
    g_cropStressManager = g_currentMission.cropStressManager
    local screen = setmetatable({ statsAvgMoisture = textStub() }, { __index = CsPDAScreen })
    screen:_rebuildStats()
    T.eq("P1 no field with a reading: the average cell is blank", screen.statsAvgMoisture.text, "")

    local z = zoneFields(0.3, 0.5)
    g_currentMission.cropStressManager = managerFor(z)
    g_cropStressManager = g_currentMission.cropStressManager
    screen = setmetatable({ statsAvgMoisture = textStub() }, { __index = CsPDAScreen })
    screen:_rebuildStats()
    T.eq("P2 the average is over fields with a reading only", screen.statsAvgMoisture.text, "40%")
end)

-- =====================================================================
-- D: consultant dialog recommendation
-- =====================================================================
group("D consultant dialog", function()
    local none = SoilMoistureSystem.new({})
    none.providerMode = "ZONE"
    none:_markAggregateUnavailable(F245H.addField(none, 1, SQ, 0.1), "NO_CURRENT_VALUE")
    g_cropStressManager = managerFor(none)
    local text = { value = nil }
    function text:setText(v) self.value = v end
    local dlg = setmetatable({ recommendText = text }, { __index = CropConsultantDialog })
    dlg:buildRecommendation()
    T.eq("D1 fields exist but none has a reading: the dash, never an urgent line", text.value, "—")

    local z = zoneFields(0.45, 0.1)
    local worstFid = nil
    g_cropStressManager = managerFor(z)
    g_cropStressManager.weatherIntegration = { getMoistureForecast = function(_, fid) worstFid = fid; return nil end }
    text.value = nil
    dlg:buildRecommendation()
    T.ok("D2a [reached: a current field gets a recommendation]", type(text.value) == "string" and text.value ~= "—")
    T.eq("D2b the worst field is chosen among fields with a reading (field 3 at 0.1, not unavailable field 2)", worstFid, 3)
end)
