-- =========================================================
-- CsMapHooks
-- Injects the Crop Moisture overlay into the native PDA map
-- as a standard category tab (alongside Growth, Soil Type, etc.)
-- =========================================================
-- Pattern: mirrors FS25_SoilFertilizer SoilMapHooks.lua
-- FAILFIX 2026-08-05: pairs(nil) Map freeze — nil-guards, coordinated
-- mouseEvent chain with Soil, overwrite generateOverviewOverlay so
-- custom page indices do not hit vanilla MAP_HOTSPOTS <= state fruit path.
-- =========================================================

CsMapHooks = {}

local LOG_PREFIX = "[CropStress] CsMapHooks: "

local function logNilOnce(key, msg)
    if InGameMenuMapFrame == nil then
        print(LOG_PREFIX .. msg)
        return
    end
    if InGameMenuMapFrame._rfMapNilLog == nil then
        InGameMenuMapFrame._rfMapNilLog = {}
    end
    if InGameMenuMapFrame._rfMapNilLog[key] then
        return
    end
    InGameMenuMapFrame._rfMapNilLog[key] = true
    print(LOG_PREFIX .. msg)
end

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

--- Ensure tables vanilla MapFrame pairs()/indexes are never nil.
--- Shared with SoilMapHooks via InGameMenuMapFrame._rfMapNilLog (once-per-key).
local function ensurePairsSafeTables(frame)
    if frame == nil then
        return
    end

    if frame.ingameMap ~= nil and frame.ingameMap.ingameMap ~= nil then
        if frame.ingameMap.ingameMap.hotspots == nil then
            frame.ingameMap.ingameMap.hotspots = {}
            logNilOnce("hotspots", "ingameMap.ingameMap.hotspots was nil; guarded to {}")
        end
    end

    if frame.subCategoryDotBox ~= nil and frame.subCategoryDotBox.elements == nil then
        frame.subCategoryDotBox.elements = {}
        logNilOnce("dotElements", "subCategoryDotBox.elements was nil; guarded to {}")
    end

    if frame.displayCropTypes == nil then
        logNilOnce("displayCropTypes", "displayCropTypes is nil (loadFilters / onLoadMapFinished may not have run)")
    end

    local state = nil
    if frame.mapOverviewSelector ~= nil then
        state = frame.mapOverviewSelector:getState()
    end
    if state == nil then
        return
    end

    if frame.dataTables ~= nil and frame.dataTables[state] == nil then
        if frame.csMoisturePageIndex ~= nil and state == frame.csMoisturePageIndex then
            local overlay = getCsOverlay(frame)
            if overlay ~= nil then
                frame.dataTables[state] = overlay:getDisplayValues() or {}
            else
                frame.dataTables[state] = {}
            end
            logNilOnce("dataTables_cs", string.format("dataTables[%s] was nil on CS page; filled", tostring(state)))
        else
            logNilOnce("dataTables_" .. tostring(state), string.format("dataTables[%s] is nil", tostring(state)))
        end
    end

    if frame.filterStates ~= nil and frame.filterStates[state] == nil then
        if frame.csMoisturePageIndex ~= nil and state == frame.csMoisturePageIndex then
            local overlay = getCsOverlay(frame)
            if overlay ~= nil then
                frame.filterStates[state] = overlay:getDefaultFilterState() or {}
            else
                frame.filterStates[state] = {}
            end
            logNilOnce("filterStates_cs", string.format("filterStates[%s] was nil on CS page; filled", tostring(state)))
        else
            logNilOnce("filterStates_" .. tostring(state), string.format("filterStates[%s] is nil", tostring(state)))
        end
    end
end

local function updateSubCategoryDotBox(frame)
    if frame == nil or frame.subCategoryDotBox == nil or frame.mapSelectorTexts == nil then return end
    local dotBox = frame.subCategoryDotBox
    local elements = dotBox.elements
    if elements == nil or #elements == 0 then return end

    local expectedCount = #frame.mapSelectorTexts
    while #elements < expectedCount do
        dotBox:addElement(elements[1]:clone(dotBox))
        elements = dotBox.elements
        if elements == nil then return end
    end
    while #elements > expectedCount do
        elements[#elements]:delete()
        elements = dotBox.elements
        if elements == nil then return end
    end
    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            return frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == index
        end
    end
    dotBox:invalidateLayout()
end

local function suppressNativeOverlay(frame)
    if frame.ingameMap ~= nil and frame.ingameMap.setOverlayVisible ~= nil then
        frame.ingameMap:setOverlayVisible(false)
    end
    if frame.ingameMapBase ~= nil and frame.ingameMapBase.setOverlayVisible ~= nil then
        frame.ingameMapBase:setOverlayVisible(false)
    end
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
                print(LOG_PREFIX .. "ingameMap ref cached")
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
    print(string.format(LOG_PREFIX .. "registered native page index %d", self.csMoisturePageIndex))

    self.mapOverviewSelector:setTexts(self.mapSelectorTexts)

    if self.dataTables ~= nil then
        self.dataTables[self.csMoisturePageIndex] = overlay:getDisplayValues() or {}
    end
    if self.filterStates ~= nil then
        self.filterStates[self.csMoisturePageIndex] = overlay:getDefaultFilterState() or {}
    end
    if self.numSelectedFilters ~= nil then
        self.numSelectedFilters[self.csMoisturePageIndex] = 0
    end

    updateSubCategoryDotBox(self)
end

function CsMapHooks:onFrameOpen()
    ensurePairsSafeTables(self)
    if self.csMoisturePageIndex == nil then
        CsMapHooks.setupMapOverview(self)
    end
end

--- Own-page activation after vanilla selector work (overwrite calls this after super).
function CsMapHooks:onCsPageSelected(state)
    if self.csMoisturePageIndex == nil or state ~= self.csMoisturePageIndex then return end

    local overlay = getCsOverlay(self)
    if overlay == nil then return end

    if self.dataTables ~= nil and self.dataTables[self.csMoisturePageIndex] == nil then
        self.dataTables[self.csMoisturePageIndex] = overlay:getDisplayValues() or {}
    end
    if self.filterStates ~= nil and self.filterStates[self.csMoisturePageIndex] == nil then
        self.filterStates[self.csMoisturePageIndex] = overlay:getDefaultFilterState() or {}
    end
    if self.numSelectedFilters ~= nil then
        self.numSelectedFilters[self.csMoisturePageIndex] = 0
    end

    suppressNativeOverlay(self)
    overlay:requestRefresh()
end

--- Overwrite: skip vanilla fruit/growth path when CS page active (MAP_HOTSPOTS <= state hazard).
function CsMapHooks:generateOverviewOverlay(superFunc)
    if isCsPageActive(self) then
        suppressNativeOverlay(self)
        local overlay = getCsOverlay(self)
        if overlay ~= nil then
            overlay:requestRefresh()
        end
        return
    end
    if superFunc ~= nil then
        return superFunc(self)
    end
end

function CsMapHooks.onDrawIngameMapElement(elementSelf, ...)
    if elementSelf == nil or elementSelf.ingameMap == nil then return end

    local _overlay = g_cropStressManager and g_cropStressManager.moistureMapOverlay
    if _overlay and not _overlay.ingameMapRef and elementSelf.ingameMap.layout then
        _overlay.ingameMapRef = elementSelf.ingameMap
        print(LOG_PREFIX .. "ingameMap ref captured from PDA draw (fallback)")
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

--- Sidebar click only; coordinated chain calls this before vanilla mouseEvent (no pcall amp).
function CsMapHooks.handleMouseEvent(frame, posX, posY, isDown, isUp, button, eventUsed)
    local pageActive = false
    local ok, result = pcall(isCsPageActive, frame)
    if ok then pageActive = result end
    if not pageActive then
        return false
    end

    if not eventUsed and isDown and (button == Input.MOUSE_BUTTON_LEFT or button == Input.MOUSE_BUTTON_RIGHT) then
        local overlay = getCsOverlay(frame)
        if overlay and overlay:onSideBarClick(posX, posY) then
            return true
        end
    end
    return false
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

-- ── Shared installs (idempotent with SoilMapHooks) ────────

--- Belt: if vanilla pageMapOverview:onLoadMapFinished never ran (e.g. aborted
--- loadMission00Finished), restore real filter tables from mapOverlayGenerator
--- before onFrameOpen → loadFilters. Do NOT paper with empty {} alone.
local function restoreVanillaMapFilterInitIfMissing(frame)
    if frame == nil then
        return
    end
    local fruitKey = InGameMenuMapFrame.MAP_FRUIT_TYPE
    local needsRestore = frame.displayCropTypes == nil
        or frame.dataTables == nil
        or (fruitKey ~= nil and frame.dataTables[fruitKey] == nil)
    if not needsRestore then
        return
    end

    local mission = g_currentMission
    local mapOverlayGenerator = mission ~= nil and mission.mapOverlayGenerator or nil
    frame.displaySoilStateMapping = {}
    if mapOverlayGenerator ~= nil then
        frame.displayCropTypes = mapOverlayGenerator:getDisplayCropTypes()
        frame.displayGrowthStates = mapOverlayGenerator:getDisplayGrowthStates()
        frame.displaySoilStates = mapOverlayGenerator:getDisplaySoilStates()
        if frame.displaySoilStates ~= nil then
            for index, state in pairs(frame.displaySoilStates) do
                if state.isActive then
                    state.soilStateIndex = index
                    table.insert(frame.displaySoilStateMapping, state)
                end
            end
        end
    end

    if frame.dataTables == nil then
        frame.dataTables = {}
    end
    frame.dataTables[InGameMenuMapFrame.MAP_SOIL] = frame.displaySoilStateMapping or {}
    frame.dataTables[InGameMenuMapFrame.MAP_FRUIT_TYPE] = frame.displayCropTypes or {}
    frame.dataTables[InGameMenuMapFrame.MAP_GROWTH] = frame.displayGrowthStates or {}
    frame.dataTables[InGameMenuMapFrame.MAP_HOTSPOTS] = InGameMenuMapFrame.HOTSPOT_FILTER_CATEGORIES or {}
    frame.dataTables[InGameMenuMapFrame.MAP_FARMLANDS] = frame.farmlandItems or {}

    if g_gameSettings ~= nil and GameSettings ~= nil and GameSettings.SETTING ~= nil then
        g_gameSettings:setValue(GameSettings.SETTING.INGAME_MAP_HOTSPOT_FILTER, 4294967295, true)
    end
    if g_terrainNode ~= nil and frame.filterList ~= nil and type(frame.filterList.reloadData) == "function" then
        frame.filterList:reloadData()
    end

    if InGameMenuMapFrame._rfVanillaFilterInitRestoredLogged ~= true then
        InGameMenuMapFrame._rfVanillaFilterInitRestoredLogged = true
        print(LOG_PREFIX .. "restored vanilla map filter init before onFrameOpen")
    end
end

local function installVanillaFilterInitBelt()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onFrameOpen == nil then
        return
    end
    if InGameMenuMapFrame._rfVanillaFilterInitBeltInstalled then
        return
    end
    InGameMenuMapFrame._rfVanillaFilterInitBeltInstalled = true
    InGameMenuMapFrame.onFrameOpen = Utils.prependedFunction(
        InGameMenuMapFrame.onFrameOpen,
        restoreVanillaMapFilterInitIfMissing
    )
end

local function installPairsSafeMouseChain()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.mouseEvent == nil then
        return
    end

    if InGameMenuMapFrame._rfMapMouseHandlers == nil then
        InGameMenuMapFrame._rfMapMouseHandlers = {}
    end

    local handlers = InGameMenuMapFrame._rfMapMouseHandlers
    local replaced = false
    for i = 1, #handlers do
        if handlers[i].name == "CsMapHooks" then
            handlers[i].fn = CsMapHooks.handleMouseEvent
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(handlers, { name = "CsMapHooks", fn = CsMapHooks.handleMouseEvent })
    end

    if InGameMenuMapFrame._rfMapMouseChainInstalled then
        return
    end
    InGameMenuMapFrame._rfMapMouseChainInstalled = true

    InGameMenuMapFrame.mouseEvent = Utils.overwrittenFunction(
        InGameMenuMapFrame.mouseEvent,
        function(self, superFunc, posX, posY, isDown, isUp, button, eventUsed)
            ensurePairsSafeTables(self)
            local list = InGameMenuMapFrame._rfMapMouseHandlers
            if list ~= nil then
                for i = 1, #list do
                    local h = list[i]
                    if h ~= nil and h.fn ~= nil then
                        local used = h.fn(self, posX, posY, isDown, isUp, button, eventUsed)
                        if used then
                            return true
                        end
                    end
                end
            end
            -- Do not pcall-swallow: pairs(nil) must not leave a half-live frame.
            return superFunc(self, posX, posY, isDown, isUp, button, eventUsed)
        end
    )
end

local function installDeselectGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onClickDeselectAll == nil then
        return
    end
    if InGameMenuMapFrame._rfDeselectGuardInstalled then
        return
    end
    InGameMenuMapFrame._rfDeselectGuardInstalled = true

    InGameMenuMapFrame.onClickDeselectAll = Utils.overwrittenFunction(
        InGameMenuMapFrame.onClickDeselectAll,
        function(self, superFunc, exceptionSection, exceptionIndex)
            if self.getHasChangeableFilterList ~= nil and not self:getHasChangeableFilterList() then
                return
            end
            ensurePairsSafeTables(self)
            local state = self.mapOverviewSelector and self.mapOverviewSelector:getState()
            if state == nil then
                return
            end
            local dt = self.dataTables and self.dataTables[state]
            if dt == nil then
                logNilOnce("deselect_nil_table", string.format("onClickDeselectAll blocked: dataTables[%s] nil", tostring(state)))
                return
            end
            if InGameMenuMapFrame.MAP_HOTSPOTS ~= nil and state == InGameMenuMapFrame.MAP_HOTSPOTS then
                if dt[1] == nil or dt[2] == nil then
                    logNilOnce("deselect_hotspot_shape", "onClickDeselectAll blocked: hotspot filter subtables nil")
                    return
                end
            end
            return superFunc(self, exceptionSection, exceptionIndex)
        end
    )
end

local function installSelectorGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onClickMapOverviewSelector == nil then
        return
    end
    if InGameMenuMapFrame._rfSelectorGuardInstalled then
        -- Still register CS post-hook if Soil installed the guard first.
        if not InGameMenuMapFrame._rfCsSelectorPostInstalled then
            InGameMenuMapFrame._rfCsSelectorPostInstalled = true
            local prev = InGameMenuMapFrame.onClickMapOverviewSelector
            InGameMenuMapFrame.onClickMapOverviewSelector = function(self, state)
                prev(self, state)
                CsMapHooks.onCsPageSelected(self, state)
            end
        end
        return
    end
    InGameMenuMapFrame._rfSelectorGuardInstalled = true
    InGameMenuMapFrame._rfCsSelectorPostInstalled = true

    InGameMenuMapFrame.onClickMapOverviewSelector = Utils.overwrittenFunction(
        InGameMenuMapFrame.onClickMapOverviewSelector,
        function(self, superFunc, state)
            ensurePairsSafeTables(self)
            if superFunc ~= nil then
                superFunc(self, state)
            end
            CsMapHooks.onCsPageSelected(self, state)
        end
    )
end

local function installFrameCloseGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onFrameClose == nil then
        return
    end
    if InGameMenuMapFrame._rfFrameCloseHotspotGuard then
        return
    end
    InGameMenuMapFrame._rfFrameCloseHotspotGuard = true

    InGameMenuMapFrame.onFrameClose = Utils.overwrittenFunction(
        InGameMenuMapFrame.onFrameClose,
        function(self, superFunc)
            ensurePairsSafeTables(self)
            return superFunc(self)
        end
    )
end

local function installFilterListDeselectGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.initialize == nil then
        return
    end
    if InGameMenuMapFrame._rfFilterListInitGuardInstalled then
        return
    end
    InGameMenuMapFrame._rfFilterListInitGuardInstalled = true

    InGameMenuMapFrame.initialize = Utils.appendedFunction(
        InGameMenuMapFrame.initialize,
        function(self)
            if self._rfFilterListDeselectGuarded then
                return
            end
            local filterList = self.filterList
            if filterList == nil or filterList.mouseEvent == nil then
                return
            end
            self._rfFilterListDeselectGuarded = true
            local prev = filterList.mouseEvent
            function filterList.mouseEvent(list, posX, posY, isDown, isUp, button, eventUsed)
                if isDown and button == Input.MOUSE_BUTTON_RIGHT then
                    if self.getHasChangeableFilterList ~= nil and not self:getHasChangeableFilterList() then
                        if SmoothListElement ~= nil and SmoothListElement.mouseEvent ~= nil then
                            return SmoothListElement.mouseEvent(list, posX, posY, isDown, isUp, button, eventUsed)
                        end
                        return eventUsed
                    end
                end
                return prev(list, posX, posY, isDown, isUp, button, eventUsed)
            end
        end
    )
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
    if InGameMenuMapFrame.onFrameOpen ~= nil then
        installVanillaFilterInitBelt()
        InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuMapFrame.onFrameOpen, CsMapHooks.onFrameOpen)
    end

    installSelectorGuard()

    if InGameMenuMapFrame.generateOverviewOverlay ~= nil then
        InGameMenuMapFrame.generateOverviewOverlay = Utils.overwrittenFunction(
            InGameMenuMapFrame.generateOverviewOverlay, CsMapHooks.generateOverviewOverlay)
    end
    if InGameMenuMapFrame.draw ~= nil then
        InGameMenuMapFrame.draw = Utils.appendedFunction(
            InGameMenuMapFrame.draw, CsMapHooks.onDrawOverlayHud)
    elseif InGameMenuMapFrame.onDraw ~= nil then
        InGameMenuMapFrame.onDraw = Utils.appendedFunction(
            InGameMenuMapFrame.onDraw, CsMapHooks.onDrawOverlayHud)
    end

    installPairsSafeMouseChain()
    installDeselectGuard()
    installFrameCloseGuard()
    installFilterListDeselectGuard()

    if InGameMenuMapFrame.getHasChangeableFilterList ~= nil then
        InGameMenuMapFrame.getHasChangeableFilterList = Utils.overwrittenFunction(
            InGameMenuMapFrame.getHasChangeableFilterList, CsMapHooks.getHasChangeableFilterList)
    end
    if InGameMenuMapFrame.onFrameClose ~= nil then
        InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(
            InGameMenuMapFrame.onFrameClose, CsMapHooks.onFrameClose)
    end
    print(LOG_PREFIX .. "installed on InGameMenuMapFrame (pairs-safe mouse chain)")
else
    print(LOG_PREFIX .. "WARNING — InGameMenuMapFrame not available at load time")
end

if IngameMapElement ~= nil then
    IngameMapElement.draw = Utils.appendedFunction(
        IngameMapElement.draw, CsMapHooks.onDrawIngameMapElement)
    print(LOG_PREFIX .. "IngameMapElement.draw hook installed")
else
    print(LOG_PREFIX .. "WARNING — IngameMapElement not available — map dots will not draw")
end

-- =========================================================
-- BUILD 09:19 (PB-12): keep the Growth-map field drawer inside the visible frame.
-- =========================================================
-- Twin of the same patch in FS25_SoilFertilizer/src/hooks/SoilMapHooks.lua; the long-form
-- reasoning lives there. Short version: vanilla InGameMenuMapUtil places the field info
-- drawer left of the cursor with `posX = posX - fieldInfoBox.size[1]` and never clamps that
-- to the screen, and getFieldInfoBoxOrientation only flips for right/top overflow, so at the
-- map's left edge the box runs off-screen and the player reads label tails ("...ds lime")
-- instead of labels.
--
-- Vanilla still chooses the side and the anchor. This appended pass only pulls the finished
-- box back inside the safe frame when it ended up outside, so away from the edges it is a
-- no-op and nothing about the normal placement changes.
--
-- Soil and Crop Stress both carry it and share one install flag on InGameMenuMapUtil, so
-- whichever loads first installs and the drawer is fixed whether or not both are present.

local function clampFieldInfoBoxInsideFrame(fieldInfoBox)
    if fieldInfoBox == nil then
        return
    end
    local ap = fieldInfoBox.absPosition
    local as = fieldInfoBox.absSize
    if type(ap) ~= "table" or type(as) ~= "table" then
        return
    end
    local px, py = ap[1], ap[2]
    local w, h = as[1], as[2]
    if type(px) ~= "number" or type(py) ~= "number"
        or type(w) ~= "number" or type(h) ~= "number" then
        return
    end

    -- Same margins the vanilla HUD keeps off the screen edge (IngameMap:getMapPosition
    -- returns g_safeFrameOffsetX, g_safeFrameOffsetY), not a number invented here.
    local marginX = (type(g_safeFrameOffsetX) == "number") and g_safeFrameOffsetX or 0
    local marginY = (type(g_safeFrameOffsetY) == "number") and g_safeFrameOffsetY or 0

    -- Left wins if the box cannot satisfy both edges: the left edge is where label text
    -- starts, and a lost first character is the defect being fixed.
    local maxX = 1 - marginX - w
    local newX = px
    if newX > maxX then newX = maxX end
    if newX < marginX then newX = marginX end

    local maxY = 1 - marginY - h
    local newY = py
    if newY > maxY then newY = maxY end
    if newY < marginY then newY = marginY end

    if newX ~= px or newY ~= py then
        if type(fieldInfoBox.setAbsolutePosition) == "function" then
            fieldInfoBox:setAbsolutePosition(newX, newY)
        end
    end
end

if InGameMenuMapUtil ~= nil
    and type(InGameMenuMapUtil.updateFieldInfoBoxPosition) == "function"
    and InGameMenuMapUtil._rfFieldInfoBoxClampInstalled ~= true then

    InGameMenuMapUtil._rfFieldInfoBoxClampInstalled = true
    InGameMenuMapUtil.updateFieldInfoBoxPosition = Utils.appendedFunction(
        InGameMenuMapUtil.updateFieldInfoBoxPosition,
        function(fieldInfoBox)
            clampFieldInfoBoxInsideFrame(fieldInfoBox)
        end)
    print(LOG_PREFIX .. "field info drawer clamped inside the safe frame (PB-12)")
elseif InGameMenuMapUtil == nil then
    print(LOG_PREFIX .. "WARNING - InGameMenuMapUtil not available - field info drawer clamp not installed")
end
