-- ============================================================
-- UsedEquipmentMarketplace.lua
-- Phase 4: Integrates with FS25_UsedPlus to add pre-owned
-- irrigation equipment to the used equipment marketplace.
-- ============================================================

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

-- Primary path: g_currentMission.usedPlusAPI (UP v2.15.4.96+ â€” the only reliable
-- cross-mod path in FS25's sandboxed environment). Bare globals kept as fallbacks.
local function getUPAPI()
    return (g_currentMission and g_currentMission.usedPlusAPI) or UsedPlusAPI or g_usedPlusManager
end

UsedEquipmentMarketplace = UsedEquipmentMarketplace or {}
UsedEquipmentMarketplace.__index = UsedEquipmentMarketplace

function UsedEquipmentMarketplace.new(manager)
    local self = setmetatable({}, UsedEquipmentMarketplace)
    self.manager = manager
    self.usedPlusActive = false
    self.isInitialized = false
    return self
end

function UsedEquipmentMarketplace:initialize()
    self.isInitialized = true
    csLog("UsedEquipmentMarketplace initialized")
end

-- Enable UsedPlus mode - called by CropStressManager after detection
function UsedEquipmentMarketplace:enableUsedPlusMode()
    self.usedPlusActive = true
    self:registerUsedEquipment()
    csLog("UsedEquipmentMarketplace: UsedPlus integration enabled")
end

-- Register pre-owned irrigation equipment with UsedPlus marketplace.
-- Uses getUPAPI() (g_currentMission.usedPlusAPI primary, bare globals as fallback).
-- registerUsedEquipment() is NOT in the confirmed public API â€” guarded with nil check
-- and pcall so this silently no-ops if the method doesn't exist.
function UsedEquipmentMarketplace:registerUsedEquipment()
    if not self.usedPlusActive then return end
    local api = getUPAPI()
    if api == nil or api.registerUsedEquipment == nil then
        csLog("UsedEquipmentMarketplace: registerUsedEquipment not available â€” marketplace registration skipped")
        return
    end

    -- Center Pivot used equipment entries (Reinke A22, the vendored pivot type)
    local pivotConfigs = {
        {
            name = "Used Reinke A22 Center Pivot",
            type = "reinkeIrrigationPivot",
            basePrice = 42500,  -- 50% of new price (85000)
            conditionRange = {0.4, 0.8},  -- 40-80% condition
            description = "Pre-owned Reinke A22 center pivot irrigation system.",
            image = "placeables/reinkeA22/store_Reinke3.dds"
        },
        {
            name = "Used Reinke A22 Center Pivot (Heavy)",
            type = "reinkeIrrigationPivot",
            basePrice = 51000,  -- 60% of new price
            conditionRange = {0.6, 0.9},  -- 60-90% condition
            description = "High-capacity Reinke A22 center pivot with reinforced arm.",
            image = "placeables/reinkeA22/store_Reinke5.dds"
        }
    }

    -- Water Pump used equipment entries
    local pumpConfigs = {
        {
            name = "Used Water Pump Unit",
            type = "waterPump",
            basePrice = 18000,  -- 60% of new price (30000)
            conditionRange = {0.4, 0.8},
            description = "Pre-owned water pump unit. Connects to any water source within 500m.",
            image = "$data/placeables/brandless/waterTanks/level02/store_waterTankLevel02.dds"
        },
        {
            name = "Used High-Flow Water Pump",
            type = "waterPump",
            basePrice = 22500,  -- 75% of new price
            conditionRange = {0.5, 0.85},
            description = "Industrial-grade water pump with increased flow capacity.",
            image = "$data/placeables/brandless/waterTanks/level02/store_waterTankLevel02.dds"
        }
    }

    -- Register all equipment types
    for _, config in ipairs(pivotConfigs) do
        self:registerSingleEquipment(config)
    end

    for _, config in ipairs(pumpConfigs) do
        self:registerSingleEquipment(config)
    end
end

-- Register a single piece of equipment with UsedPlus.
-- Wrapped in pcall: API signature unconfirmed, prevents crash on mismatch.
function UsedEquipmentMarketplace:registerSingleEquipment(config)
    local api = getUPAPI()
    if api == nil or api.registerUsedEquipment == nil then return end

    local equipmentData = {
        name           = config.name,
        type           = config.type,
        basePrice      = config.basePrice,
        conditionRange = config.conditionRange,
        description    = config.description,
        image          = config.image,
        category       = "IRRIGATION",
        subcategory    = "AGRICULTURAL_EQUIPMENT",
        attributes = {
            coverageRadius  = config.coverageRadius  or 200,
            flowRate        = config.flowRate        or 1000,
            operationalCost = config.operationalCost or 15,
        },
    }

    local ok, err = pcall(function() api:registerUsedEquipment(equipmentData) end)
    if ok then
        csLog(string.format("Registered used equipment: %s", config.name))
    else
        csLog(string.format("registerUsedEquipment failed for %s: %s", config.name, tostring(err)))
    end
end

function UsedEquipmentMarketplace:delete()
    self.isInitialized = false
end