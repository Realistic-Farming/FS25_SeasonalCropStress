-- =========================================================
-- CsMoistureMapOverlay
-- Draws per-field moisture centroid dots on the PDA map.
-- Colour-coded by moisture level: green / amber / red.
-- =========================================================

CsMoistureMapOverlay = {}
local CsMoistureMapOverlay_mt = Class(CsMoistureMapOverlay)

-- Moisture thresholds (match HUDOverlay + CropConsultant)
CsMoistureMapOverlay.THRESHOLD_HEALTHY  = 0.40
CsMoistureMapOverlay.THRESHOLD_WARNING  = 0.25
CsMoistureMapOverlay.ALPHA              = 0.82

-- World-metre radius represented by each dot
CsMoistureMapOverlay.DOT_STEP           = 60

CsMoistureMapOverlay.SAMPLE_INTERVAL_MS = 5000

CsMoistureMapOverlay.C_HEALTHY  = {0.25, 0.85, 0.40}
CsMoistureMapOverlay.C_WARNING  = {0.90, 0.82, 0.18}
CsMoistureMapOverlay.C_CRITICAL = {0.88, 0.25, 0.25}
CsMoistureMapOverlay.C_ACCENT   = {0.20, 0.65, 0.85}

local CS_MAP_MOD_NAME = g_currentModName

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[CS_MAP_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Constructor ───────────────────────────────────────────

function CsMoistureMapOverlay.new(manager)
    local self = setmetatable({}, CsMoistureMapOverlay_mt)
    self.manager       = manager
    self.samplePoints  = {}
    self.nextSampleTime = 0
    self.buttonRects   = {}
    self.ingameMapRef  = nil
    return self
end

function CsMoistureMapOverlay:initialize()
    if createImageOverlay then
        self.mapDotOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    print("[CropStress] CsMoistureMapOverlay initialized")
end

function CsMoistureMapOverlay:delete()
    if self.mapDotOverlay then
        delete(self.mapDotOverlay)
        self.mapDotOverlay = nil
    end
    self.samplePoints = {}
end

-- ── Required by CsMapHooks ────────────────────────────────

function CsMoistureMapOverlay:getDisplayValues()       return {} end
function CsMoistureMapOverlay:getDefaultFilterState()  return {} end

function CsMoistureMapOverlay:requestRefresh()
    self.nextSampleTime = 0
end

-- ── Colour helper ─────────────────────────────────────────

function CsMoistureMapOverlay:getMoistureColor(moisture)
    local t = CsMoistureMapOverlay
    if moisture >= t.THRESHOLD_HEALTHY then
        return t.C_HEALTHY[1], t.C_HEALTHY[2], t.C_HEALTHY[3]
    elseif moisture >= t.THRESHOLD_WARNING then
        return t.C_WARNING[1], t.C_WARNING[2], t.C_WARNING[3]
    else
        return t.C_CRITICAL[1], t.C_CRITICAL[2], t.C_CRITICAL[3]
    end
end

-- ── Sample field centroids ────────────────────────────────

function CsMoistureMapOverlay:updateSamplePoints(force)
    local now = (g_currentMission and g_currentMission.time) or 0
    if not force and now < self.nextSampleTime then return end
    self.nextSampleTime = now + CsMoistureMapOverlay.SAMPLE_INTERVAL_MS

    self.samplePoints = {}

    if g_currentMission == nil or g_fieldManager == nil then return end
    local fields = g_fieldManager.fields
    if fields == nil then return end

    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil then return end

    for _, field in ipairs(fields) do
        if field and field.farmland then
            local fid = field.farmland.id
            if fid and fid > 0 then
                local entry = soilSystem.fieldData[fid]
                local moisture = entry and entry.moisture or 0.5
                local r, g, b = self:getMoistureColor(moisture)
                table.insert(self.samplePoints, {
                    x        = field.posX or 0,
                    z        = field.posZ or 0,
                    r = r, g = g, b = b,
                    moisture = moisture,
                    fieldId  = fid,
                })
            end
        end
    end
end

-- ── Map bounds & projection ───────────────────────────────

function CsMoistureMapOverlay:getMapRenderBounds(frame, ingameMap)
    local layout = nil
    if frame ~= nil and frame.ingameMapBase ~= nil and frame.ingameMapBase.fullScreenLayout ~= nil then
        layout = frame.ingameMapBase.fullScreenLayout
    elseif ingameMap ~= nil and ingameMap.fullScreenLayout ~= nil then
        layout = ingameMap.fullScreenLayout
    end
    if layout == nil or layout.getMapSize == nil or layout.getMapPosition == nil then
        return nil, nil, nil, nil
    end
    local mapX, mapY = layout:getMapPosition()
    local mapW, mapH = layout:getMapSize()
    return mapX, mapY, mapW, mapH
end

function CsMoistureMapOverlay:worldToScreenPosition(ingameMap, worldX, worldZ)
    if ingameMap == nil then return nil, nil end
    local layout = ingameMap.fullScreenLayout or ingameMap.layout
    if layout == nil or layout.getMapObjectPosition == nil then return nil, nil end

    local worldSizeX = ingameMap.worldSizeX or (g_currentMission and g_currentMission.terrainSize) or 2048
    local worldSizeZ = ingameMap.worldSizeZ or (g_currentMission and g_currentMission.terrainSize) or 2048
    if worldSizeX == 0 or worldSizeZ == 0 then return nil, nil end

    local objectX = (worldX + (ingameMap.worldCenterOffsetX or 0)) / worldSizeX
    local objectZ = (worldZ + (ingameMap.worldCenterOffsetZ or 0)) / worldSizeZ
    objectX = objectX * (ingameMap.mapExtensionScaleFactor or 1) + (ingameMap.mapExtensionOffsetX or 0)
    objectZ = objectZ * (ingameMap.mapExtensionScaleFactor or 1) + (ingameMap.mapExtensionOffsetZ or 0)
    return layout:getMapObjectPosition(objectX, objectZ, 0, 0)
end

-- ── Draw dots on the map ──────────────────────────────────

function CsMoistureMapOverlay:onDraw(frame, mapElement, ingameMap, pageIndex)
    self:updateSamplePoints(false)
    if #self.samplePoints == 0 then return end

    local mapX, mapY, mapWidth, mapHeight = self:getMapRenderBounds(frame, ingameMap)
    if mapX == nil then return end

    local mapMaxX = mapX + mapWidth
    local mapMaxY = mapY + mapHeight

    local step   = CsMoistureMapOverlay.DOT_STEP
    local ax, ay = self:worldToScreenPosition(ingameMap, 0, 0)
    local bx, by = self:worldToScreenPosition(ingameMap, step, 0)
    local cx, cy = self:worldToScreenPosition(ingameMap, 0, step)

    local sizeX, sizeY
    if ax and bx and cx then
        sizeX = math.max(math.abs(bx - ax) * 0.80, 0.003)
        sizeY = math.max(math.abs(cy - ay) * 0.80, 0.003)
    else
        local sw, sh = getNormalizedScreenValues(12, 12)
        sizeX, sizeY = sw, sh
    end
    local halfX = sizeX * 0.5
    local halfY = sizeY * 0.5

    local scaleXX = ax and ((bx - ax) / step) or 0
    local scaleYX = ax and ((by - ay) / step) or 0
    local scaleXZ = ax and ((cx - ax) / step) or 0
    local scaleYZ = ax and ((cy - ay) / step) or 0

    for _, pt in ipairs(self.samplePoints) do
        local screenX, screenY
        if ax then
            screenX = ax + pt.x * scaleXX + pt.z * scaleXZ
            screenY = ay + pt.x * scaleYX + pt.z * scaleYZ
        else
            screenX, screenY = self:worldToScreenPosition(ingameMap, pt.x, pt.z)
        end
        if screenX and screenX >= mapX and screenX <= mapMaxX
           and screenY >= mapY and screenY <= mapMaxY then
            if self.mapDotOverlay then
                setOverlayColor(self.mapDotOverlay, pt.r, pt.g, pt.b, CsMoistureMapOverlay.ALPHA)
                renderOverlay(self.mapDotOverlay, screenX - halfX, screenY - halfY, sizeX, sizeY)
            end
        end
    end
end

-- ── Sidebar HUD ───────────────────────────────────────────

function CsMoistureMapOverlay:onDrawHud(frame)
    self.buttonRects = {}

    local panelX, panelWidth

    if frame.filterList and frame.filterList.absPosition then
        panelX     = frame.filterList.absPosition[1]
        panelWidth = frame.filterList.absSize[1]
    else
        local safeX, _ = getNormalizedScreenValues(14, 0)
        local minW, _  = getNormalizedScreenValues(210, 0)
        panelX     = safeX
        panelWidth = minW
    end

    local topY = 0.80
    if frame.mapOverviewSelector and frame.mapOverviewSelector.absPosition then
        local _, extraM = getNormalizedScreenValues(0, 52)
        topY = frame.mapOverviewSelector.absPosition[2] - extraM
    end

    local _, rowH  = getNormalizedScreenValues(0, 26)
    local _, gap   = getNormalizedScreenValues(0, 4)
    local _, txtSz = getNormalizedScreenValues(0, 14)
    local padX, _  = getNormalizedScreenValues(10, 0)
    local dotW, dotH = getNormalizedScreenValues(12, 12)
    local acW, _   = getNormalizedScreenValues(3, 0)

    -- Section title
    local _, titleSz = getNormalizedScreenValues(0, 15)
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(CsMoistureMapOverlay.C_ACCENT[1], CsMoistureMapOverlay.C_ACCENT[2], CsMoistureMapOverlay.C_ACCENT[3], 1.0)
    local titleText = tr("cs_map_sidebar_title", "MOISTURE LEGEND")
    renderText(panelX + padX, topY - rowH, titleSz, titleText:upper())
    setTextBold(false)

    local currentY = topY - rowH * 2 - gap

    local legend = {
        { label = tr("cs_map_legend_healthy",  "Healthy  ≥40%"),  c = CsMoistureMapOverlay.C_HEALTHY  },
        { label = tr("cs_map_legend_warning",  "Warning  25-40%"), c = CsMoistureMapOverlay.C_WARNING  },
        { label = tr("cs_map_legend_critical", "Critical <25%"),   c = CsMoistureMapOverlay.C_CRITICAL },
    }

    if not self.mapDotOverlay then return end

    local dotOffX, _ = getNormalizedScreenValues(6, 0)
    for _, entry in ipairs(legend) do
        local dotY = currentY + (rowH - dotH) * 0.5
        setOverlayColor(self.mapDotOverlay, entry.c[1], entry.c[2], entry.c[3], 0.90)
        renderOverlay(self.mapDotOverlay, panelX + padX, dotY, dotW, dotH)
        setTextColor(0.90, 0.90, 0.90, 1.0)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(panelX + padX + dotW + dotOffX, currentY + rowH * 0.22, txtSz, entry.label)
        currentY = currentY - rowH - gap
    end

    -- Separator
    currentY = currentY - gap
    local _, sepH = getNormalizedScreenValues(0, 1)
    if self.mapDotOverlay then
        setOverlayColor(self.mapDotOverlay, 0.45, 0.45, 0.45, 0.40)
        renderOverlay(self.mapDotOverlay, panelX, currentY, panelWidth, sepH)
    end
    currentY = currentY - sepH - gap * 2

    -- "Open Crop PDA" button
    local _, btnH = getNormalizedScreenValues(0, 30)
    if self.mapDotOverlay then
        setOverlayColor(self.mapDotOverlay, 0.04, 0.10, 0.18, 0.88)
        renderOverlay(self.mapDotOverlay, panelX, currentY, panelWidth, btnH)
        setOverlayColor(self.mapDotOverlay,
            CsMoistureMapOverlay.C_ACCENT[1], CsMoistureMapOverlay.C_ACCENT[2], CsMoistureMapOverlay.C_ACCENT[3], 1.0)
        renderOverlay(self.mapDotOverlay, panelX, currentY, acW, btnH)
    end
    setTextBold(false)
    setTextColor(0.80, 0.92, 1.0, 1.0)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(panelX + padX + acW, currentY + btnH * 0.28, txtSz,
               tr("cs_map_btn_open_pda", "Open Crop PDA"))

    table.insert(self.buttonRects, {
        x1 = panelX, y1 = currentY,
        x2 = panelX + panelWidth, y2 = currentY + btnH,
        action = "openPDA",
    })
end

function CsMoistureMapOverlay:onSideBarClick(posX, posY)
    for _, rect in ipairs(self.buttonRects) do
        if posX >= rect.x1 and posX <= rect.x2
           and posY >= rect.y1 and posY <= rect.y2 then
            if rect.action == "openPDA" then
                if CsPDAScreen ~= nil then
                    CsPDAScreen.toggle()
                end
            end
            return true
        end
    end
    return false
end
