-- ============================================================
-- IrrigationScheduleDialog.lua
-- Dialog for editing irrigation system schedule and manual control.
--
-- Pattern: CsDialogLoader / NPCFavor 3-layer button pattern (FS25 v1.16)
--   • CsDialogLoader creates instance + calls g_gui:loadGui()
--   • onCreate() ONLY calls superClass().onCreate(self) in pcall
--     → FS25 auto-wires all id= elements into self.*
--   • setSystemId(id) called BEFORE g_gui:showDialog() via CsDialogLoader
--   • onOpen() calls super then populates from pre-set self.systemId
--   • onClose() calls super for cleanup
--
-- Button pattern (3-layer, NPCFavor):
--   Bitmap bg + invisible Button hit (onFocus/onLeave) + Text label
--   applyHover() / applyDayHover() / applyTimeHover() / applyCloseHover()
--   drive color changes on focus/leave.
--   Day buttons use color-based selected state (green=active) — no setSelected().
--
-- Auto-wired element names (must match id= in IrrigationScheduleDialog.xml):
--   irrTitle, waterSourceValue, startHourText, endHourText
--   flowRate, efficiency, cost, wear, coveredFieldsContainer
--   btnDay1Bg/Hit/Text .. btnDay7Bg/Hit/Text
--   startHourMinusBg/Hit/Text, startHourPlusBg/Hit/Text
--   endHourMinusBg/Hit/Text, endHourPlusBg/Hit/Text
--   btnCloseBg/Hit/Text
--   btnIrrigateNowBg/Hit/Text, btnSaveBg/Hit/Text
-- ============================================================

IrrigationScheduleDialog = IrrigationScheduleDialog or {}
local IrrigationScheduleDialog_mt = Class(IrrigationScheduleDialog, MessageDialog)

-- Button color constants (NPCFavor pattern)
IrrigationScheduleDialog.COLORS = {
    BTN_NORMAL    = {0.15, 0.15, 0.18, 1},   -- default dark
    BTN_HOVER     = {0.22, 0.28, 0.38, 1},   -- blue-ish on hover
    BTN_SELECTED  = {0.18, 0.45, 0.22, 1},   -- green = active day
    BTN_SEL_HOVER = {0.22, 0.55, 0.27, 1},   -- brighter green on hover when selected
    TXT_NORMAL    = {1,    1,    1,    1},
    TXT_HOVER     = {0.7,  0.9,  1,    1},
    TXT_SELECTED  = {0.6,  1,    0.65, 1},   -- light green text for active day
}

function IrrigationScheduleDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or IrrigationScheduleDialog_mt)
    self.systemId    = nil
    self.daySelected = {false, false, false, false, false, false, false}
    return self
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

-- Called by FS25 GUI system after XML is parsed (via g_gui:loadGui).
-- ONLY calls superClass().onCreate(self) — triggers FS25 auto-wiring:
-- every XML element with an id= is set as self[id] on this instance.
function IrrigationScheduleDialog:onCreate()
    local ok, err = pcall(function()
        IrrigationScheduleDialog:superClass().onCreate(self)
    end)
    if not ok then
        print("[CropStress] IrrigationScheduleDialog:onCreate() superClass FAILED: " .. tostring(err))
    end
end

-- Data setter: called by CsDialogLoader BEFORE g_gui:showDialog() fires onOpen().
function IrrigationScheduleDialog:setSystemId(systemId)
    self.systemId = systemId
end

-- Called by FS25 GUI system each time the dialog becomes visible.
function IrrigationScheduleDialog:onOpen()
    local ok, err = pcall(function()
        IrrigationScheduleDialog:superClass().onOpen(self)
    end)
    if not ok then
        print("[CropStress] IrrigationScheduleDialog:onOpen() superClass FAILED: " .. tostring(err))
        return
    end
    -- BUILD 18:15: populateDisplay was called unguarded. Anything it threw escaped
    -- onOpen after the dialog was already on the stack, leaving a shell that drew
    -- but was never wired. Guarded, a future nil degrades to a half-filled but
    -- fully operable dialog instead of a dead one.
    local okFill, errFill = pcall(function() self:populateDisplay() end)
    if not okFill then
        print("[CropStress] IrrigationScheduleDialog:populateDisplay() FAILED: " .. tostring(errFill))
    end
    self:focusFirstDay()
end

--- Put keyboard/controller focus on the first day toggle so the dialog is
--  operable without a mouse. Close stays reachable by tab from there.
function IrrigationScheduleDialog:focusFirstDay()
    if FocusManager == nil or type(FocusManager.setFocus) ~= "function" then return end
    local target = self.btnDay1 or self.btnClose
    if target == nil then return end
    pcall(function() FocusManager:setFocus(target) end)
end

-- Called by FS25 GUI system after the dialog has fully closed (cleanup only).
function IrrigationScheduleDialog:onClose()
    IrrigationScheduleDialog:superClass().onClose(self)
end

-- Initiated by the close button.
function IrrigationScheduleDialog:onCloseClicked()
    self:close()
end

-- ============================================================
-- HOVER EFFECTS (NPCFavor 3-layer pattern)
-- ============================================================

-- Apply hover highlight to a wide action button (suffix = "IrrigateNow", "Save").
function IrrigationScheduleDialog:applyHover(suffix, isHovered)
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

-- Apply hover highlight to a time adjustment button (prefix = "startHourMinus", "startHourPlus", etc.)
function IrrigationScheduleDialog:applyTimeHover(prefix, isHovered)
    local bgElem  = self[prefix .. "Bg"]
    local txtElem = self[prefix .. "Text"]
    if bgElem then
        local c = isHovered and self.COLORS.BTN_HOVER or self.COLORS.BTN_NORMAL
        bgElem:setImageColor(c[1], c[2], c[3], c[4])
    end
    if txtElem then
        local c = isHovered and self.COLORS.TXT_HOVER or self.COLORS.TXT_NORMAL
        txtElem:setTextColor(c[1], c[2], c[3], c[4])
    end
end

-- Apply hover highlight to the close button
function IrrigationScheduleDialog:applyCloseHover(isHovered)
    local bgElem  = self["btnCloseBg"]
    local txtElem = self["btnCloseText"]
    if bgElem then
        local c = isHovered and self.COLORS.BTN_HOVER or self.COLORS.BTN_NORMAL
        bgElem:setImageColor(c[1], c[2], c[3], c[4])
    end
    if txtElem then
        local c = isHovered and self.COLORS.TXT_HOVER or self.COLORS.TXT_NORMAL
        txtElem:setTextColor(c[1], c[2], c[3], c[4])
    end
end

-- Apply hover highlight to a day toggle button (dayIdx 1–7).
-- Selected days use a distinct green color scheme.
function IrrigationScheduleDialog:applyDayHover(dayIdx, isHovered)
    local bgElem  = self["btnDay" .. dayIdx .. "Bg"]
    local txtElem = self["btnDay" .. dayIdx .. "Text"]
    local sel     = self.daySelected[dayIdx]
    if bgElem then
        local c
        if sel then
            c = isHovered and self.COLORS.BTN_SEL_HOVER or self.COLORS.BTN_SELECTED
        else
            c = isHovered and self.COLORS.BTN_HOVER or self.COLORS.BTN_NORMAL
        end
        bgElem:setImageColor(c[1], c[2], c[3], c[4])
    end
    if txtElem then
        local c = sel and self.COLORS.TXT_SELECTED or self.COLORS.TXT_NORMAL
        txtElem:setTextColor(c[1], c[2], c[3], c[4])
    end
end

-- Per-button focus/leave handlers (called from XML onFocus/onLeave)
function IrrigationScheduleDialog:onBtnDay1Focus()        self:applyDayHover(1, true)  end
function IrrigationScheduleDialog:onBtnDay1Leave()        self:applyDayHover(1, false) end
function IrrigationScheduleDialog:onBtnDay2Focus()        self:applyDayHover(2, true)  end
function IrrigationScheduleDialog:onBtnDay2Leave()        self:applyDayHover(2, false) end
function IrrigationScheduleDialog:onBtnDay3Focus()        self:applyDayHover(3, true)  end
function IrrigationScheduleDialog:onBtnDay3Leave()        self:applyDayHover(3, false) end
function IrrigationScheduleDialog:onBtnDay4Focus()        self:applyDayHover(4, true)  end
function IrrigationScheduleDialog:onBtnDay4Leave()        self:applyDayHover(4, false) end
function IrrigationScheduleDialog:onBtnDay5Focus()        self:applyDayHover(5, true)  end
function IrrigationScheduleDialog:onBtnDay5Leave()        self:applyDayHover(5, false) end
function IrrigationScheduleDialog:onBtnDay6Focus()        self:applyDayHover(6, true)  end
function IrrigationScheduleDialog:onBtnDay6Leave()        self:applyDayHover(6, false) end
function IrrigationScheduleDialog:onBtnDay7Focus()        self:applyDayHover(7, true)  end
function IrrigationScheduleDialog:onBtnDay7Leave()        self:applyDayHover(7, false) end

-- Time button hover handlers
function IrrigationScheduleDialog:onBtnStartHourMinusFocus() self:applyTimeHover("startHourMinus", true) end
function IrrigationScheduleDialog:onBtnStartHourMinusLeave() self:applyTimeHover("startHourMinus", false) end
function IrrigationScheduleDialog:onBtnStartHourPlusFocus()  self:applyTimeHover("startHourPlus", true) end
function IrrigationScheduleDialog:onBtnStartHourPlusLeave()  self:applyTimeHover("startHourPlus", false) end
function IrrigationScheduleDialog:onBtnEndHourMinusFocus()   self:applyTimeHover("endHourMinus", true) end
function IrrigationScheduleDialog:onBtnEndHourMinusLeave()   self:applyTimeHover("endHourMinus", false) end
function IrrigationScheduleDialog:onBtnEndHourPlusFocus()    self:applyTimeHover("endHourPlus", true) end
function IrrigationScheduleDialog:onBtnEndHourPlusLeave()    self:applyTimeHover("endHourPlus", false) end

-- Close button hover handlers
function IrrigationScheduleDialog:onBtnCloseFocus() self:applyCloseHover(true) end
function IrrigationScheduleDialog:onBtnCloseLeave() self:applyCloseHover(false) end

function IrrigationScheduleDialog:onBtnIrrigateNowFocus() self:applyHover("IrrigateNow", true)  end
function IrrigationScheduleDialog:onBtnIrrigateNowLeave() self:applyHover("IrrigateNow", false) end
function IrrigationScheduleDialog:onBtnSaveFocus()        self:applyHover("Save", true)  end
function IrrigationScheduleDialog:onBtnSaveLeave()        self:applyHover("Save", false) end

-- ============================================================
-- DISPLAY POPULATION
-- ============================================================

function IrrigationScheduleDialog:populateDisplay()
    local system = self:getCurrentSystem()
    if system == nil then
        self:close()
        return
    end

    local function t(key) return (g_i18n ~= nil and g_i18n:getText(key)) or key end

    -- Title
    local typeName = system.type == "pivot" and t("cs_irr_pivot") or t("cs_irr_drip")
    if self.irrTitle ~= nil then
        self.irrTitle:setText(string.format(t("cs_irr_title"), typeName))
    end

    -- Water source
    if self.waterSourceValue ~= nil then
        if system.waterSourceId ~= nil then
            self.waterSourceValue:setText(t("cs_irr_connected"))
        else
            self.waterSourceValue:setText(t("cs_irr_disconnected"))
        end
    end

    self:syncDayButtons(system)
    self:updateTimeDisplays(system)
    self:updatePerformance(system)
    self:updateCoveredFields(system)
end

-- ============================================================
-- DAY TOGGLE
-- ============================================================

-- Sync all day button colors from system schedule (called on dialog open).
function IrrigationScheduleDialog:syncDayButtons(system)
    for i = 1, 7 do
        self.daySelected[i] = system.schedule.activeDays[i] == true
        -- Color-based selected state (no setSelected — 3-layer emptyPanel hit target)
        local bgElem  = self["btnDay" .. i .. "Bg"]
        local txtElem = self["btnDay" .. i .. "Text"]
        if bgElem then
            local c = self.daySelected[i] and self.COLORS.BTN_SELECTED or self.COLORS.BTN_NORMAL
            bgElem:setImageColor(c[1], c[2], c[3], c[4])
        end
        if txtElem then
            local c = self.daySelected[i] and self.COLORS.TXT_SELECTED or self.COLORS.TXT_NORMAL
            txtElem:setTextColor(c[1], c[2], c[3], c[4])
        end
    end
end

-- FS25 XML onClick cannot pass arguments inline; each day button has its own handler.
function IrrigationScheduleDialog:onDayToggle1() self:_toggleDay(1) end
function IrrigationScheduleDialog:onDayToggle2() self:_toggleDay(2) end
function IrrigationScheduleDialog:onDayToggle3() self:_toggleDay(3) end
function IrrigationScheduleDialog:onDayToggle4() self:_toggleDay(4) end
function IrrigationScheduleDialog:onDayToggle5() self:_toggleDay(5) end
function IrrigationScheduleDialog:onDayToggle6() self:_toggleDay(6) end
function IrrigationScheduleDialog:onDayToggle7() self:_toggleDay(7) end

function IrrigationScheduleDialog:_toggleDay(idx)
    if idx == nil or idx < 1 or idx > 7 then return end
    local system = self:getCurrentSystem()
    if system == nil then return end

    self.daySelected[idx] = not self.daySelected[idx]
    system.schedule.activeDays[idx] = self.daySelected[idx]

    -- Update colors immediately (hover state resets to non-hovered after click)
    local bgElem  = self["btnDay" .. idx .. "Bg"]
    local txtElem = self["btnDay" .. idx .. "Text"]
    if bgElem then
        local c = self.daySelected[idx] and self.COLORS.BTN_SELECTED or self.COLORS.BTN_NORMAL
        bgElem:setImageColor(c[1], c[2], c[3], c[4])
    end
    if txtElem then
        local c = self.daySelected[idx] and self.COLORS.TXT_SELECTED or self.COLORS.TXT_NORMAL
        txtElem:setTextColor(c[1], c[2], c[3], c[4])
    end
end

-- ============================================================
-- TIME CONTROLS
-- ============================================================

function IrrigationScheduleDialog:updateTimeDisplays(system)
    if system == nil then return end
    if self.startHourText ~= nil then
        self.startHourText:setText(string.format("%02d:00", system.schedule.startHour))
    end
    if self.endHourText ~= nil then
        self.endHourText:setText(string.format("%02d:00", system.schedule.endHour))
    end
end

function IrrigationScheduleDialog:onStartHourMinus()
    local system = self:getCurrentSystem()
    if system == nil then return end
    local prev = (system.schedule.startHour - 1 + 24) % 24
    -- Guard: startHour must not equal endHour (zero-duration schedule)
    if prev ~= system.schedule.endHour then
        system.schedule.startHour = prev
    end
    self:updateTimeDisplays(system)
end

function IrrigationScheduleDialog:onStartHourPlus()
    local system = self:getCurrentSystem()
    if system == nil then return end
    local next = (system.schedule.startHour + 1) % 24
    if next ~= system.schedule.endHour then
        system.schedule.startHour = next
    end
    self:updateTimeDisplays(system)
end

function IrrigationScheduleDialog:onEndHourMinus()
    local system = self:getCurrentSystem()
    if system == nil then return end
    local prev = (system.schedule.endHour - 1 + 24) % 24
    if prev ~= system.schedule.startHour then
        system.schedule.endHour = prev
    end
    self:updateTimeDisplays(system)
end

function IrrigationScheduleDialog:onEndHourPlus()
    local system = self:getCurrentSystem()
    if system == nil then return end
    local next = (system.schedule.endHour + 1) % 24
    if next ~= system.schedule.startHour then
        system.schedule.endHour = next
    end
    self:updateTimeDisplays(system)
end

-- ============================================================
-- PERFORMANCE DISPLAY
-- ============================================================

-- BUILD 18:15: every read here is nil-guarded.
-- F154 removed wearLevel from the system table. This function multiplied it raw,
-- so opening Schedule threw mid-onOpen, AFTER showDialog had already pushed the
-- dialog - which is why the shell appeared with nothing clickable rather than
-- simply failing to open. operationalCostPerHour is guarded for the same reason
-- even though it never multiplies: it goes straight into string.format, and a nil
-- there is the same crash one line further down.
function IrrigationScheduleDialog:updatePerformance(system)
    if system == nil then return end
    local flowPerHour = system.flowRatePerHour   or 0
    local pressure    = system.pressureMultiplier or 1
    local wear        = system.wearLevel          or 0
    local costPerHour = system.operationalCostPerHour or 0
    local effectiveRate = flowPerHour * pressure * (1.0 - wear * 0.3)
    local efficiency    = math.floor(pressure * 100)
    local function t(key, ...) return (g_i18n ~= nil and string.format(g_i18n:getText(key), ...)) or key end
    if self.flowRate   ~= nil then self.flowRate:setText(t("cs_irr_flow_rate_value",   effectiveRate)) end
    if self.efficiency ~= nil then self.efficiency:setText(t("cs_irr_efficiency_value", efficiency))   end
    if self.cost       ~= nil then self.cost:setText(t("cs_irr_cost_value",             costPerHour))  end
    -- Wear row is hidden (Samantha 18:12): the system no longer tracks wearLevel,
    -- so reporting a hard 0% would be inventing a reading rather than omitting one.
    if self.wear      ~= nil and self.wear.setVisible      ~= nil then self.wear:setVisible(false)      end
    if self.wearLabel ~= nil and self.wearLabel.setVisible ~= nil then self.wearLabel:setVisible(false) end
end

-- ============================================================
-- COVERED FIELDS LIST
-- ============================================================

function IrrigationScheduleDialog:updateCoveredFields(system)
    if self.coveredFieldsContainer == nil then return end

    local children = self.coveredFieldsContainer.elements
    if children ~= nil then
        for i = #children, 1, -1 do
            self.coveredFieldsContainer:removeElement(children[i])
        end
    end

    local function makeTextRow(text, yPos)
        local elem = TextElement.new()
        if g_gui ~= nil then
            local prof = g_gui:getProfile("fs25_dialogText")
            if prof ~= nil then elem:loadProfile(prof, true) end
        end
        elem:setPosition(5, yPos)
        elem:setText(text)
        self.coveredFieldsContainer:addElement(elem)
        elem:onGuiSetupFinished()
    end

    if #system.coveredFields == 0 then
        makeTextRow((g_i18n ~= nil and g_i18n:getText("cs_irr_no_covered_fields")) or "No fields covered.", 0)
        return
    end

    local y = 0
    for _, fieldId in ipairs(system.coveredFields) do
        local moisture = 0
        local stress   = 0
        if g_cropStressManager ~= nil then
            if g_cropStressManager.soilSystem    ~= nil then moisture = g_cropStressManager:getMoisture(fieldId) or 0 end
            if g_cropStressManager.stressModifier ~= nil then stress  = g_cropStressManager:getStress(fieldId) or 0 end
        end
        local cropName = self:getCropName(fieldId)
        local labelStr = string.format("Field %d · %s  %d%%", fieldId, cropName, math.floor(moisture * 100))
        if stress > 0.2 then labelStr = labelStr .. " !" end
        makeTextRow(labelStr, y)
        y = y - 20
    end
end

-- ============================================================
-- BUTTON HANDLERS
-- ============================================================

function IrrigationScheduleDialog:onIrrigateNow()
    local system = self:getCurrentSystem()
    if system == nil then self:close(); return end

    if system.waterSourceId == nil then
        if g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(
                (g_i18n ~= nil and g_i18n:getText("cs_irr_no_water_source")) or "No water source connected.", 3000)
        end
        return
    end

    local ok = false
    if g_cropStressManager ~= nil and g_cropStressManager.irrigationManager ~= nil then
        if g_server == nil and g_client ~= nil and CropStressIrrigateNowEvent ~= nil then
            -- SCS-018 3.6: a client routes the request to the server; the server
            -- applies the water through the single per-cell write path. Never
            -- write local state and let the next broadcast erase it.
            CropStressIrrigateNowEvent.sendToServer(self.systemId)
            ok = true
        else
            ok = g_cropStressManager.irrigationManager:applyOneTimeIrrigation(self.systemId)
        end
    end

    if g_currentMission ~= nil then
        local msg
        if ok then
            msg = (g_i18n ~= nil and g_i18n:getText("cs_irr_started")) or "Irrigation applied."
        else
            msg = (g_i18n ~= nil and g_i18n:getText("cs_irr_no_covered_fields")) or "No fields covered by this system."
        end
        g_currentMission:showBlinkingWarning(msg, 3000)
    end
    self:close()
end

function IrrigationScheduleDialog:onSaveSchedule()
    if g_currentMission ~= nil then
        g_currentMission:showBlinkingWarning(
            (g_i18n ~= nil and g_i18n:getText("cs_schedule_saved")) or "Schedule saved.", 2000)
    end
    self:close()
end

-- ============================================================
-- HELPERS
-- ============================================================

function IrrigationScheduleDialog:getCurrentSystem()
    if g_cropStressManager == nil then return nil end
    if g_cropStressManager.irrigationManager == nil then return nil end
    return g_cropStressManager.irrigationManager.systems[self.systemId]
end

function IrrigationScheduleDialog:getFieldObject(fieldId)
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

function IrrigationScheduleDialog:getCropName(fieldId)
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

function IrrigationScheduleDialog:formatCropName(rawName)
    if rawName == nil then return "Fallow" end
    local name = rawName:lower()
    if name == "grass" or name == "drygrass" or name == "weed"
    or name == "stone" or name == "meadow" then
        return "Fallow"
    end
    return rawName:sub(1,1):upper() .. rawName:sub(2):lower()
end