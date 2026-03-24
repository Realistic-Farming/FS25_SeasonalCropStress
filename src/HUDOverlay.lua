-- ============================================================
-- HUDOverlay.lua
-- Renders the field moisture panel in the lower-left corner.
-- Uses FS25 immediate-mode render functions (renderText, renderOverlay, setOverlayColor).
--
-- Phase 1: Basic moisture bars with auto-show/auto-hide
-- Phase 3: +Forecast strip for selected field, +click-based row selection
--
-- Layout (bottom-left, above minimap):
-- ┌─────────────────────────────────────────────┐
-- │  CROP MOISTURE MONITOR               [M]    │
-- │  Field 7 · Wheat S4    ████████░░ 78%  [SEL]│
-- │  Field 3 · Corn  S5 !  ███░░░░░░░ 32%       │
-- │  Field 5 · Corn  S3    ██████████ 80%       │
-- ├─────────────────────────────────────────────┤
-- │  5-DAY FORECAST — Field 7                   │
-- │  Today  D+1   D+2   D+3   D+4               │
-- │   78%    72%   65%   58%   52%               │
-- └─────────────────────────────────────────────┘
--
-- HUD coordinates: bottom-left origin. Y=0 at BOTTOM, increases UP.
-- All values are normalized screen fractions (0.0–1.0).
-- ============================================================

HUDOverlay = {}
HUDOverlay.__index = HUDOverlay

-- ── Main panel layout ──────────────────────────────────────
HUDOverlay.PANEL_X          = 0.010
HUDOverlay.PANEL_Y          = 0.175
HUDOverlay.PANEL_W          = 0.230
HUDOverlay.ROW_H            = 0.024
HUDOverlay.HEADER_H         = 0.028
HUDOverlay.PADDING          = 0.004
HUDOverlay.BAR_W            = 0.080
HUDOverlay.BAR_H            = 0.012
HUDOverlay.TEXT_SIZE         = 0.013
HUDOverlay.HEADER_TEXT_SIZE  = 0.014
HUDOverlay.MAX_FIELDS        = 6

-- ── Forecast strip layout ──────────────────────────────────
-- Layout sections from bottom to top:
--   PADDING | PCT_ROW | BAR_AREA | PADDING | LABEL_ROW | PADDING | HEADER
-- Total = 0.004+0.018+0.032+0.004+0.014+0.004+0.022 = 0.098 → 0.100
HUDOverlay.FORECAST_H        = 0.100   -- total height of the forecast panel
HUDOverlay.FORECAST_HEADER_H = 0.022
HUDOverlay.FORECAST_BAR_AREA = 0.032   -- height of vertical bars
HUDOverlay.FORECAST_ROW_H    = 0.018   -- pct text row below bars
HUDOverlay.FORECAST_LABEL_H  = 0.014   -- day label row above bars
HUDOverlay.FORECAST_COLS     = 5
HUDOverlay.FORECAST_COL_W    = 0.040   -- width per forecast column
HUDOverlay.FORECAST_BAR_H    = 0.010
HUDOverlay.FORECAST_TEXT_SZ  = 0.011

-- ── Scale & resize ─────────────────────────────────────────
HUDOverlay.MIN_SCALE          = 0.6
HUDOverlay.MAX_SCALE          = 1.6
HUDOverlay.RESIZE_HANDLE_SIZE = 0.008

-- ── Selection highlight ────────────────────────────────────
-- A thin colored border is drawn on the selected row
HUDOverlay.SELECTED_BORDER_W  = 0.003
HUDOverlay.COLOR_SELECTED_BDR = {0.40, 0.80, 1.00, 0.90}  -- light blue

-- ── Colors ─────────────────────────────────────────────────
HUDOverlay.COLOR_BG          = {0.05, 0.05, 0.05, 0.78}
HUDOverlay.COLOR_HEADER_BG   = {0.10, 0.10, 0.10, 0.85}
HUDOverlay.COLOR_ROW_HOVER   = {0.15, 0.15, 0.15, 0.60}  -- subtle row highlight
HUDOverlay.COLOR_TEXT         = {0.90, 0.90, 0.90, 1.00}
HUDOverlay.COLOR_HEADER_TEXT  = {1.00, 1.00, 1.00, 1.00}
HUDOverlay.COLOR_BAR_BG      = {0.20, 0.20, 0.20, 0.80}
HUDOverlay.COLOR_HEALTHY     = {0.20, 0.75, 0.20, 1.00}  -- green  >60%
HUDOverlay.COLOR_WARNING     = {0.85, 0.70, 0.10, 1.00}  -- yellow 30-60%
HUDOverlay.COLOR_CRITICAL    = {0.85, 0.20, 0.10, 1.00}  -- red    <30%
HUDOverlay.COLOR_FORECAST_BG = {0.08, 0.08, 0.12, 0.82}
HUDOverlay.COLOR_DIM_TEXT    = {0.60, 0.60, 0.60, 1.00}
HUDOverlay.COLOR_EDIT_BORDER = {1.00, 0.60, 0.10, 0.90}  -- orange — edit mode indicator
HUDOverlay.EDIT_BORDER_W     = 0.002

-- ============================================================
-- LOGGING HELPER
-- ============================================================
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ============================================================
-- CONSTRUCTOR
-- ============================================================
function HUDOverlay.new(manager)
    local self = setmetatable({}, HUDOverlay)
    self.manager        = manager
    self.isVisible      = false
    self.firstRunShown  = false

    -- Display rows rebuilt each frame
    self.displayRows    = {}

    -- Phase 3: selected field for forecast strip
    self.selectedFieldId   = nil
    self.forecastCache     = nil   -- cached {fieldId, projections[5]} — rebuilt when selection changes
    self.forecastDirty     = true

    -- Scrolling support
    self.scrollOffset      = 0     -- index of first visible field (0-based)
    self.maxVisibleFields  = HUDOverlay.MAX_FIELDS

    -- Auto-show / auto-hide state
    self.autoShowActive = false
    self.autoHideTimer  = 0   -- real-time seconds; 0 = no auto-hide
    self.rebuildTimer   = 0   -- throttles row rebuilds

    -- LMB click-vs-drag detection: set true on LMB-down inside HUD, cleared on LMB-up.
    -- If LMB-up fires and we never started dragging/resizing, it counts as a row click.
    self.lmbDownOnHUD   = false

    -- Panel position — initialized from class constants, overridable via drag in edit mode
    self.panelX         = HUDOverlay.PANEL_X
    self.panelY         = HUDOverlay.PANEL_Y
    self.lastResolution = {g_screenWidth or 1920, g_screenHeight or 1080}

    -- Edit mode / drag state (mirrors NPCFavorHUD pattern)
    self.editMode       = false
    self.dragging       = false
    self.dragOffsetX    = 0
    self.dragOffsetY    = 0

    -- Scale & resize state
    self.scale            = 1.0
    self.resizing         = false
    self.resizeStartX     = 0
    self.resizeStartY     = 0
    self.resizeStartScale = 1.0
    self.hoverCorner      = nil
    self.animTimer        = 0

    -- Camera freeze state (NPCFavor pattern)
    self.savedCamRotX     = nil
    self.savedCamRotY     = nil
    self.savedCamRotZ     = nil

    self.isInitialized  = false
    return self
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function HUDOverlay:initialize()
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.subscribe("CS_MOISTURE_UPDATED",   self.onMoistureUpdated,   self)
        self.manager.eventBus.subscribe("CS_CRITICAL_THRESHOLD", self.onCriticalThreshold, self)
    end

    -- Single shared overlay handle used for every filled-rect draw call.
    -- "dataS/menu/base/graph_pixel.dds" is a 1×1 white pixel in FS25 game data —
    -- tinted at draw time via setOverlayColor(handle, r, g, b, a).
    -- Guard: createImageOverlay is always available in FS25 PC/Console builds, but
    -- we check defensively so a missing function doesn't crash at draw time (see draw()).
    if createImageOverlay ~= nil then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    else
        csLog("WARNING: createImageOverlay not available — HUD rect rendering disabled")
    end

    self.isInitialized = true
    csLog("HUDOverlay initialized (Phase 3 — with forecast strip)")
end

-- ============================================================
-- UPDATE  (called every frame by CropStressManager:update())
-- ============================================================
function HUDOverlay:update(dt)
    if not self.isInitialized then return end
    if not self.isVisible then return end

    self.animTimer = self.animTimer + dt

    -- Edit mode: assert cursor every frame + freeze free-roam camera (NPCFavor pattern).
    -- When in a vehicle we still keep the cursor unlocked, but we must NOT touch the
    -- camera transforms — the vehicle controller owns them and fighting it causes the
    -- twitchy/locked camera bug reported by in-vehicle users.
    if self.editMode then
        if g_inputBinding and g_inputBinding.setShowMouseCursor then
            g_inputBinding:setShowMouseCursor(true)
        end
        if not self:isPlayerInVehicle() and self.savedCamRotX and getCamera and setRotation then
            local ok, cam = pcall(getCamera)
            if ok and cam and cam ~= 0 then
                pcall(setRotation, cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
            end
        end
        -- Auto-exit if a GUI/dialog opens
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
            self:exitEditMode()
        end
        -- Hover detection for corner handles
        if not self.dragging and not self.resizing then
            if g_inputBinding and g_inputBinding.mousePosXLast and g_inputBinding.mousePosYLast then
                self.hoverCorner = self:hitTestCorner(g_inputBinding.mousePosXLast, g_inputBinding.mousePosYLast)
            else
                self.hoverCorner = nil
            end
        end
    else
        self.hoverCorner = nil
    end

    -- Detect resolution changes and recalculate coordinates
    local currentResolution = { g_screenWidth, g_screenHeight }
    if self.lastResolution[1] ~= currentResolution[1] or self.lastResolution[2] ~= currentResolution[2] then
        self.lastResolution = currentResolution
        self:recalculateCoordinates()
    end

    -- LMB row click detection (rising-edge poll — must run every frame)
    self:detectRowClick()

    -- Throttle row rebuilds to once per second to avoid per-frame cost
    self.rebuildTimer = self.rebuildTimer + dt
    if self.rebuildTimer >= 1.0 then
        self.rebuildTimer = 0
        self:rebuildDisplayRows()
    end

    -- Rebuild forecast when selection changes or moisture is updated.
    -- Runs after rebuildDisplayRows so selectedFieldId is always up-to-date.
    if self.forecastDirty then
        self.forecastDirty = false
        self:rebuildForecast()
    end

    -- Auto-hide countdown: tick down and hide when the timer expires.
    -- Set by onCriticalThreshold() to auto-dismiss after a critical alert.
    if self.autoShowActive and self.autoHideTimer > 0 then
        self.autoHideTimer = self.autoHideTimer - dt
        if self.autoHideTimer <= 0 then
            self.autoHideTimer  = 0
            self.autoShowActive = false
            self.isVisible      = false
        end
    end
end

-- Recalculate panel position from saved relative coordinates when resolution changes.
-- Position is stored as normalized fractions in settings so it survives resolution changes.
function HUDOverlay:recalculateCoordinates()
    local settings = self.manager and self.manager.settings
    if settings == nil then return end
    self.panelX = settings.hudPanelX or HUDOverlay.PANEL_X
    self.panelY = settings.hudPanelY or HUDOverlay.PANEL_Y
    self.scale  = settings.hudScale  or 1.0
end

-- ============================================================
-- EDIT MODE (NPCFavor pattern — cursor unlock + camera freeze)
-- ============================================================

--- Returns true when the local player is seated in a vehicle.
-- In that context we still unlock the cursor, but we must NOT freeze the
-- vehicle camera — the vehicle's own camera controller owns those transforms.
--
-- FS25 confirmed: when a player enters a vehicle, g_localPlayer becomes nil.
-- The authoritative check is g_currentMission.controlledVehicle.
-- Additional fallback: when on foot g_localPlayer is non-nil, so nil = in vehicle.
function HUDOverlay:isPlayerInVehicle()
    local mission = g_currentMission
    if mission == nil then return false end

    -- Check 1: controlledVehicle on mission — the authoritative FS25 in-vehicle flag.
    -- Set by BaseMission:setControlledVehicle() whenever the local player enters any vehicle.
    if mission.controlledVehicle ~= nil then return true end

    -- Check 2: Input binding context name.
    -- FS25 switches the active input context to a vehicle-specific name when driving.
    -- On foot the context is "PLAYER" or "ALL". Driving uses "VEHICLE", "COMBINE", etc.
    if g_inputBinding ~= nil then
        local ok, ctx = pcall(function()
            if type(g_inputBinding.getContextName) == "function" then
                return g_inputBinding:getContextName()
            end
            return g_inputBinding.currentContextName or g_inputBinding.contextName
        end)
        if ok and ctx ~= nil then
            local upper = tostring(ctx):upper()
            if upper ~= "PLAYER" and upper ~= "ALL" and upper ~= "MENU" and upper ~= "" then
                return true
            end
        end
    end

    -- Check 3: g_localPlayer nil-implies-vehicle.
    -- FS25 despawns the player pawn when entering a vehicle. If the mission has
    -- started but g_localPlayer is nil, the local client is driving.
    if mission.isMissionStarted and g_localPlayer == nil then return true end

    -- Check 4: Explicit flags on g_localPlayer when it is present
    if g_localPlayer ~= nil then
        if g_localPlayer.controlledVehicle ~= nil then return true end
        if g_localPlayer.currentVehicle    ~= nil then return true end
        if g_localPlayer.isOnFoot == false          then return true end
    end

    -- Check 5: mission.player fallback
    local mPlayer = mission.player
    if mPlayer ~= nil then
        if mPlayer.controlledVehicle ~= nil then return true end
        if mPlayer.currentVehicle    ~= nil then return true end
    end

    return false
end

function HUDOverlay:enterEditMode()
    self.editMode = true
    self.dragging = false
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true)
    end
    -- Only freeze the free-roam camera. When the player is driving, the
    -- vehicle's camera controller owns those transforms and fighting it causes
    -- the twitchy/locked camera the user reported. Cursor still unlocks fine.
    if not self:isPlayerInVehicle() then
        if getCamera and getRotation then
            local ok, cam = pcall(getCamera)
            if ok and cam and cam ~= 0 then
                local ok2, rx, ry, rz = pcall(getRotation, cam)
                if ok2 then
                    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = rx, ry, rz
                end
            end
        end
    end
    csLog("HUD edit mode ON — drag to move, corners to resize (inVehicle=" .. tostring(self:isPlayerInVehicle()) .. ")")
end

function HUDOverlay:exitEditMode()
    self.editMode    = false
    self.dragging    = false
    self.resizing    = false
    self.hoverCorner = nil
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
    if self.manager ~= nil and self.manager.settings ~= nil then
        self.manager.settings.hudPanelX = self.panelX
        self.manager.settings.hudPanelY = self.panelY
        self.manager.settings.hudScale  = self.scale
    end
    csLog("HUD edit mode OFF — position saved")
end

-- ── Geometry helpers ──────────────────────────────────────

function HUDOverlay:getHUDRect()
    local s      = self.scale
    local panelW = HUDOverlay.PANEL_W * s
    -- Use max(actual rows, 1) so hit-testing uses the same height the panel visually renders at.
    -- Previously, if displayRows was empty, numRows=0 forced calcPanelHeight(1) which is correct,
    -- but the real draw path passes max(numRows,1) as well. Keep consistent so dragging always works.
    local numRows = math.max(1, math.min(#self.displayRows, HUDOverlay.MAX_FIELDS))
    local panelH = self:calcPanelHeight(numRows)
    return self.panelX, self.panelY, panelW, panelH
end

function HUDOverlay:isPointerOverHUD(posX, posY)
    local px, py, pw, ph = self:getHUDRect()
    if posX >= px and posX <= px + pw and posY >= py and posY <= py + ph then
        return true
    end
    -- Also include forecast strip
    if self.forecastCache ~= nil then
        local s    = self.scale
        local stripH = HUDOverlay.FORECAST_H * s + HUDOverlay.PADDING * s
        if posX >= px and posX <= px + pw
        and posY >= py - stripH and posY <= py then
            return true
        end
    end
    return false
end

function HUDOverlay:getResizeHandleRects()
    local px, py, pw, ph = self:getHUDRect()
    local hs = HUDOverlay.RESIZE_HANDLE_SIZE
    return {
        bl = {x = px,        y = py,        w = hs, h = hs},
        br = {x = px+pw-hs,  y = py,        w = hs, h = hs},
        tl = {x = px,        y = py+ph-hs,  w = hs, h = hs},
        tr = {x = px+pw-hs,  y = py+ph-hs,  w = hs, h = hs},
    }
end

function HUDOverlay:hitTestCorner(posX, posY)
    local handles = self:getResizeHandleRects()
    for key, rect in pairs(handles) do
        if posX >= rect.x and posX <= rect.x + rect.w
        and posY >= rect.y and posY <= rect.y + rect.h then
            return key
        end
    end
    return nil
end

function HUDOverlay:clampPosition()
    local px, py, pw, ph = self:getHUDRect()
    self.panelX = math.max(0.01, math.min(1.0 - pw - 0.01, self.panelX))
    self.panelY = math.max(ph + 0.01, math.min(0.99, self.panelY))
end

-- ============================================================
-- SELECT ROW AT POSITION  (shared by LMB and RMB paths)
-- Returns true if a row was hit.
-- ============================================================
function HUDOverlay:selectRowAtPosition(mx, my)
    local s       = self.scale
    local panelW  = HUDOverlay.PANEL_W * s
    local rowH    = HUDOverlay.ROW_H * s
    local headerH = HUDOverlay.HEADER_H * s
    local numRows = math.min(#self.displayRows, HUDOverlay.MAX_FIELDS)
    local panelH  = self:calcPanelHeight(numRows)
    local px      = self.panelX
    local py      = self.panelY

    for i = 1, numRows do
        local rowY = py + panelH - headerH - (i * rowH)
        if mx >= px and mx <= px + panelW
        and my >= rowY and my <= rowY + rowH then
            local newId = self.displayRows[i].fieldId
            if self.selectedFieldId == newId then
                self.selectedFieldId = nil
                self.forecastCache   = nil
            else
                self.selectedFieldId = newId
                self.forecastDirty   = true
            end
            return true
        end
    end
    return false
end

-- ============================================================
-- CLICK DETECTION (stub — row selection moved to onMouseEvent LMB path)
-- Row clicks are now handled inside onMouseEvent: LMB-up in edit mode
-- without a drag/resize counts as a row selection click.
-- ============================================================
function HUDOverlay:detectRowClick()
    -- No-op: handled by onMouseEvent button==1 isUp logic.
end

-- ============================================================
-- SCROLLING
-- ============================================================
function HUDOverlay:scroll(delta)
    if #self.displayRows == 0 then return end
    
    -- Get total field count from manager
    local totalFields = 0
    if self.manager ~= nil and self.manager.soilSystem ~= nil then
        local sortedFields = self.manager.soilSystem:getFieldsSortedByMoisture()
        if sortedFields ~= nil then
            -- Count valid fields (same logic as rebuildDisplayRows)
            local fieldById = (self.manager ~= nil) and self.manager.fieldById or {}
            for _, entry in ipairs(sortedFields) do
                local field = fieldById[entry.fieldId]
                if field ~= nil then
                    local cropName = self:resolveCropName(field)
                    if cropName ~= nil and CropStressModifier.CROP_WINDOWS[cropName:lower()] ~= nil then
                        totalFields = totalFields + 1
                    end
                end
            end
        end
    end
    
    if totalFields <= self.maxVisibleFields then return end
    
    -- Apply scroll delta (negative delta = scroll up, positive = scroll down)
    self.scrollOffset = self.scrollOffset - delta
    
    -- Clamp scroll offset
    local maxOffset = math.max(0, totalFields - self.maxVisibleFields)
    self.scrollOffset = math.max(0, math.min(maxOffset, self.scrollOffset))
    
    -- Rebuild display rows to show new visible fields
    self:rebuildDisplayRows()
end

-- ============================================================
-- MOUSE EVENT — edit toggle, drag, resize, scroll, row selection
-- Called from main.lua addModEventListener mouseEvent handler.
-- FS25 button numbers: 1=left, 2=middle, 3=right, 4=wheel up, 5=wheel down.
--
-- Interaction model (NPCFavor pattern):
--   RMB on HUD          → toggle edit mode on/off
--   In edit mode, LMB   → drag body, corner-resize, OR row select (click without drag)
--   Scroll wheel        → always works over HUD (no edit mode required)
--
-- With setShowMouseCursor(true) active during edit mode, FS25 fires
-- mouseEvent on every mouse MOVEMENT as well as clicks, enabling true
-- continuous drag (NPCFavor pattern).
-- ============================================================
function HUDOverlay:onMouseEvent(posX, posY, isDown, isUp, button)
    if not self.isVisible then return end

    -- ── Mouse wheel: scroll field list (always, no edit mode needed) ──
    if button == 4 then
        if self:isPointerOverHUD(posX, posY) then self:scroll(-1) end
        return
    elseif button == 5 then
        if self:isPointerOverHUD(posX, posY) then self:scroll(1) end
        return
    end

    -- ── RMB ──────────────────────────────────────────────────────────────────
    -- On foot: RMB on HUD enters edit mode (and selects the clicked row).
    -- In vehicle: RMB is captured by the vehicle camera, so we only allow it
    --   to EXIT edit mode (cursor is visible when in edit mode, suppressing
    --   the vehicle camera, so this is safe). Entering edit mode in a vehicle
    --   must be done via the CS_EDIT_HUD keybind (Shift+H).
    if isDown and button == 3 then
        if self:isPointerOverHUD(posX, posY) then
            if self.editMode then
                self:exitEditMode()
            elseif not self:isPlayerInVehicle() then
                self:selectRowAtPosition(posX, posY)
                self:enterEditMode()
            end
        end
        return
    end

    -- ── LMB without edit mode: row selection while in a vehicle ──────────────
    -- Allows the player to select a field for the forecast panel without
    -- needing to enter full edit mode (which requires Shift+H in a vehicle).
    if isDown and button == 1 and not self.editMode then
        if self:isPlayerInVehicle() and self:isPointerOverHUD(posX, posY) then
            self.lmbDownOnHUD = true
        end
        return
    end
    if isUp and button == 1 and not self.editMode then
        if self.lmbDownOnHUD and self:isPlayerInVehicle() then
            self:selectRowAtPosition(posX, posY)
        end
        self.lmbDownOnHUD = false
        return
    end

    -- Everything below is edit-mode only
    if not self.editMode then return end

    -- ── LMB down: start corner-resize, body-drag, or mark intent for row-select ──
    -- No early return after drag-start so the movement block runs immediately
    -- on the same event (NPCFavor pattern — zero 1-frame lag).
    if isDown and button == 1 then
        local corner = self:hitTestCorner(posX, posY)
        if corner then
            self.resizing         = true
            self.dragging         = false
            self.lmbDownOnHUD     = false  -- corner resize, not a row-click candidate
            self.resizeStartX     = posX
            self.resizeStartY     = posY
            self.resizeStartScale = self.scale
            csLog("HUD resize started — corner=" .. corner)
            -- Fall through so resize block below runs immediately
        elseif self:isPointerOverHUD(posX, posY) then
            self.dragging    = true
            self.resizing    = false
            self.lmbDownOnHUD = true   -- may become a row-select if released without moving
            self.dragOffsetX = posX - self.panelX
            self.dragOffsetY = posY - self.panelY
            csLog(string.format("HUD drag started — pos=%.3f,%.3f", self.panelX, self.panelY))
            -- Fall through so drag block below runs immediately
        end
    end

    -- ── LMB up: end drag/resize OR fire row selection if it was a clean click ──
    if isUp and button == 1 then
        local wasDragging  = self.dragging
        local wasResizing  = self.resizing
        local clickIntent  = self.lmbDownOnHUD

        self.dragging     = false
        self.resizing     = false
        self.lmbDownOnHUD = false

        if wasDragging or wasResizing then
            self:clampPosition()
            if self.manager ~= nil and self.manager.settings ~= nil then
                self.manager.settings.hudPanelX = self.panelX
                self.manager.settings.hudPanelY = self.panelY
                self.manager.settings.hudScale  = self.scale
            end
            csLog(string.format("HUD repositioned to %.3f,%.3f scale=%.2f",
                self.panelX, self.panelY, self.scale))
        elseif clickIntent then
            -- LMB pressed-and-released on HUD body without moving → row select
            self:selectRowAtPosition(posX, posY)
        end
        return
    end

    -- ── Mouse movement: continuous drag / resize ──────────
    -- Fires every frame while cursor is unlocked.
    -- Also runs on the isDown event (no early return above) for immediate response.
    if self.dragging then
        local s      = self.scale
        local panelW = HUDOverlay.PANEL_W * s
        local panelH = self:calcPanelHeight(math.max(1, math.min(#self.displayRows, HUDOverlay.MAX_FIELDS)))
        self.panelX  = math.max(0.01, math.min(1.0 - panelW - 0.01, posX - self.dragOffsetX))
        self.panelY  = math.max(panelH + 0.01, math.min(0.99, posY - self.dragOffsetY))
    end

    if self.resizing then
        local px, py, pw, ph = self:getHUDRect()
        local cx = px + pw * 0.5
        local cy = py + ph * 0.5
        local startDist = math.sqrt((self.resizeStartX - cx)^2 + (self.resizeStartY - cy)^2)
        local currDist  = math.sqrt((posX - cx)^2 + (posY - cy)^2)
        local delta     = (currDist - startDist) * 2.5
        self.scale = math.max(HUDOverlay.MIN_SCALE, math.min(HUDOverlay.MAX_SCALE, self.resizeStartScale + delta))
        self:clampPosition()
    end

    -- Hover detection for corner handles (movement events only)
    if not self.dragging and not self.resizing then
        self.hoverCorner = self:hitTestCorner(posX, posY)
    end
end

-- ============================================================
-- REBUILD FORECAST
-- Requests a 5-day moisture projection from WeatherIntegration
-- for the currently selected field.
-- ============================================================
function HUDOverlay:rebuildForecast()
    if self.selectedFieldId == nil then
        self.forecastCache = nil
        return
    end
    if self.manager == nil or self.manager.weatherIntegration == nil then return end

    -- Request FORECAST_COLS-1 projected days: the first display column is "Now"
    -- (current moisture from soilSystem), so we only need 4 future projections
    -- to fill the remaining 4 columns.
    local projections = self.manager.weatherIntegration:getMoistureForecast(
        self.selectedFieldId, HUDOverlay.FORECAST_COLS - 1)

    self.forecastCache = {
        fieldId     = self.selectedFieldId,
        projections = projections,
    }
end

-- ============================================================
-- CALC PANEL HEIGHT (pure function, used in update + draw)
-- ============================================================
function HUDOverlay:calcPanelHeight(numRows)
    local s = self.scale
    return HUDOverlay.HEADER_H * s
        + (numRows * HUDOverlay.ROW_H * s)
        + HUDOverlay.PADDING * 2 * s
end

-- ============================================================
-- DRAW  (called every frame by CropStressManager:draw())
-- ============================================================
function HUDOverlay:draw()
    if not self.isInitialized or not self.isVisible then return end
    if g_currentMission == nil then return end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end
    if self.fillOverlay == nil then return end

    local s        = self.scale
    local panelW   = HUDOverlay.PANEL_W * s
    local rowH     = HUDOverlay.ROW_H * s
    local headerH  = HUDOverlay.HEADER_H * s
    local pad      = HUDOverlay.PADDING * s
    local numRows  = math.min(#self.displayRows, HUDOverlay.MAX_FIELDS)
    local showEmpty = (numRows == 0)
    local panelH   = self:calcPanelHeight(showEmpty and 1 or numRows)
    local px       = self.panelX
    local py       = self.panelY

    -- ── Debug: log vehicle detection state once every 5s (only when debug mode on) ──
    if self.manager ~= nil and self.manager.debugMode then
        self._vehicleDebugTimer = (self._vehicleDebugTimer or 0) + 0.016
        if self._vehicleDebugTimer >= 5.0 then
            self._vehicleDebugTimer = 0
            local mission = g_currentMission
            local ctv = mission and mission.controlledVehicle
            local ctxName = "?"
            if g_inputBinding ~= nil then
                local ok, ctx = pcall(function()
                    if type(g_inputBinding.getContextName) == "function" then return g_inputBinding:getContextName() end
                    return g_inputBinding.currentContextName or g_inputBinding.contextName
                end)
                if ok and ctx ~= nil then ctxName = tostring(ctx) end
            end
            csLog(string.format(
                "VehicleDetect: controlledVehicle=%s g_localPlayer=%s inputCtx=%s inVehicle=%s",
                tostring(ctv ~= nil), tostring(g_localPlayer ~= nil), ctxName,
                tostring(self:isPlayerInVehicle())
            ))
        end
    end

    -- Forecast strip BELOW the main panel
    if self.forecastCache ~= nil then
        self:drawForecastStrip(px, py - HUDOverlay.FORECAST_H * s - pad)
    end

    -- Drop shadow
    local shadowOff = 0.002 * s
    setOverlayColor(self.fillOverlay, 0, 0, 0, 0.35)
    renderOverlay(self.fillOverlay, px + shadowOff, py - shadowOff, panelW, panelH)

    -- Background panel
    setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_BG))
    renderOverlay(self.fillOverlay, px, py, panelW, panelH)

    -- Permanent subtle border
    local bwN = 0.001
    setOverlayColor(self.fillOverlay, 0.30, 0.40, 0.55, 0.50)
    renderOverlay(self.fillOverlay, px,             py + panelH - bwN, panelW, bwN)
    renderOverlay(self.fillOverlay, px,             py,                panelW, bwN)
    renderOverlay(self.fillOverlay, px,             py,                bwN, panelH)
    renderOverlay(self.fillOverlay, px + panelW - bwN, py,            bwN, panelH)

    -- Header bar
    setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_HEADER_BG))
    renderOverlay(self.fillOverlay, px, py + panelH - headerH, panelW, headerH)

    -- Header text + key hint
    setTextColor(unpack(HUDOverlay.COLOR_HEADER_TEXT))
    setTextBold(true)
    renderText(px + pad, py + panelH - headerH + pad, HUDOverlay.HEADER_TEXT_SIZE * s,
        (g_i18n ~= nil and g_i18n:getText("cs_hud_title")) or "CROP MOISTURE")
    renderText(px + panelW - 0.028 * s, py + panelH - headerH + pad, HUDOverlay.TEXT_SIZE * s, "[M]")
    setTextBold(false)

    -- Edit mode: pulsing border + corner resize handles
    if self.editMode then
        local pulse = 0.5 + 0.5 * math.sin(self.animTimer * 4)
        local bw = 0.002
        setOverlayColor(self.fillOverlay, 0.30, 0.65, 1.00, 0.4 + 0.4 * pulse)
        renderOverlay(self.fillOverlay, px,             py + panelH - bw, panelW, bw)
        renderOverlay(self.fillOverlay, px,             py,               panelW, bw)
        renderOverlay(self.fillOverlay, px,             py,               bw, panelH)
        renderOverlay(self.fillOverlay, px + panelW - bw, py,            bw, panelH)

        local handles = self:getResizeHandleRects()
        for key, rect in pairs(handles) do
            local hc = (self.hoverCorner == key)
                and {0.50, 0.80, 1.00, 0.90}
                or  {0.30, 0.55, 0.90, 0.65}
            setOverlayColor(self.fillOverlay, unpack(hc))
            renderOverlay(self.fillOverlay, rect.x, rect.y, rect.w, rect.h)
        end
    end

    -- Empty state
    if showEmpty then
        setTextColor(unpack(HUDOverlay.COLOR_DIM_TEXT))
        renderText(px + pad, py + pad + (rowH - HUDOverlay.TEXT_SIZE * s) * 0.5,
            HUDOverlay.TEXT_SIZE * s,
            (g_i18n ~= nil and g_i18n:getText("cs_hud_no_crop")) or "No field data")
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(1, 1, 1, 1)
        return
    end

    -- Field rows
    for i = 1, numRows do
        local row  = self.displayRows[i]
        local rowY = py + panelH - headerH - (i * rowH)

        if row.fieldId == self.selectedFieldId then
            setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_ROW_HOVER))
            renderOverlay(self.fillOverlay, px, rowY, panelW, rowH)
            setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_SELECTED_BDR))
            renderOverlay(self.fillOverlay, px, rowY, HUDOverlay.SELECTED_BORDER_W * s, rowH)
        end

        self:drawFieldRow(row, px, rowY, s)
    end

    -- Footer hint
    if self.editMode then
        setTextColor(0.60, 0.80, 1.00, 0.85)
        local editHint = self:isPlayerInVehicle()
            and "LMB drag  |  Corners scale  |  Shift+H to exit"
            or  "LMB drag/select  |  Corners scale  |  RMB to exit"
        renderText(px + pad, py + pad, HUDOverlay.TEXT_SIZE * s * 0.85, editHint)
    elseif self.selectedFieldId == nil then
        setTextColor(unpack(HUDOverlay.COLOR_DIM_TEXT))
        local hintText
        if self:isPlayerInVehicle() then
            hintText = "Click row to select • Shift+H = move"
        else
            hintText = (g_i18n ~= nil and g_i18n:getText("cs_hud_click_forecast")) or "RMB = select row / edit mode"
        end
        renderText(px + pad, py + pad, 0.010 * s, hintText)
    end

    -- Scroll indicator (show when there are more fields than visible)
    self:drawScrollIndicator(px, py, s)

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

-- ============================================================
-- DRAW FIELD ROW
-- ============================================================
function HUDOverlay:drawFieldRow(row, px, rowY, s)
    s = s or self.scale
    local moisture = row.moisture or 0
    local stress   = row.stress   or 0
    local barW     = HUDOverlay.BAR_W * s
    local barH     = HUDOverlay.BAR_H * s
    local pad      = HUDOverlay.PADDING * s
    local panelW   = HUDOverlay.PANEL_W * s
    local rowH     = HUDOverlay.ROW_H * s

    local cropLabel = row.cropName or "?"
    local stageStr  = row.growthStage and (" S" .. tostring(row.growthStage)) or ""
    local label     = string.format("F%d · %s%s", row.fieldId, cropLabel, stageStr)
    local stressStr = stress > 0.15 and " !" or ""

    setTextColor(unpack(HUDOverlay.COLOR_TEXT))
    renderText(px + pad + HUDOverlay.SELECTED_BORDER_W * s, rowY + pad,
        HUDOverlay.TEXT_SIZE * s, label .. stressStr)

    local barX = px + panelW - barW - pad * 2
    local barY = rowY + (rowH - barH) * 0.5
    setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_BAR_BG))
    renderOverlay(self.fillOverlay, barX, barY, barW, barH)

    setOverlayColor(self.fillOverlay, unpack(self:getMoistureColor(moisture)))
    renderOverlay(self.fillOverlay, barX, barY, barW * moisture, barH)

    setTextColor(unpack(HUDOverlay.COLOR_TEXT))
    renderText(barX + barW + pad, rowY + pad, HUDOverlay.TEXT_SIZE * s,
        string.format("%d%%", math.floor(moisture * 100 + 0.5)))
end

-- ============================================================
-- DRAW FORECAST STRIP
-- Renders a 5-column bar-chart below the main panel.
--
-- Explicit section layout (bottom → top), all relative to strip py:
--   py + 0                                      bottom edge
--   py + PADDING                                pct % text baseline
--   py + PADDING + FORECAST_ROW_H               bar area bottom
--   py + PADDING + FORECAST_ROW_H + BAR_AREA    bar area top
--   py + PADDING + FORECAST_ROW_H + BAR_AREA + PADDING  day labels
--   py + FORECAST_H - FORECAST_HEADER_H + PADDING       header text
--   py + FORECAST_H                             top edge
-- ============================================================
function HUDOverlay:drawForecastStrip(px, py)
    if self.forecastCache == nil then return end

    local s           = self.scale
    local projections = self.forecastCache.projections
    local fieldId     = self.forecastCache.fieldId
    local fH          = HUDOverlay.FORECAST_H * s
    local pad         = HUDOverlay.PADDING * s
    local panelW      = HUDOverlay.PANEL_W * s
    local textSz      = HUDOverlay.FORECAST_TEXT_SZ * s

    -- Drop shadow
    local shadowOff = 0.002 * s
    setOverlayColor(self.fillOverlay, 0, 0, 0, 0.30)
    renderOverlay(self.fillOverlay, px + shadowOff, py - shadowOff, panelW, fH)

    -- Background
    setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_FORECAST_BG))
    renderOverlay(self.fillOverlay, px, py, panelW, fH)

    -- Subtle border
    local bwN = 0.001
    setOverlayColor(self.fillOverlay, 0.25, 0.35, 0.50, 0.45)
    renderOverlay(self.fillOverlay, px,             py + fH - bwN, panelW, bwN)
    renderOverlay(self.fillOverlay, px,             py,            panelW, bwN)
    renderOverlay(self.fillOverlay, px,             py,            bwN, fH)
    renderOverlay(self.fillOverlay, px + panelW - bwN, py,        bwN, fH)

    -- Header text (top section, clearly separated from column labels)
    setTextColor(unpack(HUDOverlay.COLOR_HEADER_TEXT))
    setTextBold(true)
    renderText(px + pad, py + fH - HUDOverlay.FORECAST_HEADER_H * s + pad, textSz,
        string.format("%s — F%d",
            (g_i18n ~= nil and g_i18n:getText("cs_hud_forecast")) or "5-Day Forecast",
            fieldId))
    setTextBold(false)

    -- Explicit section anchors (bottom → top): pct | bars | labels | header
    local pctBaseY = py + pad
    local barBaseY = pctBaseY + HUDOverlay.FORECAST_ROW_H * s
    local barAreaH = HUDOverlay.FORECAST_BAR_AREA * s
    local labelY   = barBaseY + barAreaH + pad

    local colLabels = {"Now", "D+1", "D+2", "D+3", "D+4"}
    local currentMoisture = 0
    if self.manager ~= nil and self.manager.soilSystem ~= nil then
        currentMoisture = self.manager.soilSystem:getMoisture(fieldId) or 0
    end
    local displayVals = {
        currentMoisture,
        projections[1] or currentMoisture,
        projections[2] or currentMoisture,
        projections[3] or currentMoisture,
        projections[4] or currentMoisture,
    }
    local colGap    = (panelW - pad * 2) / HUDOverlay.FORECAST_COLS
    local colStartX = px + pad

    for i = 1, HUDOverlay.FORECAST_COLS do
        local val = displayVals[i] or 0
        local cx  = colStartX + (i - 1) * colGap + pad
        local bw  = HUDOverlay.FORECAST_COL_W * s - pad

        setTextColor(unpack(HUDOverlay.COLOR_DIM_TEXT))
        renderText(cx, labelY, textSz, colLabels[i] or "?")

        setOverlayColor(self.fillOverlay, unpack(HUDOverlay.COLOR_BAR_BG))
        renderOverlay(self.fillOverlay, cx, barBaseY, bw, barAreaH)

        setOverlayColor(self.fillOverlay, unpack(self:getMoistureColor(val)))
        renderOverlay(self.fillOverlay, cx, barBaseY, bw, barAreaH * val)

        setTextColor(unpack(HUDOverlay.COLOR_TEXT))
        renderText(cx, pctBaseY, textSz, string.format("%d%%", math.floor(val * 100 + 0.5)))
    end
end

-- ============================================================
-- MOISTURE COLOR
-- ============================================================
function HUDOverlay:getMoistureColor(moisture)
    -- Thresholds match CropConsultant severity bands exactly so color = alert level
    if moisture >= CropConsultant.SEVERITY_WARNING_MAX then return HUDOverlay.COLOR_HEALTHY   -- >= 0.40 green
    elseif moisture >= CropConsultant.SEVERITY_CRITICAL_MAX then return HUDOverlay.COLOR_WARNING  -- >= 0.25 yellow
    else return HUDOverlay.COLOR_CRITICAL end  -- < 0.25 red
end

function HUDOverlay:resolveCropName(field)
    if field == nil then return "?" end

    local ft = nil

    -- FS25 confirmed API: field.fieldState.fruitTypeIndex
    -- (field.currentFruitTypeIndex, field:getFruitType(), field.fruitType do NOT exist in FS25)
    local fieldState = field.fieldState
    local fti = fieldState and fieldState.fruitTypeIndex
    if fti ~= nil and fti > 0 and g_fruitTypeManager ~= nil then
        ft = g_fruitTypeManager:getFruitTypeByIndex(fti)
    end

    if ft ~= nil and ft.name ~= nil then
        local name = ft.name:lower()
        if name == "grass" or name == "drygrass" or name == "weed"
        or name == "stone" or name == "meadow" then
            return "Fallow"
        end
        return ft.name:sub(1,1):upper() .. ft.name:sub(2):lower()
    end
    return "Fallow"
end

function HUDOverlay:rebuildDisplayRows()
    self.displayRows = {}
    if self.manager == nil or self.manager.soilSystem == nil then return end

    local sortedFields = self.manager.soilSystem:getFieldsSortedByMoisture()
    if sortedFields == nil then return end

    -- Use the manager's pre-built fieldId→field map (O(1) per lookup, correct on all maps).
    -- getFieldByIndex(n) returns fields[n] by array position, NOT the field with fieldId==n
    -- — silently wrong on custom maps, renumbered fields, or non-sequential farmlands.
    local fieldById = (self.manager ~= nil) and self.manager.fieldById or {}

    -- Get ownership helpers from the manager
    local getLocalFarmId = self.manager.getLocalFarmId
    local isFarmlandOwnedByFarm = self.manager.isFarmlandOwnedByFarm
    if getLocalFarmId == nil or isFarmlandOwnedByFarm == nil then
        csLog("HUDOverlay: ERROR - ownership helpers not found on manager!")
        return
    end
    local localFarmId = getLocalFarmId()

    -- Filter and collect all valid fields
    local ownedFields = {}
    for _, entry in ipairs(sortedFields) do
        if isFarmlandOwnedByFarm(entry.fieldId, localFarmId) then
            table.insert(ownedFields, entry)
        end
    end

    -- If no owned fields found, fall back to showing all tracked fields
    local fieldsToDisplay = #ownedFields > 0 and ownedFields or sortedFields
    if #ownedFields == 0 and #sortedFields > 0 then
        csLog("HUDOverlay: No owned fields found, showing all tracked fields as a fallback.")
    end

    local allValidFields = {}
    for _, entry in ipairs(fieldsToDisplay) do
        local stress      = 0
        local cropName    = nil
        local growthStage = nil

        if self.manager.stressModifier ~= nil then
            stress = self.manager.stressModifier:getStress(entry.fieldId)
        end

        local field = fieldById[entry.fieldId]
        if field ~= nil then
            -- FS25-native crop resolution: getFieldState() → fruitTypeIndex
            cropName = self:resolveCropName(field)

            -- Growth stage (FS25: field.fieldState.growthState — confirmed from rtmnet/sdk)
            growthStage = field.fieldState and field.fieldState.growthState
        end

        -- Only show crops tracked for stress (fallow, greenhouse, carrots etc. = irrelevant noise)
        -- cropName is title-cased for display ("Wheat"); CROP_WINDOWS keys are lowercase
        if cropName ~= nil and CropStressModifier.CROP_WINDOWS[cropName:lower()] ~= nil then
            table.insert(allValidFields, {
                fieldId     = entry.fieldId,
                moisture    = entry.moisture,
                stress      = stress,
                cropName    = cropName,
                growthStage = growthStage,
            })
        end
    end

    -- Apply scrolling: show only visible fields based on scroll offset
    local totalFields = #allValidFields
    local maxVisible = self.maxVisibleFields
    
    -- Ensure scroll offset is valid
    if self.scrollOffset < 0 then self.scrollOffset = 0 end
    if self.scrollOffset > math.max(0, totalFields - maxVisible) then
        self.scrollOffset = math.max(0, totalFields - maxVisible)
    end

    -- Copy visible fields to displayRows
    local startIndex = self.scrollOffset + 1
    local endIndex = math.min(startIndex + maxVisible - 1, totalFields)
    
    for i = startIndex, endIndex do
        table.insert(self.displayRows, allValidFields[i])
    end

    -- If selected field is no longer in the display list, mark forecast dirty
    if self.selectedFieldId ~= nil then
        local found = false
        for _, row in ipairs(self.displayRows) do
            if row.fieldId == self.selectedFieldId then found = true; break end
        end
        if not found then
            -- Reselect top (driest) field if previous selected fell off the list
            if #self.displayRows > 0 then
                local newId = self.displayRows[1].fieldId
                if self.selectedFieldId ~= newId then
                    self.selectedFieldId = newId
                    self.forecastDirty   = true
                end
            else
                self.selectedFieldId = nil
                self.forecastCache   = nil
            end
        end
    end
end

-- ============================================================
-- TOGGLE (bound to CS_TOGGLE_HUD)
-- ============================================================
function HUDOverlay:toggle()
    self.isVisible      = not self.isVisible
    self.autoShowActive = false
    self.autoHideTimer  = 0

    if self.isVisible then
        if not self.firstRunShown then
            self.firstRunShown = true
        end

        -- Rebuild display rows immediately so auto-select below has data.
        -- (update() normally rebuilds rows, but it runs next frame — after toggle() returns.)
        self:rebuildDisplayRows()

        -- FIX: soilSystem may not have its moisture table yet on first open.
        -- Build stub rows from fieldById so the panel is never blank.
        if #self.displayRows == 0 then
            local fieldById = (self.manager ~= nil) and self.manager.fieldById or {}
            local count = 0
            for fid, field in pairs(fieldById) do
                if count >= HUDOverlay.MAX_FIELDS then break end
                local cn = self:resolveCropName(field)
                if cn ~= nil and CropStressModifier.CROP_WINDOWS[cn:lower()] ~= nil then
                    local stress = 0
                    if self.manager ~= nil and self.manager.stressModifier ~= nil then
                        stress = self.manager.stressModifier:getStress(fid) or 0
                    end
                    table.insert(self.displayRows, {
                        fieldId     = fid,
                        moisture    = 0,
                        stress      = stress,
                        cropName    = cn,
                        growthStage = field.fieldState and field.fieldState.growthState,
                    })
                    count = count + 1
                end
            end
        end
        
        -- Auto-select driest field when opening
        if self.selectedFieldId == nil and #self.displayRows > 0 then
            self.selectedFieldId = self.displayRows[1].fieldId
            self.forecastDirty   = true
        end
    else
        -- Exit edit mode when hiding — orange border should not persist invisibly
        if self.editMode then
            self.editMode = false
            self.dragging = false
            -- Persist position so the drag position is saved even if they hid mid-edit
            if self.manager ~= nil and self.manager.settings ~= nil then
                self.manager.settings.hudPanelX = self.panelX
                self.manager.settings.hudPanelY = self.panelY
            end
        end
    end

    csLog("HUD toggled: " .. tostring(self.isVisible))
end

-- ============================================================
-- EVENT: CS_CRITICAL_THRESHOLD
-- ============================================================
function HUDOverlay:onCriticalThreshold(data)
    if not self.isInitialized then return end

    if not self.isVisible then
        self.isVisible      = true
        self.autoShowActive = true
        self.autoHideTimer  = 120

        -- Auto-select the critical field
        if data ~= nil and data.fieldId ~= nil then
            self.selectedFieldId = data.fieldId
            self.forecastDirty   = true
        end
    end

    -- First-run tooltip (once)
    if not self.firstRunShown then
        self.firstRunShown = true
        if g_currentMission ~= nil then
            local msg = (g_i18n ~= nil and g_i18n:getText("cs_hud_first_run"))
                or "Crop Moisture Monitor active. Press Shift+M to toggle the HUD."
            g_currentMission:showBlinkingWarning(msg, 6000)
        end
    end
end

-- ============================================================
-- EVENT: CS_MOISTURE_UPDATED
-- Marks forecast dirty so it gets recalculated next frame.
-- ============================================================
function HUDOverlay:onMoistureUpdated(data)
    if data ~= nil and data.fieldId == self.selectedFieldId then
        self.forecastDirty = true
    end
end

-- ============================================================
-- DRAW SCROLL INDICATOR
-- Shows when there are more fields than can be displayed
-- ============================================================
function HUDOverlay:drawScrollIndicator(px, py, s)
    -- Get total field count from manager
    local totalFields = 0
    if self.manager ~= nil and self.manager.soilSystem ~= nil then
        local sortedFields = self.manager.soilSystem:getFieldsSortedByMoisture()
        if sortedFields ~= nil then
            -- Count valid fields (same logic as rebuildDisplayRows)
            local fieldById = (self.manager ~= nil) and self.manager.fieldById or {}
            for _, entry in ipairs(sortedFields) do
                local field = fieldById[entry.fieldId]
                if field ~= nil then
                    local cropName = self:resolveCropName(field)
                    if cropName ~= nil and CropStressModifier.CROP_WINDOWS[cropName:lower()] ~= nil then
                        totalFields = totalFields + 1
                    end
                end
            end
        end
    end
    
    -- Only show scroll indicator if there are more fields than visible
    if totalFields <= self.maxVisibleFields then return end
    
    local pad = HUDOverlay.PADDING * s
    local panelW = HUDOverlay.PANEL_W * s
    local numRows = math.min(#self.displayRows, HUDOverlay.MAX_FIELDS)
    local panelH = self:calcPanelHeight(numRows)
    local headerH = HUDOverlay.HEADER_H * s
    
    -- Draw scroll indicator on the right side of the panel
    local indicatorX = px + panelW - 0.012 * s
    local indicatorY = py + pad
    local indicatorH = panelH - headerH - pad * 2
    
    -- Background of scroll indicator
    setOverlayColor(self.fillOverlay, 0.20, 0.20, 0.20, 0.60)
    renderOverlay(self.fillOverlay, indicatorX, indicatorY, 0.008 * s, indicatorH)
    
    -- Scroll thumb
    local thumbHeight = math.max(0.010 * s, indicatorH * (self.maxVisibleFields / totalFields))
    local thumbPosition = indicatorY + (indicatorH - thumbHeight) * (self.scrollOffset / math.max(1, totalFields - self.maxVisibleFields))
    
    setOverlayColor(self.fillOverlay, 0.40, 0.80, 1.00, 0.80)
    renderOverlay(self.fillOverlay, indicatorX, thumbPosition, 0.008 * s, thumbHeight)
    
    -- Scroll hint text
    setTextColor(0.60, 0.80, 1.00, 0.85)
    renderText(px + pad, py + pad, 0.008 * s, "Scroll: Mouse Wheel")
end

-- ============================================================
-- CLEANUP
-- ============================================================
function HUDOverlay:delete()
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.unsubscribeAll(self)
    end
    if self.fillOverlay ~= nil and delete ~= nil then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.forecastCache   = nil
    self.selectedFieldId = nil
    self.isInitialized   = false
end

