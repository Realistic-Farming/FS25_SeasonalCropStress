-- ============================================================
-- waterPump.lua
-- Water pump placeable, FS25 specialization pattern.
-- Registers with IrrigationManager as a water source.
-- ============================================================

WaterPump = WaterPump or {}
WaterPump.MOD_NAME = (SeasonalCropStressModName or g_currentModName)

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
function WaterPump.prerequisitesPresent(specializations)
    return true
end

function WaterPump.registerFunctions(placeableType)
    -- BUILD 21:44: 1.2.5.105 called registerWithIrrigationManager as an instance
    -- method from onFinalizePlacement, but the function only lived on the
    -- WaterPump spec table, so both pumps threw "attempt to call missing method",
    -- their loads stayed pending, and the mission loader waited forever after
    -- the last vehicle. Register it on the placeable type so an instance call
    -- resolves.
    SpecializationUtil.registerFunction(placeableType, "registerWithIrrigationManager", WaterPump.registerWithIrrigationManager)
end

function WaterPump.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",        WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "onDelete",      WaterPump)
    -- SCS-023 finite water: save/load + MP stream for the finite remainder.
    SpecializationUtil.registerEventListener(placeableType, "loadFromXMLFile", WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "saveToXMLFile",   WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream",   WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream",    WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "onOwnerChanged",  WaterPump)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function WaterPump.onLoad(self, savegame)
    self.irrigationManager = nil
    self.waterFlowCapacity = 1000  -- default; overwritten from XML below

    -- Read custom config from the placeable XML (self.xmlFile is an XMLFile object in FS25)
    if self.xmlFile ~= nil then
        local base = "placeable.pumpConfig"
        self.waterFlowCapacity = self.xmlFile:getFloat(base .. "#waterFlowCapacity", self.waterFlowCapacity)
        -- SCS-023: finite irrigation water. capacity <= 0 means Unlimited.
        self.waterUnitsCapacity = self.xmlFile:getFloat(base .. "#waterUnitsCapacity", 48.0)
        self.waterUnitsRefillPerRainHour = self.xmlFile:getFloat(base .. "#waterUnitsRefillPerRainHour", 2.0)
    end

    -- SCS-023: onLoad reads config and initializes full or Unlimited state; it
    -- does NOT register the source. Registration happens at finalize placement
    -- so saved state is applied first.
    local capacity = self.waterUnitsCapacity or 48.0
    if capacity <= 0 then
        self.waterRemaining = nil
        self.waterFinite = false
    else
        self.waterRemaining = capacity
        self.waterFinite = true
    end
    self.waterDirty = false

    -- Do not register here; onFinalizePlacement does it once load state is
    -- available.
end

function WaterPump.loadFromXMLFile(self, xmlFile, key)
    -- SCS-023: apply a saved finite remainder when present. Missing means full.
    if self.waterFinite and xmlFile ~= nil then
        local v = xmlFile:getFloat(key .. ".finiteWaterRemaining")
        if v ~= nil then
            self.waterRemaining = math.max(0, v)
        else
            self.waterRemaining = self.waterUnitsCapacity or self.waterRemaining
        end
    end
end

function WaterPump.saveToXMLFile(self, xmlFile, key)
    -- SCS-023: persist the finite remainder; unlimited writes nothing.
    if self.waterFinite and xmlFile ~= nil and self.waterRemaining ~= nil then
        xmlFile:setFloat(key .. ".finiteWaterRemaining", self.waterRemaining)
    end
end

function WaterPump.onFinalizePlacement(self)
    if self.isPreviewMode == true or self.isConstructionPreview == true then return end
    -- Class function with the placeable as self: this cannot miss even if a
    -- future placeable type forgets registerFunctions.
    WaterPump.registerWithIrrigationManager(self)
end

function WaterPump.onOwnerChanged(self, farmId)
    -- SCS-023: revalidate bindings. Farm id <= 0 freezes refill and supplies
    -- nothing until a valid owner returns.
    if self.irrigationManager ~= nil and self.irrigationManager.rebindWaterSource ~= nil then
        self.irrigationManager:rebindWaterSource(self.id, farmId)
    end
end

-- Register once with the manager after load state is available. If the manager
-- is missing the pump is only flagged pendingRegistration; there is NO sweep in
-- IrrigationManager that picks such pumps up later. In practice the manager is
-- created in Mission00.load, before any placeable finalizes, so this branch is
-- not expected to run.
function WaterPump.registerWithIrrigationManager(self)
    self.irrigationManager = g_cropStressManager and g_cropStressManager.irrigationManager or nil
    if self.irrigationManager ~= nil then
        self.irrigationManager:registerWaterSource(self)
    else
        csLog("waterPump: IrrigationManager not available, pump marked pending")
        self.pendingRegistration = true
    end
end

function WaterPump.onDelete(self)
    if self.irrigationManager ~= nil then
        self.irrigationManager:deregisterWaterSource(self.id)
    end
end

-- SCS-023 MP stream: the finite remainder must reach clients.
function WaterPump.onWriteStream(self, streamId, connection)
    if self.waterFinite then
        local dirty = self.waterDirty == true
        streamWriteBool(streamId, dirty)
        streamWriteFloat32(streamId, self.waterRemaining or 0)
        self.waterDirty = false
    else
        streamWriteBool(streamId, false)
    end
end

function WaterPump.onReadStream(self, streamId, connection)
    local dirty = streamReadBool(streamId)
    if self.waterFinite then
        local v = streamReadFloat32(streamId)
        if dirty then
            -- Client read applies the server value with fromSync=true semantics;
            -- the manager's setter derives hasWater without originating dirt.
            if self.irrigationManager ~= nil then
                self.irrigationManager:setSourceWaterRemaining(self.id, v, true)
            else
                self.waterRemaining = math.max(0, v)
            end
        end
    end
end

-- No onUpdate needed: pumps are passive and register once at finalize placement.
-- onReadStream / onWriteStream above carry only the finite remainder on join.
