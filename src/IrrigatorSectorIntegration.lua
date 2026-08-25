-- ============================================================
-- IrrigatorSectorIntegration.lua
-- Vehicle irrigator (Rainstar play kit) -> SCS moisture cells.
--
-- The stock sprayer work area is a RECTANGLE swept by a moving vehicle. A
-- Rainstar stands still and throws a PIE SECTOR, so processSprayerArea cannot
-- describe where its water lands. This is the thin server-side sector sampler
-- George asked for: it converts flow over the swept sector into millimetres,
-- turns millimetres into the suite's 0-1 moisture fraction with the SAME
-- constant the sprayer path already uses, and writes through the SAME certified
-- door (SoilMoistureSystem:applyWaterAtCell). No second moisture store, no
-- ported Sherman simulation, no densmap writes.
--
-- Authority: server only. Clients read moisture through the normal Esc/HUD path
-- after the existing dirty/sync tick, exactly like the sprayer and Irrigate Now.
-- ============================================================

IrrigatorSectorIntegration = IrrigatorSectorIntegration or {}
IrrigatorSectorIntegration.__index = IrrigatorSectorIntegration

--- Vehicle types this tick drives. Keyed by modDesc vehicleType name so swapping
--- the art (i3d/textures) never touches this file - Samantha's swap-art contract.
IrrigatorSectorIntegration.VEHICLE_TYPES = {
    rwsmPlayRainstar = true,
}

--- Match a vehicle's typeName against VEHICLE_TYPES, stripping the mod prefix
--- FS25 uses "ModName.typeName" at runtime (TypeManager.lua:259).
function IrrigatorSectorIntegration.matchesType(typeName)
    if typeName == nil then return false end
    if IrrigatorSectorIntegration.VEHICLE_TYPES[typeName] then return true end
    local baseName = typeName:match("%.(.+)$")
    return baseName ~= nil and IrrigatorSectorIntegration.VEHICLE_TYPES[baseName] == true
end

IrrigatorSectorIntegration.TICK_MS      = 500    -- server sample cadence
IrrigatorSectorIntegration.FLOW_LPS     = 20.0   -- liters/second while running
IrrigatorSectorIntegration.RADIUS_M     = 28.0   -- throw radius
IrrigatorSectorIntegration.SECTOR_DEG   = 200.0  -- swept arc, centred on forward
IrrigatorSectorIntegration.RINGS        = 3      -- sample rings across the radius
IrrigatorSectorIntegration.SPOKES       = 8      -- sample spokes across the arc

function IrrigatorSectorIntegration.new(manager)
    local self = setmetatable({}, IrrigatorSectorIntegration)
    self.manager = manager
    self.isInitialized = false
    self._accMs = 0
    self._waterFillType = nil
    -- farmlandId -> true for every field this tick actually watered. The PDA
    -- reads this so a parked Rainstar shows its field as irrigated the same way
    -- a placed pivot or drip line does; cleared at the top of each tick window.
    self._activeWateredFields = {}
    return self
end

function IrrigatorSectorIntegration:initialize()
    if self.isInitialized then return end
    self.isInitialized = true
    print("[CropStress] IrrigatorSectorIntegration: sector irrigator tick armed")
end

--- Resolve (and cache) the WATER fill type index.
function IrrigatorSectorIntegration:_waterIndex()
    if self._waterFillType == nil and g_fillTypeManager ~= nil then
        self._waterFillType = g_fillTypeManager:getFillTypeIndexByName("WATER")
    end
    return self._waterFillType
end

--- The fill unit actually holding WATER on this vehicle.
local function resolveWaterFillUnit(vehicle, waterIndex)
    local spec = vehicle.spec_sprayer
    if spec ~= nil and spec.fillUnitIndex ~= nil then
        return spec.fillUnitIndex
    end
    if vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits ~= nil then
        for i, unit in ipairs(vehicle.spec_fillUnit.fillUnits) do
            if unit ~= nil and unit.supportedFillTypes ~= nil
                    and waterIndex ~= nil and unit.supportedFillTypes[waterIndex] then
                return i
            end
        end
    end
    return 1
end

--- Sample points across the pie sector, in world space.
--- Rings x spokes is deliberately coarse: cell size is ~10 m and the radius is
--- ~28 m, so this lands on distinct cells without a per-square-metre sweep.
local function sectorPoints(ox, oz, dirX, dirZ, radius, sectorDeg, rings, spokes)
    local pts = {}
    local baseAng = math.atan2(dirX, dirZ)
    local half = math.rad(sectorDeg) * 0.5
    for r = 1, rings do
        -- Ring radii biased outward so area per sample stays comparable.
        local rr = radius * (r / rings)
        for s = 1, spokes do
            local f = (spokes == 1) and 0.5 or ((s - 1) / (spokes - 1))
            local ang = baseAng - half + (2 * half * f)
            pts[#pts + 1] = { ox + math.sin(ang) * rr, oz + math.cos(ang) * rr }
        end
    end
    return pts
end

---@param dt number frame delta in ms (from CropStressManager:update)
function IrrigatorSectorIntegration:update(dt)
    if not self.isInitialized then return end

    -- Server authority: the write door is server-only, same as the sprayer path.
    local mission = g_currentMission
    if mission == nil or mission.getIsServer == nil or not mission:getIsServer() then
        return
    end

    self._accMs = self._accMs + (dt or 0)
    if self._accMs < IrrigatorSectorIntegration.TICK_MS then return end
    local elapsedMs = self._accMs
    self._accMs = 0
    self._activeWateredFields = {}   -- fresh window; repopulated as water lands

    local soilSystem = self.manager ~= nil and self.manager.soilSystem or nil
    if soilSystem == nil or type(soilSystem.applyWaterAtCell) ~= "function" then return end

    local vehicleSystem = mission.vehicleSystem
    local vehicles = (vehicleSystem ~= nil and vehicleSystem.vehicles) or mission.vehicles
    if vehicles == nil then return end

    local waterIndex = self:_waterIndex()
    local anyApplied = false

    for _, vehicle in pairs(vehicles) do
        if vehicle ~= nil and IrrigatorSectorIntegration.matchesType(vehicle.typeName) then
            anyApplied = self:_tickVehicle(vehicle, soilSystem, waterIndex, elapsedMs) or anyApplied
        end
    end

    -- One dirty mark per tick, not per cell: the sync bridge batches at 1 Hz and
    -- marking inside the cell loop would be pure churn.
    if anyApplied and CropStressNetworkSyncBridge ~= nil
            and type(CropStressNetworkSyncBridge.markFieldDirty) == "function" then
        CropStressNetworkSyncBridge.markFieldDirty()
    end
end

---@return boolean true when water was actually applied
function IrrigatorSectorIntegration:_tickVehicle(vehicle, soilSystem, waterIndex, elapsedMs)
    -- Gate 1: turned on (TurnOnVehicle). A parked, off Rainstar wets nothing.
    if type(vehicle.getIsTurnedOn) ~= "function" or not vehicle:getIsTurnedOn() then
        return false
    end

    -- Gate 2: it must actually be holding water.
    local fillUnitIndex = resolveWaterFillUnit(vehicle, waterIndex)
    if type(vehicle.getFillUnitFillLevel) ~= "function" then return false end
    local level = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
    if level <= 0 then return false end

    local fillType = vehicle.getFillUnitFillType ~= nil
        and vehicle:getFillUnitFillType(fillUnitIndex) or nil
    if waterIndex ~= nil and fillType ~= nil and fillType ~= waterIndex then
        return false
    end

    -- Origin + facing. Prefer the nozzle node so the sector starts at the gun,
    -- and fall back to the root so a re-exported model cannot break the tick.
    local node = vehicle.rootNode
    if type(vehicle.getRootNode) == "function" then node = vehicle:getRootNode() or node end
    if vehicle.spec_sprayer ~= nil and vehicle.spec_sprayer.effects ~= nil then
        local eff = vehicle.spec_sprayer.effects[1]
        if eff ~= nil and eff.node ~= nil then node = eff.node end
    end
    if node == nil then return false end

    local ox, _, oz = getWorldTranslation(node)
    local dirX, _, dirZ = localDirectionToWorld(node, 0, 0, 1)

    -- Liters delivered this tick, scaled by the sim clock so a fast timescale
    -- waters proportionally rather than in real seconds.
    local timeScale = 1.0
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
            and g_currentMission.missionInfo.timeScale ~= nil then
        timeScale = math.max(0.1, g_currentMission.missionInfo.timeScale)
    end
    local liters = IrrigatorSectorIntegration.FLOW_LPS * (elapsedMs / 1000) * timeScale
    liters = math.min(liters, level)
    if liters <= 0 then return false end

    -- Pie-sector area, then mm. 1 mm == 1 liter per square metre.
    local radius = IrrigatorSectorIntegration.RADIUS_M
    local sectorDeg = IrrigatorSectorIntegration.SECTOR_DEG
    local area = math.pi * radius * radius * (sectorDeg / 360.0)
    if area <= 0 then return false end
    local mm = liters / area

    -- Same constant the sprayer path uses: one store, one conversion.
    local perLiter = (SprayerIntegration ~= nil and SprayerIntegration.MOISTURE_PER_LITER_PER_SQM)
        or 0.0024
    local gain = mm * perLiter
    if gain <= 0 then return false end

    local pts = sectorPoints(ox, oz, dirX, dirZ, radius, sectorDeg,
        IrrigatorSectorIntegration.RINGS, IrrigatorSectorIntegration.SPOKES)

    local applied = false
    for _, p in ipairs(pts) do
        local x, z = p[1], p[2]
        local farmland = g_farmlandManager ~= nil
            and g_farmlandManager:getFarmlandAtWorldPosition(x, z) or nil
        if farmland ~= nil then
            -- Off-field samples are simply skipped: applyWaterAtCell no-ops on an
            -- unknown fieldId, so water thrown at a road wets nothing. That is the
            -- honest outcome rather than crediting it to the nearest field.
            soilSystem:applyWaterAtCell(farmland.id, x, z, gain)
            self._activeWateredFields[farmland.id] = true
            applied = true
        end
    end

    if not applied then return false end

    -- Drain what we delivered, on the server, through the normal fill unit API.
    if type(vehicle.addFillUnitFillLevel) == "function" then
        local farmId = vehicle:getOwnerFarmId()
        pcall(function()
            vehicle:addFillUnitFillLevel(farmId, fillUnitIndex, -liters,
                fillType or waterIndex, ToolType and ToolType.UNDEFINED or nil)
        end)
    end

    if self.manager ~= nil and self.manager.debugMode then
        print(string.format(
            "[CropStress] Irrigator sector @(%.1f,%.1f): %.1f L over %.0f m2 = %.3f mm, +%.5f moisture x%d cells",
            ox, oz, liters, area, mm, gain, #pts))
    end
    return true
end

--- Farmland ids an active vehicle irrigator watered on the last tick.
--- The PDA merges these into its covered-fields set so a Rainstar on a field
--- shows as irrigated without needing a placed pivot or drip line.
---@return table farmlandId -> true
function IrrigatorSectorIntegration:getActiveWateredFields()
    return self._activeWateredFields
end

function IrrigatorSectorIntegration:delete()
    self.isInitialized = false
    self._activeWateredFields = {}
end
