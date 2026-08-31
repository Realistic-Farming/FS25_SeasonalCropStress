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

CsRfPdaGuest = CsRfPdaGuest or {}

-- Capture at source() time — (SeasonalCropStressModDirectory or g_currentModDirectory) is often nil at deferred/map-load callbacks.
local MOD_DIR = (SeasonalCropStressModDirectory or g_currentModDirectory)
local CS_RF_MOD_NAME = (SeasonalCropStressModName or g_currentModName)
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

--- Numeric-safe field id compare (farmland ids may arrive as number or string).
local function fieldIdEquals(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local na, nb = tonumber(a), tonumber(b)
    return na ~= nil and nb ~= nil and na == nb
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
                if fieldIdEquals(fid, fieldId) then
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
--- Keys are farmland ids (CropStressManager.fieldById / coveredFields contract).
--- Rows are session farm patches (polygon edge-proximity), not raw field ids.
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

    -- Vehicle irrigators (Rainstar play kit): a field a Rainstar is parked on
    -- reads as irrigated the same way a placed system does, running or not.
    local vehIrr = mgr.irrigatorSectorIntegration
    if vehIrr and type(vehIrr.getPresentFields) == "function" then
        for fid in pairs(vehIrr:getPresentFields()) do
            coveredFields[fid] = true
        end
    end

    local yesText = tr("cs_pda_irrigated_yes", "Yes")
    local noText = tr("cs_pda_irrigated_no", "No")

    local ownedIds = {}
    for fid, _ in pairs(soilSystem.fieldData) do
        local field = fieldById[fid]
        local fl = field and field.farmland
        local farmlandId = fl and fl.id or fid
        local owned = false
        if farmlandId ~= nil then
            owned = g_farmlandManager:getFarmlandOwner(farmlandId) == farmId
        end
        if owned then
            ownedIds[#ownedIds + 1] = fid
        end
    end

    local patchList = nil
    if FarmPatchUtil ~= nil and type(FarmPatchUtil.buildPatches) == "function" then
        local ok, result = pcall(function()
            return FarmPatchUtil.buildPatches(ownedIds, {
                fieldLookup = function(id) return fieldById[id] end,
                useDensmapConfirm = true,
                tr = tr,
            })
        end)
        if ok then
            patchList = result
        end
    end

    local function moistureFor(fid, entry)
        local moisture = (entry and entry.moisture) or 0
        if type(soilSystem.getMoisture) == "function" then
            local okM, mv = pcall(function() return soilSystem:getMoisture(fid) end)
            if okM and type(mv) == "number" then moisture = mv end
        end
        return moisture
    end

    local function buildOneRow(patchId, members, label)
        local minMoist = nil
        local maxStress = 0
        local anyIrrigated = false
        local cropName = nil
        local cropMixed = false
        for _, fid in ipairs(members) do
            local entry = soilSystem.fieldData[fid]
            local moisture = moistureFor(fid, entry)
            if minMoist == nil or moisture < minMoist then
                minMoist = moisture
            end
            local stress = (stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0
            if type(mgr.getStress) == "function" then
                local okS, sv = pcall(function() return mgr:getStress(fid) end)
                if okS and type(sv) == "number" then stress = sv end
            end
            if stress > maxStress then maxStress = stress end
            if coveredFields[fid] == true then
                anyIrrigated = true
            end
            local field = fieldById[fid]
            local fti = field and field.fieldState and field.fieldState.fruitTypeIndex or 0
            local cn = getCropName(fti)
            if cropName == nil then
                cropName = cn
            elseif cn ~= cropName and cn ~= "-" then
                cropMixed = true
            end
        end
        if minMoist == nil then minMoist = 0 end
        local statusText, statusColor = moistureStatus(minMoist)
        local displayCrop = cropMixed and tr("cs_rf_pda_crop_mixed", "Mixed") or (cropName or "-")
        local displayLabel = label
        if displayLabel == nil and FarmPatchUtil ~= nil then
            displayLabel = FarmPatchUtil.formatPatchLabel(members, tr)
        elseif displayLabel == nil then
            displayLabel = string.format("%s %s", tr("cs_rf_pda_col_field", "Field"), tostring(patchId))
        end

        table.insert(rows, {
            fieldId = patchId,
            memberFieldIds = members,
            fieldLabel = displayLabel,
            cropName = displayCrop,
            moistureText = string.format("%.0f%%", minMoist * 100),
            moistureColor = moistureColor(minMoist),
            stressText = string.format("%.0f%%", maxStress * 100),
            irrigatedText = anyIrrigated and yesText or noText,
            statusText = statusText,
            statusColor = statusColor,
            _minMoisture = minMoist,
            _maxStress = maxStress,
        })
    end

    if patchList ~= nil and #patchList > 0 then
        for _, patch in ipairs(patchList) do
            local members = patch.memberFieldIds or { patch.patchId }
            buildOneRow(patch.patchId, members, patch.label)
        end
    else
        for _, fid in ipairs(ownedIds) do
            buildOneRow(fid, { fid }, nil)
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

-- ============================================================
-- ESC ACTIONS - open the existing Consultant / Irrigation dialogs
-- ============================================================
-- George GO WITH CONSTRAINTS 2026-08-09: Esc must reopen the EXISTING
-- MessageDialogs through the CropStress manager. Never bare CsDialogLoader from a
-- host (it is SCS-env-scoped), never an inline Esc editor, and never
-- applyOneTimeIrrigation from here - Irrigate Now stays inside the schedule dialog
-- so CropStressIrrigateNowEvent remains the single write door.

--- Systems whose coveredFields include fieldId.
--- coveredFields is an ipairs ARRAY (CropStressManager contract) - not a set.
local function coveringSystems(mgr, fieldId)
    local out = {}
    if mgr == nil or fieldId == nil then return out end
    local irr = mgr.irrigationManager
    if irr == nil or irr.systems == nil then return out end
    for id, sys in pairs(irr.systems) do
        local covered = sys ~= nil and sys.coveredFields or nil
        if covered ~= nil then
            for i = 1, #covered do
                if fieldIdEquals(covered[i], fieldId) then
                    out[#out + 1] = { id = id, isActive = sys.isActive and true or false, sys = sys }
                    break
                end
            end
        end
    end
    return out
end

--- Union of covering systems across all patch member farmland ids (ordered by id).
local function coveringSystemsForMembers(mgr, memberIds)
    local byId = {}
    local out = {}
    for _, mid in ipairs(memberIds or {}) do
        local cands = coveringSystems(mgr, mid)
        for _, c in ipairs(cands) do
            if not byId[c.id] then
                byId[c.id] = true
                out[#out + 1] = c
            end
        end
    end
    table.sort(out, function(a, b)
        local na, nb = tonumber(a.id), tonumber(b.id)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

--- Member subset of this patch that a given system covers.
local function membersCoveredBySystem(sys, memberIds)
    local hit = {}
    if sys == nil or type(sys.coveredFields) ~= "table" then
        return hit
    end
    for _, mid in ipairs(memberIds or {}) do
        for i = 1, #sys.coveredFields do
            if fieldIdEquals(sys.coveredFields[i], mid) then
                hit[#hit + 1] = mid
                break
            end
        end
    end
    table.sort(hit, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a) < tostring(b)
    end)
    return hit
end

--- Deterministic pick when switcher is absent / single candidate.
--- Prefer isActive, then lowest id. Returns nil when nothing covers.
local function resolveSystemIdSilent(mgr, memberIds)
    local cands = coveringSystemsForMembers(mgr, memberIds)
    if #cands == 0 then return nil end
    local active = {}
    for _, c in ipairs(cands) do
        if c.isActive then active[#active + 1] = c end
    end
    local pool = (#active > 0) and active or cands
    table.sort(pool, function(a, b)
        local na, nb = tonumber(a.id), tonumber(b.id)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a.id) < tostring(b.id)
    end)
    return pool[1].id
end

--- Selected field id for the Esc CS module, or nil.
local function selectedFieldId(container)
    local page = getHostPage()
    if page == nil then return nil end
    if page.csSelectedFieldId ~= nil then return page.csSelectedFieldId end
    local rows = page.csFieldData or {}
    local e = page.csSelectedIndex ~= nil and rows[page.csSelectedIndex] or nil
    return e ~= nil and e.fieldId or nil
end

--- Resolve patch members for the current Esc selection.
local function selectedMemberIds(container)
    local page = getHostPage()
    if page == nil then return nil end
    local rows = page.csFieldData or {}
    local entry = nil
    if page.csSelectedFieldId ~= nil then
        for _, row in ipairs(rows) do
            if fieldIdEquals(row.fieldId, page.csSelectedFieldId) then
                entry = row
                break
            end
        end
    end
    if entry == nil and page.csSelectedIndex ~= nil then
        entry = rows[page.csSelectedIndex]
    end
    if entry == nil then
        local fid = selectedFieldId(container)
        if fid == nil then return nil end
        return { fid }
    end
    if entry.memberFieldIds ~= nil and #entry.memberFieldIds > 0 then
        return entry.memberFieldIds
    end
    return { entry.fieldId }
end

--- Esc-bound system id: switcher selection when multi; auto when 0/1.
--- George veto: no silent resolveSystemId when switcher is present (#cands > 1).
local function selectedSystemId(container, mgr, memberIds)
    local page = getHostPage()
    local cands = coveringSystemsForMembers(mgr, memberIds)
    if #cands == 0 then
        if page ~= nil then page.csSelectedSystemId = nil end
        return nil, cands
    end
    if #cands == 1 then
        if page ~= nil then page.csSelectedSystemId = cands[1].id end
        return cands[1].id, cands
    end
    -- Multi: require explicit page.csSelectedSystemId in the candidate set.
    if page ~= nil and page.csSelectedSystemId ~= nil then
        for _, c in ipairs(cands) do
            if fieldIdEquals(c.id, page.csSelectedSystemId) then
                return c.id, cands
            end
        end
    end
    -- First paint after select: seed to first ordered candidate (not silent active prefer).
    -- Player sees that choice in the switcher; arrows change it. Do not prefer isActive.
    if page ~= nil then
        page.csSelectedSystemId = cands[1].id
    end
    return cands[1].id, cands
end

--- Pivot switcher MultiTextOption texts + visibility (detail card only).
local function refreshPivotSwitcher(container, mgr, memberIds, cands)
    local page = getHostPage()
    local sel = findDescendant(container, "csPivotSwitcher")
    if sel == nil and page ~= nil then
        sel = page.csPivotSwitcher
    end
    if sel == nil then
        return
    end

    cands = cands or coveringSystemsForMembers(mgr, memberIds)
    if #cands <= 1 then
        if sel.setVisible then sel:setVisible(false) end
        return
    end

    local texts = {}
    local state = 1
    local selectedId = page ~= nil and page.csSelectedSystemId or nil
    for i, c in ipairs(cands) do
        local irr = mgr ~= nil and mgr.irrigationManager or nil
        local sys = (irr ~= nil and irr.systems ~= nil) and irr.systems[c.id] or c.sys
        local subset = membersCoveredBySystem(sys, memberIds)
        local subsetText
        if FarmPatchUtil ~= nil and FarmPatchUtil.formatFieldIdSubset ~= nil then
            subsetText = FarmPatchUtil.formatFieldIdSubset(subset)
        else
            local parts = {}
            for _, id in ipairs(subset) do parts[#parts + 1] = tostring(id) end
            subsetText = table.concat(parts, ", ")
        end
        local tpl = tr("cs_rf_pda_pivot_switch", "Pivot %s · covers %s of this block")
        local ok, label = pcall(string.format, tpl, tostring(c.id), subsetText)
        texts[i] = ok and label or string.format("Pivot %s · covers %s of this block", tostring(c.id), subsetText)
        if selectedId ~= nil and fieldIdEquals(c.id, selectedId) then
            state = i
        end
    end

    if sel.setVisible then sel:setVisible(true) end
    if sel.setTexts then sel:setTexts(texts) end
    sel.disableButtonsOnSingleText = false
    if sel.setState then
        pcall(function() sel:setState(state, true) end)
    end
    if page ~= nil then
        page._csPivotCandIds = {}
        for i, c in ipairs(cands) do
            page._csPivotCandIds[i] = c.id
        end
    end
end

-- Forward declare: defined later; Esc switcher click refreshes pivot card only.
local updatePivotCard

--- Host callback: MultiTextOption arrows changed pivot selection (no list reload).
function CsRfPdaGuest.onPivotSwitcherChanged(container)
    local page = getHostPage()
    local sel = findDescendant(container, "csPivotSwitcher")
    if sel == nil and page ~= nil then
        sel = page.csPivotSwitcher
    end
    if page == nil or sel == nil then
        return
    end
    local state = 1
    if sel.getState then
        local ok, s = pcall(function() return sel:getState() end)
        if ok and type(s) == "number" then state = s end
    end
    local ids = page._csPivotCandIds or {}
    local sysId = ids[state]
    if sysId == nil then
        return
    end
    page.csSelectedSystemId = sysId
    -- Light detail/pivot refresh only — never SmoothList reloadData (George hang fence).
    if updatePivotCard ~= nil then
        updatePivotCard(container, page.csSelectedFieldId)
    end
    CsRfPdaGuest.refreshActionButtons(container, page.csSelectedFieldId)
end


-- ============================================================
-- INLINE CONSULTANT READOUT (Alex Chen desk in the Esc panel)
-- ============================================================
-- George GO WITH CONSTRAINTS 2026-08-09: readout only, fixed Texts, manager reads.
-- NO-GO he named and this honours: no CropConsultantDialog XML nested into the page,
-- no TextElement.new/addElement rebuild on a tick, no SmoothList, no inline schedule
-- editor, no Esc applyOneTimeIrrigation. Risk formula is the dialog's own
-- (CropConsultantDialog.lua:164) rather than a second one invented here.

local function consSetText(container, id, s, visible)
    local el = findDescendant(container, id)
    if el == nil then return end
    if el.setVisible then el:setVisible(visible ~= false) end
    if visible ~= false and el.setText then el:setText(s or "") end
end

--- Top owned fields by risk, highest first. Owned-only, same farmland filter as
--- buildFieldRows so the consultant cannot advise on land the player does not have.
local function topRiskFields(mgr, limit)
    local out = {}
    if mgr == nil then return out end
    local rows = CsRfPdaGuest.buildFieldRows() or {}
    for _, r in ipairs(rows) do
        -- buildFieldRows carries FORMATTED strings (moistureText / stressText), not
        -- numbers, so the risk maths reads the certified getters the dialog itself
        -- uses. Reading r.moisture would silently score every field identically.
        local moisture, stress = 0.5, 0
        if type(mgr.getMoisture) == "function" then
            local ok, v = pcall(function() return mgr:getMoisture(r.fieldId) end)
            if ok and type(v) == "number" then moisture = v end
        end
        if type(mgr.getStress) == "function" then
            local ok, v = pcall(function() return mgr:getStress(r.fieldId) end)
            if ok and type(v) == "number" then stress = v end
        end
        -- dialog formula (CropConsultantDialog.lua:164), not a new one
        local risk = stress * 0.6 + (1 - moisture) * 0.4
        out[#out + 1] = {
            fieldId = r.fieldId, label = r.fieldLabel or r.label,
            crop = r.cropName, moisture = moisture, stress = stress, risk = risk,
        }
    end
    table.sort(out, function(a, b) return a.risk > b.risk end)
    while #out > (limit or 5) do table.remove(out) end
    return out
end

--- Samantha sit lock: Field Detail + Schedule resolve follow the crowned field
--- (top-risk on consultant enter; Top-5 row click recrowns).
local function crownConsultField(container, fieldId)
    local page = getHostPage()
    if page == nil then return end
    page.csSelectedFieldId = fieldId
    local rows = page.csFieldData or {}
    local idx = nil
    if fieldId ~= nil then
        for i, row in ipairs(rows) do
            if row.fieldId == fieldId then
                idx = i
                break
            end
        end
    end
    page.csSelectedIndex = idx
    -- Light refresh only (text/schedule resolve). Call via module table so this
    -- helper can sit above the local updateDetailBand definition safely.
    if type(CsRfPdaGuest.onShow) == "function" then
        CsRfPdaGuest.onShow(container, true)
    end
end

--- Destination label on the toggle: consultant home → "Field list"; table → "Crop consultant".
local function applyConsultToggleLabel(page)
    if page == nil then
        return
    end
    local btn = page.csBtnConsultant
    if btn == nil or type(btn.setText) ~= "function" then
        return
    end
    if page._csConsultOpen then
        btn:setText(tr("cs_rf_pda_btn_field_list", "Field list"))
    else
        btn:setText(tr("cs_rf_pda_btn_consultant", "Crop consultant"))
    end
end

--- Keep SPACE / button label in sync whenever the host flips consult vs table.
local function wireConsultViewLabels(page)
    if page == nil or page._csConsultLabelWired then
        return
    end
    local orig = page.setCsConsultView
    if type(orig) ~= "function" then
        return
    end
    page._csConsultLabelWired = true
    function page:setCsConsultView(open)
        orig(self, open)
        applyConsultToggleLabel(self)
    end
end

--- Top-5 rows are fixed Texts (no Button / SmoothList). Hit-test the row span on
--- the consultant panel so a click recrowns strip + Schedule without new XML ids.
local function wireConsultRowHits(container)
    local page = getHostPage()
    if page == nil then return end
    local panel = page.csConsultPanel or findDescendant(container, "csConsultPanel")
    if panel == nil or panel._csConsHitWired then return end
    panel._csConsHitWired = true
    local prevMouse = panel.mouseEvent
    function panel:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
        eventUsed = eventUsed or false
        if prevMouse ~= nil then
            local used = prevMouse(self, posX, posY, isDown, isUp, button, eventUsed)
            if used then eventUsed = true end
        end
        if eventUsed or not self.visible then
            return eventUsed
        end
        local mouseUp = isUp and (button == nil or button == Input.MOUSE_BUTTON_LEFT)
        if not mouseUp then
            return eventUsed
        end
        if not page._csConsultOpen then
            return eventUsed
        end
        local top = page._csConsultTop or {}
        for i = 1, #top do
            local fieldEl = findDescendant(self, "csConsRow" .. i .. "Field")
                or findDescendant(container, "csConsRow" .. i .. "Field")
            local yieldEl = findDescendant(self, "csConsRow" .. i .. "Yield")
                or findDescendant(container, "csConsRow" .. i .. "Yield")
            if fieldEl ~= nil and fieldEl.visible ~= false
                and fieldEl.absPosition ~= nil and fieldEl.size ~= nil then
                local x = fieldEl.absPosition[1]
                local y = fieldEl.absPosition[2]
                local h = fieldEl.size[2] or 0
                local w = fieldEl.size[1] or 0
                if yieldEl ~= nil and yieldEl.absPosition ~= nil and yieldEl.size ~= nil then
                    w = (yieldEl.absPosition[1] + (yieldEl.size[1] or 0)) - x
                end
                local hit = false
                if GuiUtils ~= nil and type(GuiUtils.checkOverlayOverlap) == "function" then
                    hit = GuiUtils.checkOverlayOverlap(posX, posY, x, y, w, h)
                else
                    hit = posX >= x and posX <= (x + w) and posY >= y and posY <= (y + h)
                end
                if hit then
                    local e = top[i]
                    if e ~= nil and e.fieldId ~= nil then
                        page._csConsultPlayerCrown = e.fieldId
                        crownConsultField(container, e.fieldId)
                    end
                    return true
                end
            end
        end
        return eventUsed
    end
end

--- Paint the inline consultant. Called by the host when the toggle opens the view.
function CsRfPdaGuest.onPaintConsultant(container)
    local mgr = getMgr()
    consSetText(container, "csConsTitle", tr("cs_rf_pda_cons_title", "Alex Chen - Crop Consultant"))
    consSetText(container, "csConsColField",    tr("cs_rf_pda_cons_col_field", "Field"))
    consSetText(container, "csConsColRisk",     tr("cs_rf_pda_cons_col_risk", "Risk"))
    consSetText(container, "csConsColMoisture", tr("cs_rf_pda_cons_col_moisture", "Moisture"))
    consSetText(container, "csConsColYield",    tr("cs_rf_pda_cons_col_yield", "Yield keep"))
    consSetText(container, "csConsRecTitle",    tr("cs_rf_pda_cons_rec_title", "Recommendations"))

    -- Relationship: shown ONLY when the NPC is really registered. An unregistered
    -- consultant prints nothing at all rather than a fake 0 / 100.
    local relShown = false
    local npc = mgr ~= nil and mgr.npcIntegration or nil
    if npc ~= nil and npc.isRegistered and type(npc.getRelationshipLevel) == "function" then
        local ok, rel = pcall(function() return npc:getRelationshipLevel() end)
        if ok and type(rel) == "number" then
            consSetText(container, "csConsRelation",
                string.format(tr("cs_rf_pda_cons_relation", "With Alex: %d / 100"), rel))
            relShown = true
        end
    end
    if not relShown then consSetText(container, "csConsRelation", nil, false) end

    local top = topRiskFields(mgr, 5)
    local page = getHostPage()
    if page ~= nil then
        page._csConsultTop = top
    end
    for i = 1, 5 do
        local e = top[i]
        if e == nil then
            for _, sfx in ipairs({ "Field", "Risk", "Moisture", "Yield" }) do
                consSetText(container, "csConsRow" .. i .. sfx, nil, false)
            end
        else
            local name = e.label or ("Field " .. tostring(e.fieldId))
            if e.crop ~= nil and e.crop ~= "" then name = name .. " - " .. tostring(e.crop) end
            local keep = nil
            if mgr ~= nil and type(mgr.getYieldKeepFactor) == "function" then
                local ok, k = pcall(function() return mgr:getYieldKeepFactor(e.fieldId) end)
                if ok and type(k) == "number" then keep = k end
            end
            consSetText(container, "csConsRow" .. i .. "Field", name)
            consSetText(container, "csConsRow" .. i .. "Risk", string.format("%d%%", math.floor(e.risk * 100 + 0.5)))
            consSetText(container, "csConsRow" .. i .. "Moisture", string.format("%d%%", math.floor(e.moisture * 100 + 0.5)))
            consSetText(container, "csConsRow" .. i .. "Yield",
                keep ~= nil and string.format("%d%%", math.floor(keep * 100 + 0.5)) or "-")
        end
    end

    -- Honest empty: no owned field data at all.
    consSetText(container, "csConsEmpty",
        tr("cs_rf_pda_cons_empty", "No field data yet - fields appear after the simulation runs."),
        #top == 0)

    -- Recommendations. Each line is omitted rather than guessed when its source
    -- has nothing usable to say.
    local recs = {}
    if #top > 0 then
        local t1 = top[1]
        recs[#recs + 1] = string.format(
            tr("cs_rf_pda_cons_rec_driest", "Driest now: %s at %d%% moisture - water this one first."),
            t1.label or ("Field " .. tostring(t1.fieldId)), math.floor(t1.moisture * 100 + 0.5))
        local wi = mgr ~= nil and mgr.weatherIntegration or nil
        if wi ~= nil and type(wi.getMoistureForecast) == "function" then
            local ok, fc = pcall(function() return wi:getMoistureForecast(t1.fieldId, 3) end)
            if ok and type(fc) == "number" then
                recs[#recs + 1] = string.format(
                    tr("cs_rf_pda_cons_rec_forecast", "3-day outlook for %s: %d%% moisture."),
                    t1.label or ("Field " .. tostring(t1.fieldId)), math.floor(fc * 100 + 0.5))
            end
        end
    end
    local irr = mgr ~= nil and mgr.irrigationManager or nil
    local active = 0
    if irr ~= nil and irr.systems ~= nil then
        for _, sys in pairs(irr.systems) do
            if sys ~= nil and sys.isActive then active = active + 1 end
        end
    end
    recs[#recs + 1] = (active > 0)
        and string.format(tr("cs_rf_pda_cons_rec_systems", "%d irrigation systems active."), active)
        or tr("cs_rf_pda_cons_rec_nosystems", "No active irrigation - shop coverage for the driest fields.")

    for i = 1, 3 do
        consSetText(container, "csConsRec" .. i, recs[i], recs[i] ~= nil)
    end

    -- Selection SoT: keep the table-highlighted field. Only crown top-risk when
    -- nothing is selected yet (never overwrite Field N with a different Top-5 row).
    local page2 = getHostPage()
    if page2 == nil or page2.csSelectedFieldId == nil then
        if #top > 0 then
            crownConsultField(container, top[1].fieldId)
        else
            crownConsultField(container, nil)
        end
    else
        -- Light refresh detail + PIVOT for the existing selection.
        if type(CsRfPdaGuest.onShow) == "function" then
            CsRfPdaGuest.onShow(container, true)
        end
    end
    wireConsultRowHits(container)
end

--- Crop consultant: farm-wide, always available on the module.
function CsRfPdaGuest.onOpenConsultant(container)
    local mgr = getMgr()
    if mgr == nil or type(mgr.onOpenConsultantDialog) ~= "function" then return end
    pcall(function() mgr:onOpenConsultantDialog() end)
end

--- Irrigation schedule for the selected field's covering system.
--- BUILD 16:44: after the schedule dialog closes, focus was left on the dismissed
--- dialog, so the Esc Crop Stress page took no clicks until a full Esc out and back
--- in. Re-assert focus on the first remote that is actually LIVE, in the order the
--- farmer would reach for: Door, then Power, then ops, with Schedule as the fallback
--- so focus always lands somewhere real. Only enabled remotes are candidates - a
--- gated chip is not clickable, so focusing it would repeat the original problem.
local PIVOT_FOCUS_ORDER = {
    "csPivotBtnDoor", "csPivotBtnPower", "csPivotBtnSpray", "csPivotBtnEndGun",
    "csPivotBtnSpeed", "csPivotBtnStart", "csPivotBtnStop",
    "csPivotBtnMinUp", "csPivotBtnMinDn", "csPivotBtnMaxUp", "csPivotBtnMaxDn",
    "csPivotBtnArmPlus", "csPivotBtnArmMinus", "csBtnSchedule",
}

local function refocusPivotAfterDialog(container)
    if FocusManager == nil or type(FocusManager.setFocus) ~= "function" then return end
    for _, id in ipairs(PIVOT_FOCUS_ORDER) do
        local el = findDescendant(container, id)
        if el ~= nil and el.rfPivotChipEnabled and el.disabled ~= true then
            pcall(function() FocusManager:setFocus(el) end)
            return
        end
    end
end

function CsRfPdaGuest.onOpenSchedule(container)
    local mgr = getMgr()
    if mgr == nil or type(mgr.onOpenIrrigationDialog) ~= "function" then return end
    local members = selectedMemberIds(container)
    local sysId = select(1, selectedSystemId(container, mgr, members))
    if sysId == nil then
        -- 0 covering systems: honest no-open. The strip already carries the copy.
        return
    end
    pcall(function() mgr:onOpenIrrigationDialog(sysId) end)

    -- Wrap this dialog instance's onClose once so the Esc page gets focus back.
    -- Wrapping the live instance rather than the class keeps it scoped to the
    -- dialog we just opened and cannot leak onto anything else that reuses it.
    local dlg = g_gui ~= nil and g_gui.currentGuiName ~= nil and g_gui.currentGui or nil
    if dlg ~= nil and dlg._csRfReturnFocusWired ~= true and type(dlg.onClose) == "function" then
        dlg._csRfReturnFocusWired = true
        local prevClose = dlg.onClose
        function dlg:onClose(...)
            prevClose(self, ...)
            pcall(refocusPivotAfterDialog, container)
        end
    end
end

--- Esc Help → CsHelpDialog (SCS env only). Never call CsDialogLoader from a Soil-hosted door.
function CsRfPdaGuest.onOpenHelp(container)
    if CsDialogLoader == nil or type(CsDialogLoader.show) ~= "function" then
        return
    end
    pcall(function()
        CsDialogLoader.show("CsHelpDialog")
    end)
    -- MessageDialog close can leave focus on the dismissed dialog; re-assert pivot/table.
    local dlg = g_gui ~= nil and g_gui.currentGuiName ~= nil and g_gui.currentGui or nil
    if dlg ~= nil and dlg._csRfHelpReturnFocusWired ~= true and type(dlg.onClose) == "function" then
        dlg._csRfHelpReturnFocusWired = true
        local prevClose = dlg.onClose
        function dlg:onClose(...)
            prevClose(self, ...)
            pcall(refocusPivotAfterDialog, container)
        end
    end
end

--- Button chrome for the CS module: consultant activate chip stays hidden (XML default);
--- Schedule lives on the PIVOT card (enabled only when a covering system exists).
function CsRfPdaGuest.refreshActionButtons(container, fieldId)
    local consultBtn = findDescendant(container, "csBtnConsultant")
    local schedBtn   = findDescendant(container, "csBtnSchedule")
    local noCovEl    = findDescendant(container, "csDetailNoCoverage")

    -- BUILD Help restore 2026-08-12: never re-paint the SPACE Crop consultant chip.
    if consultBtn ~= nil and consultBtn.setVisible then
        consultBtn:setVisible(false)
    end

    local mgr = getMgr()
    local members = selectedMemberIds(container)
    if (members == nil or #members == 0) and fieldId ~= nil then
        members = { fieldId }
    end
    local covered = (members ~= nil) and (#coveringSystemsForMembers(mgr, members) > 0) or false
    if schedBtn ~= nil then
        if schedBtn.setText then schedBtn:setText(tr("cs_rf_pda_pivot_btn_schedule", "Schedule")) end
        if schedBtn.setVisible then schedBtn:setVisible(true) end
        if type(schedBtn.setDisabled) == "function" then
            schedBtn:setDisabled(not covered)
        end
    end
    if noCovEl ~= nil and noCovEl.setVisible then
        local show = (fieldId ~= nil) and not covered
        noCovEl:setVisible(show)
        if show and noCovEl.setText then
            noCovEl:setText(tr("cs_rf_pda_no_coverage_act",
                "No irrigation covers this field - place a system in the shop, then schedule it here."))
        end
    end
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

-- ============================================================
-- PIVOT CARD (Soil ROTATION seat) — dial + status + remote
-- George ENGINE ACK 2026-08-09: live Reinke reads; Event write path.
-- ============================================================

local PIVOT_ACTION = {
    DOOR_TOGGLE = 1, POWER_TOGGLE = 2, SPRAY_TOGGLE = 3, END_GUN_TOGGLE = 4,
    SPEED_CYCLE = 5, AUTO_START = 6, AUTO_STOP = 7,
    SWEEP_MIN_UP = 8, SWEEP_MIN_DN = 9, SWEEP_MAX_UP = 10, SWEEP_MAX_DN = 11,
    ARM_STEP_PLUS = 12, ARM_STEP_MINUS = 13,
}

local function resolvePlaceableById(systemId)
    if systemId == nil or g_currentMission == nil then return nil end
    local ps = g_currentMission.placeableSystem
    if ps == nil or ps.placeables == nil then return nil end
    for _, p in pairs(ps.placeables) do
        if p ~= nil and p.id == systemId then return p end
    end
    return nil
end

local function getReinkeSpec(placeable)
    if placeable == nil then return nil end
    if ReinkeIrrigationPivot ~= nil and type(ReinkeIrrigationPivot.SPEC_TABLE_NAME) == "string" then
        return placeable[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    end
    -- Soft-detect across mod env: scan for known Reinke fields.
    for k, v in pairs(placeable) do
        if type(k) == "string" and k:find("reinkeIrrigationPivot", 1, true) and type(v) == "table" then
            if v.armAngle ~= nil or v.autoMinAngleDeg ~= nil then
                return v
            end
        end
    end
    return nil
end

local function isReinke(placeable)
    if placeable == nil then return false end
    return type(placeable.toggleMasterPower) == "function"
        or type(placeable.toggleSprayActive) == "function"
        or getReinkeSpec(placeable) ~= nil
end

local function setPivotText(container, id, text, visible)
    local el = findDescendant(container, id)
    if el == nil then return end
    if el.setVisible then el:setVisible(visible ~= false) end
    if visible ~= false and el.setText then el:setText(text or "") end
end

--- Remote buttons paint as vanilla ButtonOverlay key chips (BUILD 07:43), so the
--- label is stored on the element rather than written into its TextElement. Two
--- things must never draw at once: the TextElement label and the chip. Leaving
--- setText(label) on gave the DOOR-over-SPACE overlap Wizard was looking at.
local function setPivotBtn(container, id, label, enabled, dead)
    local el = findDescendant(container, id)
    if el == nil then return end
    if el.setVisible then el:setVisible(true) end
    if el.setText then el:setText("") end
    el.rfPivotChipLabel = label
    el.rfPivotChipEnabled = enabled and true or false
    -- BUILD 15:26: "dead" means there is no system behind this card at all, which
    -- is different from a gated remote on a real pivot. Gated still shows a grey
    -- chip so the farmer can see what is locked; dead paints nothing, because a
    -- chip on a field with no pivot is pure false confidence.
    el.rfPivotChipDead = dead and true or false
    if type(el.setDisabled) == "function" then
        el:setDisabled(not enabled)
    end
end

-- Vanilla wideButton chip tints, from guiProfiles: icon = colorMainHighlight,
-- icon background = colorGreenDark. Using the same numbers is what makes these
-- read as base-game chips rather than a suite-coloured lookalike.
local PIVOT_CHIP_TEXT = { 0.22323, 0.40724, 0.00368 }
local PIVOT_CHIP_BG   = { 0.00913, 0.01033, 0.00651 }
-- GATED palette (BUILD 15:26). Deliberately ZERO green: a dimmed green chip still
-- reads as "live but faint", which is the confusion this build exists to remove.
local PIVOT_CHIP_GATED_TEXT = { 0.62, 0.64, 0.66 }
local PIVOT_CHIP_GATED_BG   = { 0.06, 0.06, 0.065 }

local PIVOT_CHIP_IDS = {
    "csPivotBtnDoor", "csPivotBtnPower", "csPivotBtnSpray", "csPivotBtnEndGun",
    "csPivotBtnSpeed", "csPivotBtnStart", "csPivotBtnStop",
    "csPivotBtnMinUp", "csPivotBtnMinDn", "csPivotBtnMaxUp", "csPivotBtnMaxDn",
    "csPivotBtnArmPlus", "csPivotBtnArmMinus", "csBtnSchedule",
}

--- Paint one remote as a vanilla key chip, centred in its hit box.
local function renderPivotChip(el, overlay)
    local label = el.rfPivotChipLabel
    if label == nil or label == "" then return end
    if el.absPosition == nil or el.absSize == nil then return end
    if el.visible == false then return end

    -- Chip height rides the hit box so it scales with resolution without needing
    -- a px conversion. 0.72 of a 32px row lands on the vanilla 30px icon feel.
    local height = el.absSize[2] * 0.72
    if height <= 0 then return end

    -- DEAD: no system on this field. Paint nothing at all - the hit box stays,
    -- disabled, but an empty seat is more honest than any chip.
    if el.rfPivotChipDead then return end

    local enabled = el.rfPivotChipEnabled
    local t, b, ta, ba
    if enabled then
        t, b, ta, ba = PIVOT_CHIP_TEXT, PIVOT_CHIP_BG, 1.0, 1.0
    else
        -- GATED: real pivot, this tier locked (door / power / ownership / autoRotate).
        -- Label stays legible so the farmer can see what is locked, but nothing green.
        t, b, ta, ba = PIVOT_CHIP_GATED_TEXT, PIVOT_CHIP_GATED_BG, 0.45, 0.55
    end
    overlay:setColor(t[1], t[2], t[3], ta, b[1], b[2], b[3], ba)

    -- getButtonWidth hugs the label. Schedule's hit box stays 530 and its chip is
    -- narrower; that is intended, and it is why setMinWidth is not used here. The
    -- overlay is SHARED with the rest of the game UI, so widening it would follow
    -- every other key chip on screen.
    local width = overlay:getButtonWidth(label, height)
    local x = el.absPosition[1] + (el.absSize[1] - width) * 0.5
    local y = el.absPosition[2] + (el.absSize[2] - height) * 0.5
    overlay:renderButton(label, x, y, height, true)
end

--- Wrap the pivot card's draw once so the chips repaint every frame while the
--- card is visible. Light tick stays text/enable only; nothing is rebuilt here.
local function wirePivotChipPaint(container)
    local card = findDescendant(container, "csPivotCard")
    if card == nil or card._rfPivotChipWired then return end
    card._rfPivotChipWired = true
    local prevDraw = card.draw
    function card:draw(...)
        if prevDraw ~= nil then prevDraw(self, ...) end
        local idm = g_inputDisplayManager
        if idm == nil or type(idm.getKeyboardKeyOverlay) ~= "function" then return end
        local overlay = idm:getKeyboardKeyOverlay()
        if overlay == nil or type(overlay.renderButton) ~= "function" then return end
        for _, id in ipairs(PIVOT_CHIP_IDS) do
            local el = findDescendant(self, id) or findDescendant(container, id)
            if el ~= nil then
                pcall(renderPivotChip, el, overlay)
            end
        end
        -- renderButton leaves global text state set (bold, centre, middle, colour).
        -- Vanilla gets away with it because every element sets its own state first;
        -- this draws outside that order, so put the defaults back.
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
        setTextColor(1, 1, 1, 1)
    end
end

--- BUILD 15:30: put the rotation origin on the dial hub.
---
--- GuiOverlay.renderOverlay defaults the pivot to the element centre:
---     local pivotX, pivotY = sizeX / 2, sizeY / 2
---     if overlay.customPivot ~= nil then pivotX, pivotY = overlay.customPivot[1], [2] end
--- so a bar rotated by setImageRotation spun about its own middle and swept like a
--- propeller. customPivot is honoured in the same screen-space units as the render size,
--- so {width/2, 0} - bottom-centre - makes the bar turn about its base. The page XML
--- parks each base on the hub; the two halves are one geometry and move together.
local function setNeedleHubPivot(el)
    if el == nil or el.overlay == nil then return end
    local w = el.absSize ~= nil and el.absSize[1] or nil
    if w == nil or w <= 0 then return end
    el.overlay.customPivot = { w * 0.5, 0 }
end

local function rotateNeedle(el, deg)
    if el == nil then return end
    setNeedleHubPivot(el)
    local rad = math.rad(deg or 0)
    if type(el.setImageRotation) == "function" then
        pcall(function() el:setImageRotation(rad) end)
    elseif type(el.setRotation) == "function" then
        pcall(function() el:setRotation(0, 0, rad) end)
    end
end

local function formatCoverageFields(sys)
    if sys == nil or type(sys.coveredFields) ~= "table" or #sys.coveredFields == 0 then
        return tr("cs_rf_pda_pivot_coverage_none", "Coverage: No fields covered")
    end
    local parts = {}
    for i = 1, math.min(#sys.coveredFields, 6) do
        parts[#parts + 1] = tostring(sys.coveredFields[i])
    end
    local list = table.concat(parts, ", ")
    if #sys.coveredFields > 6 then
        list = list .. "…"
    end
    return string.format(tr("cs_rf_pda_pivot_coverage", "Coverage: Fields %s"), list)
end

local function formatScheduleGlance(sys)
    if sys == nil or sys.schedule == nil then
        return tr("cs_rf_pda_pivot_sched_none", "Schedule: No schedule")
    end
    local s = sys.schedule
    local startH = tonumber(s.startHour) or 0
    local endH = tonumber(s.endHour) or 0
    local tag = scheduleDaysTag(s.activeDays)
    return string.format(
        tr("cs_rf_pda_pivot_sched", "Schedule: %02d:00–%02d:00%s"),
        startH, endH, tag or ""
    )
end

local function localFarmOwns(placeable)
    if placeable == nil or type(placeable.getOwnerFarmId) ~= "function" then
        return false
    end
    local owner = placeable:getOwnerFarmId()
    if owner == nil or owner == 0 then return false end
    local mgr = getMgr()
    local farmId = nil
    if mgr ~= nil and type(mgr.getLocalFarmId) == "function" then
        farmId = mgr.getLocalFarmId()
    elseif g_currentMission ~= nil and g_currentMission.player ~= nil then
        farmId = g_currentMission.player.farmId
    end
    return farmId ~= nil and farmId ~= 0 and farmId == owner
end

--- Light-tick safe: text + needle angles only. No SmoothList / no element rebuild.
--- BUILD 16:44c: the Esc dial face is the Reinke pivot panel's own POSITION scale.
--- The texture now ships inside this mod (the Reinke A22 pivot is vendored), so the
--- path resolves from SCS's own directory; the UV crop lives in the RF_CsPivotDialFace
--- profile (atlas pixel rect 288 354 400 400).
local REINKE_DECALS = "placeables/reinkeA22/textures/ControlDecals.dds"
local reinkeDecalPathCache = nil

local function reinkeDecalPath()
    if reinkeDecalPathCache ~= nil then
        return reinkeDecalPathCache ~= "" and reinkeDecalPathCache or nil
    end
    reinkeDecalPathCache = ""
    local function try(dir)
        if dir == nil or dir == "" then return false end
        local path = dir
        if path:sub(-1) ~= "/" then path = path .. "/" end
        path = path .. REINKE_DECALS
        if fileExists ~= nil and fileExists(path) then
            reinkeDecalPathCache = path
            return true
        end
        return false
    end
    -- The pivot is vendored, so SCS's own mod directory is the primary source.
    if g_currentModDirectory ~= nil then
        try(g_currentModDirectory)
    end
    -- Fall back to a live external Reinke mod if one is still installed.
    if reinkeDecalPathCache == "" and g_modManager ~= nil and type(g_modManager.getMods) == "function" then
        local ok, mods = pcall(function() return g_modManager:getMods() end)
        if ok and type(mods) == "table" then
            for _, m in pairs(mods) do
                local name = tostring((type(m) == "table" and (m.modName or m.title)) or "")
                if name:lower():find("reinke", 1, true) then
                    if try(type(m) == "table" and (m.modDir or m.directory) or nil) then break end
                end
            end
        end
    end
    if reinkeDecalPathCache == "" and g_modsDirectory ~= nil then
        try(g_modsDirectory .. "FS25_ReinkeA22")
    end
    return reinkeDecalPathCache ~= "" and reinkeDecalPathCache or nil
end

local function applyDialFace(container)
    local face = findDescendant(container, "csPivotDialFace")
    if face == nil or face._csDialFaceSet then return end
    local path = reinkeDecalPath()
    local function setDialChrome(visible)
        for _, id in ipairs({"csPivotDialLabel", "csPivotHubDot"}) do
            local el = findDescendant(container, id)
            if el ~= nil and el.setVisible then el:setVisible(visible) end
        end
    end
    if path == nil then
        -- Honest empty: no Reinke installed, so no dial face rather than a fake one.
        -- The POSITION label and hub cap go with it - they are the face's furniture, and
        -- leaving them floating over nothing would read as a broken dial.
        if face.setVisible then face:setVisible(false) end
        setDialChrome(false)
        face._csDialFaceSet = true
        return
    end
    setDialChrome(true)
    if type(face.setImageFilename) == "function" then
        pcall(function() face:setImageFilename(path) end)
        face._csDialFaceSet = true
        if face.setVisible then face:setVisible(true) end
    end
end

updatePivotCard = function(container, fieldId)
    local card = findDescendant(container, "csPivotCard")
    if card == nil then
        return
    end
    wirePivotChipPaint(container)
    applyDialFace(container)
    if card.setVisible then card:setVisible(true) end

    local mgr = getMgr()
    local members = selectedMemberIds(container)
    if (members == nil or #members == 0) and fieldId ~= nil then
        members = { fieldId }
    end
    local sysId, cands = selectedSystemId(container, mgr, members)
    refreshPivotSwitcher(container, mgr, members, cands)
    local irr = mgr ~= nil and mgr.irrigationManager or nil
    local sys = (irr ~= nil and irr.systems ~= nil and sysId ~= nil) and irr.systems[sysId] or nil
    local placeable = sysId ~= nil and resolvePlaceableById(sysId) or nil
    local reinke = isReinke(placeable)
    local spec = reinke and getReinkeSpec(placeable) or nil
    local owned = localFarmOwns(placeable)

    if sysId == nil or sys == nil then
        setPivotText(container, "csPivotTitle", tr("cs_rf_pda_pivot_title", "PIVOT"))
        setPivotText(container, "csPivotDialCur", tr("cs_rf_pda_pivot_dial_empty", "Cur —"))
        setPivotText(container, "csPivotDialMin", tr("cs_rf_pda_pivot_dial_min_empty", "Min —"))
        setPivotText(container, "csPivotDialMax", tr("cs_rf_pda_pivot_dial_max_empty", "Max —"))
        setPivotText(container, "csPivotCoverage", tr("cs_rf_pda_pivot_coverage_none", "Coverage: No fields covered"))
        setPivotText(container, "csPivotWatering", tr("cs_rf_pda_pivot_watering_off", "Watering now: Off"))
        setPivotText(container, "csPivotPressure", tr("cs_rf_pda_pivot_pressure_na", "Pressure: —"))
        setPivotText(container, "csPivotRate", tr("cs_rf_pda_pivot_rate_na", "Rate: —"))
        setPivotText(container, "csPivotSchedule", tr("cs_rf_pda_pivot_sched_none", "Schedule: No schedule"))
        setPivotText(container, "csPivotWarn",
            tr("cs_rf_pda_pivot_warn_none", "No pivot on this field"))
        local dead = {
            "csPivotBtnDoor", "csPivotBtnPower", "csPivotBtnSpray", "csPivotBtnEndGun",
            "csPivotBtnSpeed", "csPivotBtnStart", "csPivotBtnStop",
            "csPivotBtnMinUp", "csPivotBtnMinDn", "csPivotBtnMaxUp", "csPivotBtnMaxDn",
            "csPivotBtnArmPlus", "csPivotBtnArmMinus", "csBtnSchedule",
        }
        local labels = {
            csPivotBtnDoor = tr("cs_rf_pda_pivot_btn_door", "Door"),
            csPivotBtnPower = tr("cs_rf_pda_pivot_btn_power", "Power"),
            csPivotBtnSpray = tr("cs_rf_pda_pivot_btn_spray", "Spray"),
            csPivotBtnEndGun = tr("cs_rf_pda_pivot_btn_endgun", "End gun"),
            csPivotBtnSpeed = tr("cs_rf_pda_pivot_btn_speed", "Speed"),
            csPivotBtnStart = tr("cs_rf_pda_pivot_btn_start", "Start"),
            csPivotBtnStop = tr("cs_rf_pda_pivot_btn_stop", "Stop"),
            csPivotBtnMinUp = tr("cs_rf_pda_pivot_btn_min_up", "Min+"),
            csPivotBtnMinDn = tr("cs_rf_pda_pivot_btn_min_dn", "Min−"),
            csPivotBtnMaxUp = tr("cs_rf_pda_pivot_btn_max_up", "Max+"),
            csPivotBtnMaxDn = tr("cs_rf_pda_pivot_btn_max_dn", "Max−"),
            csPivotBtnArmPlus = tr("cs_rf_pda_pivot_btn_arm_plus", "Arm+"),
            csPivotBtnArmMinus = tr("cs_rf_pda_pivot_btn_arm_minus", "Arm−"),
            csBtnSchedule = tr("cs_rf_pda_pivot_btn_schedule", "Schedule"),
        }

        -- RAINSTAR SEAT: a vehicle irrigator is not a placeable system, so no
        -- Reinke pivot resolves here. When one is present on the selected field
        -- (parked or running) the seat is not empty: report it, show whether it
        -- is actually watering, and offer a Stop while it is active.
        local vehIrr = mgr ~= nil and mgr.irrigatorSectorIntegration or nil
        local presentFields = vehIrr and type(vehIrr.getPresentFields) == "function"
            and vehIrr:getPresentFields() or nil
        local activeFields = vehIrr and type(vehIrr.getActiveWateredFields) == "function"
            and vehIrr:getActiveWateredFields() or nil
        local rainstarHere = false
        local rainstarActive = false
        if presentFields then
            if fieldId ~= nil and presentFields[fieldId] then
                rainstarHere = true
            else
                for _, mid in ipairs(members or {}) do
                    if presentFields[mid] then rainstarHere = true break end
                end
            end
        end
        if activeFields then
            local anyActive = false
            if fieldId ~= nil and activeFields[fieldId] then
                anyActive = true
            else
                for _, mid in ipairs(members or {}) do
                    if activeFields[mid] then anyActive = true break end
                end
            end
            rainstarActive = anyActive
            -- A Rainstar whose root sits beside the field but whose sector lands
            -- on it is still the irrigator here; presence or active both count.
            if anyActive then rainstarHere = true end
        end
        if rainstarHere then
            setPivotText(container, "csPivotTitle",
                tr("cs_rf_pda_pivot_title_rainstar", "RAINSTAR"))
            setPivotText(container, "csPivotDialCur",
                tr("cs_rf_pda_pivot_rainstar_label", "Vehicle irrigator"))
            setPivotText(container, "csPivotDialMin", "")
            setPivotText(container, "csPivotDialMax", "")
            setPivotText(container, "csPivotCoverage",
                tr("cs_rf_pda_pivot_coverage_rainstar", "Coverage: Rainstar spraying this field"))
            setPivotText(container, "csPivotWatering", rainstarActive
                and tr("cs_rf_pda_pivot_watering_on", "Watering now: On")
                or tr("cs_rf_pda_pivot_watering_off", "Watering now: Off"))
            setPivotText(container, "csPivotPressure",
                tr("cs_rf_pda_pivot_pressure_na", "Pressure: —"))
            setPivotText(container, "csPivotRate",
                tr("cs_rf_pda_pivot_rate_na", "Rate: —"))
            setPivotText(container, "csPivotSchedule",
                tr("cs_rf_pda_pivot_sched_none", "Schedule: No schedule"))
            setPivotText(container, "csPivotWarn",
                tr("cs_rf_pda_pivot_warn_rainstar", "Vehicle irrigator"))
            for _, id in ipairs(dead) do
                if id == "csPivotBtnStop" then
                    setPivotBtn(container, id, labels[id], rainstarActive, false)
                else
                    setPivotBtn(container, id, labels[id], false, true)
                end
            end
            return
        end

        for _, id in ipairs(dead) do
            setPivotBtn(container, id, labels[id], false, true)
        end
        return
    end

    -- Title surfaces resolved covering systemId for the selected field (multi-cover honesty).
    local sysTag = tostring(sysId)
    if not reinke then
        -- Drip / non-pivot: honest status, no fake needles.
        setPivotText(container, "csPivotTitle",
            string.format("%s #%s", tr("cs_rf_pda_pivot_title_irrig", "IRRIGATION"), sysTag))
        setPivotText(container, "csPivotDialCur", tr("cs_rf_pda_pivot_drip_label", "Drip line"))
        setPivotText(container, "csPivotDialMin", "")
        setPivotText(container, "csPivotDialMax", "")
    else
        setPivotText(container, "csPivotTitle",
            string.format("%s #%s", tr("cs_rf_pda_pivot_title", "PIVOT"), sysTag))
        local curDeg, minDeg, maxDeg = 0, 0, 0
        if spec ~= nil then
            curDeg = math.deg(spec.armAngle or 0) % 360
            if spec.autoRotate then
                minDeg = spec.autoMinAngleDeg or 0
                maxDeg = spec.autoMaxAngleDeg or 360
            else
                local tgt = spec.targetAngle or spec.armAngle or 0
                minDeg = math.deg(tgt) % 360
                maxDeg = minDeg
            end
        end
        setPivotText(container, "csPivotDialCur",
            string.format(tr("cs_rf_pda_pivot_dial_cur", "Cur %.0f°"), curDeg))
        setPivotText(container, "csPivotDialMin",
            string.format(tr("cs_rf_pda_pivot_dial_min", "Min %.0f°"), minDeg))
        setPivotText(container, "csPivotDialMax",
            string.format(tr("cs_rf_pda_pivot_dial_max", "Max %.0f°"), maxDeg))
        rotateNeedle(findDescendant(container, "csPivotNeedleCur"), curDeg)
        rotateNeedle(findDescendant(container, "csPivotNeedleMin"), minDeg)
        rotateNeedle(findDescendant(container, "csPivotNeedleMax"), maxDeg)
    end

    setPivotText(container, "csPivotCoverage", formatCoverageFields(sys))
    local watering = sys.isActive == true
    setPivotText(container, "csPivotWatering", watering
        and tr("cs_rf_pda_pivot_watering_on", "Watering now: On")
        or tr("cs_rf_pda_pivot_watering_off", "Watering now: Off"))

    local pressurePct = math.floor((sys.pressureMultiplier or 0) * 100 + 0.5)
    setPivotText(container, "csPivotPressure",
        string.format(tr("cs_rf_pda_pivot_pressure", "Pressure: %d%%"), pressurePct))

    local wear = sys.wearLevel or 0
    local rate = (sys.flowRatePerHour or 0) * (sys.pressureMultiplier or 0) * (1 - wear * 0.3)
    if rate > 0 then
        setPivotText(container, "csPivotRate",
            string.format(tr("cs_rf_pda_pivot_rate", "Rate: +%.3f/h"), rate))
    else
        setPivotText(container, "csPivotRate", tr("cs_rf_pda_pivot_rate_na", "Rate: —"))
    end
    setPivotText(container, "csPivotSchedule", formatScheduleGlance(sys))

    local warn = ""
    if not owned then
        warn = tr("cs_rf_pda_pivot_warn_owner", "Not your pivot")
    elseif reinke and spec ~= nil and not spec.doorOpen then
        warn = tr("cs_rf_pda_pivot_warn_door", "Open door for ops")
    elseif reinke and spec ~= nil and not spec.masterPower then
        warn = tr("cs_rf_pda_pivot_warn_power", "Power off")
    elseif (sys.pressureMultiplier or 0) <= 0 then
        warn = tr("cs_rf_pda_pivot_warn_pump", "Pump disconnected")
    end
    setPivotText(container, "csPivotWarn", warn, warn ~= "")

    local doorOpen = spec ~= nil and spec.doorOpen == true
    local powered = spec ~= nil and spec.masterPower == true
    local opsOk = owned and reinke and doorOpen and powered
    local doorOk = owned and reinke
    local powerOk = owned and reinke and doorOpen
    local autoRotate = (spec ~= nil and spec.autoRotate) or watering
    local armOk = opsOk and not autoRotate

    local speedLabel = tr("cs_rf_pda_pivot_btn_speed", "Speed")
    if spec ~= nil and ReinkeIrrigationPivot ~= nil and ReinkeIrrigationPivot.SPEED_LABELS ~= nil then
        local lab = ReinkeIrrigationPivot.SPEED_LABELS[spec.speedIndex or 2]
        if lab ~= nil then
            speedLabel = tostring(lab)
        end
    end

    setPivotBtn(container, "csPivotBtnDoor", tr("cs_rf_pda_pivot_btn_door", "Door"), doorOk)
    setPivotBtn(container, "csPivotBtnPower", tr("cs_rf_pda_pivot_btn_power", "Power"), powerOk)
    setPivotBtn(container, "csPivotBtnSpray", tr("cs_rf_pda_pivot_btn_spray", "Spray"), opsOk)
    setPivotBtn(container, "csPivotBtnEndGun", tr("cs_rf_pda_pivot_btn_endgun", "End gun"), opsOk)
    setPivotBtn(container, "csPivotBtnSpeed", speedLabel, opsOk)
    setPivotBtn(container, "csPivotBtnStart", tr("cs_rf_pda_pivot_btn_start", "Start"), owned and (reinke or sys ~= nil))
    setPivotBtn(container, "csPivotBtnStop", tr("cs_rf_pda_pivot_btn_stop", "Stop"), owned and (reinke or sys ~= nil))
    setPivotBtn(container, "csPivotBtnMinUp", tr("cs_rf_pda_pivot_btn_min_up", "Min+"), opsOk)
    setPivotBtn(container, "csPivotBtnMinDn", tr("cs_rf_pda_pivot_btn_min_dn", "Min−"), opsOk)
    setPivotBtn(container, "csPivotBtnMaxUp", tr("cs_rf_pda_pivot_btn_max_up", "Max+"), opsOk)
    setPivotBtn(container, "csPivotBtnMaxDn", tr("cs_rf_pda_pivot_btn_max_dn", "Max−"), opsOk)
    setPivotBtn(container, "csPivotBtnArmPlus", tr("cs_rf_pda_pivot_btn_arm_plus", "Arm+"), armOk)
    setPivotBtn(container, "csPivotBtnArmMinus", tr("cs_rf_pda_pivot_btn_arm_minus", "Arm−"), armOk)
    setPivotBtn(container, "csBtnSchedule", tr("cs_rf_pda_pivot_btn_schedule", "Schedule"), true)
end


--- Esc CS breath: upper-right Agronomist card (stacked with Pivot). Fixed Text
--- only; field table stays visible (George: no table-hiding consult view).
local function updateAgronomistCard(container, fieldId)
    local card = findDescendant(container, "csAgronomistCard")
    if card == nil then
        return
    end
    if card.setVisible then card:setVisible(true) end
    local mgr = getMgr()
    setPivotText(container, "csAgroTitle", tr("cs_rf_pda_agro_title", "AGRONOMIST"))

    -- Relationship: only when the NPC is genuinely registered. Never a fake score.
    local relShown = false
    local npc = mgr ~= nil and mgr.npcIntegration or nil
    if npc ~= nil and npc.isRegistered and type(npc.getRelationshipLevel) == "function" then
        local ok, rel = pcall(function() return npc:getRelationshipLevel() end)
        if ok and type(rel) == "number" then
            setPivotText(container, "csAgroRelationship",
                string.format(tr("cs_rf_pda_agro_relation", "Alex Chen - %d / 100"), rel), true)
            relShown = true
        end
    end
    if not relShown then
        setPivotText(container, "csAgroRelationship", "", false)
    end

    local top = topRiskFields(mgr, 5)
    setPivotText(container, "csAgroTopHeader", tr("cs_rf_pda_agro_top_header", "Top 5 at risk"), #top > 0)
    for i = 1, 5 do
        local e = top[i]
        if e == nil then
            setPivotText(container, "csAgroTop" .. i, "", false)
        else
            local name = e.label or ("Field " .. tostring(e.fieldId))
            setPivotText(container, "csAgroTop" .. i, string.format(
                tr("cs_rf_pda_agro_top_row", "%s - risk %d%% - moisture %d%%"),
                name,
                math.floor(e.risk * 100 + 0.5),
                math.floor(e.moisture * 100 + 0.5)), true)
        end
    end

    -- Recommendations: same compose as the certified consultant read.
    local recs = {}
    if #top > 0 then
        local t1 = top[1]
        recs[#recs + 1] = string.format(
            tr("cs_rf_pda_cons_rec_driest", "Driest now: %s at %d%% moisture - water this one first."),
            t1.label or ("Field " .. tostring(t1.fieldId)), math.floor(t1.moisture * 100 + 0.5))
        local wi = mgr ~= nil and mgr.weatherIntegration or nil
        if wi ~= nil and type(wi.getMoistureForecast) == "function" then
            local ok, fc = pcall(function() return wi:getMoistureForecast(t1.fieldId, 3) end)
            if ok and type(fc) == "number" then
                recs[#recs + 1] = string.format(
                    tr("cs_rf_pda_cons_rec_forecast", "3-day outlook for %s: %d%% moisture."),
                    t1.label or ("Field " .. tostring(t1.fieldId)), math.floor(fc * 100 + 0.5))
            end
        end
    end
    local irr = mgr ~= nil and mgr.irrigationManager or nil
    local activeCount = 0
    if irr ~= nil and irr.systems ~= nil then
        for _, sys in pairs(irr.systems) do
            if sys ~= nil and sys.isActive then activeCount = activeCount + 1 end
        end
    end
    recs[#recs + 1] = (activeCount > 0)
        and string.format(tr("cs_rf_pda_cons_rec_systems", "%d irrigation systems active."), activeCount)
        or tr("cs_rf_pda_cons_rec_nosystems", "No active irrigation - shop coverage for the driest fields.")

    setPivotText(container, "csAgroRecHeader", tr("cs_rf_pda_agro_rec_header", "Recommendations"), #recs > 0)
    for i = 1, 3 do
        setPivotText(container, "csAgroRec" .. i, recs[i] or "", recs[i] ~= nil)
    end

    -- Honest empty: no owned field data at all, so say that rather than show blanks.
    setPivotText(container, "csAgroEmpty",
        tr("cs_rf_pda_agro_empty", "No field data yet - fields appear once the simulation runs."),
        #top == 0)
end

--- Esc PIVOT remote: send CropStressPivotRemoteEvent (server authority).
function CsRfPdaGuest.onPivotRemote(container, actionToken)
    local A = CropStressPivotRemoteEvent ~= nil and CropStressPivotRemoteEvent.ACTION or PIVOT_ACTION
    local action = A[actionToken]
    if action == nil and type(actionToken) == "number" then
        action = actionToken
    end
    -- BUILD 15:26 prove-path: a remote that does nothing must say why. These fire
    -- on player clicks only, never on the light tick, so the log stays readable.
    if action == nil then
        print(string.format("[CropStress] Esc pivot %s IGNORED: unknown action token",
            tostring(actionToken)))
        return
    end
    local fieldId = selectedFieldId(container)
    local mgr = getMgr()
    local members = selectedMemberIds(container)
    if (members == nil or #members == 0) and fieldId ~= nil then
        members = { fieldId }
    end
    local sysId = select(1, selectedSystemId(container, mgr, members))
    if sysId == nil then
        -- RAINSTAR STOP: no placed pivot covers this field, but a Rainstar may
        -- be actively watering it. Route the Stop remote to the vehicle rig.
        if action == A.AUTO_STOP and fieldId ~= nil then
            local vehIrr = mgr ~= nil and mgr.irrigatorSectorIntegration or nil
            if vehIrr and type(vehIrr.stopForField) == "function" then
                vehIrr:stopForField(fieldId)
                print(string.format(
                    "[CropStress] Esc pivot STOP -> Rainstar stop fieldId=%s",
                    tostring(fieldId)))
                if type(CsRfPdaGuest.onShow) == "function" then
                    CsRfPdaGuest.onShow(container, true)
                end
                return
            end
        end
        print(string.format(
            "[CropStress] Esc pivot %s IGNORED: no system resolved for fieldId=%s",
            tostring(actionToken), tostring(fieldId)))
        return
    end
    if CropStressPivotRemoteEvent ~= nil and type(CropStressPivotRemoteEvent.sendToServer) == "function" then
        print(string.format(
            "[CropStress] Esc pivot %s -> sendToServer(sysId=%s, action=%s) fieldId=%s",
            tostring(actionToken), tostring(sysId), tostring(action), tostring(fieldId)))
        CropStressPivotRemoteEvent.sendToServer(sysId, action)
    else
        print(string.format(
            "[CropStress] Esc pivot %s IGNORED: CropStressPivotRemoteEvent.sendToServer unavailable",
            tostring(actionToken)))
    end
    -- Light refresh so Watering now / dial catch listen-server apply quickly.
    if type(CsRfPdaGuest.onShow) == "function" then
        CsRfPdaGuest.onShow(container, true)
    end
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
    -- Action buttons follow the selection: Consultant always, Schedule only when
    -- a covering system exists (0 coverage paints the honest strip copy instead).
    CsRfPdaGuest.refreshActionButtons(container, hasEntry and entry.fieldId or nil)
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
        updatePivotCard(container, nil)
        updateAgronomistCard(container, nil)
        return
    end

    local fieldId = entry.fieldId
    local mgr = getMgr()
    local members = entry.memberFieldIds or { fieldId }
    local covered = #coveringSystemsForMembers(mgr, members) > 0

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

    -- PIVOT card and AGRONOMIST card follow the same selection SoT as the strip.
    updatePivotCard(container, fieldId)
    updateAgronomistCard(container, fieldId)
end

---@param container table|nil rfHostPlaceholder from Soil RfPdaMenuPage
---@param lightOnly boolean|nil when true (host 2s tick): text only, no SmoothList reload
function CsRfPdaGuest.onShow(container, lightOnly)
    local stats = CsRfPdaGuest.computeGlanceStats()
    local title = tr("cs_rf_pda_module_title", "Crop Stress")
    -- Samantha DESIGN 2026-08-09: field table is HOME; no Tablet gate.
    local blurb = tr("cs_rf_pda_blurb", "Field desk - moisture, stress, irrigation. Pivot is on page 2.")
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

    local page = getHostPage()
    wireConsultViewLabels(page)

    if not lightOnly then
        reloadHostTable(container)
        -- Field table is always home on module show. Never auto-open consultant.
        local entering = page == nil or page._lastShownPanelId ~= "seasonalCropStress"
        if entering and page ~= nil and type(page.setCsConsultView) == "function" then
            page:setCsConsultView(false)
        end
        -- Selection SoT: if none yet, crown first row so detail + PIVOT agree with highlight.
        if page ~= nil and page.csSelectedFieldId == nil and page.csFieldData ~= nil and page.csFieldData[1] ~= nil then
            page.csSelectedIndex = 1
            page.csSelectedFieldId = page.csFieldData[1].fieldId
            if page.csFieldOverviewList ~= nil and type(page.csFieldOverviewList.setSelectedIndex) == "function" then
                pcall(function() page.csFieldOverviewList:setSelectedIndex(1) end)
            end
        elseif page ~= nil and page.csSelectedFieldId ~= nil then
            -- Keep fieldId SoT; re-resolve index after reload so highlight matches strip.
            local rows = page.csFieldData or {}
            local idx = nil
            for i, row in ipairs(rows) do
                if row.fieldId == page.csSelectedFieldId then
                    idx = i
                    break
                end
            end
            page.csSelectedIndex = idx
            if idx ~= nil and page.csFieldOverviewList ~= nil
                and type(page.csFieldOverviewList.setSelectedIndex) == "function" then
                pcall(function() page.csFieldOverviewList:setSelectedIndex(idx) end)
            end
        end
    end
    -- Bottom info band + PIVOT: text/needle only, allowed on light tick.
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
    -- Always ensureDoor when bootstrap class is sourced; never trust bare (SeasonalCropStressModDirectory or g_currentModDirectory) at callback time.
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
            onOpenConsultant = CsRfPdaGuest.onOpenConsultant,
            onPaintConsultant = CsRfPdaGuest.onPaintConsultant,
            onOpenSchedule = CsRfPdaGuest.onOpenSchedule,
            onOpenHelp = CsRfPdaGuest.onOpenHelp,
            onPivotRemote = CsRfPdaGuest.onPivotRemote,
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
