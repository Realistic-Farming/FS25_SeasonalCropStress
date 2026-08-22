-- ============================================================
-- centerPivot.lua
-- Center pivot irrigation system — FS25 specialization pattern.
-- Registers with IrrigationManager. Spins arm when active.
-- Terrain-following: each span_N node tracks terrain height at its
-- current world position every 500ms as the arm rotates.
-- Wheel rotation: each optional wheel child node spins proportional
-- to the arc distance traveled at its tower radius.
-- E-key proximity interaction: opens IrrigationScheduleDialog.
-- ============================================================

IrrigationPivot = IrrigationPivot or {}
IrrigationPivot.MOD_NAME = (SeasonalCropStressModName or g_currentModName)
IrrigationPivot.INTERACTION_RADIUS = 8

local TWO_PI                    = 2 * math.pi
local TERRAIN_SAMPLE_INTERVAL_MS = 500
local DEFAULT_ARM_MIN_PER_REV   = 30    -- 30 real-minutes per revolution
local DEFAULT_WHEEL_RADIUS_M    = 0.5   -- metres, wheel circumference calculation

local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- Recursive depth-first search for a node by name.
-- Safe: guards against nil and invalid entities.
local function findNodeByName(rootNode, name)
    if rootNode == nil or not entityExists(rootNode) then return nil end
    if getName(rootNode) == name then return rootNode end
    local count = getNumOfChildren(rootNode)
    for i = 0, count - 1 do
        local found = findNodeByName(getChildAt(rootNode, i), name)
        if found ~= nil then return found end
    end
    return nil
end

-- ============================================================
-- SPECIALIZATION REGISTRATION
-- ============================================================
function IrrigationPivot.prerequisitesPresent(specializations)
    return true
end

function IrrigationPivot.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "registerInteractionAction", IrrigationPivot.registerInteractionAction)
    SpecializationUtil.registerFunction(placeableType, "removeInteractionAction",   IrrigationPivot.removeInteractionAction)
    SpecializationUtil.registerFunction(placeableType, "onInteractPressed",         IrrigationPivot.onInteractPressed)
end

function IrrigationPivot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",        IrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate",      IrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onDelete",      IrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream",  IrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", IrrigationPivot)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function IrrigationPivot.onLoad(self, savegame)
    self.irrigationManager       = nil
    self.radius                  = 200
    self.flowRatePerHour         = 0.018
    self.operationalCostPerHour  = 15
    self.liftCoeff               = 0.0   -- SCS-038: the LIFT term's XML balance value (0.0 = neutral)
    self.defaultStartHour        = 6
    self.defaultEndHour          = 10
    self.defaultActiveDays       = {true, true, true, true, true, false, false}
    self.irrigationType          = "pivot"
    self.isActive                = false
    self.playerInRange           = false
    self.actionEventId           = nil

    -- Animation state
    self.armNode                 = nil
    self.armRotation             = 0
    self.armSpeedRadPerMs        = TWO_PI / (DEFAULT_ARM_MIN_PER_REV * 60 * 1000)
    self.wheelRadius             = DEFAULT_WHEEL_RADIUS_M
    self.spanNodes               = {}
    self.terrainSampleTimer      = 0
    self.basePivotTerrainY       = nil  -- lazy-initialised on first active update

    if self.xmlFile ~= nil then
        local base = "placeable.irrigationConfig"
        self.radius                 = self.xmlFile:getFloat(base .. "#radius",                 self.radius)
        self.flowRatePerHour        = self.xmlFile:getFloat(base .. "#flowRatePerHour",        self.flowRatePerHour)
        self.operationalCostPerHour = self.xmlFile:getFloat(base .. "#operationalCostPerHour", self.operationalCostPerHour)
        self.liftCoeff               = self.xmlFile:getFloat(base .. "#liftCoeff",               self.liftCoeff)
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

        local armMinPerRev = self.xmlFile:getFloat(base .. "#armMinPerRev", DEFAULT_ARM_MIN_PER_REV)
        if armMinPerRev > 0 then
            self.armSpeedRadPerMs = TWO_PI / (armMinPerRev * 60 * 1000)
        end

        local wr = self.xmlFile:getFloat(base .. "#wheelRadius", DEFAULT_WHEEL_RADIUS_M)
        if wr > 0 then self.wheelRadius = wr end
    end

    -- Find the arm node that rotates around Y.
    -- Named "armNode" — must be a direct or near child of the placeable root.
    if self.nodeId ~= nil then
        self.armNode = findNodeByName(self.nodeId, "armNode")
        if self.armNode == nil then
            csLog("centerPivot: 'armNode' not found in i3d — arm will not animate")
        end
    end

    -- Discover span nodes for terrain-following and wheel animation.
    -- Expected: span_1, span_2, ... as direct children of armNode.
    -- Each span node's local X = its radius from the pivot center.
    -- Each span node may optionally contain a child named "wheel".
    if self.armNode ~= nil then
        for i = 1, 10 do
            local span = findNodeByName(self.armNode, "span_" .. i)
            if span == nil then break end
            local lx, ly, lz = getTranslation(span)
            local wheelNode   = findNodeByName(span, "wheel")
            table.insert(self.spanNodes, {
                node        = span,
                baseLocalX  = lx,
                baseLocalY  = ly,
                baseLocalZ  = lz,
                radius      = lx,   -- local X along the arm = distance from pivot centre
                wheelNode   = wheelNode,
                wheelAngle  = 0,
            })
        end
        if #self.spanNodes > 0 then
            csLog("centerPivot: " .. #self.spanNodes .. " span nodes found for terrain following")
        end
        if self.armNode ~= nil then
            local wheelCount = 0
            for _, s in ipairs(self.spanNodes) do
                if s.wheelNode ~= nil then wheelCount = wheelCount + 1 end
            end
            if wheelCount > 0 then
                csLog("centerPivot: " .. wheelCount .. " wheel nodes found")
            end
        end
    end

    -- Register with IrrigationManager
    self.irrigationManager = g_cropStressManager and g_cropStressManager.irrigationManager or nil
    if self.irrigationManager ~= nil then
        self.irrigationManager:registerIrrigationSystem(self)
    else
        csLog("centerPivot: IrrigationManager not available at onLoad — pivot not registered")
    end
end

function IrrigationPivot.onUpdate(self, dt)
    -- Sync active state from IrrigationManager
    local mgr = g_cropStressManager and g_cropStressManager.irrigationManager or nil
    local sys = mgr ~= nil and mgr.systems[self.id] or nil
    self.isActive = sys ~= nil and sys.isActive == true

    -- Arm spin + terrain-following + wheel rotation: client-only, active only
    if self.isClient and self.isActive and self.armNode ~= nil then
        local armDelta = self.armSpeedRadPerMs * dt
        self.armRotation = (self.armRotation + armDelta) % TWO_PI
        setRotation(self.armNode, 0, self.armRotation, 0)

        -- Wheel rotation: arc distance at each tower's radius drives the spin angle.
        -- arc = armDelta_radians * radius;  wheel_angle += arc / wheelCircumferenceRadius
        for _, span in ipairs(self.spanNodes) do
            if span.wheelNode ~= nil then
                local arc = armDelta * span.radius
                span.wheelAngle = (span.wheelAngle + arc / self.wheelRadius) % TWO_PI
                setRotation(span.wheelNode, span.wheelAngle, 0, 0)
            end
        end

        -- Terrain following: every 500ms, sample terrain under each span's current
        -- world position and adjust its local Y so the arm drapes over hills/slopes.
        if #self.spanNodes > 0 then
            self.terrainSampleTimer = self.terrainSampleTimer + dt
            if self.terrainSampleTimer >= TERRAIN_SAMPLE_INTERVAL_MS then
                self.terrainSampleTimer = 0

                -- Capture base pivot terrain height the first time we're active.
                if self.basePivotTerrainY == nil and g_terrainNode ~= nil then
                    local px, _, pz = getWorldTranslation(self.nodeId)
                    self.basePivotTerrainY = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
                end

                if self.basePivotTerrainY ~= nil and g_terrainNode ~= nil then
                    for _, span in ipairs(self.spanNodes) do
                        local wx, _, wz = getWorldTranslation(span.node)
                        local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, wx, 0, wz)
                        local delta = terrainY - self.basePivotTerrainY
                        setTranslation(span.node, span.baseLocalX, span.baseLocalY + delta, span.baseLocalZ)
                    end
                end
            end
        end
    end

    -- Distance poll for proximity interaction (client-only)
    if self.isClient and self.nodeId ~= nil then
        local player = g_localPlayer
        if player ~= nil then
            local px, _, pz = getWorldTranslation(player.rootNode or player.nodeId)
            local sx, _, sz = getWorldTranslation(self.nodeId)
            local r = IrrigationPivot.INTERACTION_RADIUS
            local inRange = (px-sx)*(px-sx) + (pz-sz)*(pz-sz) <= r*r
            if inRange and not self.playerInRange then
                self.playerInRange = true
                self:registerInteractionAction()
            elseif not inRange and self.playerInRange then
                self.playerInRange = false
                self:removeInteractionAction()
            end
        end
    end

    -- Re-register if player is in range but action was cleared (e.g. after dialog closed)
    if self.isClient and self.playerInRange and self.actionEventId == nil then
        self:registerInteractionAction()
    end
end

function IrrigationPivot.onDelete(self)
    if self.isClient then
        self:removeInteractionAction()
    end
    if self.irrigationManager ~= nil then
        self.irrigationManager:deregisterIrrigationSystem(self.id)
    end
end

function IrrigationPivot.onReadStream(self, streamId, connection)
    self.isActive = streamReadBool(streamId)
end

function IrrigationPivot.onWriteStream(self, streamId, connection)
    streamWriteBool(streamId, self.isActive or false)
end

-- ============================================================
-- INPUT ACTION REGISTRATION
-- ============================================================
function IrrigationPivot.registerInteractionAction(self)
    if self.actionEventId ~= nil then return end
    if g_inputBinding == nil then return end
    if InputAction == nil or InputAction.ACTIVATE_HANDTOOL == nil then return end

    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.ACTIVATE_HANDTOOL, self, IrrigationPivot.onInteractPressed,
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

function IrrigationPivot.removeInteractionAction(self)
    if self.actionEventId == nil then return end
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEvent(self.actionEventId)
    end
    self.actionEventId = nil
end

function IrrigationPivot.onInteractPressed(self)
    if not self.playerInRange then return end
    if g_cropStressManager == nil then return end

    CsDialogLoader.show("IrrigationScheduleDialog", "setSystemId", self.id)
    self:removeInteractionAction()
end
