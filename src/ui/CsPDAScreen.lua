-- =========================================================
-- CsPDAScreen
-- InGameMenu (PDA) page for Seasonal Crop Stress.
-- Two tabs:
--   Overview  — farm-wide moisture / stress stats
--   Irrigation — field triage list sorted by moisture asc
--
-- Pattern: mirrors FS25_SoilFertilizer SoilPDAScreen.lua /
--          FS25_MarketDynamics MDMMarketScreen.
-- =========================================================

---@class CsPDAScreen
CsPDAScreen = CsPDAScreen or {}
CsPDAScreen._mt = Class(CsPDAScreen, TabbedMenuFrameElement)

CsPDAScreen.CLASS_NAME     = "CsPDAScreen"
CsPDAScreen.MENU_PAGE_NAME = "menuCropStress"
CsPDAScreen.XML_FILENAME   = "xml/gui/CsPDAScreen.xml"
CsPDAScreen.MENU_ICON_PATH = "icon.dds"

local CS_PDA_MOD_DIR  = (SeasonalCropStressModDirectory or g_currentModDirectory)
local CS_PDA_MOD_NAME = (SeasonalCropStressModName or g_currentModName)

CsPDAScreen.CONTROLS = {
    -- Field list (left sidebar)
    "fieldList",
    -- Stats panel (right, overview tab)
    "overviewContent",
    "statsFieldsTracked", "statsFieldsOwned",
    "statsAvgMoisture",
    "statsHealthy", "statsWarning", "statsCritical",
    "statsAvgStress", "statsYieldLoss",
    "statsIrrigated", "statsIrrSystems",
    "overviewEmptyHint",
    -- Irrigation tab
    "irrigationContent",
    "irrigationList",
    "irrigationEmptyHint",
    -- Tab decorations
    "tabLabelOverview", "tabLabelIrrigation",
    "tabUnderlineOverview", "tabUnderlineIrrigation",
}

local TAB_OVERVIEW   = 1
local TAB_IRRIGATION = 2

local REFRESH_INTERVAL = 2500  -- ms between data rebuilds while PDA is open

local COLOR_HEALTHY = {0.25, 0.85, 0.40, 1.0}
local COLOR_WARNING = {0.90, 0.82, 0.18, 1.0}
local COLOR_CRITICAL= {0.88, 0.25, 0.25, 1.0}
local COLOR_DIM     = {0.65, 0.65, 0.65, 1.0}
local COLOR_WHITE   = {1.00, 1.00, 1.00, 1.0}

-- Module-level pending registration
local _pendingRegistration = false
local _pendingModDir       = nil

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[CS_PDA_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Data helpers ──────────────────────────────────────────

--- BUILD 19:23 (George CLOSED DESIGN 19:12): the Soil list-row merge module on the mission bridge
--- (Soil attaches it next to soilFertilityManager; getfenv(0) does not cross mods). nil when Soil is
--- absent, and then every caller keeps today's per-farmland rows. Only Soil drives the outline walks;
--- this side only calls buildGroups (may queue a walk on Soil's driver) or readGroups (cached only).
local function getSoilMerge()
    if g_currentMission == nil or g_currentMission.soilFertilityManager == nil then
        return nil
    end
    local merge = g_currentMission.RfPdaSoilMerge
    if type(merge) ~= "table" then
        return nil
    end
    return merge
end

local function getMgr()
    return g_cropStressManager
end

local function getCropName(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex == 0 then return "—" end
    local ft = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if ft and ft.name then
        local name = ft.name
        return name:sub(1,1):upper() .. name:sub(2):lower()
    end
    return "—"
end

local function getMoistureColor(moisture)
    if moisture >= 0.40 then return COLOR_HEALTHY
    elseif moisture >= 0.25 then return COLOR_WARNING
    else return COLOR_CRITICAL end
end

local function getMoistureStatus(moisture)
    if moisture >= 0.40 then return tr("cs_pda_status_healthy", "Healthy")
    elseif moisture >= 0.25 then return tr("cs_pda_status_warning", "Warning")
    else return tr("cs_pda_status_critical", "Critical") end
end

-- ── Constructor ───────────────────────────────────────────

function CsPDAScreen.new()
    local self = CsPDAScreen:superClass().new(nil, CsPDAScreen._mt)
    self.name      = "CsPDAScreen"
    self.className = "CsPDAScreen"

    self.activeTab        = TAB_OVERVIEW
    self.fieldData        = {}  -- sorted list: {fieldId, cropName, moisture, stress, irrigated}
    self.irrigationData   = {}  -- subset sorted by moisture asc
    self.showOwnedOnly    = false  -- ownership filter state

    self.refreshTimer     = 0
    self.returnScreenName = ""
    self.menuButtonInfo   = {}
    return self
end

-- ── Initialize ────────────────────────────────────────────

function CsPDAScreen:initialize()
    CsPDAScreen:superClass().initialize(self)
    -- SoilFertilizer pattern: MENU_BACK + MENU_ACCEPT (filter) + MENU_EXTRA_1/2 for actions.
    -- MENU_EXTRA_3 does not render; Help is an inline button in the XML sidebar.
    -- Store the filter entry so _updateFilterButton can update its text in-place.
    self.filterButtonEntry = {
        inputAction = "MENU_EXTRA_1",
        text        = tr("cs_pda_filter_all", "ALL FIELDS"),
        callback    = function() self:onClickFilterToggle() end,
    }
    self.menuButtonInfo = {
        {inputAction = "MENU_BACK"},
        {inputAction = "MENU_EXTRA_2",
         text     = tr("cs_pda_btn_help", "Help"),
         callback = function() self:onClickHelp() end},
        self.filterButtonEntry,
    }
    self:setMenuButtonInfo(self.menuButtonInfo)
end

function CsPDAScreen:onClickIrrigationSchedule()
    CsDialogLoader.show("IrrigationScheduleDialog")
end

function CsPDAScreen:onClickCropConsultant()
    CsDialogLoader.show("CropConsultantDialog")
end

function CsPDAScreen:onClickHelp()
    CsDialogLoader.show("CsHelpDialog")
end

-- Wire SmoothList datasource/delegate (MDM pattern — must be done after loadGui)
function CsPDAScreen:onGuiSetupFinished()
    CsPDAScreen:superClass().onGuiSetupFinished(self)

    if self.fieldList then
        self.fieldList.dataSource = self
        self.fieldList.delegate   = self
    end
    if self.irrigationList then
        self.irrigationList.dataSource = self
        self.irrigationList.delegate   = self
    end
end

-- ── Registration ──────────────────────────────────────────

function CsPDAScreen.register(modDir)
    -- Greenfield RF Esc door owns the Esc tab when it actually exists.
    -- RfEscBootstrap ~= nil only means the class was sourced — NOT that the door is live.
    if RfEscBootstrap ~= nil and CsRfPdaGuest ~= nil and type(CsRfPdaGuest.tryRegister) == "function" then
        CsRfPdaGuest.tryRegister()
    end
    if g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil then
        print("[CropStress] CsPDAScreen: RF Esc door present — skipping legacy menuCropStress inject")
        _pendingRegistration = false
        return
    end
    if CsPDAScreen._performRegistration(modDir) then return end
    _pendingRegistration = true
    _pendingModDir       = modDir
    print("[CropStress] CsPDAScreen: deferred registration — InGameMenu not ready yet")
end

function CsPDAScreen._attemptDeferredRegister(dt)
    if RfEscBootstrap ~= nil and CsRfPdaGuest ~= nil and type(CsRfPdaGuest.tryRegister) == "function" then
        CsRfPdaGuest.tryRegister()
    end
    if g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil then
        _pendingRegistration = false
        return
    end
    if not _pendingRegistration then return end
    if CsPDAScreen._performRegistration(_pendingModDir) then
        _pendingRegistration = false
        _pendingModDir       = nil
    end
end

function CsPDAScreen._performRegistration(modDir)
    if g_gui == nil or g_inGameMenu == nil then return false end

    if RfEscBootstrap ~= nil and CsRfPdaGuest ~= nil and type(CsRfPdaGuest.tryRegister) == "function" then
        CsRfPdaGuest.tryRegister()
    end
    if g_inGameMenu.menuRealisticFarming ~= nil then
        print("[CropStress] CsPDAScreen: RF Esc door present — skipping legacy inject")
        return true
    end

    if g_inGameMenu[CsPDAScreen.MENU_PAGE_NAME] ~= nil then
        print("[CropStress] CsPDAScreen: already registered, skipping")
        return true
    end

    local screen  = CsPDAScreen.new()
    local xmlPath = modDir .. CsPDAScreen.XML_FILENAME

    print("[CropStress] CsPDAScreen: loading GUI from: " .. xmlPath)
    local ok, err = pcall(function()
        g_gui:loadGui(xmlPath, CsPDAScreen.CLASS_NAME, screen, true)
    end)
    if not ok then
        print("[CropStress] CsPDAScreen: loadGui failed: " .. tostring(err))
        return false
    end

    local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        print("[CropStress] CsPDAScreen: inGameMenu or pagingElement nil")
        return false
    end

    if g_inGameMenu ~= nil and g_inGameMenu.controlIDs ~= nil then
        g_inGameMenu.controlIDs[CsPDAScreen.MENU_PAGE_NAME] = nil
    end

    inGameMenu[CsPDAScreen.MENU_PAGE_NAME] = screen

    local alreadyAdded = false
    if inGameMenu.pagingElement.elements then
        for _, el in ipairs(inGameMenu.pagingElement.elements) do
            if el == screen then alreadyAdded = true; break end
        end
    end
    if not alreadyAdded then
        inGameMenu.pagingElement:addElement(screen)
    end

    if type(inGameMenu.exposeControlsAsFields) == "function" then
        pcall(inGameMenu.exposeControlsAsFields, inGameMenu, CsPDAScreen.MENU_PAGE_NAME)
    end
    if type(inGameMenu.pagingElement.updateAbsolutePosition) == "function" then
        pcall(inGameMenu.pagingElement.updateAbsolutePosition, inGameMenu.pagingElement)
    end
    if type(inGameMenu.pagingElement.updatePageMapping) == "function" then
        pcall(inGameMenu.pagingElement.updatePageMapping, inGameMenu.pagingElement)
    end
    if type(inGameMenu.registerPage) == "function" then
        pcall(inGameMenu.registerPage, inGameMenu, screen, nil, function() return true end)
    end

    -- Tab icon
    local iconFile = Utils.getFilename(CsPDAScreen.MENU_ICON_PATH, modDir)
    if iconFile and type(inGameMenu.addPageTab) == "function" then
        local okTab, errTab = pcall(inGameMenu.addPageTab, inGameMenu, screen,
                                    iconFile, GuiUtils.getUVs({0, 0, 1024, 1024}))
        if not okTab then
            print("[CropStress] CsPDAScreen: addPageTab failed: " .. tostring(errTab))
        end
    end

    if type(inGameMenu.rebuildTabList) == "function" then
        pcall(inGameMenu.rebuildTabList, inGameMenu)
    end
    if type(screen.initialize) == "function" then
        pcall(screen.initialize, screen)
    end

    print("[CropStress] CsPDAScreen: registered successfully")
    return true
end

-- ── Public toggle (called from map overlay button & keybind) ──

--- Ensure the deep PDA screen is in InGameMenu paging (no Esc tab) for map open only.
function CsPDAScreen._ensureDeepPageInjectable(inGameMenu, page)
    if inGameMenu == nil or page == nil or inGameMenu.pagingElement == nil then
        return false
    end
    local pe = inGameMenu.pagingElement
    local inElements = false
    if pe.elements ~= nil then
        for _, el in ipairs(pe.elements) do
            if el == page then
                inElements = true
                break
            end
        end
    end
    if not inElements and type(pe.addElement) == "function" then
        pe:addElement(page)
    end
    inGameMenu[CsPDAScreen.MENU_PAGE_NAME] = page
    if type(pe.updateAbsolutePosition) == "function" then
        pcall(pe.updateAbsolutePosition, pe)
    end
    if type(pe.updatePageMapping) == "function" then
        pcall(pe.updatePageMapping, pe)
    end
    return true
end

function CsPDAScreen.toggle()
    if g_gui == nil then return end
    -- Don't interrupt other dialogs (MDM pattern)
    local curName = g_gui.currentGuiName
    if curName ~= nil and curName ~= "" and curName ~= "InGameMenu" then return end

    local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil then return end

    local screen = inGameMenu[CsPDAScreen.MENU_PAGE_NAME] or CsPDAScreen._retainedDeepScreen
    if screen == nil then return end

    -- If already on our page, close the menu
    if curName == "InGameMenu" and inGameMenu.currentPage == screen then
        g_gui:changeScreen(nil)
        return
    end

    -- After Esc rail stand-down, page lives only on _retainedDeepScreen; re-inject without tab.
    if inGameMenu[CsPDAScreen.MENU_PAGE_NAME] == nil or CsPDAScreen._retainedDeepScreen == screen then
        CsPDAScreen._ensureDeepPageInjectable(inGameMenu, screen)
    end

    -- Navigate to our page — works from map view and gameplay (MDM: goToPage pattern)
    g_gui:showGui("InGameMenu")
    if type(inGameMenu.goToPage) == "function" then
        inGameMenu:goToPage(screen)
    elseif type(inGameMenu.showPage) == "function" then
        inGameMenu:showPage(screen)
    end
end

-- ── Filter toggle ────────────────────────────────────────

function CsPDAScreen:onClickFilterToggle()
    self.showOwnedOnly = not self.showOwnedOnly
    self:_updateFilterButton()
    self:_rebuildData()
    self:_reloadLists()
    if self.activeTab == TAB_OVERVIEW then
        self:_rebuildStats()
    end
end

function CsPDAScreen:_updateFilterButton()
    local label = self.showOwnedOnly
        and tr("cs_pda_filter_owned", "MY FIELDS")
        or  tr("cs_pda_filter_all",   "ALL FIELDS")
    if self.filterButtonEntry then
        self.filterButtonEntry.text = label
        self:setMenuButtonInfo(self.menuButtonInfo)
    end
end

-- ── Data rebuild ──────────────────────────────────────────

function CsPDAScreen:_rebuildData()
    local mgr = getMgr()
    if mgr == nil then
        self.fieldData      = {}
        self.irrigationData = {}
        return
    end

    local soilSystem  = mgr.soilSystem
    local stressMod   = mgr.stressModifier
    local irrMgr      = mgr.irrigationManager

    if soilSystem == nil then return end

    -- On dedi clients the field-ready updater may not have fired yet.
    -- Enumerate directly so the first open is not blank.
    if next(soilSystem.fieldData) == nil then
        soilSystem:enumerateFields()
        mgr:buildFieldMap()
    end

    local fieldById   = mgr.fieldById or {}

    -- Build covered fields map: fieldId -> systemId (first system found wins)
    local coveredFields = {}  -- fieldId -> systemId
    if irrMgr and irrMgr.systems then
        for sysId, sys in pairs(irrMgr.systems) do
            if sys.coveredFields then
                -- coveredFields is an array of farmland ids — iterate values, not keys.
                for _, fid in ipairs(sys.coveredFields) do
                    if coveredFields[fid] == nil then
                        coveredFields[fid] = sysId
                    end
                end
            end
        end
    end

    -- Vehicle irrigators (Rainstar play kit): a field a Rainstar is parked on
    -- is irrigated even when no placeable system covers it, running or not.
    -- Kept separate from coveredFields so a vehicle-watered field keeps a nil
    -- systemId and the row click still says "no irrigation system connected".
    local vehicleFields = {}
    local vehIrr = mgr.irrigatorSectorIntegration
    if vehIrr and type(vehIrr.getPresentFields) == "function" then
        for fid in pairs(vehIrr:getPresentFields()) do
            vehicleFields[fid] = true
        end
    end

    local localFarmId = self.showOwnedOnly and mgr.getLocalFarmId() or nil

    local rows = {}
    for fid, entry in pairs(soilSystem.fieldData) do
        local field = fieldById[fid]

        local include = true
        if self.showOwnedOnly then
            local fl = field and field.farmland
            include = fl ~= nil and mgr.isFarmlandOwnedByFarm(fl.id, localFarmId)
        end

        if include then
            local ftiIndex   = field and field.fieldState and field.fieldState.fruitTypeIndex or 0
            local cropName   = getCropName(ftiIndex)
            local moisture   = entry.moisture or 0
            local stress     = (stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0
            local systemId   = coveredFields[fid]  -- nil if not irrigated
            local irrigated  = systemId ~= nil or vehicleFields[fid] == true

            table.insert(rows, {
                fieldId   = fid,
                cropName  = cropName,
                moisture  = moisture,
                stress    = stress,
                irrigated = irrigated,
                systemId  = systemId,
            })
        end
    end

    -- BUILD 19:23 (George CLOSED DESIGN 19:12): one row per GPS-outline block. Owned rows group
    -- through the Soil merge bridge (foreign rows come back as singles); a block row keeps the
    -- lead farmland id, min moisture, max stress, irrigated if any member is, the first system,
    -- Mixed when the crops differ. Soil absent = the rows above, untouched. Irrigation tab is
    -- systems, not fields: untouched.
    local merge = getSoilMerge()
    if merge ~= nil and type(merge.buildGroups) == "function" and #rows > 1 then
        local byId, ids = {}, {}
        for _, r in ipairs(rows) do
            byId[r.fieldId] = r
            ids[#ids + 1] = r.fieldId
        end
        local ok, groups = pcall(merge.buildGroups, ids)
        if ok and type(groups) == "table" then
            local grouped = {}
            for _, g in ipairs(groups) do
                local lead = byId[g.fieldId]
                local members = g.memberIds or { g.fieldId }
                if lead ~= nil and #members > 1 then
                    local row = {
                        fieldId = g.fieldId, memberFieldIds = members,
                        cropName = lead.cropName, moisture = lead.moisture, stress = lead.stress,
                        irrigated = lead.irrigated, systemId = lead.systemId,
                    }
                    for _, mid in ipairs(members) do
                        local m = byId[mid]
                        if m ~= nil then
                            if m.moisture < row.moisture then row.moisture = m.moisture end
                            if m.stress > row.stress then row.stress = m.stress end
                            if m.irrigated then row.irrigated = true end
                            if row.systemId == nil then row.systemId = m.systemId end
                            if m.cropName ~= row.cropName then row.cropName = tr("cs_rf_pda_crop_mixed", "Mixed") end
                        end
                    end
                    grouped[#grouped + 1] = row
                elseif lead ~= nil then
                    lead.memberFieldIds = members
                    grouped[#grouped + 1] = lead
                end
            end
            rows = grouped
        end
    end

    -- Sort field list: alphabetical crop, then by moisture asc within crop
    table.sort(rows, function(a, b)
        if a.cropName ~= b.cropName then return a.cropName < b.cropName end
        return a.moisture < b.moisture
    end)
    self.fieldData = rows

    -- Irrigation tab: driest first, all fields
    local irrRows = {}
    for _, r in ipairs(rows) do
        table.insert(irrRows, r)
    end
    table.sort(irrRows, function(a, b)
        return a.moisture < b.moisture
    end)
    self.irrigationData = irrRows
end

function CsPDAScreen:_rebuildStats()
    local mgr = getMgr()
    if mgr == nil then return end

    local soilSystem = mgr.soilSystem
    local stressMod  = mgr.stressModifier
    local irrMgr     = mgr.irrigationManager
    local fieldById  = mgr.fieldById or {}

    if soilSystem == nil then return end

    local localFarmId = mgr.getLocalFarmId()
    local totalTracked = 0
    local totalOwned   = 0
    local sumMoisture  = 0
    local sumStress    = 0
    local healthy = 0
    local warning = 0
    local critical = 0
    local irrigatedCount = 0

    -- Covered fields set
    local coveredFields = {}
    if irrMgr and irrMgr.systems then
        for _, sys in pairs(irrMgr.systems) do
            if sys.coveredFields then
                -- coveredFields is an array of farmland ids — iterate values, not keys.
                for _, fid in ipairs(sys.coveredFields) do
                    coveredFields[fid] = true
                end
            end
        end
    end

    -- Vehicle irrigators count toward the irrigated total too, parked or running.
    local vehIrr = mgr.irrigatorSectorIntegration
    if vehIrr and type(vehIrr.getPresentFields) == "function" then
        for fid in pairs(vehIrr:getPresentFields()) do
            coveredFields[fid] = true
        end
    end

    for fid, entry in pairs(soilSystem.fieldData) do
        totalTracked = totalTracked + 1
        local m = entry.moisture or 0
        sumMoisture = sumMoisture + m
        if m >= 0.40 then healthy = healthy + 1
        elseif m >= 0.25 then warning = warning + 1
        else critical = critical + 1 end

        local s = (stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0
        sumStress = sumStress + s

        if coveredFields[fid] then irrigatedCount = irrigatedCount + 1 end

        local field = fieldById[fid]
        if field and field.farmland and field.farmland.ownerFarmId == localFarmId then
            totalOwned = totalOwned + 1
        end
    end

    local avgMoisture = totalTracked > 0 and (sumMoisture / totalTracked) or 0
    local avgStress   = totalTracked > 0 and (sumStress   / totalTracked) or 0
    local yieldLoss   = avgStress * 0.60  -- matches CropStressModifier.MAX_YIELD_LOSS

    local irrSystems = 0
    if irrMgr and irrMgr.systems then
        for _ in pairs(irrMgr.systems) do irrSystems = irrSystems + 1 end
    end

    local function setText(el, val)
        if el then el:setText(tostring(val)) end
    end
    local function setTextFmt(el, val, fmt)
        if el then el:setText(string.format(fmt, val)) end
    end
    local function setColor(el, color)
        if el then el:setTextColor(unpack(color)) end
    end

    setText(self.statsFieldsTracked, totalTracked)
    setText(self.statsFieldsOwned,   totalOwned)

    if self.statsAvgMoisture then
        self.statsAvgMoisture:setText(string.format("%.0f%%", avgMoisture * 100))
        setColor(self.statsAvgMoisture, getMoistureColor(avgMoisture))
    end

    if self.statsHealthy  then
        self.statsHealthy:setText(tostring(healthy))
        setColor(self.statsHealthy, COLOR_HEALTHY)
    end
    if self.statsWarning  then
        self.statsWarning:setText(tostring(warning))
        setColor(self.statsWarning, COLOR_WARNING)
    end
    if self.statsCritical then
        self.statsCritical:setText(tostring(critical))
        setColor(self.statsCritical, critical > 0 and COLOR_CRITICAL or COLOR_DIM)
    end

    if self.statsAvgStress then
        self.statsAvgStress:setText(string.format("%.0f%%", avgStress * 100))
        setColor(self.statsAvgStress, avgStress > 0.5 and COLOR_CRITICAL or avgStress > 0.2 and COLOR_WARNING or COLOR_HEALTHY)
    end
    if self.statsYieldLoss then
        self.statsYieldLoss:setText(string.format("-%.0f%%", yieldLoss * 100))
        setColor(self.statsYieldLoss, yieldLoss > 0.20 and COLOR_CRITICAL or yieldLoss > 0.05 and COLOR_WARNING or COLOR_DIM)
    end

    setText(self.statsIrrigated,   irrigatedCount)
    setText(self.statsIrrSystems,  irrSystems)

    if self.overviewEmptyHint then
        self.overviewEmptyHint:setVisible(totalTracked == 0)
    end
end

-- ── SmoothList datasource ─────────────────────────────────

function CsPDAScreen:getNumberOfItemsInSection(list, section)
    if list == self.fieldList then
        return #self.fieldData
    elseif list == self.irrigationList then
        return #self.irrigationData
    end
    return 0
end

function CsPDAScreen:populateCellForItemInSection(list, section, index, cell)
    if list == self.fieldList then
        self:_populateFieldCell(index, cell)
    elseif list == self.irrigationList then
        self:_populateIrrigationCell(index, cell)
    end
end

function CsPDAScreen:_populateFieldCell(index, cell)
    local row = self.fieldData[index]
    if not row then return end

    local idEl     = cell:getDescendantByName("fieldRowId")
    local cropEl   = cell:getDescendantByName("fieldRowCrop")
    local moistEl  = cell:getDescendantByName("fieldRowMoisture")
    local statusEl = cell:getDescendantByName("fieldRowStatus")

    if idEl     then idEl:setText("F" .. tostring(row.fieldId)) end
    if cropEl   then cropEl:setText(row.cropName) end

    if moistEl  then
        moistEl:setText(string.format("%.0f%%", row.moisture * 100))
        moistEl:setTextColor(unpack(getMoistureColor(row.moisture)))
    end
    if statusEl then
        statusEl:setText(getMoistureStatus(row.moisture))
        statusEl:setTextColor(unpack(getMoistureColor(row.moisture)))
    end
end

function CsPDAScreen:_populateIrrigationCell(index, cell)
    local row = self.irrigationData[index]
    if not row then return end

    local idEl    = cell:getDescendantByName("irrRowId")
    local cropEl  = cell:getDescendantByName("irrRowCrop")
    local moistEl = cell:getDescendantByName("irrRowMoisture")
    local strEl   = cell:getDescendantByName("irrRowStress")
    local irrEl   = cell:getDescendantByName("irrRowIrrigated")

    if idEl   then idEl:setText("F" .. tostring(row.fieldId)) end
    if cropEl then cropEl:setText(row.cropName) end

    if moistEl then
        moistEl:setText(string.format("%.0f%%", row.moisture * 100))
        moistEl:setTextColor(unpack(getMoistureColor(row.moisture)))
    end
    if strEl then
        local stressPct = math.floor(row.stress * 100)
        strEl:setText(stressPct .. "%")
        strEl:setTextColor(unpack(stressPct > 50 and COLOR_CRITICAL or stressPct > 20 and COLOR_WARNING or COLOR_DIM))
    end
    if irrEl then
        if row.irrigated then
            irrEl:setText(tr("cs_pda_irrigated_yes", "Active"))
            irrEl:setTextColor(unpack(COLOR_HEALTHY))
        else
            irrEl:setText("--")
            irrEl:setTextColor(unpack(COLOR_DIM))
        end
    end

    -- stamp systemId so onClickIrrigationRow can open the right schedule dialog
    cell.csSystemId = row.systemId
end

-- ── Row click handlers ────────────────────────────────────

function CsPDAScreen:onClickFieldRow(item)
    -- Reserved for future field detail dialog
end

function CsPDAScreen:onClickIrrigationRow(item)
    local sysId = item and item.csSystemId
    if sysId then
        CsDialogLoader.show("IrrigationScheduleDialog", "setSystemId", sysId)
    else
        InfoDialog.show(tr("cs_pda_no_system_msg", "No irrigation system is connected to this field. Place a center pivot or drip line to manage irrigation."))
    end
end

-- ── Mouse event — tab hit testing (MDM pattern) ──────────

function CsPDAScreen:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        local tabs = {
            { el = self.tabLabelOverview,   cb = CsPDAScreen.onClickTabOverview   },
            { el = self.tabLabelIrrigation, cb = CsPDAScreen.onClickTabIrrigation },
        }
        for _, t in ipairs(tabs) do
            if t.el then
                local ap = t.el.absPosition
                local as = t.el.absSize
                if ap and as and
                   posX >= ap[1] and posX <= ap[1] + as[1] and
                   posY >= ap[2] and posY <= ap[2] + as[2] then
                    t.cb(self)
                    return true
                end
            end
        end
    end
    return CsPDAScreen:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
end

-- ── Tab switching ─────────────────────────────────────────

function CsPDAScreen:onClickTabOverview()
    self:_setTab(TAB_OVERVIEW)
end

function CsPDAScreen:onClickTabIrrigation()
    self:_setTab(TAB_IRRIGATION)
end

function CsPDAScreen:_setTab(tabIndex)
    self.activeTab = tabIndex
    local isOverview   = (tabIndex == TAB_OVERVIEW)
    local isIrrigation = (tabIndex == TAB_IRRIGATION)

    -- MDM pattern: updateAbsolutePosition() on the newly-visible container
    -- before reloadData() so the SmoothList knows its bounds.
    if self.overviewContent then
        self.overviewContent:setVisible(isOverview)
        if isOverview and type(self.overviewContent.updateAbsolutePosition) == "function" then
            self.overviewContent:updateAbsolutePosition()
        end
    end
    if self.irrigationContent then
        self.irrigationContent:setVisible(isIrrigation)
        if isIrrigation and type(self.irrigationContent.updateAbsolutePosition) == "function" then
            self.irrigationContent:updateAbsolutePosition()
        end
    end

    if self.tabUnderlineOverview   then self.tabUnderlineOverview:setVisible(isOverview)   end
    if self.tabUnderlineIrrigation then self.tabUnderlineIrrigation:setVisible(isIrrigation) end

    -- Active tab: full white. Inactive tab: clearly dim (0.38) so both states are obvious.
    if self.tabLabelOverview then
        local v = isOverview and 1.0 or 0.38
        self.tabLabelOverview:setTextColor(v, v, v, 1)
    end
    if self.tabLabelIrrigation then
        local v = isIrrigation and 1.0 or 0.38
        self.tabLabelIrrigation:setTextColor(v, v, v, 1)
    end

    self:_reloadLists()
    if isOverview then self:_rebuildStats() end
end

function CsPDAScreen:_reloadLists()
    if self.fieldList      then self.fieldList:reloadData()      end
    if self.irrigationList then self.irrigationList:reloadData() end

    if self.irrigationEmptyHint then
        self.irrigationEmptyHint:setVisible(#self.irrigationData == 0)
    end
end

-- ── FS25 TabbedMenuFrameElement lifecycle ─────────────────

function CsPDAScreen:onOpen()
    CsPDAScreen:superClass().onOpen(self)
    -- Re-register footer buttons each open — FS25 clears them on page switch.
    self:setMenuButtonInfo(self.menuButtonInfo)
    self.refreshTimer = 0
    self._deferredReload        = true  -- retry until field data arrives (issue #83)
    self._deferredLoadTimer     = 0
    self._deferredReloadAttempts = 0
    self:_updateFilterButton()
    self:_rebuildData()
    -- Force layout finalization before first list populate (MDM pattern).
    -- Without this the SmoothList doesn't know its bounds on cold open.
    if self.fieldList and type(self.fieldList.updateAbsolutePosition) == "function" then
        self.fieldList:updateAbsolutePosition()
    end
    if self.irrigationList and type(self.irrigationList.updateAbsolutePosition) == "function" then
        self.irrigationList:updateAbsolutePosition()
    end
    self:_reloadLists()
    self:_rebuildStats()
    self:_setTab(TAB_OVERVIEW)
end

function CsPDAScreen:onClose()
    CsPDAScreen:superClass().onClose(self)
end

function CsPDAScreen:onFrameUpdate(dt)
    CsPDAScreen:superClass().onFrameUpdate(self, dt)

    if _pendingRegistration then
        CsPDAScreen._attemptDeferredRegister(dt)
    end

    -- Retry loop for dedi clients: keep rebuilding every 500 ms until field data
    -- appears (enumerateFields fires in installFieldReadyUpdater, which waits for
    -- isMissionStarted — on dedi this can take several seconds after onOpen).
    -- Also re-pushes menu buttons so our labels win over any other mod that injects on open.
    -- Stops after 30 attempts (~15 s) to avoid spinning forever if something is broken.
    if self._deferredReload then
        self._deferredLoadTimer = (self._deferredLoadTimer or 0) + dt
        if self._deferredLoadTimer >= 500 then
            self._deferredLoadTimer = 0
            self._deferredReloadAttempts = (self._deferredReloadAttempts or 0) + 1
            self:setMenuButtonInfo(self.menuButtonInfo)
            self:_rebuildData()
            self:_reloadLists()
            if self.activeTab == TAB_OVERVIEW then
                self:_rebuildStats()
            end
            local mgr = getMgr()
            local hasData = mgr and mgr.soilSystem and next(mgr.soilSystem.fieldData) ~= nil
            if hasData or self._deferredReloadAttempts >= 30 then
                self._deferredReload = false
            end
        end
        return
    end

    self.refreshTimer = (self.refreshTimer or 0) + dt
    if self.refreshTimer >= REFRESH_INTERVAL then
        self.refreshTimer = 0
        self:_rebuildData()
        self:_reloadLists()
        if self.activeTab == TAB_OVERVIEW then
            self:_rebuildStats()
        end
    end
end

-- Registration is triggered by main.lua's Mission00.loadMission00Finished hook.
-- Deferred retries run from onFrameUpdate (while the PDA is open) and from
-- main.lua's FSBaseMission.update hook (which calls _attemptDeferredRegister).

