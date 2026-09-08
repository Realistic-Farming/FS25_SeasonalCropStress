-- =========================================================
-- Crop Stress Field Guide - Field Guide
-- =========================================================
-- BUILD 19:15 (George CLOSED DESIGN 18:55 item 5): every Realistic Farming Esc page gets its own
-- guide, in its own mod, opened from the shared Help footer through this guest's onOpenHelp. The
-- chrome is SoilGuideDialog's so all of them read as one family; only the words differ.
-- Rows are { t = "H" | "B" | "S" | "COL", v = "text" }: header, body, spacer, column break.
-- =========================================================

---@class CsHelpDialog
CsHelpDialog = CsHelpDialog or {}
local CsHelpDialog_mt = Class(CsHelpDialog, ScreenElement)

local GUIDE_MOD_DIR = (SeasonalCropStressModDirectory or g_currentModDirectory)

CsHelpDialog.INSTANCE = nil
CsHelpDialog.GUI_NAME = "CsHelpDialog"

CsHelpDialog.SUBTITLES = {
    "Overview - what the mod tracks and what the page shows",
    "HUD and Bands - reading the moisture HUD and its colours",
    "Crops and Stress - thirsty windows and what a harvest costs",
    "Irrigation - pumps, pivots, schedules and planning",
    "Settings and FAQ - the sliders and the common questions",
}

CsHelpDialog.PAGE1 = {
    { t="H", v="WHAT THIS MOD DOES" },
    { t="B", v="Every field carries its own soil moisture, from" },
    { t="B", v="0% bone dry to 100% saturated. Rain fills it." },
    { t="B", v="Heat, season and soil type dry it every hour." },
    { t="B", v="While a crop is in its thirsty growth window" },
    { t="B", v="and the field is drier than that crop needs," },
    { t="B", v="drought stress builds. At harvest that stress" },
    { t="B", v="takes a share of the yield." },
    { t="S", v=" " },
    { t="H", v="WHAT THE ESC PAGE SHOWS" },
    { t="B", v="Fields you own. Columns are Field, Crop," },
    { t="B", v="Moisture, Stress, Irrigated and Status." },
    { t="B", v="Click a row for the detail card and for the" },
    { t="B", v="pivot that covers that field." },
    { t="B", v="The list scrolls when you own many fields." },
    { t="S", v=" " },
    { t="H", v="FIRST STEPS" },
    { t="B", v="Turn on the moisture HUD and watch for red." },
    { t="B", v="Place a Water Pump, then a Center Pivot" },
    { t="B", v="within 500 m of it." },
    { t="B", v="Water the thirsty crops first, not the driest" },
    { t="B", v="field: an empty field cannot be stressed." },
    { t="COL", v="" },
    { t="H", v="THE WATER CYCLE" },
    { t="B", v="Rain raises moisture. Heat and time lower it." },
    { t="B", v="About 0.4% is lost each in-game hour before" },
    { t="B", v="weather, season, soil and your settings scale" },
    { t="B", v="it up or down." },
    { t="B", v="A sprayer filled with WATER raises moisture" },
    { t="B", v="wherever you spray, which is handy on a corner" },
    { t="B", v="a pivot cannot reach." },
    { t="S", v=" " },
    { t="H", v="SOIL TYPES" },
    { t="B", v="Sandy dries 1.4 times faster than loamy and" },
    { t="B", v="soaks up rain 1.25 times faster. It swings" },
    { t="B", v="quickly both ways." },
    { t="B", v="Loamy is the reference and the easiest." },
    { t="B", v="Clay dries at 0.7 and takes rain at 0.72, so" },
    { t="B", v="it holds water longest." },
    { t="S", v=" " },
    { t="H", v="WHAT STRESS COSTS" },
    { t="B", v="Stress does not heal when the rain returns." },
    { t="B", v="At harvest the yield is cut by the stress" },
    { t="B", v="times your Max Yield Loss setting. The factory" },
    { t="B", v="cap is 30%, so a fully stressed field still" },
    { t="B", v="yields 70%. A new crop starts clean." },
}

CsHelpDialog.PAGE2 = {
    { t="H", v="THE MOISTURE HUD" },
    { t="B", v="Toggle it with the Controls action Toggle" },
    { t="B", v="Moisture HUD. The factory key is Right Shift+M." },
    { t="B", v="If nothing happens, look under Options," },
    { t="B", v="Controls, Seasonal Crop Stress: the key may" },
    { t="B", v="have been rebound on this save." },
    { t="B", v="Edit and move the panel with the Edit/Move" },
    { t="B", v="Moisture HUD action, factory Right Shift+N." },
    { t="B", v="The layout is remembered for each player." },
    { t="S", v=" " },
    { t="H", v="READING A ROW" },
    { t="B", v="Each row shows the field number, the crop, its" },
    { t="B", v="growth stage, a colour bar and the moisture" },
    { t="B", v="percentage." },
    { t="B", v="An exclamation mark at the end means that" },
    { t="B", v="field is already building drought stress." },
    { t="B", v="Only crops that can suffer drought are listed." },
    { t="COL", v="" },
    { t="H", v="THE THREE BANDS" },
    { t="B", v="Green, healthy: 40% and above. Nothing to do." },
    { t="B", v="Yellow, warning: 25% to 40%. Plan water." },
    { t="B", v="Red, critical: below 25%. Yield loss can start." },
    { t="B", v="The same three bands colour the Esc page." },
    { t="S", v=" " },
    { t="H", v="THE FORECAST STRIP" },
    { t="B", v="The strip shows whether moisture is heading up" },
    { t="B", v="or down over the coming days." },
    { t="B", v="If rain is one or two days away and the field" },
    { t="B", v="is only yellow, wait for it and save the cost." },
    { t="B", v="Act early when several dry days line up with a" },
    { t="B", v="thirsty growth window." },
    { t="S", v=" " },
    { t="H", v="OTHER CONTROLS" },
    { t="B", v="Open Irrigation Manager, Open Crop Consultant" },
    { t="B", v="and Open Crop Stress Settings have no factory" },
    { t="B", v="key. Bind them under Options, Controls." },
}

CsHelpDialog.PAGE3 = {
    { t="H", v="THE THIRSTY WINDOW" },
    { t="B", v="Each crop has a growth window where water" },
    { t="B", v="matters, and its own moisture need." },
    { t="B", v="Stress builds every hour the crop is inside" },
    { t="B", v="that window and the field is below the need." },
    { t="B", v="Outside the window, a dry field costs nothing." },
    { t="S", v=" " },
    { t="H", v="WHAT EACH CROP NEEDS" },
    { t="B", v="Rice          70%" },
    { t="B", v="Potato        55%" },
    { t="B", v="Sugar beet    50%" },
    { t="B", v="Canola        45%" },
    { t="B", v="Corn          40%" },
    { t="B", v="Soybeans      40%" },
    { t="B", v="Wheat         35%" },
    { t="B", v="Barley        30%" },
    { t="B", v="Sunflower     30%" },
    { t="B", v="Rye           25%" },
    { t="B", v="Other crops carry their own window and need." },
    { t="COL", v="" },
    { t="H", v="HOW FAST IT BUILDS" },
    { t="B", v="The further below the need, the faster stress" },
    { t="B", v="accrues. A field just under the line drifts;" },
    { t="B", v="a bone dry field climbs quickly." },
    { t="B", v="Difficulty scales it: Easy is half speed," },
    { t="B", v="Hard is half again as fast as Normal." },
    { t="S", v=" " },
    { t="H", v="HARVEST" },
    { t="B", v="Yield is cut by the field's stress times your" },
    { t="B", v="Max Yield Loss setting." },
    { t="B", v="Factory cap 30%: a fully stressed field still" },
    { t="B", v="brings in 70% of normal." },
    { t="B", v="You can raise the cap as far as 75% in" },
    { t="B", v="settings if you want drought to bite harder." },
    { t="S", v=" " },
    { t="H", v="AFTER THE HARVEST" },
    { t="B", v="Stress is cleared with the crop. The next" },
    { t="B", v="planting starts clean, whatever the last one" },
    { t="B", v="went through." },
}

CsHelpDialog.PAGE4 = {
    { t="H", v="WHAT YOU CAN BUILD" },
    { t="B", v="Build menu: Water Pump and Center Pivot, in" },
    { t="B", v="three spans." },
    { t="B", v="The pump feeds the pivots and must sit within" },
    { t="B", v="500 m of the system it serves." },
    { t="B", v="Pressure falls by about 30% at that full" },
    { t="B", v="range, so keep pumps close to their pivots." },
    { t="B", v="A system with no pump in range reads as" },
    { t="B", v="Disconnected." },
    { t="S", v=" " },
    { t="H", v="VEHICLES AND SPRAYERS" },
    { t="B", v="The shop also sells irrigator vehicles." },
    { t="B", v="A sprayer filled with WATER raises moisture" },
    { t="B", v="wherever you spray it. Useful on a small" },
    { t="B", v="field, or until a pivot is affordable." },
    { t="COL", v="" },
    { t="H", v="SCHEDULES" },
    { t="B", v="Open a system's Irrigation Manager from the" },
    { t="B", v="Controls action, or from the Schedule chip on" },
    { t="B", v="the pivot card when that system covers the" },
    { t="B", v="field you have selected." },
    { t="B", v="Pick the days of the week, set a start and an" },
    { t="B", v="end hour, then Save." },
    { t="B", v="Irrigate Now waters the covered fields for one" },
    { t="B", v="hour straight away." },
    { t="S", v=" " },
    { t="H", v="RUNNING COSTS" },
    { t="B", v="With Irrigation Costs on, a running system is" },
    { t="B", v="charged by the hour. Turn it off for a simpler" },
    { t="B", v="game." },
    { t="S", v=" " },
    { t="H", v="PLANNING" },
    { t="B", v="Put the first pivot on sandy fields: they dry" },
    { t="B", v="twice as fast as clay." },
    { t="B", v="A pivot over a large sandy area is usually a" },
    { t="B", v="better buy than one on a small clay field that" },
    { t="B", v="holds water on its own." },
}

CsHelpDialog.PAGE5 = {
    { t="H", v="SETTINGS" },
    { t="B", v="Open them at Settings, Seasonal Crop Stress." },
    { t="B", v="Enable Mod switches the whole system off" },
    { t="B", v="without removing anything you have built." },
    { t="B", v="Difficulty scales stress and drying together:" },
    { t="B", v="Easy 0.5 and 0.7, Normal 1.0, Hard 1.5 and" },
    { t="B", v="1.4." },
    { t="B", v="Evapotranspiration Rate scales drying again on" },
    { t="B", v="top of difficulty." },
    { t="B", v="Max Yield Loss is the harvest cap, factory" },
    { t="B", v="30%, adjustable from 30% to 75%." },
    { t="B", v="Critical Threshold, factory 25%, is where the" },
    { t="B", v="red band and its alerts begin." },
    { t="B", v="Alert Cooldown, factory 12 hours, is the wait" },
    { t="B", v="before the same field warns you again." },
    { t="COL", v="" },
    { t="H", v="QUESTIONS" },
    { t="B", v="My field is dry but has no stress." },
    { t="B", v="The crop is outside its thirsty window, or the" },
    { t="B", v="field is bare. Only a thirsty crop suffers." },
    { t="S", v=" " },
    { t="B", v="It rained. Why is the stress still there?" },
    { t="B", v="Stress does not heal. Rain stops it growing;" },
    { t="B", v="the harvest still pays for what accrued." },
    { t="S", v=" " },
    { t="B", v="Where is Finite Water?" },
    { t="B", v="It is off by default and experimental: it does" },
    { t="B", v="nothing until both it and Experimental Systems" },
    { t="B", v="are switched on." },
    { t="S", v=" " },
    { t="B", v="Does this work in multiplayer?" },
    { t="B", v="Yes. The server runs moisture, stress and" },
    { t="B", v="irrigation. The HUD layout is per player." },
}

CsHelpDialog.PAGE_CONTENT = { CsHelpDialog.PAGE1, CsHelpDialog.PAGE2, CsHelpDialog.PAGE3, CsHelpDialog.PAGE4, CsHelpDialog.PAGE5 }

-- -- Constructor ------------------------------------------

function CsHelpDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or CsHelpDialog_mt)
    self._contentLineEls = {}
    self._currentPage = 1
    return self
end

--- Loads the dialog into g_gui once. Safe to call twice, and safe to call when some other path has
--- already registered the same name.
function CsHelpDialog.register(modDirectory)
    if g_gui == nil then return end
    if g_gui.guis ~= nil and g_gui.guis[CsHelpDialog.GUI_NAME] ~= nil then return end
    if modDirectory ~= nil then GUIDE_MOD_DIR = modDirectory end
    if GUIDE_MOD_DIR == nil then return end
    CsHelpDialog.INSTANCE = CsHelpDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(GUIDE_MOD_DIR .. "xml/gui/CsHelpDialog.xml", CsHelpDialog.GUI_NAME, CsHelpDialog.INSTANCE)
    end)
    if not ok then
        print("[CropStress] CsHelpDialog: loadGui failed: " .. tostring(err))
        CsHelpDialog.INSTANCE = nil
    end
end

function CsHelpDialog.show()
    if g_gui == nil then return end
    local loaded = g_gui.guis ~= nil and g_gui.guis[CsHelpDialog.GUI_NAME] ~= nil
    if not loaded then
        CsHelpDialog.register(GUIDE_MOD_DIR)
        loaded = g_gui.guis ~= nil and g_gui.guis[CsHelpDialog.GUI_NAME] ~= nil
    end
    if not loaded then return end
    g_gui:showDialog(CsHelpDialog.GUI_NAME)
end

-- -- Lifecycle --------------------------------------------

function CsHelpDialog:onGuiSetupFinished()
    CsHelpDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("csHelp_col1")
    self._elCol2 = self:getDescendantById("csHelp_col2")
    self._elSubtitle = self:getDescendantById("csHelp_subtitle")
end

function CsHelpDialog:onOpen()
    CsHelpDialog:superClass().onOpen(self)
    self._currentPage = 1
    self:_selectPage(1)
end

function CsHelpDialog:onClose()
    CsHelpDialog:superClass().onClose(self)
    self:_clearContent()
    self._currentPage = 1
end

-- -- Tabs -------------------------------------------------

function CsHelpDialog:onClickTab1() self:_selectPage(1) end
function CsHelpDialog:onClickTab2() self:_selectPage(2) end
function CsHelpDialog:onClickTab3() self:_selectPage(3) end
function CsHelpDialog:onClickTab4() self:_selectPage(4) end
function CsHelpDialog:onClickTab5() self:_selectPage(5) end

function CsHelpDialog:_selectPage(pageNum)
    if self._currentPage == pageNum and #self._contentLineEls > 0 then return end
    self:_clearContent()
    self._currentPage = pageNum
    if self._elSubtitle ~= nil then
        self._elSubtitle:setText(CsHelpDialog.SUBTITLES[pageNum] or "")
    end
    self:_buildContent(pageNum)
end

-- -- Content ----------------------------------------------

function CsHelpDialog:_buildContent(pageNum)
    local profileH = g_gui:getProfile("csHelp_colHeader")
    local profileB = g_gui:getProfile("csHelp_colBody")
    local profileS = g_gui:getProfile("csHelp_colSpacer")
    if not profileH or not profileB then
        print("[CropStress] CsHelpDialog: column profiles not found")
        return
    end
    local content = CsHelpDialog.PAGE_CONTENT[pageNum]
    if content == nil then return end
    local currentBox = self._elCol1
    for _, row in ipairs(content) do
        if row.t == "COL" then
            if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox ~= nil then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB
            if profile ~= nil then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v or "")
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

function CsHelpDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls or {}) do
        if entry.box ~= nil then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
    if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

-- -- Button -----------------------------------------------

function CsHelpDialog:onClickClose()
    g_gui:closeDialogByName(CsHelpDialog.GUI_NAME)
end
