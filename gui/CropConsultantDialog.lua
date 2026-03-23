-- ============================================================
-- CropConsultantDialog.lua
-- Agronomist consultation panel.
--
-- Pattern: CsDialogLoader / NPCFavor 3-layer button pattern (FS25 v1.16)
--   • CsDialogLoader creates instance + calls g_gui:loadGui()
--   • onCreate() ONLY calls superClass().onCreate(self) in pcall
--     → FS25 auto-wires all id= elements into self.*
--   • onOpen() calls super then calls refreshContent() (reads live data)
--   • onClose() calls super for cleanup
--
-- Button pattern (3-layer, NPCFavor):
--   Bitmap bg + invisible Button hit (onFocus/onLeave) + Text label
--   applyHover() drives color changes on focus/leave events.
--
-- Auto-wired element names (must match id= in CropConsultantDialog.xml):
--   titleText, subtitleText, npcSection, npcRelLabel, npcRelValue,
--   fieldListContainer, recommendText,
--   btnOpenIrrBg, btnOpenIrr, btnOpenIrrText
--
-- Opened via CS_OPEN_CONSULTANT (Shift+C) or from Crop Consultant NPC
-- (FS25_NPCFavor integration). Reads live field/stress/moisture data on open.
-- ============================================================

CropConsultantDialog = {}
local CropConsultantDialog_mt = Class(CropConsultantDialog, MessageDialog)

-- Button color constants (NPCFavor pattern)
CropConsultantDialog.COLORS = {
    BTN_NORMAL = {0.15, 0.15, 0.18, 1},
    BTN_HOVER  = {0.22, 0.28, 0.38, 1},
    TXT_NORMAL = {1,    1,    1,    1},
    TXT_HOVER  = {0.7,  0.9,  1,    1},
}

-- ============================================================
-- CONSTRUCTOR
-- ============================================================

function CropConsultantDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or CropConsultantDialog_mt)
    return self
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

-- Called by FS25 GUI system after XML is parsed (via g_gui:loadGui).
-- ONLY calls superClass().onCreate(self) — triggers FS25 auto-wiring.
function CropConsultantDialog:onCreate()
    local ok, err = pcall(function()
        CropConsultantDialog:superClass().onCreate(self)
    end)
    if not ok then
        print("[CropStress] CropConsultantDialog:onCreate() superClass FAILED: " .. tostring(err))
    end
end

-- Called by FS25 GUI system each time the dialog becomes visible.
function CropConsultantDialog:onOpen()
    local ok, err = pcall(function()
        CropConsultantDialog:superClass().onOpen(self)
    end)
    if not ok then
        print("[CropStress] CropConsultantDialog:onOpen() superClass FAILED: " .. tostring(err))
        return
    end
    self:refreshContent()
end

-- Called by FS25 GUI system after the dialog has fully closed (cleanup only).
function CropConsultantDialog:onClose()
    CropConsultantDialog:superClass().onClose(self)
end

-- Initiated by close button.
function CropConsultantDialog:onCloseClicked()
    self:close()
end

-- ============================================================
-- HOVER EFFECTS (NPCFavor 3-layer pattern)
-- ============================================================

-- Apply hover highlight to an action button (suffix = "OpenIrr").
function CropConsultantDialog:applyHover(suffix, isHovered)
    local bgElem  = self["btn" .. suffix .. "Bg"]
    local txtElem = self["btn" .. suffix .. "Text"]
    if bgElem then
        local c = isHovered and self.COLORS.BTN_HOVER or self.COLORS.BTN_NORMAL
        bgElem:setImageColor(c[1], c[2], c[3], c[4])
    end
    if txtElem then
        local c = isHovered and self.COLORS.TXT_HOVER or self.COLORS.TXT_NORMAL
        txtElem:setTextColor(c[1], c[2], c[3], c[4])
    end
end

function CropConsultantDialog:onBtnOpenIrrFocus() self:applyHover("OpenIrr", true)  end
function CropConsultantDialog:onBtnOpenIrrLeave() self:applyHover("OpenIrr", false) end

-- ============================================================
-- REFRESH CONTENT
-- Rebuilds the field risk list, recommendations, and optional NPC panel.
-- ============================================================

function CropConsultantDialog:refreshContent()
    if g_cropStressManager == nil then return end

    if self.titleText ~= nil then
        local name = (g_i18n ~= nil and g_i18n:getText("cs_consultant_name")) or "Crop Consultant"
        self.titleText:setText(name)
    end

    -- NPC section (only when FS25_NPCFavor active and NPC registered)
    if self.npcSection ~= nil then
        local npcActive = g_cropStressManager.npcIntegration ~= nil
            and g_cropStressManager.npcIntegration.isRegistered
        self.npcSection:setVisible(npcActive)

        if npcActive and self.npcRelValue ~= nil then
            local rel = g_cropStressManager.npcIntegration:getRelationshipLevel()
            self.npcRelValue:setText(string.format("%d / 100", rel))
        end
    end

    self:buildFieldList()
    self:buildRecommendation()
end

-- ============================================================
-- BUILD FIELD LIST
-- Populates fieldListContainer with up to 5 fields sorted by risk.
-- ============================================================

function CropConsultantDialog:buildFieldList()
    if self.fieldListContainer == nil then return end

    local children = self.fieldListContainer.elements
    if children ~= nil then
        for i = #children, 1, -1 do
            self.fieldListContainer:removeElement(children[i])
        end
    end

    local soilSystem     = g_cropStressManager.soilSystem
    local stressModifier = g_cropStressManager.stressModifier
    if soilSystem == nil or soilSystem.fieldData == nil then return end

    local getLocalFarmId = g_cropStressManager.getLocalFarmId
    local isFarmlandOwnedByFarm = g_cropStressManager.isFarmlandOwnedByFarm
    if getLocalFarmId == nil or isFarmlandOwnedByFarm == nil then
        print("[CropStress] CropConsultantDialog: ERROR - ownership helpers not found on manager!")
        return
    end
    local localFarmId = getLocalFarmId()

    local riskList = {}
    for fieldId, data in pairs(soilSystem.fieldData) do
        if isFarmlandOwnedByFarm(fieldId, localFarmId) then
            local stress   = stressModifier ~= nil and stressModifier:getStress(fieldId) or 0
            local moisture = data.moisture or 0.5
            local risk     = stress * 0.6 + (1 - moisture) * 0.4
            table.insert(riskList, { fieldId = fieldId, moisture = moisture, stress = stress, risk = risk })
        end
    end
    table.sort(riskList, function(a, b) return a.risk > b.risk end)

    -- If no owned fields, show all as a fallback so the dialog is never blank
    if #riskList == 0 and next(soilSystem.fieldData) ~= nil then
        print("[CropStress] CropConsultantDialog: No owned fields found, showing all tracked fields as a fallback.")
        for fieldId, data in pairs(soilSystem.fieldData) do
            local stress   = stressModifier ~= nil and stressModifier:getStress(fieldId) or 0
            local moisture = data.moisture or 0.5
            local risk     = stress * 0.6 + (1 - moisture) * 0.4
            table.insert(riskList, { fieldId = fieldId, moisture = moisture, stress = stress, risk = risk })
        end
        table.sort(riskList, function(a, b) return a.risk > b.risk end)
    end

    local function addRow(text, yPos)
        local label = TextElement.new()
        if g_gui ~= nil then
            local prof = g_gui:getProfile("fs25_dialogText")
            if prof ~= nil then label:loadProfile(prof, true) end
        end
        label:setPosition(5, yPos)
        label:setText(text)
        self.fieldListContainer:addElement(label)
        label:onGuiSetupFinished()
    end

    if #riskList == 0 then
        addRow((g_i18n ~= nil and g_i18n:getText("cs_consultant_no_data")) or "No field data available.", 0)
        return
    end

    local y = 0
    for i = 1, math.min(5, #riskList) do
        local entry = riskList[i]
        local cropName    = self:getCropName(entry.fieldId)
        local yieldImpact = stressModifier ~= nil and stressModifier:getYieldImpactString(entry.fieldId) or "0%"
        local severityStr
        if entry.moisture < 0.25 then
            severityStr = "[CRITICAL]"
        elseif entry.moisture < 0.40 then
            severityStr = "[WARNING]"
        else
            severityStr = "[OK]"
        end
        local labelStr = string.format(
            "Field %d · %s  %d%% moisture  Yield %s  %s",
            entry.fieldId, cropName, math.floor(entry.moisture * 100), yieldImpact, severityStr
        )
        addRow(labelStr, y)
        y = y - 22
    end
end

-- ============================================================
-- BUILD RECOMMENDATION
-- ============================================================

function CropConsultantDialog:buildRecommendation()
    if self.recommendText == nil then return end

    local soilSystem   = g_cropStressManager and g_cropStressManager.soilSystem
    local weatherInteg = g_cropStressManager and g_cropStressManager.weatherIntegration

    local function t(key, ...) return (g_i18n ~= nil and string.format(g_i18n:getText(key), ...)) or key end

    if soilSystem == nil or soilSystem.fieldData == nil then
        self.recommendText:setText("—")
        return
    end

    local worst = nil
    for fieldId, data in pairs(soilSystem.fieldData) do
        if worst == nil or data.moisture < worst.moisture then
            worst = { fieldId = fieldId, moisture = data.moisture }
        end
    end

    if worst == nil then
        self.recommendText:setText(t("cs_rec_all_healthy"))
        return
    end

    local lines = {}
    if worst.moisture < 0.25 then
        table.insert(lines, t("cs_rec_urgent",  worst.fieldId, worst.moisture * 100))
    elseif worst.moisture < 0.40 then
        table.insert(lines, t("cs_rec_warning", worst.fieldId, worst.moisture * 100))
    else
        table.insert(lines, t("cs_rec_ok"))
    end

    if weatherInteg ~= nil then
        local proj = weatherInteg:getMoistureForecast(worst.fieldId, 3)
        if proj ~= nil and #proj >= 3 then
            table.insert(lines, t("cs_rec_forecast",
                (proj[1] or 0) * 100, (proj[2] or 0) * 100, (proj[3] or 0) * 100))
        end
    end

    local irrMgr = g_cropStressManager.irrigationManager
    if irrMgr ~= nil then
        local active = 0
        for _, sys in pairs(irrMgr.systems) do
            if sys.isActive then active = active + 1 end
        end
        if active > 0 then
            table.insert(lines, t("cs_rec_systems_running", active))
        else
            table.insert(lines, t("cs_rec_no_systems"))
        end
    end

    self.recommendText:setText(table.concat(lines, "\n"))
end

-- ============================================================
-- BUTTON HANDLERS
-- ============================================================

function CropConsultantDialog:onOpenIrrigationDialog()
    self:close()
    if g_cropStressManager ~= nil then
        g_cropStressManager:onOpenIrrigationDialog()
    end
end

-- ============================================================
-- HELPERS
-- ============================================================

-- Returns the field object for a fieldId using the manager's map (fast path)
-- or a linear scan of getFields() as fallback.
function CropConsultantDialog:getFieldObject(fieldId)
    local mgr = g_cropStressManager
    if mgr ~= nil and mgr.fieldById ~= nil then
        local f = mgr.fieldById[fieldId]
        if f ~= nil then return f end
    end
    if g_currentMission == nil or g_currentMission.fieldManager == nil then return nil end
    local ok, fields = pcall(function()
        return g_currentMission.fieldManager:getFields()
    end)
    if ok and fields ~= nil then
        for _, f in pairs(fields) do
            if f ~= nil and f.farmland ~= nil and f.farmland.id == fieldId then return f end
        end
    end
    return nil
end

function CropConsultantDialog:getCropName(fieldId)
    local field = self:getFieldObject(fieldId)
    if field == nil then return "?" end

    -- FS25 confirmed API: field.fieldState.fruitTypeIndex (no getter method exists)
    local fti = field.fieldState and field.fieldState.fruitTypeIndex
    if fti ~= nil and fti > 0 and g_fruitTypeManager ~= nil then
        local ft = g_fruitTypeManager:getFruitTypeByIndex(fti)
        if ft ~= nil and ft.name ~= nil then
            return self:formatCropName(ft.name)
        end
    end
    return "Fallow"
end

function CropConsultantDialog:formatCropName(rawName)
    if rawName == nil then return "Fallow" end
    local name = rawName:lower()
    if name == "grass" or name == "drygrass" or name == "weed"
    or name == "stone" or name == "meadow" then
        return "Fallow"
    end
    return rawName:sub(1,1):upper() .. rawName:sub(2):lower()
end