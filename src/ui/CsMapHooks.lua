-- =========================================================
-- CsMapHooks
-- Injects the Crop Moisture overlay into the native PDA map
-- as a standard category tab (alongside Growth, Soil Type, etc.)
-- =========================================================
-- Pattern: mirrors FS25_SoilFertilizer SoilMapHooks.lua
-- =========================================================

CsMapHooks = {}

local function getCsOverlay(frame)
    if frame == nil then return nil end
    return g_cropStressManager and g_cropStressManager.moistureMapOverlay
end

local function isCsPageActive(frame)
    if frame == nil or frame.csMoisturePageIndex == nil or frame.mapOverviewSelector == nil then
        return false
    end
    return frame.mapOverviewSelector:getState() == frame.csMoisturePageIndex
end

local function updateSubCategoryDotBox(frame)
    if frame == nil or frame.subCategoryDotBox == nil or frame.mapSelectorTexts == nil then return end
    local dotBox  = frame.subCategoryDotBox
    local elements = dotBox.elements
    if elements == nil or #elements == 0 then return end

    local expectedCount = #frame.mapSelectorTexts
    while #elements < expectedCount do
        dotBox:addElement(elements[1]:clone(dotBox))
        elements = dotBox.elements
    end
    while #elements > expectedCount do
        elements[#elements]:delete()
        elements = dotBox.elements
    end
    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            return frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == index
        end
    end
    dotBox:invalidateLayout()
end

-- ── Hook handlers ─────────────────────────────────────────

function CsMapHooks:onLoadMapFinished()
    local overlay = getCsOverlay(self)
    if overlay then
        overlay:requestRefresh()
        if not overlay.ingameMapRef then
            local ref = nil
            if self.ingameMapBase and self.ingameMapBase.layout then
                ref = self.ingameMapBase
            elseif self.ingameMap and self.ingameMap.layout then
                ref = self.ingameMap
            end
            if ref then
                overlay.ingameMapRef = ref
                print("[CropStress] CsMapHooks: ingameMap ref cached")
            end
        end
    end
end

function CsMapHooks:setupMapOverview()
    if self.csMoisturePageIndex ~= nil then return end
    if self.mapSelectorTexts == nil or self.mapOverviewSelector == nil then return end

    local overlay = getCsOverlay(self)
    if overlay == nil then return end

    local pageText = (g_i18n and g_i18n:getText("cs_map_page_title")) or "Crop Moisture"

    table.insert(self.mapSelectorTexts, pageText)
    self.csMoisturePageIndex = #self.mapSelectorTexts
    print(string.format("[CropStress] CsMapHooks: registered native page index %d", self.csMoisturePageIndex))

    self.mapOverviewSelector:setTexts(self.mapSelectorTexts)

    if self.dataTables ~= nil then
        self.dataTables[self.csMoisturePageIndex] = overlay:getDisplayValues()
    end
    if self.filterStates ~= nil then
        self.filterStates[self.csMoisturePageIndex] = overlay:getDefaultFilterState()
    end

    updateSubCategoryDotBox(self)
end

function CsMapHooks:onClickMapOverviewSelector(state)
    if self.csMoisturePageIndex == nil or state ~= self.csMoisturePageIndex then return end

    local overlay = getCsOverlay(self)
    if overlay == nil then return end

    if self.dataTables ~= nil and self.dataTables[self.csMoisturePageIndex] == nil then
        self.dataTables[self.csMoisturePageIndex] = overlay:getDisplayValues()
    end
    if self.filterStates ~= nil and self.filterStates[self.csMoisturePageIndex] == nil then
        self.filterStates[self.csMoisturePageIndex] = overlay:getDefaultFilterState()
    end
    if self.numSelectedFilters ~= nil then
        self.numSelectedFilters[self.csMoisturePageIndex] = 0
    end

    if self.generateOverviewOverlay ~= nil then
        self:generateOverviewOverlay()
    end

    overlay:requestRefresh()
end

function CsMapHooks:generateOverviewOverlay()
    if self.csMoisturePageIndex == nil or self.mapOverviewSelector == nil then return end
    if self.mapOverviewSelector:getState() ~= self.csMoisturePageIndex then return end

    if self.ingameMap ~= nil and self.ingameMap.setOverlayVisible ~= nil then
        self.ingameMap:setOverlayVisible(false)
    end
    if self.ingameMapBase ~= nil and self.ingameMapBase.setOverlayVisible ~= nil then
        self.ingameMapBase:setOverlayVisible(false)
    end

    local overlay = getCsOverlay(self)
    if overlay ~= nil then overlay:requestRefresh() end
end

function CsMapHooks.onDrawIngameMapElement(elementSelf, ...)
    if elementSelf == nil or elementSelf.ingameMap == nil then return end

    local _overlay = g_cropStressManager and g_cropStressManager.moistureMapOverlay
    if _overlay and not _overlay.ingameMapRef and elementSelf.ingameMap.layout then
        _overlay.ingameMapRef = elementSelf.ingameMap
        print("[CropStress] CsMapHooks: ingameMap ref captured from PDA draw (fallback)")
    end

    local frame = elementSelf.parent
    local depth = 0
    while frame ~= nil and depth < 6 do
        if frame.csMoisturePageIndex ~= nil then break end
        frame = frame.parent
        depth = depth + 1
    end

    if frame == nil or frame.csMoisturePageIndex == nil then return end
    if frame.mapOverviewSelector == nil then return end
    if frame.mapOverviewSelector:getState() ~= frame.csMoisturePageIndex then return end

    local overlay = g_cropStressManager and g_cropStressManager.moistureMapOverlay
    if overlay == nil then return end

    overlay:onDraw(frame, elementSelf, elementSelf.ingameMap, frame.csMoisturePageIndex)
end

function CsMapHooks:onDrawOverlayHud()
    local ok, active = pcall(isCsPageActive, self)
    if not ok or not active then return end

    local overlay = getCsOverlay(self)
    if overlay == nil then return end

    overlay:onDrawHud(self)
end

function CsMapHooks:onMouseEvent(superFunc, posX, posY, isDown, isUp, button, eventUsed)
    local pageActive = false
    local ok, result = pcall(isCsPageActive, self)
    if ok then pageActive = result end

    if not pageActive then
        local ok2, ret = pcall(superFunc, self, posX, posY, isDown, isUp, button, eventUsed)
        if not ok2 then
            print("[CropStress] CsMapHooks: mouseEvent superFunc error: " .. tostring(ret))
        end
        return ret
    end

    if not eventUsed and isDown and (button == Input.MOUSE_BUTTON_LEFT or button == Input.MOUSE_BUTTON_RIGHT) then
        local overlay = getCsOverlay(self)
        if overlay and overlay:onSideBarClick(posX, posY) then
            return true
        end
    end

    local ok3, ret3 = pcall(superFunc, self, posX, posY, isDown, isUp, button, eventUsed)
    if not ok3 then
        print("[CropStress] CsMapHooks: mouseEvent superFunc error (2): " .. tostring(ret3))
    end
    return ret3
end

function CsMapHooks:getHasChangeableFilterList(superFunc, ...)
    if self.csMoisturePageIndex ~= nil and self.mapOverviewSelector ~= nil then
        if self.mapOverviewSelector:getState() == self.csMoisturePageIndex then
            return false
        end
    end
    return superFunc(self, ...)
end

function CsMapHooks:onFrameClose()
    local overlay = getCsOverlay(self)
    if overlay ~= nil then overlay:requestRefresh() end
end

-- ── Install hooks ─────────────────────────────────────────

if InGameMenuMapFrame ~= nil then
    if InGameMenuMapFrame.onLoadMapFinished ~= nil then
        InGameMenuMapFrame.onLoadMapFinished = Utils.appendedFunction(
            InGameMenuMapFrame.onLoadMapFinished, CsMapHooks.onLoadMapFinished)
    end
    if InGameMenuMapFrame.setupMapOverview ~= nil then
        InGameMenuMapFrame.setupMapOverview = Utils.appendedFunction(
            InGameMenuMapFrame.setupMapOverview, CsMapHooks.setupMapOverview)
    end
    if InGameMenuMapFrame.onClickMapOverviewSelector ~= nil then
        InGameMenuMapFrame.onClickMapOverviewSelector = Utils.appendedFunction(
            InGameMenuMapFrame.onClickMapOverviewSelector, CsMapHooks.onClickMapOverviewSelector)
    end
    if InGameMenuMapFrame.generateOverviewOverlay ~= nil then
        InGameMenuMapFrame.generateOverviewOverlay = Utils.appendedFunction(
            InGameMenuMapFrame.generateOverviewOverlay, CsMapHooks.generateOverviewOverlay)
    end
    if InGameMenuMapFrame.draw ~= nil then
        InGameMenuMapFrame.draw = Utils.appendedFunction(
            InGameMenuMapFrame.draw, CsMapHooks.onDrawOverlayHud)
    elseif InGameMenuMapFrame.onDraw ~= nil then
        InGameMenuMapFrame.onDraw = Utils.appendedFunction(
            InGameMenuMapFrame.onDraw, CsMapHooks.onDrawOverlayHud)
    end
    if InGameMenuMapFrame.mouseEvent ~= nil then
        InGameMenuMapFrame.mouseEvent = Utils.overwrittenFunction(
            InGameMenuMapFrame.mouseEvent, CsMapHooks.onMouseEvent)
    end
    if InGameMenuMapFrame.getHasChangeableFilterList ~= nil then
        InGameMenuMapFrame.getHasChangeableFilterList = Utils.overwrittenFunction(
            InGameMenuMapFrame.getHasChangeableFilterList, CsMapHooks.getHasChangeableFilterList)
    end
    if InGameMenuMapFrame.onFrameClose ~= nil then
        InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(
            InGameMenuMapFrame.onFrameClose, CsMapHooks.onFrameClose)
    end
    print("[CropStress] CsMapHooks: installed on InGameMenuMapFrame")
else
    print("[CropStress] CsMapHooks: WARNING — InGameMenuMapFrame not available at load time")
end

if IngameMapElement ~= nil then
    IngameMapElement.draw = Utils.appendedFunction(
        IngameMapElement.draw, CsMapHooks.onDrawIngameMapElement)
    print("[CropStress] CsMapHooks: IngameMapElement.draw hook installed")
else
    print("[CropStress] CsMapHooks: WARNING — IngameMapElement not available — map dots will not draw")
end
