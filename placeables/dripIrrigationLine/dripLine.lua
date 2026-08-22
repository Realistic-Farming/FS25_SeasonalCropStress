-- ============================================================
-- dripLine.lua
-- Drip irrigation line system — FS25 specialization pattern.
-- Registers with IrrigationManager. Uses linear coverage.
-- E-key proximity interaction: opens IrrigationScheduleDialog when
-- player is within INTERACTION_RADIUS metres of the line.
-- ============================================================

DripIrrigationLine = DripIrrigationLine or {}
DripIrrigationLine.MOD_NAME = (SeasonalCropStressModName or g_currentModName)
DripIrrigationLine.INTERACTION_RADIUS = 8  -- metres

local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ============================================================
-- SPECIALIZATION REGISTRATION
-- ============================================================
function DripIrrigationLine.prerequisitesPresent(specializations)
    return true
end

function DripIrrigationLine.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "registerInteractionAction", DripIrrigationLine.registerInteractionAction)
    SpecializationUtil.registerFunction(placeableType, "removeInteractionAction",   DripIrrigationLine.removeInteractionAction)
    SpecializationUtil.registerFunction(placeableType, "onInteractPressed",         DripIrrigationLine.onInteractPressed)
end

function DripIrrigationLine.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",        DripIrrigationLine)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate",      DripIrrigationLine)
    SpecializationUtil.registerEventListener(placeableType, "onDelete",      DripIrrigationLine)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream",  DripIrrigationLine)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", DripIrrigationLine)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function DripIrrigationLine.onLoad(self, savegame)
    -- Initialise custom fields
    self.irrigationManager      = nil
    self.lineLength             = 100
    self.lineSpacing            = 0.8
    self.flowRatePerHour        = 0.012
    self.operationalCostPerHour = 8
    self.liftCoeff              = 0.0   -- SCS-038: the LIFT term's XML balance value (0.0 = neutral)
    self.defaultStartHour       = 6
    self.defaultEndHour         = 10
    self.defaultActiveDays      = {true, true, true, true, true, false, false}
    self.irrigationType         = "drip"
    self.isActive               = false
    self.startX = 0;  self.startZ = 0
    self.endX   = 0;  self.endZ   = 0
    self.coverageMinX = 0;  self.coverageMaxX = 0
    self.coverageMinZ = 0;  self.coverageMaxZ = 0
    self.playerInRange  = false
    self.actionEventId  = nil

    -- Read custom config from the placeable XML (self.xmlFile is an XMLFile object in FS25)
    if self.xmlFile ~= nil then
        local base = "placeable.dripConfig"
        self.lineLength             = self.xmlFile:getFloat(base .. "#lineLength",             self.lineLength)
        self.lineSpacing            = self.xmlFile:getFloat(base .. "#lineSpacing",            self.lineSpacing)
        self.flowRatePerHour        = self.xmlFile:getFloat(base .. "#flowRatePerHour",        self.flowRatePerHour)
        self.operationalCostPerHour = self.xmlFile:getFloat(base .. "#operationalCostPerHour", self.operationalCostPerHour)
        self.liftCoeff              = self.xmlFile:getFloat(base .. "#liftCoeff",              self.liftCoeff)
        self.defaultStartHour       = self.xmlFile:getInt(  base .. "#defaultStartHour",       self.defaultStartHour)
        self.defaultEndHour         = self.xmlFile:getInt(  base .. "#defaultEndHour",         self.defaultEndHour)

        local daysStr = self.xmlFile:getString(base .. "#defaultActiveDays", nil)
        if daysStr ~= nil then
            local days = {}
            for v in string.gmatch(daysStr, "[^,]+") do
                table.insert(days, tonumber(v) ~= 0)
            end
            if #days == 7 then self.defaultActiveDays = days end
        end
    end

    -- Get position and orientation from root node.
    -- Project the line along local X (cos ry, -sin ry in world XZ).
    -- VERIFY: if the line axis is local Z, swap to dirX=-sin(ry), dirZ=-cos(ry).
    if self.nodeId ~= nil then
        local x, _, z = getWorldTranslation(self.nodeId)
        local _, ry, _ = getWorldRotation(self.nodeId)
        local dirX =  math.cos(ry)
        local dirZ = -math.sin(ry)
        self.startX = x
        self.startZ = z
        self.endX   = x + dirX * self.lineLength
        self.endZ   = z + dirZ * self.lineLength
        self.coverageMinX = math.min(self.startX, self.endX)
        self.coverageMaxX = math.max(self.startX, self.endX)
        self.coverageMinZ = math.min(self.startZ, self.endZ) - self.lineSpacing * 0.5
        self.coverageMaxZ = math.max(self.startZ, self.endZ) + self.lineSpacing * 0.5
    end

    -- Register with IrrigationManager
    self.irrigationManager = g_cropStressManager and g_cropStressManager.irrigationManager or nil
    if self.irrigationManager ~= nil then
        self.irrigationManager:registerIrrigationSystem(self)
    else
        csLog("dripLine: IrrigationManager not available at onLoad — drip line not registered")
    end
end

function DripIrrigationLine.onUpdate(self, dt)
    -- Sync active state from IrrigationManager
    local mgr = g_cropStressManager and g_cropStressManager.irrigationManager or nil
    local sys = mgr ~= nil and mgr.systems[self.id] or nil
    self.isActive = sys ~= nil and sys.isActive == true

    -- Distance poll — closest-point-on-segment for long lines (client-only)
    if self.isClient then
        local player = g_localPlayer
        if player ~= nil then
            local px, _, pz = getWorldTranslation(player.rootNode or player.nodeId)
            local lx = self.endX - self.startX
            local lz = self.endZ - self.startZ
            local len2 = lx*lx + lz*lz
            local t = 0
            if len2 > 0 then
                t = math.max(0, math.min(1, ((px-self.startX)*lx + (pz-self.startZ)*lz) / len2))
            end
            local cx = self.startX + t*lx
            local cz = self.startZ + t*lz
            local r = DripIrrigationLine.INTERACTION_RADIUS
            local inRange = (px-cx)*(px-cx) + (pz-cz)*(pz-cz) <= r*r
            if inRange and not self.playerInRange then
                self.playerInRange = true
                self:registerInteractionAction()
            elseif not inRange and self.playerInRange then
                self.playerInRange = false
                self:removeInteractionAction()
            end
        end
    end

    if self.isClient and self.playerInRange and self.actionEventId == nil then
        self:registerInteractionAction()
    end
end

function DripIrrigationLine.onDelete(self)
    if self.isClient then
        self:removeInteractionAction()
    end
    if self.irrigationManager ~= nil then
        self.irrigationManager:deregisterIrrigationSystem(self.id)
    end
end

function DripIrrigationLine.onReadStream(self, streamId, connection)
    self.isActive     = streamReadBool(streamId)
    self.startX       = streamReadFloat32(streamId)
    self.startZ       = streamReadFloat32(streamId)
    self.endX         = streamReadFloat32(streamId)
    self.endZ         = streamReadFloat32(streamId)
    self.coverageMinX = streamReadFloat32(streamId)
    self.coverageMaxX = streamReadFloat32(streamId)
    self.coverageMinZ = streamReadFloat32(streamId)
    self.coverageMaxZ = streamReadFloat32(streamId)
end

function DripIrrigationLine.onWriteStream(self, streamId, connection)
    streamWriteBool(streamId,    self.isActive     or false)
    streamWriteFloat32(streamId, self.startX       or 0)
    streamWriteFloat32(streamId, self.startZ       or 0)
    streamWriteFloat32(streamId, self.endX         or 0)
    streamWriteFloat32(streamId, self.endZ         or 0)
    streamWriteFloat32(streamId, self.coverageMinX or 0)
    streamWriteFloat32(streamId, self.coverageMaxX or 0)
    streamWriteFloat32(streamId, self.coverageMinZ or 0)
    streamWriteFloat32(streamId, self.coverageMaxZ or 0)
end

-- ============================================================
-- INPUT ACTION REGISTRATION
-- ============================================================
function DripIrrigationLine.registerInteractionAction(self)
    if self.actionEventId ~= nil then return end
    if g_inputBinding == nil then return end
    if InputAction == nil or InputAction.ACTIVATE_HANDTOOL == nil then return end

    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_HANDTOOL, self, DripIrrigationLine.onInteractPressed,
        false, true, false, true
    )
    self.actionEventId = actionEventId

    if actionEventId ~= nil then
        local label = (g_i18n ~= nil and g_i18n:getText("cs_irr_open_schedule")) or "Open Irrigation Schedule"
        g_inputBinding:setActionEventText(actionEventId, label)
        g_inputBinding:setActionEventActive(actionEventId, true)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    end
end

function DripIrrigationLine.removeInteractionAction(self)
    if self.actionEventId == nil then return end
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEvent(self.actionEventId)
    end
    self.actionEventId = nil
end

function DripIrrigationLine.onInteractPressed(self)
    if not self.playerInRange then return end
    if g_cropStressManager == nil then return end

    -- CsDialogLoader.show() calls setSystemId(self.id) BEFORE showDialog(),
    -- so onOpen() sees a valid systemId when it fires.
    CsDialogLoader.show("IrrigationScheduleDialog", "setSystemId", self.id)

    self:removeInteractionAction()
end
