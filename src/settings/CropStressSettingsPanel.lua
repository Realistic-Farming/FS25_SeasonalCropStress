-- ============================================================
-- CropStressSettingsPanel.lua
-- Fully custom-drawn settings panel. No XML — pure overlay.
-- Open/close: SHIFT+S
-- Landing → 2 category tiles → settings rows + Admin page.
-- Modeled on FS25_SoilFertilizer SoilSettingsPanel.lua pattern.
-- ============================================================

CropStressSettingsPanel = CropStressSettingsPanel or {}
local CropStressSettingsPanel_mt = Class(CropStressSettingsPanel)

-- ── Panel geometry (normalized, Y=0 at bottom) ─────────────
local PW   = 0.58
local PH   = 0.72
local PX   = (1 - PW) / 2
local PY   = (1 - PH) / 2
local TB_H = 0.052
local IB_H = 0.046
local PAD  = 0.018

local CX     = PX + PAD
local CW     = PW - PAD * 2
local CY_BOT = PY + IB_H + 0.010
local CY_TOP = PY + PH - TB_H - 0.008
local CH     = CY_TOP - CY_BOT

-- 2 category cards side by side
local CARD_GAP = 0.015
local CARD_W   = (CW - CARD_GAP) / 2
local CARD_H   = 0.30
local CARD_Y   = CY_BOT + (CH - CARD_H) / 2

-- Settings rows
local ROW_H      = 0.036
local SEC_H      = 0.026
local TOGGLE_W   = 0.048
local TOGGLE_H   = 0.026
local TOGGLE_GAP = 0.004
local MULTI_W    = 0.175
local ARROW_W    = 0.022

-- Text sizes
local TS_TITLE = 0.018
local TS_BODY  = 0.015
local TS_SMALL = 0.013
local TS_TINY  = 0.011

-- ── Colors (water/blue theme) ────────────────────────────────
local C = {
    bg          = {0.04, 0.06, 0.10, 0.97},
    title_bg    = {0.06, 0.08, 0.13, 1.0},
    info_bg     = {0.03, 0.05, 0.08, 1.0},
    border      = {0.20, 0.50, 0.85, 0.45},
    shadow      = {0.00, 0.00, 0.00, 0.45},
    divider     = {0.18, 0.25, 0.35, 0.55},
    row_alt     = {1.00, 1.00, 1.00, 0.025},
    row_hover   = {0.22, 0.52, 0.88, 0.10},
    blue        = {0.28, 0.65, 0.95, 1.0},
    blue_dim    = {0.18, 0.40, 0.65, 1.0},
    white       = {1.00, 1.00, 1.00, 1.0},
    dim         = {0.55, 0.55, 0.60, 1.0},
    hint        = {0.38, 0.38, 0.46, 1.0},
    on_bg       = {0.18, 0.55, 0.88, 1.0},
    off_bg      = {0.12, 0.14, 0.18, 1.0},
    on_text     = {0.00, 0.00, 0.00, 1.0},
    off_text    = {0.45, 0.46, 0.52, 1.0},
    card_hover  = {1.00, 1.00, 1.00, 0.04},
    sim_accent  = {0.28, 0.65, 0.95, 1.0},
    disp_accent = {0.35, 0.88, 0.55, 1.0},
    close_hover = {0.88, 0.25, 0.25, 0.80},
    back_hover  = {0.22, 0.52, 0.88, 0.20},
    info_admin  = {0.28, 0.75, 0.95, 1.0},
    info_no_adm = {0.88, 0.60, 0.18, 1.0},
    info_mode   = {0.55, 0.55, 0.62, 1.0},
    lock_text   = {0.88, 0.60, 0.18, 1.0},
}

local ADMIN_ACCENT = {0.88, 0.28, 0.22}

-- ── Category definitions ─────────────────────────────────────
local CATEGORIES = {
    {
        id     = "simulation",
        label  = "Simulation",
        desc   = "Difficulty, evaporation\nand yield loss settings",
        accent = C.sim_accent,
        sections = {
            { header = "Core Systems",       items = { "enabled", "difficulty", "evapotranspiration" } },
            { header = "Yield & Thresholds", items = { "maxYieldLoss", "criticalThreshold" } },
            { header = "Finance",            items = { "irrigationCosts", "finiteWater" } },
        },
    },
    {
        id     = "display",
        label  = "Display & Alerts",
        desc   = "HUD visibility, alert\nfrequency and debug mode",
        accent = C.disp_accent,
        sections = {
            { header = "HUD",    items = { "hudVisible" } },
            { header = "Alerts", items = { "alertsEnabled", "alertCooldown" } },
            { header = "Debug",  items = { "debugMode" } },
            { header = "Release Gate", items = { "experimentalSystems" } },
        },
    },
}

-- ── Per-setting metadata ──────────────────────────────────────
-- stype: "bool" | "multi"
-- localOnly: true → apply client-side, no admin required, no network
local SETTINGS_META = {
    enabled = {
        label = "Mod Enabled",
        desc  = "Activate or deactivate the entire crop stress simulation",
        stype = "bool",
    },
    difficulty = {
        label = "Difficulty",
        desc  = "How aggressively crops accumulate water stress",
        stype = "multi",
        opts  = { "Easy", "Normal", "Hard" },
        vals  = { "easy", "normal", "hard" },
    },
    evapotranspiration = {
        label = "Evaporation Rate",
        desc  = "How quickly soil moisture evaporates each hour",
        stype = "multi",
        opts  = { "Slow", "Normal", "Fast" },
        vals  = { "slow", "normal", "fast" },
    },
    maxYieldLoss = {
        label = "Max Yield Loss",
        desc  = "Maximum harvest reduction from accumulated crop stress",
        stype = "multi",
        opts  = { "30%", "45%", "60%", "75%" },
        vals  = { 0.30, 0.45, 0.60, 0.75 },
    },
    criticalThreshold = {
        label = "Critical Threshold",
        desc  = "Moisture level that triggers stress accumulation",
        stype = "multi",
        opts  = { "15%", "25%", "35%" },
        vals  = { 0.15, 0.25, 0.35 },
    },
    irrigationCosts = {
        label = "Irrigation Costs",
        desc  = "Charge hourly running costs for active irrigation systems",
        stype = "bool",
    },
    finiteWater = {
        label = "Finite Irrigation Water",
        desc  = "Pumps carry a finite store in irrigation-hours, refilled by rain",
        stype = "bool",
    },
    hudVisible = {
        label     = "Show Moisture HUD",
        desc      = "Display the soil moisture overlay panel (client-local)",
        stype     = "bool",
        localOnly = true,
    },
    alertsEnabled = {
        label = "Crop Alerts",
        desc  = "Show blinking warnings when fields reach critical moisture",
        stype = "bool",
    },
    alertCooldown = {
        label = "Alert Cooldown",
        desc  = "Minimum in-game hours between repeated alerts for the same field",
        stype = "multi",
        opts  = { "4h", "8h", "12h", "24h" },
        vals  = { 4, 8, 12, 24 },
    },
    debugMode = {
        label = "Debug Mode",
        desc  = "Extra logging to game log for troubleshooting",
        stype = "bool",
    },
    experimentalSystems = {
        label = "Experimental Systems",
        desc  = "Enable experimental (not yet released) systems at your own risk",
        stype = "bool",
    },
}

-- ── Admin page ────────────────────────────────────────────────
local ADMIN_ROW_H = 0.033
local ADMIN_ACT_H = 0.030

local ADMIN_SECTIONS = {
    {
        header = "Mod Control",
        items  = {
            { label = "Mod Enabled", desc = "Toggle the entire simulation on/off", stype = "setting", id = "enabled"   },
            { label = "Debug Mode",  desc = "Verbose logging to game log",          stype = "setting", id = "debugMode" },
        },
    },
    {
        header = "Actions",
        items  = {
            { label = "Print System Status",  desc = "Show moisture and stress for all tracked fields",   stype = "action", id = "admin_status" },
            { label = "Simulate Heat Wave",   desc = "Run a 3-day extreme-heat / no-rain simulation",    stype = "action", id = "admin_heat"   },
            { label = "Reset All Settings",   desc = "Restore every setting to its default value",       stype = "danger", id = "admin_reset"  },
        },
    },
}

local PAGE_LANDING  = "landing"
local PAGE_CATEGORY = "category"
local PAGE_ADMIN    = "admin"

-- ── Constructor ───────────────────────────────────────────────
function CropStressSettingsPanel.new(manager)
    local self = setmetatable({}, CropStressSettingsPanel_mt)
    self.manager      = manager
    self.fillOverlay  = nil
    self.isVisible    = false
    self.page         = PAGE_LANDING
    self.activeCatIdx = nil
    self.mouseX       = 0
    self.mouseY       = 0
    self.initialized  = false
    self._clickRects  = {}
    self.popupVisible = false
    self.popupMsg     = nil
    self.popupLines   = nil
    self.popupScroll  = 0
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    local mod = g_modManager and g_modManager:getModByName((SeasonalCropStressModName or g_currentModName))
    self.modVersion = "v" .. (mod and mod.version or "?")
    return self
end

function CropStressSettingsPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    self.initialized = true
end

function CropStressSettingsPanel:delete()
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Visibility ────────────────────────────────────────────────
function CropStressSettingsPanel:open()
    if not self.initialized then self:initialize() end
    self.isVisible    = true
    self.page         = PAGE_LANDING
    self.activeCatIdx = nil
    self.popupVisible = false
    self.popupMsg     = nil
    self.popupLines   = nil
    self.popupScroll  = 0
    -- Freeze camera while panel is open (SoilFertilizer pattern)
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if getCamera and getRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            local ok2, rx, ry, rz = pcall(getRotation, cam)
            if ok2 then
                self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = rx, ry, rz
            end
        end
    end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
end

function CropStressSettingsPanel:close()
    self.isVisible = false
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
end

function CropStressSettingsPanel:toggle()
    if self.isVisible then self:close() else self:open() end
end

function CropStressSettingsPanel:isOpen()
    return self.isVisible
end

-- ── Per-frame update ─────────────────────────────────────────
function CropStressSettingsPanel:update(dt)
    if not self.isVisible then return end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    if self.savedCamRotX ~= nil and getCamera and setRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            pcall(setRotation, cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
        end
    end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        self:close()
    end
end

-- ── Setting access helpers ────────────────────────────────────
function CropStressSettingsPanel:getSettings()
    return self.manager and self.manager.settings
end

function CropStressSettingsPanel:getRawValue(id)
    local s = self:getSettings()
    return s and s[id]
end

function CropStressSettingsPanel:isAdmin()
    if g_currentMission == nil then return true end
    local isMP = g_currentMission.missionDynamicInfo and
                 g_currentMission.missionDynamicInfo.isMultiplayer
    if not isMP then return true end
    local user = g_currentMission.userManager and
                 g_currentMission.userManager:getUserByUserId(g_currentMission.playerUserId)
    return user and user:getIsAdmin() or false
end

function CropStressSettingsPanel:requestChange(id, value)
    local meta = SETTINGS_META[id]
    if meta == nil then return end
    local settings = self:getSettings()
    if settings == nil then return end

    if meta.localOnly then
        settings[id] = value
        if self.manager then self.manager:applySettings() end
        if g_currentMission and g_currentMission.missionInfo then
            settings:saveToXMLFile(g_currentMission.missionInfo)
        end
        return
    end

    if not self:isAdmin() then
        if g_currentMission and g_currentMission.hud and
           g_currentMission.hud.showBlinkingWarning then
            g_currentMission.hud:showBlinkingWarning("Only server admins can change this setting", 4000)
        end
        return
    end

    if g_server ~= nil then
        -- SCS-023 v2.3 (SDS 4): the host panel routes through the ONE
        -- authoritative settings owner (validates, re-applies, fires the
        -- finite-water mode edge). Broadcast to clients stays here.
        if self.manager ~= nil and type(self.manager.applyAuthoritativeSettingChange) == "function" then
            if not self.manager:applyAuthoritativeSettingChange(id, value, "panel") then
                return
            end
        else
            settings[id] = value
            settings:validateSettings()
            if self.manager then self.manager:applySettings() end
        end
        if CropStressSettingsSyncEvent ~= nil then
            g_server:broadcastEvent(CropStressSettingsSyncEvent.newSingle(id, value), false)
        end
    else
        if CropStressSettingsSyncEvent ~= nil then
            CropStressSettingsSyncEvent.sendSingleToServer(id, value)
        end
    end
end

-- ── Drawing helpers ───────────────────────────────────────────
function CropStressSettingsPanel:drawRect(x, y, w, h, col, alpha)
    if not self.fillOverlay then return end
    local a = alpha or col[4] or 1.0
    setOverlayColor(self.fillOverlay, col[1], col[2], col[3], a)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

function CropStressSettingsPanel:drawText(x, y, size, text, col, align, bold)
    setTextColor(col[1], col[2], col[3], col[4] or 1.0)
    setTextBold(bold == true)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, text)
end

function CropStressSettingsPanel:registerClick(id, x, y, w, h, data)
    table.insert(self._clickRects, { id = id, x = x, y = y, w = w, h = h, data = data })
end

function CropStressSettingsPanel:hitTest(rx, ry, rw, rh, mx, my)
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

-- ── Main draw ─────────────────────────────────────────────────
function CropStressSettingsPanel:draw()
    if not self.isVisible then return end
    if not self.initialized then return end
    if not g_currentMission then return end

    self._clickRects = {}

    self:drawRect(0, 0, 1, 1, C.shadow, 0.40)
    self:drawRect(PX + 0.004, PY - 0.004, PW, PH, C.shadow, 0.55)
    self:drawRect(PX, PY, PW, PH, C.bg)

    local bw = 0.0015
    self:drawRect(PX,           PY,           PW, bw, C.border)
    self:drawRect(PX,           PY + PH - bw, PW, bw, C.border)
    self:drawRect(PX,           PY,           bw, PH, C.border)
    self:drawRect(PX + PW - bw, PY,           bw, PH, C.border)

    self:drawTitleBar()
    self:drawInfoBar()

    if not self.popupVisible then
        if self.page == PAGE_LANDING then
            self:drawLandingPage()
        elseif self.page == PAGE_CATEGORY then
            self:drawCategoryPage()
        elseif self.page == PAGE_ADMIN then
            self:drawAdminPage()
        end
    end

    if self.popupVisible then self._clickRects = {} end
    self:drawPopupDialog()
end

-- ── Title bar ─────────────────────────────────────────────────
function CropStressSettingsPanel:drawTitleBar()
    local ty = PY + PH - TB_H
    self:drawRect(PX, ty, PW, TB_H, C.title_bg)

    local accColor = (self.page == PAGE_ADMIN) and ADMIN_ACCENT
                  or (self.activeCatIdx and CATEGORIES[self.activeCatIdx].accent)
                  or C.blue
    self:drawRect(PX, ty, 0.004, TB_H, accColor)

    local title = "SEASONAL CROP STRESS — SETTINGS"
    if self.page == PAGE_ADMIN then
        title = title .. "  /  ADMIN"
    elseif self.activeCatIdx then
        title = title .. "  /  " .. string.upper(CATEGORIES[self.activeCatIdx].label)
    end
    self:drawText(PX + 0.018, ty + TB_H * 0.32, TS_TITLE, title, C.white, RenderText.ALIGN_LEFT, true)
    self:drawText(PX + PW - 0.020, ty + TB_H * 0.32, TS_TINY, self.modVersion, C.hint, RenderText.ALIGN_RIGHT, false)

    local cbW = 0.038
    local cbH = TB_H * 0.60
    local cbX = PX + PW - cbW - 0.010
    local cbY = ty + (TB_H - cbH) / 2
    local closeHover = self:hitTest(cbX, cbY, cbW, cbH, self.mouseX, self.mouseY)
    self:drawRect(cbX, cbY, cbW, cbH, closeHover and C.close_hover or C.off_bg)
    self:drawText(cbX + cbW * 0.5, cbY + cbH * 0.18, TS_SMALL, "X", C.white, RenderText.ALIGN_CENTER, true)
    self:registerClick("close", cbX, cbY, cbW, cbH)
end

-- ── Info bar ──────────────────────────────────────────────────
function CropStressSettingsPanel:drawInfoBar()
    local iy = PY
    self:drawRect(PX, iy, PW, IB_H, C.info_bg)
    self:drawRect(PX, iy + IB_H - 0.001, PW, 0.001, C.divider)

    local isAdmin = self:isAdmin()
    local isMP    = g_currentMission and g_currentMission.missionDynamicInfo and
                    g_currentMission.missionDynamicInfo.isMultiplayer
    local adminColor = isAdmin and C.info_admin or C.info_no_adm
    local modeText   = isMP and "Multiplayer" or "Single Player"

    local textY = iy + IB_H * 0.25
    self:drawText(PX + PAD, textY, TS_SMALL, isAdmin and "Admin: YES" or "Admin: NO", adminColor, RenderText.ALIGN_LEFT, true)
    self:drawText(PX + PAD + 0.10, textY, TS_SMALL, "·  " .. modeText, C.info_mode, RenderText.ALIGN_LEFT, false)

    if self.page == PAGE_CATEGORY or self.page == PAGE_ADMIN then
        local bbW = 0.085
        local bbH = IB_H * 0.62
        local bbX = PX + PW - bbW - 0.020
        local bbY = iy + (IB_H - bbH) / 2
        local backHover = self:hitTest(bbX, bbY, bbW, bbH, self.mouseX, self.mouseY)
        self:drawRect(bbX, bbY, bbW, bbH, backHover and C.back_hover or C.off_bg)
        self:drawRect(bbX, bbY, 0.002, bbH, C.blue_dim)
        self:drawText(bbX + bbW * 0.5, bbY + bbH * 0.18, TS_SMALL, "< Back", C.white, RenderText.ALIGN_CENTER, false)
        self:registerClick("back", bbX, bbY, bbW, bbH)
    else
        self:drawText(PX + PW - PAD, textY, TS_SMALL, "SHIFT+S to close", C.hint, RenderText.ALIGN_RIGHT, false)
    end
end

-- ── Landing page ──────────────────────────────────────────────
function CropStressSettingsPanel:drawLandingPage()
    local headerY = CY_BOT + CH - 0.042
    self:drawText(PX + PW * 0.5, headerY, TS_SMALL,
        "Select a category to configure settings", C.hint, RenderText.ALIGN_CENTER, false)

    for i, cat in ipairs(CATEGORIES) do
        local cardX = CX + (i - 1) * (CARD_W + CARD_GAP)
        self:drawCategoryCard(cardX, CARD_Y, CARD_W, CARD_H, cat, i)
    end

    local btnW = 0.090
    local btnH = 0.032
    local btnX = CX + CW - btnW
    local btnY = CY_BOT + 0.005
    local btnHov = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(btnX, btnY, btnW, btnH,
        btnHov and {0.55, 0.08, 0.08, 0.95} or {0.22, 0.05, 0.05, 0.88})
    self:drawRect(btnX, btnY, 0.003, btnH, ADMIN_ACCENT)
    self:drawRect(btnX, btnY + btnH - 0.001, btnW, 0.001, ADMIN_ACCENT, 0.40)
    self:drawText(btnX + btnW * 0.5 + 0.002, btnY + btnH * 0.22, TS_SMALL,
        "ADMIN",
        btnHov and {1.0, 0.55, 0.55, 1.0} or {0.85, 0.35, 0.35, 1.0},
        RenderText.ALIGN_CENTER, true)
    self:registerClick("open_admin", btnX, btnY, btnW, btnH)
end

function CropStressSettingsPanel:drawCategoryCard(x, y, w, h, cat, idx)
    local hovered = self:hitTest(x, y, w, h, self.mouseX, self.mouseY)
    self:drawRect(x, y, w, h, C.bg)
    if hovered then self:drawRect(x, y, w, h, C.card_hover) end

    local bw = 0.0012
    self:drawRect(x,         y,         w, bw, cat.accent, 0.30)
    self:drawRect(x,         y + h - bw, w, bw, cat.accent, 0.30)
    self:drawRect(x,         y,         bw, h,  cat.accent, 0.30)
    self:drawRect(x + w - bw, y,        bw, h,  cat.accent, 0.30)
    self:drawRect(x, y + h - 0.018, w, 0.018, cat.accent, hovered and 0.85 or 0.65)

    local titleY = y + h - 0.018 - 0.044
    self:drawText(x + w * 0.5, titleY, TS_BODY, string.upper(cat.label), C.white, RenderText.ALIGN_CENTER, true)
    self:drawRect(x + 0.010, titleY - 0.006, w - 0.020, 0.001, C.divider)

    local count = 0
    for _, sec in ipairs(cat.sections) do count = count + #sec.items end

    local descY = titleY - 0.038
    local lines = {}
    for line in (cat.desc .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    for j, line in ipairs(lines) do
        self:drawText(x + w * 0.5, descY - (j - 1) * 0.022, TS_SMALL, line, C.dim, RenderText.ALIGN_CENTER, false)
    end

    self:drawText(x + w * 0.5, y + 0.040, TS_SMALL, count .. " settings", cat.accent, RenderText.ALIGN_CENTER, false)

    local btnW = w - 0.024
    local btnH = 0.028
    local btnX = x + 0.012
    local btnY = y + 0.008
    self:drawRect(btnX, btnY, btnW, btnH, hovered and cat.accent or C.off_bg, hovered and 0.20 or 1.0)
    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.18, TS_SMALL,
        hovered and "Open >>" or "Configure >>",
        hovered and cat.accent or C.hint, RenderText.ALIGN_CENTER, false)

    self:registerClick("cat_" .. idx, x, y, w, h)
end

-- ── Category page ──────────────────────────────────────────────
function CropStressSettingsPanel:drawCategoryPage()
    if not self.activeCatIdx then return end
    local cat = CATEGORIES[self.activeCatIdx]
    if not cat then return end

    local curY = CY_TOP
    local isAdmin = self:isAdmin()
    local rowIdx  = 0

    for _, sec in ipairs(cat.sections) do
        curY = curY - SEC_H
        if curY < CY_BOT then break end
        self:drawRect(CX, curY, CW, SEC_H, C.title_bg, 0.60)
        self:drawRect(CX, curY, 0.003, SEC_H, cat.accent)
        self:drawText(CX + 0.012, curY + SEC_H * 0.25, TS_SMALL,
            string.upper(sec.header), cat.accent, RenderText.ALIGN_LEFT, true)

        for _, settingId in ipairs(sec.items) do
            curY = curY - ROW_H
            if curY < CY_BOT then break end
            rowIdx = rowIdx + 1
            self:drawSettingRow(CX, curY, CW, settingId, rowIdx, isAdmin)
        end
        curY = curY - 0.005
    end

    self:drawRect(CX, CY_TOP, CW, 0.001, C.divider)
end

-- ── Admin page ─────────────────────────────────────────────────
function CropStressSettingsPanel:drawAdminPage()
    local isAdmin = self:isAdmin()
    local curY    = CY_TOP
    local rowIdx  = 0

    for _, sec in ipairs(ADMIN_SECTIONS) do
        curY = curY - SEC_H
        if curY < CY_BOT then break end
        self:drawRect(CX, curY, CW, SEC_H, C.title_bg, 0.60)
        self:drawRect(CX, curY, 0.003, SEC_H, ADMIN_ACCENT)
        self:drawText(CX + 0.012, curY + SEC_H * 0.25, TS_SMALL,
            string.upper(sec.header),
            {ADMIN_ACCENT[1], ADMIN_ACCENT[2], ADMIN_ACCENT[3], 1.0},
            RenderText.ALIGN_LEFT, true)

        for _, item in ipairs(sec.items) do
            local isAction = (item.stype == "action" or item.stype == "danger")
            local rh = isAction and ADMIN_ACT_H or ADMIN_ROW_H
            curY = curY - rh
            if curY < CY_BOT then break end
            rowIdx = rowIdx + 1
            if rowIdx % 2 == 0 then self:drawRect(CX, curY, CW, rh, C.row_alt) end

            if item.stype == "setting" then
                self:drawSettingRow(CX, curY, CW, item.id, rowIdx, isAdmin, rh)
            else
                local isDanger = (item.stype == "danger")
                local btnW = 0.130
                local btnH = rh * 0.72
                local btnX = CX + CW - btnW - 0.012
                local btnY = curY + (rh - btnH) * 0.5
                local hov  = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)

                self:drawText(CX + 0.008, curY + rh * 0.55, TS_BODY, item.label, C.white, RenderText.ALIGN_LEFT, true)
                self:drawText(CX + 0.008, curY + rh * 0.15, TS_TINY, item.desc, C.dim, RenderText.ALIGN_LEFT, false)

                local bgCol = isDanger
                    and (hov and {0.65, 0.10, 0.10, 0.95} or {0.30, 0.06, 0.06, 0.85})
                    or  (hov and {0.08, 0.28, 0.50, 0.95} or {0.05, 0.14, 0.22, 0.85})
                local acCol = isDanger and ADMIN_ACCENT or C.blue
                self:drawRect(btnX, btnY, btnW, btnH, bgCol)
                self:drawRect(btnX, btnY, 0.002, btnH, acCol)
                self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.20, TS_TINY,
                    isDanger and "!! " .. item.label or ">  " .. item.label,
                    hov and {1,1,1,1} or {0.75,0.75,0.75,1},
                    RenderText.ALIGN_CENTER, isDanger)
                self:registerClick("admin_action_" .. item.id, btnX, btnY, btnW, btnH,
                    { actionId = item.id })
            end
            self:drawRect(CX, curY, CW, 0.0005, C.divider, 0.35)
        end
        curY = curY - 0.005
    end

    self:drawRect(CX, CY_TOP, CW, 0.001, C.divider)
end

-- ── Setting row ────────────────────────────────────────────────
function CropStressSettingsPanel:drawSettingRow(x, y, w, settingId, rowIdx, isAdmin, rowH)
    local meta = SETTINGS_META[settingId]
    if meta == nil then return end
    local rh = rowH or ROW_H

    if rowIdx % 2 == 0 then self:drawRect(x, y, w, rh, C.row_alt) end
    if self:hitTest(x, y, w, rh, self.mouseX, self.mouseY) then
        self:drawRect(x, y, w, rh, C.row_hover)
    end

    local locked = not meta.localOnly and not isAdmin
    local labelColor = locked and C.lock_text or C.white
    local descColor  = locked and {C.lock_text[1]*0.7, C.lock_text[2]*0.7, C.lock_text[3]*0.7, 1} or C.dim

    if locked then
        self:drawRect(x, y, 0.003, rh, {0.88, 0.60, 0.18, 0.45})
    end

    local labelX = x + (locked and 0.010 or 0.008)
    self:drawText(labelX, y + rh * 0.52, TS_BODY, meta.label, labelColor, RenderText.ALIGN_LEFT, not locked)
    self:drawText(labelX, y + rh * 0.15, TS_TINY, meta.desc,  descColor,  RenderText.ALIGN_LEFT, false)

    local ctrlX = x + w - 0.012
    local ctrlY = y + (rh - TOGGLE_H) * 0.5

    if meta.stype == "bool" then
        self:drawToggleControl(ctrlX, ctrlY, settingId, locked)
    elseif meta.stype == "multi" then
        self:drawMultiControl(ctrlX, ctrlY, settingId, locked)
    end

    self:drawRect(x, y, w, 0.0005, C.divider, 0.35)
end

-- ── Toggle control [OFF] [ON] ──────────────────────────────────
function CropStressSettingsPanel:drawToggleControl(rightX, y, settingId, locked)
    local isOn  = self:getRawValue(settingId) == true
    local offX  = rightX - TOGGLE_W * 2 - TOGGLE_GAP
    local onX   = rightX - TOGGLE_W

    local offHover = not locked and self:hitTest(offX, y, TOGGLE_W, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(offX, y, TOGGLE_W, TOGGLE_H, (not isOn) and C.dim or C.off_bg, (not isOn) and 0.90 or 0.60)
    self:drawText(offX + TOGGLE_W * 0.5, y + TOGGLE_H * 0.20, TS_TINY, "OFF",
        (not isOn) and C.white or C.off_text, RenderText.ALIGN_CENTER, not isOn)

    local onHover = not locked and self:hitTest(onX, y, TOGGLE_W, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(onX, y, TOGGLE_W, TOGGLE_H, isOn and C.on_bg or C.off_bg, isOn and 1.0 or 0.60)
    self:drawText(onX + TOGGLE_W * 0.5, y + TOGGLE_H * 0.20, TS_TINY, "ON",
        isOn and C.on_text or C.off_text, RenderText.ALIGN_CENTER, isOn)

    if not locked then
        self:registerClick("toggle_off_" .. settingId, offX, y, TOGGLE_W, TOGGLE_H,
            { id = settingId, value = false })
        self:registerClick("toggle_on_" .. settingId,  onX,  y, TOGGLE_W, TOGGLE_H,
            { id = settingId, value = true })
    end
end

-- ── Multi-select control [< Option >] ─────────────────────────
function CropStressSettingsPanel:drawMultiControl(rightX, y, settingId, locked)
    local meta = SETTINGS_META[settingId]
    if meta == nil or meta.vals == nil then return end
    local rawVal = self:getRawValue(settingId)
    local curIdx = 1
    for i, v in ipairs(meta.vals) do
        if v == rawVal then curIdx = i; break end
    end
    local current = meta.opts[curIdx] or "?"

    local labelW  = MULTI_W - ARROW_W * 2
    local totalX  = rightX - MULTI_W
    local leftX   = totalX
    local midX    = totalX + ARROW_W
    local rightBX = totalX + ARROW_W + labelW

    local lHover = not locked and self:hitTest(leftX, y, ARROW_W, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(leftX, y, ARROW_W, TOGGLE_H, lHover and C.back_hover or C.off_bg)
    self:drawText(leftX + ARROW_W * 0.5, y + TOGGLE_H * 0.18, TS_TINY,
        "<", lHover and C.blue or C.dim, RenderText.ALIGN_CENTER, true)

    self:drawRect(midX, y, labelW, TOGGLE_H, {0.10, 0.11, 0.15, 0.90})
    self:drawText(midX + labelW * 0.5, y + TOGGLE_H * 0.18, TS_TINY, current, C.white, RenderText.ALIGN_CENTER, false)

    local rHover = not locked and self:hitTest(rightBX, y, ARROW_W, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(rightBX, y, ARROW_W, TOGGLE_H, rHover and C.back_hover or C.off_bg)
    self:drawText(rightBX + ARROW_W * 0.5, y + TOGGLE_H * 0.18, TS_TINY,
        ">", rHover and C.blue or C.dim, RenderText.ALIGN_CENTER, true)

    if not locked then
        self:registerClick("multi_prev_" .. settingId, leftX, y, ARROW_W, TOGGLE_H,
            { id = settingId, dir = -1, meta = meta })
        self:registerClick("multi_next_" .. settingId, rightBX, y, ARROW_W, TOGGLE_H,
            { id = settingId, dir = 1, meta = meta })
    end
end

-- ── Popup dialog ───────────────────────────────────────────────
function CropStressSettingsPanel:showPopup(msg)
    self.popupMsg  = msg or ""
    local lines = {}
    for line in (self.popupMsg .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    self.popupLines   = lines
    self.popupScroll  = 0
    self.popupVisible = true
    if g_currentMission and g_currentMission.hud and
       g_currentMission.hud.showBlinkingWarning then
        local short = msg and msg:sub(1, 60) or ""
        g_currentMission.hud:showBlinkingWarning(short, 4000)
    end
end

function CropStressSettingsPanel:drawPopupDialog()
    if not self.popupVisible then return end

    local DW   = 0.52
    local DH   = 0.50
    local DX   = (1 - DW) / 2
    local DY   = (1 - DH) / 2
    local DPAD = 0.016

    local LINE_H    = TS_TINY + 0.004
    local MAX_LINES = math.floor((DH - 0.095) / LINE_H)
    local lines     = self.popupLines or {}
    local total     = #lines
    local maxScroll = math.max(0, total - MAX_LINES)
    if self.popupScroll > maxScroll then self.popupScroll = maxScroll end

    self:drawRect(0, 0, 1, 1, {0,0,0, 0.55})
    self:drawRect(DX + 0.005, DY - 0.005, DW, DH, C.shadow, 0.65)
    self:drawRect(DX, DY, DW, DH, {0.05, 0.07, 0.11, 0.98})

    local bw = 0.0015
    self:drawRect(DX,           DY,           DW, bw, ADMIN_ACCENT, 0.80)
    self:drawRect(DX,           DY + DH - bw, DW, bw, ADMIN_ACCENT, 0.80)
    self:drawRect(DX,           DY,           bw, DH, ADMIN_ACCENT, 0.80)
    self:drawRect(DX + DW - bw, DY,           bw, DH, ADMIN_ACCENT, 0.80)

    local TH = 0.036
    local TY = DY + DH - TH
    self:drawRect(DX, TY, DW, TH, {0.07, 0.08, 0.13, 1.0})
    self:drawRect(DX, TY, 0.004, TH, ADMIN_ACCENT)
    self:drawText(DX + DPAD, TY + TH * 0.28, TS_SMALL, "OUTPUT", {ADMIN_ACCENT[1],ADMIN_ACCENT[2],ADMIN_ACCENT[3],1.0}, RenderText.ALIGN_LEFT, true)

    local cbW = 0.034
    local cbH = TH * 0.62
    local cbX = DX + DW - cbW - 0.010
    local cbY = TY + (TH - cbH) * 0.5
    local cbHov = self:hitTest(cbX, cbY, cbW, cbH, self.mouseX, self.mouseY)
    self:drawRect(cbX, cbY, cbW, cbH, cbHov and C.close_hover or {0.18,0.10,0.10,0.80})
    self:drawText(cbX + cbW * 0.5, cbY + cbH * 0.18, TS_SMALL, "[X]",
        cbHov and {1,1,1,1} or {0.70,0.35,0.35,1}, RenderText.ALIGN_CENTER, true)
    self:registerClick("popup_close", cbX, cbY, cbW, cbH)

    local contentY_top = TY - 0.006
    local contentY_bot = DY + 0.044
    local curY = contentY_top
    for i = self.popupScroll + 1, math.min(self.popupScroll + MAX_LINES, total) do
        local line = lines[i]
        curY = curY - LINE_H
        if curY < contentY_bot then break end
        local col = C.white
        if line:match("^===") or line:match("^---") then
            col = {ADMIN_ACCENT[1], ADMIN_ACCENT[2], ADMIN_ACCENT[3], 0.90}
        elseif line:match("^  ") then
            col = {0.75, 0.88, 0.95, 1.0}
        end
        self:drawText(DX + DPAD, curY + LINE_H * 0.15, TS_TINY, line, col, RenderText.ALIGN_LEFT, false)
    end

    if total > MAX_LINES then
        local sbW = 0.032
        local sbH = 0.034
        local sbX = DX + DW - sbW - 0.006
        local upY = contentY_top - sbH - 0.004
        local dnY = upY - sbH - 0.004
        local canUp = self.popupScroll > 0
        local canDn = self.popupScroll < maxScroll
        local upHov = self:hitTest(sbX, upY, sbW, sbH, self.mouseX, self.mouseY)
        local dnHov = self:hitTest(sbX, dnY, sbW, sbH, self.mouseX, self.mouseY)
        self:drawRect(sbX, upY, sbW, sbH, upHov and canUp and {0.20,0.40,0.65,0.95} or {0.10,0.12,0.18,0.80})
        self:drawText(sbX + sbW * 0.5, upY + sbH * 0.18, TS_SMALL, "^", canUp and {1,1,1,1} or {0.35,0.35,0.35,1}, RenderText.ALIGN_CENTER, true)
        self:drawRect(sbX, dnY, sbW, sbH, dnHov and canDn and {0.20,0.40,0.65,0.95} or {0.10,0.12,0.18,0.80})
        self:drawText(sbX + sbW * 0.5, dnY + sbH * 0.18, TS_SMALL, "v", canDn and {1,1,1,1} or {0.35,0.35,0.35,1}, RenderText.ALIGN_CENTER, true)
        self:registerClick("popup_scroll_up", sbX, upY, sbW, sbH)
        self:registerClick("popup_scroll_dn", sbX, dnY, sbW, sbH)
    end

    local btnW = 0.100
    local btnH = 0.028
    local btnX = DX + (DW - btnW) * 0.5
    local btnY = DY + 0.008
    local btnHov = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(btnX, btnY, btnW, btnH, btnHov and {0.65,0.10,0.10,0.95} or {0.20,0.06,0.06,0.90})
    self:drawRect(btnX, btnY, 0.002, btnH, ADMIN_ACCENT)
    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.20, TS_SMALL, "[X] Close",
        btnHov and {1,1,1,1} or {0.80,0.75,0.75,1}, RenderText.ALIGN_CENTER, true)
    self:registerClick("popup_close", btnX, btnY, btnW, btnH)
end

-- ── Mouse event ────────────────────────────────────────────────
function CropStressSettingsPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.isVisible then return false end
    self.mouseX = posX
    self.mouseY = posY
    if not isDown then return true end
    if button ~= Input.MOUSE_BUTTON_LEFT then return true end

    for _, r in ipairs(self._clickRects) do
        if self:hitTest(r.x, r.y, r.w, r.h, posX, posY) then
            self:handleClick(r.id, r.data)
            return true
        end
    end

    if not self.popupVisible and not self:hitTest(PX, PY, PW, PH, posX, posY) then
        self:close()
    end
    return true
end

-- ── Click handler ──────────────────────────────────────────────
function CropStressSettingsPanel:handleClick(id, data)
    if id == "close" then
        self:close()

    elseif id == "back" then
        self.page = PAGE_LANDING
        self.activeCatIdx = nil

    elseif id:sub(1, 4) == "cat_" then
        local idx = tonumber(id:sub(5))
        if idx and CATEGORIES[idx] then
            self.activeCatIdx = idx
            self.page = PAGE_CATEGORY
        end

    elseif id == "open_admin" then
        self.page = PAGE_ADMIN

    elseif id:sub(1, 11) == "toggle_off_" then
        if data then self:requestChange(data.id, false) end

    elseif id:sub(1, 10) == "toggle_on_" then
        if data then self:requestChange(data.id, true) end

    elseif id:sub(1, 10) == "multi_prev" then
        if data then
            local meta = data.meta
            local cur  = self:getRawValue(data.id)
            local curIdx = 1
            for i, v in ipairs(meta.vals) do if v == cur then curIdx = i; break end end
            local nxt = curIdx - 1
            if nxt < 1 then nxt = #meta.vals end
            self:requestChange(data.id, meta.vals[nxt])
        end

    elseif id:sub(1, 10) == "multi_next" then
        if data then
            local meta = data.meta
            local cur  = self:getRawValue(data.id)
            local curIdx = 1
            for i, v in ipairs(meta.vals) do if v == cur then curIdx = i; break end end
            local nxt = curIdx + 1
            if nxt > #meta.vals then nxt = 1 end
            self:requestChange(data.id, meta.vals[nxt])
        end

    elseif id == "popup_close" then
        self.popupVisible = false
        self.popupMsg, self.popupLines = nil, nil
        self.popupScroll = 0

    elseif id == "popup_scroll_up" then
        if self.popupScroll > 0 then self.popupScroll = self.popupScroll - 1 end

    elseif id == "popup_scroll_dn" then
        local total    = self.popupLines and #self.popupLines or 0
        local LINE_H   = TS_TINY + 0.004
        local MAX_LINES = math.floor((0.50 - 0.095) / LINE_H)
        local maxScroll = math.max(0, total - MAX_LINES)
        if self.popupScroll < maxScroll then self.popupScroll = self.popupScroll + 1 end

    elseif id:sub(1, 13) == "admin_action_" then
        local actionId = data and data.actionId
        if actionId == "admin_status" then
            local msg = self:buildStatusString()
            self:showPopup(msg)
        elseif actionId == "admin_heat" then
            local msg = "Simulating 3-day heat wave..."
            if g_cropStressManager then
                g_cropStressManager:consoleSimulateHeat("3")
                msg = "3-day heat wave simulated.\nCheck field moisture — stress may have increased."
            end
            self:showPopup(msg)
        elseif actionId == "admin_reset" then
            local msg = "Settings reset to defaults."
            if g_cropStressManager and g_cropStressManager.settings then
                g_cropStressManager.settings:resetToDefaults()
                g_cropStressManager:applySettings()
                msg = "All settings have been reset to their default values."
            end
            self:showPopup(msg)
        end
    end
end

-- ── Status string builder ──────────────────────────────────────
function CropStressSettingsPanel:buildStatusString()
    if g_cropStressManager == nil then return "CropStressManager not initialized." end
    local m = g_cropStressManager
    local lines = {}

    table.insert(lines, "=== CropStress System Status ===")
    table.insert(lines, string.format("  Mod enabled:  %s", tostring(m.settings and m.settings.enabled)))
    table.insert(lines, string.format("  Initialized:  %s", tostring(m.isInitialized)))
    table.insert(lines, string.format("  Debug mode:   %s", tostring(m.debugMode)))

    if m.weatherIntegration ~= nil then
        local wi = m.weatherIntegration
        local seas = WeatherIntegration.SEASON_NAMES[wi.currentSeason] or "?"
        table.insert(lines, "")
        table.insert(lines, "--- Weather ---")
        table.insert(lines, string.format("  Season: %s  Temp: %.1f°C  Raining: %s",
            seas, wi.currentTemp or 0, tostring(wi.isRaining)))
    end

    table.insert(lines, "")
    table.insert(lines, "--- Settings ---")
    if m.settings then
        local s = m.settings
        table.insert(lines, string.format("  Difficulty: %s  Evap: %s", s.difficulty, s.evapotranspiration))
        table.insert(lines, string.format("  Max yield loss: %.0f%%  Crit threshold: %.0f%%",
            (s.maxYieldLoss or 0) * 100, (s.criticalThreshold or 0) * 100))
        table.insert(lines, string.format("  Irrigation costs: %s  Alerts: %s  Cooldown: %dh",
            tostring(s.irrigationCosts), tostring(s.alertsEnabled), s.alertCooldown or 0))
    end

    table.insert(lines, "")
    table.insert(lines, "--- Integrations ---")
    table.insert(lines, string.format("  NPCFavor:       %s", tostring(m.npcIntegration and m.npcIntegration.npcFavorActive or false)))
    table.insert(lines, string.format("  SoilFertilizer: %s", tostring(m.soilFertilizerIntegration and m.soilFertilizerIntegration.sfActive or false)))
    table.insert(lines, string.format("  CoursePlay:     %s", tostring(m.coursePlayIntegration and m.coursePlayIntegration.cpActive or false)))
    table.insert(lines, string.format("  AutoDrive:      %s", tostring(m.autoDriveIntegration and m.autoDriveIntegration.adActive or false)))

    table.insert(lines, "")
    table.insert(lines, "--- Fields ---")
    local fieldCount = m.soilSystem and m.soilSystem:getFieldCount() or 0
    table.insert(lines, string.format("  Tracked: %d", fieldCount))

    local sorted = m.soilSystem and m.soilSystem:getFieldsSortedByMoisture()
    if sorted and #sorted > 0 then
        table.insert(lines, "  Driest fields:")
        for i = 1, math.min(8, #sorted) do
            local f = sorted[i]
            local stress = m:getStress(f.fieldId)
            table.insert(lines, string.format("    Field %d: %d%% moisture  stress %.2f",
                f.fieldId, math.floor((f.moisture or 0) * 100 + 0.5), stress))
        end
    end

    return table.concat(lines, "\n")
end
