-- SCS-map_click_guard_current_page_spec_test.lua - the map frame's moisture overlay may
-- only take mouse clicks, and draw its HUD, while the map frame is the page on screen.
--
-- WHY THIS EXISTS. isCsPageActive tested one thing: whether the map frame's
-- mapOverviewSelector is parked on the Crop Moisture layer. That selector is the map
-- frame's REMEMBERED sub-page. It survives leaving the map, so it answers "the moisture
-- layer is what the map will show next time", not "the map is on screen now". The shared
-- mouse chain runs every handler before the engine's own mouseEvent, where the visibility
-- check lives (GuiElement.lua:502), and CsMoistureMapOverlay:onSideBarClick matches its
-- buttonRects on screen coordinates alone. So a click on another Esc Realistic Farming
-- page that landed on the remembered button rects toggled the Crop Stress PDA screen
-- (CsMoistureMapOverlay.lua:1024-1026) or cycled the overlay density and dropped its
-- polygon cache (:1028-1038). The sibling of SoilFertilizer's SG10-051 fix (#1035),
-- found by Bob reading source; not seen in game.
--
-- THE ENTRY-POINT BAR IS GROUP S. The engine's map frame is modelled (SCS-map_frame_model.lua)
-- and CsMapHooks' own install block wraps it at file load; every click goes through
-- InGameMenuMapFrame.mouseEvent, the chain production installs. The overlay is the real
-- CsMoistureMapOverlay. Its buttonRects are hand-set, a stand-in for the two rects
-- onDrawHud lays out (CsMoistureMapOverlay.lua:809-923: cycleDensity at :911, openPDA at
-- :921), because that draw needs the renderer, and onDrawHud itself is replaced by a
-- counter for group D. Nothing else about the click path is supplied.
--
-- Groups:
--   S  the entry-point bar: on the moisture layer, the map frame NOT on screen declines
--      and falls through to the engine; the map frame on screen still takes the click
--   P  the menu cannot be resolved: permissive, unchanged
--   L  the displayed map frame on another layer still declines
--   D  the HUD draw is gated the same way
--
--!load: tools/test/lua/SCS-map_frame_model.lua, src/ui/CsMoistureMapOverlay.lua, src/ui/CsMapHooks.lua

Input = Input or { MOUSE_BUTTON_LEFT = 1, MOUSE_BUTTON_RIGHT = 2 }
InGameMenu = InGameMenu or {}

local CS_PAGE = 5
local PDA_X, PDA_Y = 0.15, 0.12       -- inside the "openPDA" button
local DENSITY_X, DENSITY_Y = 0.15, 0.22   -- inside the "cycleDensity" button

local toggles = 0
CsPDAScreen = { toggle = function() toggles = toggles + 1 end }

--- A map frame parked on the moisture layer (the state that used to be enough), the real
--- overlay with its two sidebar buttons, and a polygon cache to see dropped.
local function world()
    local overlay = CsMoistureMapOverlay.new({})
    overlay.buttonRects = {
        { x1 = 0.10, y1 = 0.10, x2 = 0.20, y2 = 0.15, action = "openPDA" },
        { x1 = 0.10, y1 = 0.20, x2 = 0.20, y2 = 0.25, action = "cycleDensity" },
    }
    overlay.fieldPolyCache = { sentinel = true }
    overlay.hudDraws = 0
    overlay.onDrawHud = function(self) self.hudDraws = self.hudDraws + 1 end   -- the renderer is not modelled
    g_cropStressManager = { moistureMapOverlay = overlay }
    local frame = { csMoisturePageIndex = CS_PAGE, mapOverviewSelector = { state = CS_PAGE, getState = function(s) return s.state end } }
    toggles = 0
    InGameMenuMapFrame.resetModel()
    return frame, overlay
end

--- Put the engine in a state where `which` is the page on screen.
local function setCurrentPage(which)
    g_gui = { screenControllers = { [InGameMenu] = { currentPage = which } } }
    g_inGameMenu = nil
end
local OTHER_PAGE = { name = "the RF PDA page the player is actually on" }

--- A left click through production's chain.
local function click(frame, x, y)
    return InGameMenuMapFrame.mouseEvent(frame, x, y, true, false, Input.MOUSE_BUTTON_LEFT, false)
end
local function state(overlay)
    return "toggles=" .. toggles .. " density=" .. tostring(overlay.density) .. " cache=" .. tostring(overlay.fieldPolyCache.sentinel == true) .. " engine=" .. InGameMenuMapFrame.engineMouseCalls
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
do
    T.ok("S1 CsMapHooks' install block wrapped the engine's mouseEvent into the shared chain",
        InGameMenuMapFrame._rfMapMouseChainInstalled == true and InGameMenuMapFrame._rfMapMouseHandlers ~= nil
        and InGameMenuMapFrame._rfMapMouseHandlers[1] ~= nil and InGameMenuMapFrame._rfMapMouseHandlers[1].name == "CsMapHooks")

    local frame, overlay = world()
    local density = overlay.density
    setCurrentPage(OTHER_PAGE)
    local used = click(frame, PDA_X, PDA_Y)
    T.eq("S2 another page on screen: a click on the PDA button's spot does not open the Crop Stress PDA, and reaches the engine",
        tostring(used) .. " " .. state(overlay), "false toggles=0 density=" .. tostring(density) .. " cache=true engine=1")

    frame, overlay = world()
    density = overlay.density
    setCurrentPage(OTHER_PAGE)
    used = click(frame, DENSITY_X, DENSITY_Y)
    T.eq("S3 and a click on the density button's spot leaves the density and the polygon cache alone",
        tostring(used) .. " " .. state(overlay), "false toggles=0 density=" .. tostring(density) .. " cache=true engine=1")

    frame, overlay = world()
    setCurrentPage(frame)
    used = click(frame, PDA_X, PDA_Y)
    T.eq("S4 the map frame on screen: the PDA button still opens the Crop Stress PDA, and the chain stops there",
        tostring(used) .. " toggles=" .. toggles .. " engine=" .. InGameMenuMapFrame.engineMouseCalls, "true toggles=1 engine=0")

    frame, overlay = world()
    density = overlay.density
    setCurrentPage(frame)
    used = click(frame, DENSITY_X, DENSITY_Y)
    local want = density + 1
    if want > #CsMoistureMapOverlay.DENSITY_POINTS then want = 1 end
    T.eq("S5 and the density button still cycles the density and drops the cache",
        tostring(used) .. " density=" .. tostring(overlay.density) .. " cache=" .. tostring(overlay.fieldPolyCache.sentinel == true), "true density=" .. want .. " cache=false")
end

-- ══════════════════════════════════════════════════════════════════════════
-- P. The menu cannot be resolved: permissive, unchanged
-- ══════════════════════════════════════════════════════════════════════════
do
    local frame, overlay = world()
    g_gui, g_inGameMenu = nil, nil
    T.eq("P1 with no g_gui the click lands exactly as before", tostring(click(frame, PDA_X, PDA_Y)) .. " toggles=" .. toggles, "true toggles=1")

    frame, overlay = world()
    g_gui = { screenControllers = { [InGameMenu] = { currentPage = nil } } }
    T.eq("P2 a menu with no current page is undeterminable, so also permissive", tostring(click(frame, PDA_X, PDA_Y)) .. " toggles=" .. toggles, "true toggles=1")

    frame, overlay = world()
    g_gui = { screenControllers = {} }
    g_inGameMenu = { currentPage = OTHER_PAGE }
    T.eq("P3 with no screen controller the menu falls back to g_inGameMenu, which says another page is on screen",
        tostring(click(frame, PDA_X, PDA_Y)) .. " " .. state(overlay):match("toggles=%d+"), "false toggles=0")
    g_inGameMenu = nil
end

-- ══════════════════════════════════════════════════════════════════════════
-- L. The displayed map frame on another layer still declines
-- ══════════════════════════════════════════════════════════════════════════
do
    local frame, overlay = world()
    frame.mapOverviewSelector.state = CS_PAGE + 1
    setCurrentPage(frame)
    T.eq("L1 the map on screen but on a vanilla layer: the moisture overlay is never consulted",
        tostring(click(frame, PDA_X, PDA_Y)) .. " toggles=" .. toggles .. " engine=" .. InGameMenuMapFrame.engineMouseCalls, "false toggles=0 engine=1")
end

-- ══════════════════════════════════════════════════════════════════════════
-- D. The HUD draw is gated the same way
-- ══════════════════════════════════════════════════════════════════════════
do
    local frame, overlay = world()
    setCurrentPage(OTHER_PAGE)
    InGameMenuMapFrame.draw(frame)
    T.eq("D1 another page on screen: the engine draws the frame, the moisture HUD does not", InGameMenuMapFrame.engineDrawCalls .. "/" .. overlay.hudDraws, "1/0")
    setCurrentPage(frame)
    InGameMenuMapFrame.draw(frame)
    T.eq("D2 the map frame on screen: the moisture HUD draws", InGameMenuMapFrame.engineDrawCalls .. "/" .. overlay.hudDraws, "2/1")
end

g_gui, g_inGameMenu, g_cropStressManager = nil, nil, nil
