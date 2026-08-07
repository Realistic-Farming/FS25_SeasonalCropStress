-- =========================================================
-- CsRfPdaGuest
-- Esc RF PDA guest panel for Seasonal Crop Stress.
-- Owned: Claude Engineering Stage-8 BUILD 2026-07-30 (reuse-after-review).
-- Soft-detects g_currentMission.rfEscModules (NO HOST); registerModule.
-- When host present: stand down legacy menuCropStress Esc rail.
-- Glance aggregates match CsPDAScreen:_rebuildStats (required parity).
-- Content table: twin SmoothList on Soil host (csFieldOverviewList).
-- Hang fences: reloadData only on full show (not light tick); Phase B NO-GO.
-- Host-capable SCS-alone (shared chrome package) is a later slice.
-- =========================================================

CsRfPdaGuest = {}

-- Capture at source() time — g_currentModDirectory is often nil at deferred/map-load callbacks.
local MOD_DIR = g_currentModDirectory
local CS_RF_MOD_NAME = g_currentModName
local PANEL_ID = "seasonalCropStress"
local PANEL_ORDER = 20

local COLOR_HEALTHY  = {0.30, 0.80, 0.35, 1}
local COLOR_WARNING  = {0.95, 0.75, 0.20, 1}
local COLOR_CRITICAL = {0.90, 0.25, 0.20, 1}

local _registered = false
local _legacyStoodDown = false

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[CS_RF_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            local lower = text:lower()
            -- Reject unresolved keys (engine often returns "MISSING KEY_NAME").
            if lower ~= tostring(key):lower()
                and text ~= ("$l10n_" .. key)
                and not lower:find("^missing%s")
                and not lower:find("^missing_")
            then
                return text
            end
        end
    end
    return fallback or key
end

local function getMgr()
    -- Prefer mission handle; bare g_cropStressManager is a named temporary fallback.
    if g_currentMission ~= nil and g_currentMission.cropStressManager ~= nil then
        return g_currentMission.cropStressManager
    end
    return g_cropStressManager
end

local function getHost()
    -- Shared module registry only (NO HOST). Never rfPdaHost.
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules
    end
    local env = getfenv(0)
    if env ~= nil and env.g_rfEscModules ~= nil then
        return env.g_rfEscModules
    end
    if RfEscModules ~= nil then
        return RfEscModules.getOrCreate()
    end
    return nil
end

local function getHostPage()
    if g_inGameMenu == nil then
        return nil
    end
    return g_inGameMenu.menuRealisticFarming
end

local function getCropName(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex == 0 then
        return "-"
    end
    local ft = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if ft and ft.name then
        local name = ft.name
        return name:sub(1, 1):upper() .. name:sub(2):lower()
    end
    return "-"
end

local function moistureColor(m)
    if m >= 0.40 then return COLOR_HEALTHY end
    if m >= 0.25 then return COLOR_WARNING end
    return COLOR_CRITICAL
end

local function moistureStatus(m)
    if m >= 0.40 then return tr("cs_pda_status_healthy", "Healthy"), COLOR_HEALTHY end
    if m >= 0.25 then return tr("cs_pda_status_warning", "Warning"), COLOR_WARNING end
    return tr("cs_pda_status_critical", "Critical"), COLOR_CRITICAL
end

--- Aggregate glance stats (parity with CsPDAScreen:_rebuildStats).
---@return table|nil
function CsRfPdaGuest.computeGlanceStats()
    local mgr = getMgr()
    if mgr == nil then
        return nil
    end

    local soilSystem = mgr.soilSystem
    local stressMod = mgr.stressModifier
    local irrMgr = mgr.irrigationManager
    local fieldById = mgr.fieldById or {}
    if soilSystem == nil or soilSystem.fieldData == nil then
        return nil
    end

    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end

    local coveredFields = {}
    if irrMgr and irrMgr.systems then
        for _, sys in pairs(irrMgr.systems) do
            if sys.coveredFields then
                for _, fid in ipairs(sys.coveredFields) do
                    coveredFields[fid] = true
                end
            end
        end
    end

    local totalTracked = 0
    local totalOwned = 0
    local sumMoisture = 0
    local sumStress = 0
    local healthy = 0
    local warning = 0
    local critical = 0
    local irrigatedCount = 0

    for fid, entry in pairs(soilSystem.fieldData) do
        totalTracked = totalTracked + 1
        local m = entry.moisture or 0
        sumMoisture = sumMoisture + m
        if m >= 0.40 then
            healthy = healthy + 1
        elseif m >= 0.25 then
            warning = warning + 1
        else
            critical = critical + 1
        end

        local s = (stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0
        sumStress = sumStress + s

        if coveredFields[fid] then
            irrigatedCount = irrigatedCount + 1
        end

        -- Owned count: field id → farmland.id → getFarmlandOwner (match buildFieldRows).
        local field = fieldById[fid]
        local fl = field and field.farmland
        local farmlandId = fl and fl.id
        if farmId ~= nil and farmId ~= 0 and farmlandId ~= nil and g_farmlandManager ~= nil then
            if g_farmlandManager:getFarmlandOwner(farmlandId) == farmId then
                totalOwned = totalOwned + 1
            end
        end
    end

    local avgMoisture = totalTracked > 0 and (sumMoisture / totalTracked) or 0
    local avgStress = totalTracked > 0 and (sumStress / totalTracked) or 0
    -- Honest max: CropStressModifier.getMaxYieldLoss (not stale 0.60).
    local maxLoss = 0.30
    if stressMod ~= nil and type(stressMod.getMaxYieldLoss) == "function" then
        maxLoss = stressMod:getMaxYieldLoss() or maxLoss
    elseif CropStressModifier ~= nil and CropStressModifier.MAX_YIELD_LOSS ~= nil then
        maxLoss = CropStressModifier.MAX_YIELD_LOSS
    end
    local yieldLoss = avgStress * maxLoss

    local irrSystems = 0
    if irrMgr and irrMgr.systems then
        for _ in pairs(irrMgr.systems) do
            irrSystems = irrSystems + 1
        end
    end

    return {
        totalTracked = totalTracked,
        totalOwned = totalOwned,
        avgMoisture = avgMoisture,
        healthy = healthy,
        warning = warning,
        critical = critical,
        avgStress = avgStress,
        yieldLoss = yieldLoss,
        irrigatedCount = irrigatedCount,
        irrSystems = irrSystems,
    }
end

--- True when a placed irrigation system lists this field in coveredFields.
--- Distinct from mgr:isFieldIrrigated (rate > 0 / actively watering).
local function isFieldCovered(fieldId)
    local mgr = getMgr()
    if mgr == nil or mgr.irrigationManager == nil or mgr.irrigationManager.systems == nil then
        return false
    end
    for _, sys in pairs(mgr.irrigationManager.systems) do
        if sys.coveredFields ~= nil then
            for _, fid in ipairs(sys.coveredFields) do
                if fid == fieldId then
                    return true
                end
            end
        end
    end
    return false
end

--- Sensitive growth window + moisture threshold from CropStressModifier.CROP_WINDOWS.
--- Returns inWindow, criticalMoisture, hasCrop, growthState.
local function getSensitiveWindowInfo(fieldId)
    local mgr = getMgr()
    if mgr == nil then
        return false, nil, false, 0
    end
    local fieldById = mgr.fieldById or {}
    local field = fieldById[fieldId]
    local fti = field and field.fieldState and field.fieldState.fruitTypeIndex or 0
    if fti == nil or fti == 0 then
        return false, nil, false, 0
    end
    local ft = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fti)
    if ft == nil or ft.name == nil then
        return false, nil, true, 0
    end
    local windows = CropStressModifier and CropStressModifier.CROP_WINDOWS
    if windows == nil then
        return false, nil, true, 0
    end
    local window = windows[ft.name:lower()]
    if window == nil then
        return false, nil, true, 0
    end
    local growthState = field.fieldState and field.fieldState.growthState or 0
    if growthState == 0 then
        return false, window.criticalMoisture, true, growthState
    end
    local inWindow = false
    if window.stages ~= nil then
        for _, s in ipairs(window.stages) do
            if growthState == s then
                inWindow = true
                break
            end
        end
    end
    return inWindow, window.criticalMoisture, true, growthState
end

--- One first-action tip for the selected field (Samantha ladder + George APIs).
--- Returns body (no "Next:" prefix), severityColor.
---@return string|nil, table|nil
function CsRfPdaGuest.buildNextStepLine(fieldId)
    if fieldId == nil then
        return nil, nil
    end
    local mgr = getMgr()
    if mgr == nil then
        return nil, nil
    end

    local moisture = 0
    if type(mgr.getMoisture) == "function" then
        moisture = mgr:getMoisture(fieldId) or 0
    end
    local stress = 0
    if type(mgr.getStress) == "function" then
        stress = mgr:getStress(fieldId) or 0
    end
    local covered = isFieldCovered(fieldId)
    local watering = false
    if type(mgr.isFieldIrrigated) == "function" then
        watering = mgr:isFieldIrrigated(fieldId) == true
    end
    local inWindow, winMoist, hasCrop = getSensitiveWindowInfo(fieldId)

    if not hasCrop then
        return tr("cs_rf_pda_next_no_crop",
            "No crop on this field - nothing to stress; pick another row."), COLOR_HEALTHY
    end

    local impactStr = nil
    if mgr.stressModifier ~= nil and type(mgr.stressModifier.getYieldImpactString) == "function" then
        impactStr = mgr.stressModifier:getYieldImpactString(fieldId)
    end
    local keep = 1.0
    if type(mgr.getYieldKeepFactor) == "function" then
        keep = mgr:getYieldKeepFactor(fieldId) or 1.0
    end
    local lossPct = (1.0 - keep) * 100
    local meaningfulLoss = (impactStr ~= nil and impactStr ~= "0%") or lossPct >= 1.0

    local tip = nil
    local color = COLOR_HEALTHY

    -- Priority 1: Critical moisture
    if moisture < 0.25 then
        color = COLOR_CRITICAL
        if watering then
            tip = tr("cs_rf_pda_next_critical_watering",
                "Moisture critical - irrigation is on; wait for moisture to recover, then recheck.")
        elseif covered then
            tip = tr("cs_rf_pda_next_critical_covered",
                "Moisture critical - irrigate now. A system covers this field; confirm it is running.")
        else
            tip = tr("cs_rf_pda_next_critical_uncovered",
                "Moisture critical - irrigate now (spray WATER or place / aim coverage).")
        end
        -- Optional short append when also in a sensitive window (drop if too long).
        if inWindow then
            local append = tr("cs_rf_pda_next_window_append", " Crop is in a sensitive window.")
            if tip ~= nil and (#tip + #append) <= 110 then
                tip = tip .. append
            end
        end

    -- Priority 2: Sensitive growth window + under that crop's window moisture
    elseif inWindow and winMoist ~= nil and moisture < winMoist then
        color = COLOR_WARNING
        tip = tr("cs_rf_pda_next_window",
            "Sensitive growth window - keep this field watered so stress does not climb.")

    -- Priority 3: High accumulated stress / meaningful yield impact
    elseif meaningfulLoss and stress >= 0.05 then
        color = COLOR_WARNING
        local lossLabel = impactStr
        if lossLabel == nil or lossLabel == "0%" then
            lossLabel = string.format("-%.0f%%", lossPct)
        end
        local tpl = tr("cs_rf_pda_next_stress",
            "Stress is high (about %s harvest risk) - water / protect before it gets worse.")
        tip = string.format(tpl, lossLabel)

    -- Priority 4: Warning moisture (25-40%)
    elseif moisture < 0.40 then
        color = COLOR_WARNING
        if watering then
            tip = tr("cs_rf_pda_next_warning_watering",
                "Moisture low - irrigation is on; recheck Moisture as it recovers.")
        elseif covered then
            tip = tr("cs_rf_pda_next_warning_covered",
                "Moisture low - irrigate soon. Coverage is on this field; confirm the system is running.")
        else
            tip = tr("cs_rf_pda_next_warning_uncovered",
                "Moisture low - irrigate soon (coverage / WATER sprayer).")
        end

    -- Priority 5: Dry-ish and no coverage
    elseif moisture < 0.50 and not covered then
        color = COLOR_WARNING
        tip = tr("cs_rf_pda_next_no_coverage",
            "No irrigation coverage - add a system, or spray WATER for a temporary boost.")

    -- Priority 6: Looking good / covered & quiet
    else
        color = COLOR_HEALTHY
        if covered and not watering then
            tip = tr("cs_rf_pda_next_covered_idle",
                "Irrigation covers this field - confirm it is running when dry, then recheck Moisture.")
        else
            tip = tr("cs_rf_pda_next_looking_good",
                "Looking good - recheck later; handle Critical fields first.")
        end
    end

    return tip, color
end

--- Owned-field rows for Esc content table (Wizard ruling: owned-only).
--- SCS fieldData keys are field ids; ownership is via field.farmland.id then
--- g_farmlandManager:getFarmlandOwner (same RfSoilFrame / Soil RfPda pattern).
--- Spectator (farmId nil/0) returns empty rows — never default to farm 1.
---@return table
function CsRfPdaGuest.buildFieldRows()
    local rows = {}
    local mgr = getMgr()
    if mgr == nil or mgr.soilSystem == nil or mgr.soilSystem.fieldData == nil then
        return rows
    end

    local soilSystem = mgr.soilSystem
    local stressMod = mgr.stressModifier
    local irrMgr = mgr.irrigationManager
    local fieldById = mgr.fieldById or {}

    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    if farmId == nil or farmId == 0 or g_farmlandManager == nil then
        return rows
    end

    local coveredFields = {}
    if irrMgr and irrMgr.systems then
        for _, sys in pairs(irrMgr.systems) do
            if sys.coveredFields then
                for _, fid in ipairs(sys.coveredFields) do
                    coveredFields[fid] = true
                end
            end
        end
    end

    local yesText = tr("cs_pda_irrigated_yes", "Yes")
    local noText = tr("cs_pda_irrigated_no", "No")

    for fid, entry in pairs(soilSystem.fieldData) do
        local field = fieldById[fid]
        local fl = field and field.farmland
        local farmlandId = fl and fl.id
        local owned = false
        if farmlandId ~= nil then
            owned = g_farmlandManager:getFarmlandOwner(farmlandId) == farmId
        end

        if owned then
            local fti = field and field.fieldState and field.fieldState.fruitTypeIndex or 0
            local moisture = entry.moisture or 0
            local stress = (stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0
            local irrigated = coveredFields[fid] == true
            local statusText, statusColor = moistureStatus(moisture)

            table.insert(rows, {
                fieldId = fid,
                fieldLabel = string.format("%s %s", tr("cs_rf_pda_col_field", "Field"), tostring(fid)),
                cropName = getCropName(fti),
                moistureText = string.format("%.0f%%", moisture * 100),
                moistureColor = moistureColor(moisture),
                stressText = string.format("%.0f%%", stress * 100),
                irrigatedText = irrigated and yesText or noText,
                statusText = statusText,
                statusColor = statusColor,
            })
        end
    end

    table.sort(rows, function(a, b)
        return (a.fieldId or 0) < (b.fieldId or 0)
    end)
    return rows
end

local function formatGlanceBody(stats)
    if stats == nil then
        return tr("cs_rf_pda_empty", "No crop stress data yet. Fields appear after the simulation runs.")
    end
    if stats.totalTracked == 0 then
        return tr("cs_pda_no_fields",
            "No field data yet. Fields appear once the simulation has run for one in-game hour.")
    end

    local line1 = string.format(
        "%s %d  |  %s %d  |  %s %.0f%%",
        tr("cs_pda_fields_tracked", "Fields Tracked"), stats.totalTracked,
        tr("cs_pda_fields_owned", "Fields Owned"), stats.totalOwned,
        tr("cs_pda_avg_moisture", "Average Moisture"), stats.avgMoisture * 100
    )
    local line2 = string.format(
        "%s %d  |  %s %d  |  %s %d",
        tr("cs_pda_fields_healthy", "Healthy (>=40%)"), stats.healthy,
        tr("cs_pda_fields_warning", "Warning (25-40%)"), stats.warning,
        tr("cs_pda_fields_critical", "Critical (<25%)"), stats.critical
    )
    local line3 = string.format(
        "%s %.0f%%  |  %s -%.0f%%  |  %s %d (%s %d)",
        tr("cs_pda_avg_stress", "Average Stress"), stats.avgStress * 100,
        tr("cs_pda_est_yield_loss", "Est. Yield Loss"), stats.yieldLoss * 100,
        tr("cs_pda_irrigated_fields", "Irrigated Fields"), stats.irrigatedCount,
        tr("cs_pda_irrigation_systems", "Active Systems"), stats.irrSystems
    )
    return line1 .. "\n" .. line2 .. "\n" .. line3
end

local function findDescendant(root, id)
    if root == nil or id == nil then
        return nil
    end
    if root.getDescendantById then
        local el = root:getDescendantById(id)
        if el ~= nil then
            return el
        end
    end
    local page = getHostPage()
    if page and page.getDescendantById then
        return page:getDescendantById(id)
    end
    return nil
end

local function setHeaderTexts(container)
    local headers = {
        { "csColField", "cs_rf_pda_col_field", "Field" },
        { "csColCrop", "cs_rf_pda_col_crop", "Crop" },
        { "csColMoisture", "cs_rf_pda_col_moisture", "Moisture" },
        { "csColStress", "cs_rf_pda_col_stress", "Stress" },
        { "csColIrrigated", "cs_rf_pda_col_irrigated", "Irrigated" },
        { "csColStatus", "cs_rf_pda_col_status", "Status" },
    }
    for _, h in ipairs(headers) do
        local el = findDescendant(container, h[1])
        if el and el.setText then
            el:setText(tr(h[2], h[3]))
        end
    end
end

local function reloadHostTable(container)
    local page = getHostPage()
    if page == nil then
        return
    end
    page.csFieldData = CsRfPdaGuest.buildFieldRows()
    setHeaderTexts(container or page)
    if type(page.reloadCsFieldList) == "function" then
        page:reloadCsFieldList()
    elseif page.csFieldOverviewList and page.csFieldOverviewList.reloadData then
        page.csFieldOverviewList:reloadData()
        if page.csFieldsEmptyHint then
            page.csFieldsEmptyHint:setVisible(#page.csFieldData == 0)
        end
    end
end

--- Days tag for schedule window: " daily" / " weekdays" / "" (omit long lists).
local function scheduleDaysTag(activeDays)
    if type(activeDays) ~= "table" or #activeDays < 7 then
        return ""
    end
    local allTrue = true
    for i = 1, 7 do
        if activeDays[i] ~= true then
            allTrue = false
            break
        end
    end
    if allTrue then
        return tr("cs_rf_pda_sched_daily", " daily")
    end
    -- Mon–Fri shape: first five true, Sat/Sun false.
    local weekdays = true
    for i = 1, 5 do
        if activeDays[i] ~= true then
            weekdays = false
            break
        end
    end
    if weekdays and activeDays[6] ~= true and activeDays[7] ~= true then
        return tr("cs_rf_pda_sched_weekdays", " weekdays")
    end
    return ""
end

--- Compact schedule + rate clause (coverage / schedule / rate stay distinct).
---@return string
local function buildScheduleRateClause(fieldId, covered)
    local mgr = getMgr()
    local schedule = nil
    if mgr ~= nil and type(mgr.getIrrigationSchedule) == "function" then
        schedule = mgr:getIrrigationSchedule(fieldId)
    end
    local rate = 0
    if mgr ~= nil and type(mgr.getIrrigationRate) == "function" then
        rate = mgr:getIrrigationRate(fieldId) or 0
    end

    local rateStr
    if rate > 0 then
        rateStr = string.format(tr("cs_rf_pda_rate_on", "Rate +%.2f/h"), rate)
    else
        rateStr = tr("cs_rf_pda_rate_off", "Rate off")
    end

    if not covered then
        return tr("cs_rf_pda_no_coverage", "No coverage") .. " · " .. rateStr
    end

    if schedule ~= nil then
        local hours = string.format(
            tr("cs_rf_pda_sched_hours", "Sched %d–%d"),
            schedule.startHour or 0,
            schedule.endHour or 0
        )
        return hours .. scheduleDaysTag(schedule.activeDays) .. " · " .. rateStr
    end

    -- Covered, no active schedule on covering system.
    if rate > 0 then
        return "No schedule · " .. rateStr
    end
    return tr("cs_rf_pda_covered_no_sched", "Covered · no schedule") .. " · " .. rateStr
end

--- Pack Status line: optional Alert + schedule/rate + Status. Never duplicate Alert on Next.
---@return string
local function buildStatusLine(fieldId, covered, statusWord, alertHint, alertOnStatus)
    local schedRate = buildScheduleRateClause(fieldId, covered)
    local statusJoin = string.format(
        tr("cs_rf_pda_status_join", "%s  ·  Status: %s"),
        schedRate,
        statusWord or "-"
    )

    if not alertOnStatus or alertHint == nil or alertHint == "" then
        return statusJoin
    end

    local alertPrefix = string.format(tr("cs_rf_pda_alert_prefix", "Alert: %s"), alertHint)
    local full = alertPrefix .. " · " .. statusJoin
    -- If over budget, keep Alert + rate/coverage + Status; drop schedule hours when needed.
    if #full <= 120 then
        return full
    end

    local mgr = getMgr()
    local rate = 0
    if mgr ~= nil and type(mgr.getIrrigationRate) == "function" then
        rate = mgr:getIrrigationRate(fieldId) or 0
    end
    local rateStr
    if rate > 0 then
        rateStr = string.format(tr("cs_rf_pda_rate_on", "Rate +%.2f/h"), rate)
    else
        rateStr = tr("cs_rf_pda_rate_off", "Rate off")
    end
    local shortLeft
    if not covered then
        shortLeft = tr("cs_rf_pda_no_coverage", "No coverage") .. " · " .. rateStr
    else
        shortLeft = rateStr
    end
    return alertPrefix .. " · " .. string.format(
        tr("cs_rf_pda_status_join", "%s  ·  Status: %s"),
        shortLeft,
        statusWord or "-"
    )
end

--- Fill the bottom info band (csDetailStrip) for the selected field.
--- Lua-first (no new XML Text): Field | Next | Moisture+Keep | Stress+heat | Sched·Rate·Status.
--- Text-only: safe on both light tick and full show. No SmoothList, no Soil NPK.
local function updateDetailBand(container)
    local page = getHostPage()
    if page == nil then
        return
    end

    local titleEl = findDescendant(container, "csDetailTitle")
    local fieldEl = findDescendant(container, "csDetailField")
    local nextEl = findDescendant(container, "csDetailMoisture") -- Next coach
    local moistEl = findDescendant(container, "csDetailStress") -- Moisture + Yield keep
    local stressEl = findDescendant(container, "csDetailIrrigated") -- Stress + heat why
    local statusEl = findDescendant(container, "csDetailStatus") -- Sched · Rate · Status
    local emptyEl = findDescendant(container, "csDetailEmpty")
    if fieldEl == nil and emptyEl == nil then
        return
    end

    if titleEl and titleEl.setText then
        titleEl:setText(tr("cs_rf_pda_detail_title", "Field Detail"))
    end

    -- Resolve selection by fieldId first: the row set can change on full reloads.
    local rows = page.csFieldData or {}
    local entry = nil
    if page.csSelectedFieldId ~= nil then
        for _, row in ipairs(rows) do
            if row.fieldId == page.csSelectedFieldId then
                entry = row
                break
            end
        end
    end
    if entry == nil and page.csSelectedIndex ~= nil then
        entry = rows[page.csSelectedIndex]
    end

    local hasEntry = entry ~= nil
    for _, el in ipairs({ fieldEl, nextEl, moistEl, stressEl, statusEl }) do
        if el and el.setVisible then
            el:setVisible(hasEntry)
        end
    end
    if emptyEl then
        if emptyEl.setText then
            emptyEl:setText(tr("cs_rf_pda_select_field", "Select a field in the table for details."))
        end
        if emptyEl.setVisible then
            emptyEl:setVisible(not hasEntry)
        end
    end
    if not hasEntry then
        return
    end

    local fieldId = entry.fieldId
    local mgr = getMgr()
    local covered = isFieldCovered(fieldId)

    -- Line 1: Field (+ crop when known)
    if fieldEl and fieldEl.setText then
        local label = entry.fieldLabel or tostring(fieldId or "")
        if entry.cropName and entry.cropName ~= "-" then
            label = string.format("%s  |  %s", label, entry.cropName)
        end
        fieldEl:setText(label)
        if fieldEl.setTextColor then
            fieldEl:setTextColor(0.659, 0.878, 0.290, 1)
        end
    end

    -- Critical alert hint (nil-omit; never invent AD copy). Prefer Next append on
    -- Critical moisture tip when under ~110 char body; else Alert on Status (never both).
    local alertHint = nil
    if mgr ~= nil and type(mgr.getCriticalAlertHint) == "function" then
        local hint = mgr:getCriticalAlertHint()
        if type(hint) == "string" and hint ~= "" then
            alertHint = hint
        end
    end
    local moisture = 0
    if mgr ~= nil and type(mgr.getMoisture) == "function" then
        moisture = mgr:getMoisture(fieldId) or 0
    end

    -- Line 2: Next (coach). Ladder unchanged; optional Critical-tip alert append only.
    local nextBody, nextColor = CsRfPdaGuest.buildNextStepLine(fieldId)
    local alertOnStatus = false
    if alertHint ~= nil and nextBody ~= nil and nextBody ~= "" and moisture < 0.25 then
        local sepTpl = tr("cs_rf_pda_next_alert_sep", " · %s")
        local append = string.format(sepTpl, alertHint)
        if (#nextBody + #append) <= 110 then
            nextBody = nextBody .. append
        else
            alertOnStatus = true
        end
    elseif alertHint ~= nil then
        alertOnStatus = true
    end

    if nextEl and nextEl.setText then
        if nextBody ~= nil and nextBody ~= "" then
            local nextTpl = tr("cs_rf_pda_next", "Next: %s")
            nextEl:setText(string.format(nextTpl, nextBody))
            if nextEl.setTextColor then
                local c = nextColor or COLOR_WARNING
                nextEl:setTextColor(unpack(c))
            end
        else
            nextEl:setText("")
        end
    end

    -- Line 3: Moisture · Yield keep (certified getYieldKeepFactor; no * 0.60).
    if moistEl and moistEl.setText then
        local keep = 1.0
        if mgr ~= nil and type(mgr.getYieldKeepFactor) == "function" then
            keep = mgr:getYieldKeepFactor(fieldId) or 1.0
        end
        local keepPct = math.floor(keep * 100 + 0.5)
        local moistLabel = string.format("%s: %s",
            tr("cs_rf_pda_col_moisture", "Moisture"), entry.moistureText or "-")
        local keepLabel = string.format(tr("cs_rf_pda_yield_keep", "Yield keep: %d%%"), keepPct)
        moistEl:setText(moistLabel .. "  ·  " .. keepLabel)
        if entry.moistureColor and moistEl.setTextColor then
            moistEl:setTextColor(unpack(entry.moistureColor))
        end
    end

    -- Line 4: Stress · Air / dry pull (map weather; never heat-from-stress).
    if stressEl and stressEl.setText then
        local tempC = 15.0
        local evap = 1.0
        if mgr ~= nil then
            if type(mgr.getTemperature) == "function" then
                tempC = mgr:getTemperature() or 15.0
            end
            if type(mgr.getEvaporativeDemand) == "function" then
                evap = mgr:getEvaporativeDemand() or 1.0
            end
        end
        local stressLabel = string.format("%s: %s",
            tr("cs_rf_pda_col_stress", "Stress"), entry.stressText or "-")
        local heatClause = string.format(
            tr("cs_rf_pda_heat_clause", "Air %.0f°C, dry pull %.1f"),
            tempC,
            evap
        )
        stressEl:setText(stressLabel .. "  ·  " .. heatClause)
        if stressEl.setTextColor then
            stressEl:setTextColor(0.659, 0.678, 0.702, 1)
        end
    end

    -- Line 5: Schedule · Rate · Status (+ Alert when not on Next).
    if statusEl and statusEl.setText then
        statusEl:setText(buildStatusLine(
            fieldId,
            covered,
            entry.statusText,
            alertHint,
            alertOnStatus
        ))
        if entry.statusColor and statusEl.setTextColor then
            statusEl:setTextColor(unpack(entry.statusColor))
        end
    end
end

---@param container table|nil rfHostPlaceholder from Soil RfPdaMenuPage
---@param lightOnly boolean|nil when true (host 2s tick): text only, no SmoothList reload
function CsRfPdaGuest.onShow(container, lightOnly)
    local stats = CsRfPdaGuest.computeGlanceStats()
    local title = tr("cs_rf_pda_module_title", "Crop Stress")
    local blurb = tr("cs_rf_pda_blurb",
        "Field moisture, stress, irrigation schedule and rate, and yield keep. Open Farm Tablet to edit systems or open Crop Consultant.")
    local body = formatGlanceBody(stats)

    local titleEl = findDescendant(container, "rfHostTitle")
    local blurbEl = findDescendant(container, "rfHostBlurb")
    local bodyEl = findDescendant(container, "rfHostBody")

    if titleEl and titleEl.setText then
        titleEl:setText(title)
    end
    if blurbEl and blurbEl.setText then
        blurbEl:setText(blurb)
    end
    if bodyEl and bodyEl.setText then
        bodyEl:setText(body)
    end

    if not lightOnly then
        reloadHostTable(container)
    end
    -- Bottom info band: text-only, allowed on light tick and selection refresh.
    updateDetailBand(container)
end

function CsRfPdaGuest.onHide()
end

--- Remove legacy Esc Crop Stress tab when RF host is present (one door).
function CsRfPdaGuest.standDownLegacyEsc()
    if _legacyStoodDown then
        return true
    end
    if g_gui == nil then
        return false
    end

    local inGameMenu = g_gui.screenControllers and g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil then
        return false
    end

    local pageName = CsPDAScreen and CsPDAScreen.MENU_PAGE_NAME or "menuCropStress"
    local screen = inGameMenu[pageName]
    if screen == nil then
        if CsPDAScreen ~= nil and CsPDAScreen._retainedDeepScreen ~= nil then
            _legacyStoodDown = true
            return true
        end
        _legacyStoodDown = true
        return true
    end

    -- Giants-safe remove: retain the deep page before nilling it so the map
    -- overlay can still open it. The Esc rail tab stays stood down.
    if CsPDAScreen ~= nil then
        CsPDAScreen._retainedDeepScreen = screen
    end

    local ok = pcall(function()
        if inGameMenu.pagingElement ~= nil then
            local pe = inGameMenu.pagingElement
            if pe.elements ~= nil then
                for i = #pe.elements, 1, -1 do
                    if pe.elements[i] == screen then
                        table.remove(pe.elements, i)
                    end
                end
            end
            if pe.pages ~= nil then
                for i = #pe.pages, 1, -1 do
                    local pg = pe.pages[i]
                    if pg ~= nil and pg.element == screen then
                        table.remove(pe.pages, i)
                    end
                end
            end
            if type(pe.updateAbsolutePosition) == "function" then
                pe:updateAbsolutePosition()
            end
            if type(pe.updatePageMapping) == "function" then
                pe:updatePageMapping()
            end
        end

        if inGameMenu.pageFrames ~= nil then
            for i = #inGameMenu.pageFrames, 1, -1 do
                if inGameMenu.pageFrames[i] == screen then
                    table.remove(inGameMenu.pageFrames, i)
                end
            end
        end

        if g_inGameMenu ~= nil and g_inGameMenu.controlIDs ~= nil then
            g_inGameMenu.controlIDs[pageName] = nil
        end

        inGameMenu[pageName] = nil

        if type(inGameMenu.rebuildTabList) == "function" then
            inGameMenu:rebuildTabList()
        end
        if type(inGameMenu.updatePages) == "function" then
            inGameMenu:updatePages()
        end
    end)

    if ok then
        _legacyStoodDown = true
        print("[CropStress] CsRfPdaGuest: stood down legacy Esc menuCropStress (RF host present)")
        return true
    end
    print("[CropStress] CsRfPdaGuest: legacy Esc stand-down failed (will retry)")
    return false
end

function CsRfPdaGuest.tryRegister()
    -- Always ensureDoor when bootstrap class is sourced; never trust bare g_currentModDirectory at callback time.
    if RfEscBootstrap ~= nil then
        if MOD_DIR == nil then
            print("[CropStress] CsRfPdaGuest: WARNING MOD_DIR nil — cannot ensureDoor (source capture failed)")
        else
            local doorOk = RfEscBootstrap.ensureDoor(MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
            if not doorOk then
                print("[CropStress] CsRfPdaGuest: WARNING ensureDoor failed (will retry)")
            end
        end
    end

    local host = getHost()
    local registerFn = nil
    if host ~= nil then
        if type(host.registerModule) == "function" then
            registerFn = host.registerModule
        elseif type(host.registerPanel) == "function" then
            registerFn = host.registerPanel
        end
    end
    if host == nil or registerFn == nil then
        return false
    end

    if not _registered then
        local ok = registerFn(host, {
            id = PANEL_ID,
            title = tr("cs_rf_pda_module_title", "Crop Stress"),
            order = PANEL_ORDER,
            isAvailable = function()
                return getMgr() ~= nil
            end,
            onShow = CsRfPdaGuest.onShow,
            onHide = CsRfPdaGuest.onHide,
        })
        if ok then
            _registered = true
            print("[CropStress] CsRfPdaGuest: registered module seasonalCropStress on rfEscModules")
        else
            return false
        end
    end

    local doorPresent = g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
    if doorPresent then
        CsRfPdaGuest.standDownLegacyEsc()
    end
    -- Ready only when module registered AND Esc door actually exists.
    return _registered and doorPresent
end

function CsRfPdaGuest.isHostPresent()
    return getHost() ~= nil
end

function CsRfPdaGuest.isRegistered()
    return _registered
end

--- Clear file-local flags on mission unload so the next save can re-register.
function CsRfPdaGuest.reset()
    _registered = false
    _legacyStoodDown = false
end
