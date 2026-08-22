-- ============================================================
-- waterPump.lua
-- Water pump placeable — FS25 specialization pattern.
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
    -- No additional public functions needed for water pump
end

function WaterPump.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",   WaterPump)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", WaterPump)
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
    end

    -- waterFlowCapacity must be set BEFORE registerWaterSource so the
    -- manager records the correct capacity on first registration
    self.irrigationManager = g_cropStressManager and g_cropStressManager.irrigationManager or nil
    if self.irrigationManager ~= nil then
        self.irrigationManager:registerWaterSource(self)
    else
        csLog("waterPump: IrrigationManager not available at onLoad — pump not registered")
    end
end

function WaterPump.onDelete(self)
    if self.irrigationManager ~= nil then
        self.irrigationManager:deregisterWaterSource(self.id)
    end
end

-- No onUpdate needed: pumps are passive and register once at onLoad.
-- No onReadStream / onWriteStream: no additional state to sync.
