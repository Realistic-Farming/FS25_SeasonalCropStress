-- ============================================================
-- SoilMoistureSystem.lua
-- Maintains a soil moisture value (0.0–1.0) for every field on
-- the map. Updated every in-game hour via CropStressManager's
-- hourly tick.
--
-- Moisture rises from:
--   • Rainfall (via WeatherIntegration poll)
--   • Irrigation (Phase 2 — IrrigationManager sets irrigationGainRate)
-- Moisture falls from:
--   • Evapotranspiration: base rate × temp modifier × season modifier × soil modifier
-- ============================================================

SoilMoistureSystem = SoilMoistureSystem or {}
SoilMoistureSystem.__index = SoilMoistureSystem

-- Base evaporation per in-game hour (before modifiers).
-- At 1.0 modifier: 0.004 = 0.4% per hour → full evap in ~104 hours (~4 game days)
SoilMoistureSystem.BASE_EVAP_RATE = 0.004

-- SCS-020 TRANSPIRATION FEEDBACK: the share of evapotranspiration attributed to
-- crop transpiration, scaled by the 2m growth family's condition (SF-52/53's
-- published getFieldGrowthSummary). The soil-evaporation share (1 - the share) is
-- never scaled, so a blocked cell keeps its full soil drying; only transpiration
-- scales with the crop's condition. Dials awaiting the spine (neutral defaults).
SoilMoistureSystem.TRANSPIRATION_SHARE = 0.5
SoilMoistureSystem.BLOCKED_WEIGHT       = 0.5
SoilMoistureSystem.EXCELLENT_WEIGHT     = 0.25
SoilMoistureSystem.GROWTH_EVAP_MIN      = 0.25
SoilMoistureSystem.GROWTH_EVAP_MAX      = 1.25

-- SCS-020: the 2m growth family's per-field condition summary, duck-typed and
-- pull-only. Returns { blockedFrac, excellentFrac } or nil when SF is absent or
-- the getter is not present, which degrades to the neutral factor 1.0. Never a
-- write into SF's state (the firewall).
function SoilMoistureSystem:_growthSummary(fieldId)
    local sfm = g_currentMission ~= nil and g_currentMission.soilFertilityManager
    if sfm == nil or sfm.getFieldGrowthSummary == nil then return nil end
    local ok, summary = pcall(function() return sfm:getFieldGrowthSummary(fieldId) end)
    if not ok or type(summary) ~= "table" then return nil end
    return summary
end

-- Soil type evaporation modifiers and rain absorption coefficients
SoilMoistureSystem.SOIL_PARAMS = {
    sandy = { evapMod = 1.40, rainAbsorb = 1.25 },
    loamy = { evapMod = 1.00, rainAbsorb = 1.00 },
    clay  = { evapMod = 0.70, rainAbsorb = 0.72 },
}

-- Season-aware starting moisture (used when no saved state exists)
-- 0=spring, 1=summer, 2=autumn, 3=winter
SoilMoistureSystem.SEASON_START_MOISTURE = { [0]=0.60, [1]=0.50, [2]=0.55, [3]=0.70 }

-- Critical threshold — below this, fire CS_CRITICAL_THRESHOLD
SoilMoistureSystem.CRITICAL_MOISTURE = 0.25

-- ============================================================
-- PER-CELL MOISTURE STORE (SCS-018, the certified sparse-cell body)
-- A field's moisture becomes a property of the ground, cell by cell,
-- with the field scalar as the derived aggregate. Cells materialise
-- only where the ground genuinely differs (relief) or where water is
-- applied (pivot, drip, sprayer). Numbers below are the brief's ruled
-- values; the backstop cap is sized near SoilFertilizer's 1000.
-- ============================================================
SoilMoistureSystem.CELL_SENS               = 0.03   -- relief sensitivity (brief 3.2)
SoilMoistureSystem.CELL_RELIEF_THRESHOLD   = 0.10   -- |offset| above this materialises a cell
SoilMoistureSystem.CELL_RELIEF_MAX         = 0.30   -- relief offset clamp (plus or minus)
SoilMoistureSystem.CELL_BACKSTOP_CAP       = 1000   -- per-field max materialised cells
SoilMoistureSystem.CELL_DRAIN_FRACTION     = 0.05   -- daily downhill bleed per step (brief 3.4)
SoilMoistureSystem.CELL_DRAIN_NEIGHBOURS   = 4      -- downhill neighbours sampled per step
SoilMoistureSystem.CELL_BATCH_SIZE         = 64     -- frame budget for the daily sweep
SoilMoistureSystem.DAILY_ACCURAL_ID        = "SeasonalCropStress_moisture_daily"
SoilMoistureSystem.DAILY_ACCURAL_PRIORITY  = 90     -- below 100: ground settles before any economy read

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
-- CELL GRID HELPERS (SCS-018)
-- Cells align to SoilFertilizer's zone grid by shared formula:
--   cellSize = max(10, floor(terrainSize / 4096) * 10)
-- 10m on a 4x map, 20m at 8x, 40m at 16x. Key by nested integer
-- coordinates, NEVER encode into one number (brief 3.1).
-- ============================================================
function SoilMoistureSystem:getCellSize()
    if self._cellSize ~= nil then return self._cellSize end
    local terrainSize = 4096
    if g_currentMission ~= nil and g_currentMission.terrainSize ~= nil then
        terrainSize = g_currentMission.terrainSize
    end
    self._cellSize = math.max(10, math.floor(terrainSize / 4096) * 10)
    return self._cellSize
end

-- Derive integer cell coords from a world position (brief 3.1).
function SoilMoistureSystem:worldToCell(worldX, worldZ)
    local cs = self:getCellSize()
    return math.floor(worldX / cs), math.floor(worldZ / cs)
end

-- Field polygon in world space (mirror of IrrigationManager:getFieldPolygonWorld,
-- kept local so SoilMoistureSystem needs no cross-mod dependency). Returns
-- vx, vz, n or nil when the field has no usable polygon.
function SoilMoistureSystem:getFieldPolygonWorld(field)
    local pts = field and field.polygonPoints
    if pts == nil then return nil end
    local n = #pts
    if n < 3 then return nil end
    local vx, vz = {}, {}
    for i = 1, n do
        local node = pts[i]
        if node == nil or node == 0 then return nil end
        local wx, _, wz = getWorldTranslation(node)
        vx[i] = wx
        vz[i] = wz
    end
    return vx, vz, n
end

-- Even-odd point-in-polygon (the same guard IrrigationManager uses).
local function csPointInPolygon(px, pz, vx, vz, n)
    local inside = false
    local j = n
    for i = 1, n do
        if ((vz[i] > pz) ~= (vz[j] > pz)) and
           (px < (vx[j] - vx[i]) * (pz - vz[i]) / (vz[j] - vz[i]) + vx[i]) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function SoilMoistureSystem.new(manager)
    local self = setmetatable({}, SoilMoistureSystem)
    self.manager = manager

    -- keyed by fieldId (integer)
    -- Each entry:
    -- {
    --   fieldId         = number,
    --   moisture        = float (0.0-1.0),
    --   soilType        = string ("sandy"/"loamy"/"clay"),
    --   irrigationGain  = float (0.0 = none; set by IrrigationManager in Phase 2),
    --   centerX         = float (world X of field centre, used for RW cell sampling),
    --   centerZ         = float (world Z of field centre, used for RW cell sampling),
    -- }
    self.fieldData = {}

    -- When FS25_RealisticWeather is present this is g_currentMission.moistureSystem.
    -- hourlyUpdate() reads RW cells instead of running our own evap/rain simulation.
    self.rwMoistureSystem = nil

    self.irrigationGains = {}  -- fieldId -> total gain per hour

    -- Per-field cooldown to avoid spamming CS_CRITICAL_THRESHOLD
    self.criticalAlertCooldown = {}  -- fieldId → lastAlertHourKey

    -- SCS-018 per-cell store: derived-grid cell size (lazy), and a per-field
    -- relief-scan guard so the one-time materialisation pass runs once per field.
    self._cellSize = nil
    self._reliefScanned = {}   -- fieldId -> true once the relief pass ran

    -- SCS-018 daily settle: registered with Time Guard when present (server),
    -- otherwise driven by the fallback day-change hook inside hourlyUpdate.
    self._tgAccrualRegistered = false
    self._lastSettledDay = nil

    -- SCS-039: the vendored 2 m value map. nil until initValueMap runs, and
    -- still inert afterwards on any install where the engine cannot carry it.
    -- Every branch below tests mapActive(); when it is false NOTHING changes and
    -- the sparse-cell store above is the whole system, bit for bit.
    self.valueMap = nil
    self._fieldVerts = {}      -- fieldId -> {vx, vz, n}, cached polygon
    self._mapSeeded  = {}      -- fieldId -> true once migrated onto the map

    self.isInitialized = false
    return self
end

-- ============================================================
-- SCS-039 THE VALUE MAP: detection, and the one test every branch uses.
-- ============================================================

--- Stand the map up. Safe to call more than once. Returns true when the map is
--- carrying the moisture truth, false when the cell store still is.
function SoilMoistureSystem:initValueMap(savegameDir)
    if self.valueMap ~= nil then return self.valueMap.available end
    -- Once it has declined it stays declined for the session. Without this the
    -- nil-on-failure below would make every caller retry the whole engine probe.
    if self._valueMapTried then return false end
    self._valueMapTried = true
    if CropStressValueMap == nil then return false end

    -- SCS-039 ships LOCKED. Until the in-game layer look clears it, the map only
    -- stands up for a player who has opted into experimental systems; everyone
    -- else runs the shipped cell store, which is exactly today.
    if ReleaseGate ~= nil and ReleaseGate.isSystemLive ~= nil
       and not ReleaseGate.isSystemLive("cs_grid_concordance") then
        csLog("Moisture: the 2m value map is release-gated off; using the cell store")
        return false
    end

    self.valueMap = CropStressValueMap.new()
    local ok = self.valueMap:initialize(savegameDir)
    if ok then
        csLog("Moisture: the 2m value map is live; the cell store is now the fallback only")
    else
        -- THE DEGRADE, and it is the whole reason the scalar rows stay in the
        -- savegame. A map that cannot stand up (no engine, or a .grle that is
        -- missing or refuses to load) leaves the cell store and its per-field
        -- scalars carrying the save, with nothing lost but the sub-field detail.
        csLog("Moisture: the 2m value map declined; the cell store and its scalars carry this save")
        self.valueMap = nil
    end
    return ok
end

--- THE SINGLE DELEGATE TEST. Read it as "is the map carrying the truth".
function SoilMoistureSystem:mapActive()
    return self.valueMap ~= nil and self.valueMap.available == true
end

--- Field polygon in world space, cached. The map's region ops need it on every
--- hourly write, and rebuilding it per tick from scene nodes would be wasteful.
function SoilMoistureSystem:_getFieldVerts(fieldId)
    local cached = self._fieldVerts[fieldId]
    if cached ~= nil then
        if cached.n == 0 then return nil end
        return cached.vx, cached.vz, cached.n
    end
    local field = nil
    if g_fieldManager ~= nil and g_fieldManager.fields ~= nil then
        for _, f in pairs(g_fieldManager.fields) do
            if f.farmland ~= nil and f.farmland.id == fieldId then
                field = f
                break
            end
        end
    end
    local vx, vz, n = nil, nil, nil
    if field ~= nil then
        vx, vz, n = self:getFieldPolygonWorld(field)
    end
    if vx == nil or n == nil or n < 3 then
        -- Cache the refusal too, or every tick re-walks the field list.
        self._fieldVerts[fieldId] = { n = 0 }
        return nil
    end
    self._fieldVerts[fieldId] = { vx = vx, vz = vz, n = n }
    return vx, vz, n
end

--- ONE-TIME MIGRATION (brief step 4): seed the map from whatever the cell store
--- already knows, once per field, at the first engine-present load.
---
--- CLAMP-HONEST: the field is painted at its aggregate first so no pixel is left
--- at the raw-0 no-data sentinel, then each materialised cell stamps its own
--- value over the top. Totals are preserved up to each tier's clamp, which is
--- the most that can be promised when 10-40 m cells land on a 2 m grid.
function SoilMoistureSystem:migrateFieldToMap(fieldId)
    if not self:mapActive() then return false end
    if self._mapSeeded[fieldId] then return true end
    local d = self.fieldData[fieldId]
    if d == nil then return false end
    local vx, vz, n = self:_getFieldVerts(fieldId)
    if vx == nil then return false end

    self._mapSeeded[fieldId] = true
    local base = self:getFieldAggregate(d) or 0.5
    self.valueMap:paintPolygon(vx, vz, n, base)

    -- Stamp the materialised cells over the base coat. Absent cells were always
    -- "read the aggregate", and the base coat is exactly that, so nothing is lost.
    local cs = self:getCellSize()
    local stamped = 0
    if d.cells ~= nil then
        for cx, row in pairs(d.cells) do
            for cz, cell in pairs(row) do
                local wx = (cx + 0.5) * cs
                local wz = (cz + 0.5) * cs
                self.valueMap:writeValueAtWorld(wx, wz, cell.moisture, cs * 0.5)
                stamped = stamped + 1
            end
        end
    end
    csLog(string.format("Moisture map: field %d migrated (base=%.2f, %d cells stamped)",
        fieldId, base, stamped))
    return true
end

--- SCS-039: paint every tracked field onto the map from the store, once, so the
--- moisture overlay is not blank on the first open. A fresh map (no .grle) is
--- the only one seeded: a map restored from its own savegame file is already
--- the per-pixel truth and must not be flattened back to field averages.
---@return integer number of fields painted
function SoilMoistureSystem:seedMapFromStore()
    if not self:mapActive() then return 0 end
    if self.valueMap.loadedFromSave then return 0 end
    local count = 0
    for fid in pairs(self.fieldData) do
        if self:migrateFieldToMap(fid) then count = count + 1 end
    end
    if count > 0 then
        csLog(string.format("Moisture map: seeded %d fields from the store", count))
    end
    return count
end

function SoilMoistureSystem:initialize()
    -- Subscribe to irrigation events immediately (don't depend on fieldManager being ready)
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.subscribe("CS_IRRIGATION_STARTED", self.onIrrigationStarted, self)
        self.manager.eventBus.subscribe("CS_IRRIGATION_STOPPED", self.onIrrigationStopped, self)
    end

    self.isInitialized = true
end

-- Populate fieldData for every field on the map.
-- Uses g_fieldManager.fields directly (NPCFavor pattern) — more reliable than
-- g_currentMission.fieldManager:getFields() which can be nil until well after
-- isMissionStarted fires. Safe to call multiple times — skips fields already
-- in fieldData to preserve any save data loaded earlier.
-- Returns the number of NEW fields added. [SCS-036] The count now ALSO
-- includes backfilled records (a record that existed without a soilType,
-- detected and repaired here), so a client that backfills every field and
-- creates none reports the right work done rather than 0.
function SoilMoistureSystem:enumerateFields()
    if g_fieldManager == nil or g_fieldManager.fields == nil then
        csLog("SoilMoistureSystem: g_fieldManager unavailable — field enumeration deferred")
        return 0
    end

    -- currentSeason is a direct property on the environment object, not a method call.
    -- Normalise to 0-based (spring=0) — some FS25 builds return 1-based (1–4).
    local season = 0
    if g_currentMission ~= nil and g_currentMission.environment ~= nil then
        local rawSeason = g_currentMission.environment.currentSeason or 0
        if rawSeason >= 1 and rawSeason <= 4 then
            rawSeason = rawSeason - 1
        end
        season = rawSeason
    end
    local startMoisture = SoilMoistureSystem.SEASON_START_MOISTURE[season] or 0.50

    local count = 0
    for _, field in pairs(g_fieldManager.fields) do
        -- FS25: fields are identified by farmland ID. field.fieldId does not exist.
        local fid = field.farmland and field.farmland.id
        if fid ~= nil and self.fieldData[fid] == nil then
            -- field.posX/posZ are confirmed FS25 properties (set from polygon centroid in Field:load).
            -- field:getCenterOfFieldWorldPosition() returns the same values and is also valid.
            local cx = field.posX or 0
            local cz = field.posZ or 0
            self.fieldData[fid] = {
                fieldId        = fid,
                moisture       = startMoisture,
                soilType       = self:detectSoilType(field),
                irrigationGain = 0.0,
                centerX        = cx,
                centerZ        = cz,
                -- SCS-018: sparse per-cell store. cells[cx][cz] = { moisture = 0..1 }.
                -- cellSum/cellCount keep the derived aggregate O(1); relief is
                -- materialised once by the relief pass (called from CropStressManager
                -- after fields are ready). Absent cells simply read the aggregate.
                cells       = {},
                cellSum     = 0,
                cellCount   = 0,
                reliefScan  = false,
            }
            count = count + 1
        elseif fid ~= nil and self.fieldData[fid] ~= nil and self.fieldData[fid].soilType == nil then
            -- [SCS-036] THE BACKFILL: a record that EXISTS but has no soilType
            -- (a pre-fix client, or a wire handler that joined without one)
            -- gets one detected and written. The field object is already in
            -- scope from the same loop, so no new lookup is needed. Idempotent:
            -- one detection per field per peer per session; every later rebuild
            -- is a no-op. Counted so the return contract reports the repair.
            self.fieldData[fid].soilType = self:detectSoilType(field)
            count = count + 1
        end
    end

    if count > 0 then
        csLog(string.format(
            "SoilMoistureSystem: %d fields enumerated (season %d, start moisture=%.0f%%)",
            count, season, startMoisture * 100
        ))
    end
    return count
end

--- Called every in-game hour.
---
--- SCS-037 COMPOSITION SEAM: `elapsedHours` defaults to 1, which is exactly
--- today's behaviour. SCS-037 replaces the hourly EDGE DETECTOR with a real
--- elapsed count, and when it lands it passes that count here and this path
--- integrates it without any further change. The map's pending-delta
--- accumulator is what makes that safe: a 72-hour catch-up is 72 hours of
--- weather added to the accumulator, which then spends whole raw steps once,
--- rather than 72 separate sub-step writes that would each floor to nothing.
---@param weather table
---@param elapsedHours number|nil  hours since the last tick (default 1)
---@param rainHours number|nil  SCS-037 round 2: how many of those hours brought
---  rain, reconstructed from SoilFertilizer's Water Record. nil (the normal case)
---  means the sky is held at its last-known state for the whole span, which is
---  round-1 behaviour and identical to what shipped.
function SoilMoistureSystem:hourlyUpdate(weather, elapsedHours, rainHours)
    if not self.isInitialized then return end
    if weather == nil then return end
    local hours = math.max(1, math.floor(elapsedHours or 1))
    -- Clamped to the span: the record can never say it rained for more hours than
    -- the skip actually lasted.
    local wetHours = hours
    if rainHours ~= nil then
        wetHours = math.max(0, math.min(hours, rainHours))
    end

    -- SCS-018 RW unwind: SeasonalCropStress owns its whole moisture simulation.
    -- RealisticWeather remains a read-only WEATHER source through WeatherIntegration
    -- (temperature, rain); its moisture grid is neither read nor written. So the
    -- hourly path always runs our own simulation and there is no RW moisture sync.
    if self.rwMoistureSystem ~= nil then
        -- (legacy wiring cleared below; own simulation always runs)
    end

    local evapMultiplier = weather:getHourlyEvapMultiplier()
    local rainAmount     = weather:getHourlyRainAmount()

    -- currentHour is a direct property on the environment object, not a method call
    local env     = g_currentMission and g_currentMission.environment
    local hourKey = 0
    if env ~= nil then
        hourKey = (env.currentMonotonicDay or 0) * 24 + (env.currentHour or 0)
    end

    -- Hoist SoilFertilizer integration reference outside the field loop — it is
    -- constant for the entire tick and resolving it per-field is wasteful.
    local settingsEvapMult = self.evapMultiplier or 1.0
    local sfInteg = self.manager and self.manager.soilFertilizerIntegration
    local sfHasEvap   = sfInteg ~= nil and type(sfInteg.getFieldEvapMod)   == "function"
    local sfHasStress = sfInteg ~= nil and type(sfInteg.getFieldStressMod) == "function"

    for fieldId, data in pairs(self.fieldData) do
        local soilParams = SoilMoistureSystem.SOIL_PARAMS[data.soilType]
            or SoilMoistureSystem.SOIL_PARAMS.loamy

        -- Evapotranspiration loss this hour.
        -- evapMultiplier   = weather-based (temperature + season) from WeatherIntegration
        -- settingsEvapMult = player-configured multiplier (difficulty × evap rate setting)
        -- sfEvapMod        = per-field organic matter modifier from FS25_SoilFertilizer (if present)
        --                    High OM (>5%) lowers evap; poor OM (<1%) raises it. Default 1.0.
        local sfEvapMod = sfHasEvap and sfInteg:getFieldEvapMod(fieldId) or 1.0
        -- Every term below is a PER-HOUR quantity, so each is multiplied by the
        -- elapsed count. At the default of 1 this is arithmetically identical to
        -- what shipped; SCS-037 changes only what arrives in `hours`.
        local evapPerHour = SoilMoistureSystem.BASE_EVAP_RATE
            * evapMultiplier
            * soilParams.evapMod
            * settingsEvapMult
            * sfEvapMod

        -- SCS-020 TRANSPIRATION FEEDBACK: a field with cells blocked by SF-52's
        -- viability mask draws less water and stays wetter; a field growing at
        -- excellent credit draws more and dries faster. Only the transpiration
        -- share is scaled, never the soil-evaporation share, so a blocked cell
        -- keeps its full soil drying (the pinned invariant). Duck-typed read of
        -- SF's getFieldGrowthSummary, neutral 1.0 when absent.
        local growthEvapMod = 1.0
        local summary = self:_growthSummary(fieldId)
        if summary ~= nil then
            local blocked    = summary.blockedFrac or 0
            local excellent  = summary.excellentFrac or 0
            growthEvapMod = SoilMoistureSystem.GROWTH_EVAP_MIN
            local v = 1 - SoilMoistureSystem.BLOCKED_WEIGHT * blocked
                     + SoilMoistureSystem.EXCELLENT_WEIGHT * excellent
            if v > growthEvapMod then growthEvapMod = v end
            if growthEvapMod > SoilMoistureSystem.GROWTH_EVAP_MAX then
                growthEvapMod = SoilMoistureSystem.GROWTH_EVAP_MAX
            end
        end
        local soilEvapShare = evapPerHour * (1 - SoilMoistureSystem.TRANSPIRATION_SHARE) * hours
        local transpShare   = evapPerHour * SoilMoistureSystem.TRANSPIRATION_SHARE * hours
        local evapLoss = soilEvapShare + transpShare * growthEvapMod

        -- Rain gain (modulated by soil absorption). Charged over `wetHours`, which
        -- is the whole span unless the Water Record narrowed it (SCS-037 round 2).
        local rainGain  = rainAmount * soilParams.rainAbsorb * wetHours
        local irrigGain = (self.irrigationGains[fieldId] or 0.0) * hours

        local prevMoisture = self:getFieldAggregate(data)
        -- SCS-039 MAP PATH. The hourly net is almost always SMALLER than one raw
        -- step (one step is ~0.0039 moisture), so writing it straight through
        -- would floor to nothing every hour and the ground would stop answering
        -- the weather entirely. Accumulate instead, and spend only whole steps.
        -- The remainder is carried, so nothing is lost and nothing is invented.
        if self:mapActive() then
            self:migrateFieldToMap(fieldId)
            local net = -evapLoss + rainGain + irrigGain
            local pending = (data.mapPending or 0) + net
            local applied, remainder = CropStressValueMap.quantiseDelta(pending)
            data.mapPending = remainder
            if applied ~= 0 then
                local vx, vz, n = self:_getFieldVerts(fieldId)
                if vx ~= nil then
                    local moved = self.valueMap:applyDeltaToPolygon(vx, vz, n, applied)
                    if moved == 0 then
                        -- The engine refused the add path. Give the delta back to
                        -- the accumulator rather than dropping it on the floor.
                        data.mapPending = pending
                    else
                        -- applyDeltaToPolygon shifts every written pixel by the
                        -- same amount, so the field mean moves by exactly that.
                        -- The daily settle re-derives from the map and corrects
                        -- any drift the positional writes introduce.
                        data.moisture = math.max(0.0, math.min(1.0, data.moisture + moved))
                    end
                end
            end
        elseif data.cellCount ~= nil and data.cellCount > 0 then
            local net = -evapLoss + rainGain + irrigGain
            local newSum = 0
            for cx, row in pairs(data.cells) do
                for cz, cell in pairs(row) do
                    cell.moisture = math.max(0.0, math.min(1.0, cell.moisture + net))
                    newSum = newSum + cell.moisture
                end
            end
            data.cellSum = newSum
            data.moisture = newSum / data.cellCount
        else
            data.moisture = math.max(0.0, math.min(1.0,
                data.moisture - evapLoss + rainGain + irrigGain))
        end

        -- Publish moisture update event
        if self.manager ~= nil and self.manager.eventBus ~= nil then
            self.manager.eventBus.publish("CS_MOISTURE_UPDATED", {
                fieldId  = fieldId,
                previous = prevMoisture,
                current  = self:getFieldAggregate(data),
            })
        end

        -- Critical threshold check (12-hour cooldown per field to avoid spam).
        -- Use getCriticalMoisture() so the player's settings value is honoured;
        -- falls back to the class constant if applySettings() hasn't run yet.
        -- SoilFertilizer pH modifier raises the threshold for acid/alkaline fields,
        -- and the compaction modifier sharpens the swing on compacted ground
        -- (crops become moisture-stressed at a higher moisture level when pH is
        -- poor or the soil is compacted). Both are Arrow-2 reads, never a write.
        local sfStressMod = sfHasStress and sfInteg:getFieldStressMod(fieldId) or 0.0
        local sfCompactMod = (sfInteg ~= nil and type(sfInteg.getFieldCompactMod) == "function")
            and sfInteg:getFieldCompactMod(fieldId) or 0.0
        local agg = self:getFieldAggregate(data)
        if agg <= (self:getCriticalMoisture() + sfStressMod + sfCompactMod) then
            local lastAlert = self.criticalAlertCooldown[fieldId] or -999
            if (hourKey - lastAlert) >= 12 then
                self.criticalAlertCooldown[fieldId] = hourKey
                if self.manager ~= nil and self.manager.eventBus ~= nil then
                    self.manager.eventBus.publish("CS_CRITICAL_THRESHOLD", {
                        fieldId       = fieldId,
                        moistureLevel = agg,
                    })
                end
            end
        end

        if self.manager ~= nil and self.manager.debugMode then
            csLog(string.format(
                "Field %d: %.1f%% → %.1f%% (evap=%.4f rain=%.4f irr=%.4f cells=%d)",
                fieldId, prevMoisture * 100, agg * 100,
                evapLoss, rainGain, irrigGain,
                data.cellCount or 0
            ))
        end
    end
end

-- Returns moisture (0.0–1.0) for a field, or nil if unknown.
-- With a world position, returns the cell moisture where a cell exists,
-- else the field aggregate (SCS-018 positional getter, never nil).
-- Without a position, returns the derived aggregate.
--- SCS-039 THE CONCORDANCE: every read now also reports the GRAIN it was
--- measured at, in metres, as a second return. A consumer that cares can tell a
--- 2 m map reading from a 10-40 m cell reading; one that does not care ignores
--- the extra value and behaves exactly as it always has. That additive shape is
--- why all six existing consumers are untouched.
---@return number|nil moisture 0..1
---@return number|nil grainMetres
function SoilMoistureSystem:getMoisture(fieldId, x, z)
    local d = self.fieldData[fieldId]
    if d == nil then return nil, nil end

    if x ~= nil and z ~= nil then
        if self:mapActive() then
            local v, grain = self.valueMap:readValueAtWorld(x, z)
            -- nil means nothing is written at that pixel (off-field or not yet
            -- seeded), which is the aggregate's job to answer, not a hole.
            if v ~= nil then return v, grain end
            return self:getFieldAggregate(d), grain
        end
        local cx, cz = self:worldToCell(x, z)
        local row = d.cells and d.cells[cx]
        local cell = row and row[cz]
        if cell ~= nil then return cell.moisture, self:getCellSize() end
        return self:getFieldAggregate(d), self:getCellSize()
    end

    -- Field-level read: the scalar is the derived aggregate either way, so the
    -- grain reported is the field itself rather than any cell size.
    return self:getFieldAggregate(d), nil
end

-- Derived field aggregate, O(1). Once a field has cells it is the mean of the
-- materialised cells; before any cell exists it returns exactly the field scalar.
function SoilMoistureSystem:getFieldAggregate(d)
    if d == nil then return nil end
    if d.cellCount ~= nil and d.cellCount > 0 then
        return d.cellSum / d.cellCount
    end
    return d.moisture
end

-- THE SINGLE WRITE PATH (SCS-018 brief 3.3): read the cell, compute, write the
-- cell, adjust the field's running sum by the delta, in that order. All eight
-- simulation doors fold through here. Returns the new aggregate.
function SoilMoistureSystem:_writeCell(fieldId, cx, cz, newValue)
    local d = self.fieldData[fieldId]
    if d == nil then return nil end
    if d.cells == nil then d.cells = {} end
    if d.cellCount == nil then d.cellCount = 0 end
    if d.cellSum == nil then d.cellSum = 0 end
    newValue = math.max(0.0, math.min(1.0, newValue or 0))
    local row = d.cells[cx]
    if row == nil then
        row = {}
        d.cells[cx] = row
    end
    local cell = row[cz]
    if cell == nil then
        -- New cell seeds from the field's CURRENT aggregate (brief 3.2).
        local seed = self:getFieldAggregate(d)
        cell = { moisture = seed }
        row[cz] = cell
        d.cellCount = d.cellCount + 1
        d.cellSum = d.cellSum + seed
    end
    local delta = newValue - cell.moisture
    cell.moisture = newValue
    d.cellSum = d.cellSum + delta
    return self:getFieldAggregate(d)
end

-- Field-level write: adjusts the scalar and (where cells exist) every cell
-- uniformly, so the aggregate follows. Used by the weather/irrigation gains
-- that land field-wide (doors 1/5/7 keep their per-cell form where geometry
-- applies; this is the flat-gain fallback).
function SoilMoistureSystem:_writeFieldMoisture(fieldId, newValue)
    local d = self.fieldData[fieldId]
    if d == nil then return nil end
    newValue = math.max(0.0, math.min(1.0, newValue or 0))

    -- SCS-039: a field-level set must reach the MAP, or the daily re-derive
    -- reads the untouched ground back over it and the write silently reverts.
    -- That would make csSetMoisture and the sprayer path look like they worked
    -- for a few hours and then undo themselves, which is worse than refusing.
    if self:mapActive() then
        self:migrateFieldToMap(fieldId)
        local vx, vz, n = self:_getFieldVerts(fieldId)
        if vx ~= nil then
            self.valueMap:paintPolygon(vx, vz, n, newValue)
        end
        -- The scalar is the derived aggregate, and a uniform paint makes the
        -- mean exactly the painted value. Any carried sub-step delta is now
        -- stale: it was accumulated against ground that no longer exists.
        d.mapPending = 0
        d.moisture = newValue
        return newValue
    end

    if d.cellCount ~= nil and d.cellCount > 0 then
        local delta = newValue - self:getFieldAggregate(d)
        for _, row in pairs(d.cells) do
            for _, cell in pairs(row) do
                cell.moisture = math.max(0.0, math.min(1.0, cell.moisture + delta))
            end
        end
        d.cellSum = d.cellSum + delta * d.cellCount
    end
    d.moisture = newValue
    return newValue
end

-- Force-set moisture (debug console + SprayerIntegration). Field-level keeps
-- today's signature; the sprayer per-cell path calls _writeCell directly.
function SoilMoistureSystem:setMoisture(fieldId, value)
    if self.fieldData[fieldId] ~= nil then
        self:_writeFieldMoisture(fieldId, value)
        return true
    end
    return false
end

function SoilMoistureSystem:getFieldCount()
    local count = 0
    for _ in pairs(self.fieldData) do count = count + 1 end
    return count
end

-- ============================================================
-- SCS-018 RELIEF MATERIALISATION (brief 3.2)
-- A cell materialises when its relief offset from the field mean exceeds
-- the threshold:  offset = CELL_SENS * (meanHeight - cellHeight), clamped
-- to plus/minus CELL_RELIEF_MAX. The backstop cap bounds materialised cells
-- per field. Runs once per field after fields are ready.
-- ============================================================
function SoilMoistureSystem:materialiseRelief(fieldId)
    local d = self.fieldData[fieldId]
    if d == nil or d.reliefScan then return end
    d.reliefScan = true
    if d.cells == nil then d.cells = {} end
    if d.cellCount == nil then d.cellCount = 0 end
    if d.cellSum == nil then d.cellSum = 0 end
    self._reliefScanned[fieldId] = true

    local field = nil
    if g_fieldManager ~= nil and g_fieldManager.fields ~= nil then
        for _, f in pairs(g_fieldManager.fields) do
            if f.farmland ~= nil and f.farmland.id == fieldId then
                field = f
                break
            end
        end
    end
    if field == nil then return end

    local vx, vz, n = self:getFieldPolygonWorld(field)
    if vx == nil or n < 3 then return end

    local cs = self:getCellSize()
    -- Field bounding box in world space.
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        if vx[i] < minX then minX = vx[i] end
        if vx[i] > maxX then maxX = vx[i] end
        if vz[i] < minZ then minZ = vz[i] end
        if vz[i] > maxZ then maxZ = vz[i] end
    end

    -- Sample terrain height at every cell centre inside the polygon, collect
    -- them, then materialise cells whose relief offset exceeds the threshold.
    local heights = {}
    local count = 0
    local cellMinX = math.floor(minX / cs)
    local cellMaxX = math.floor(maxX / cs)
    local cellMinZ = math.floor(minZ / cs)
    local cellMaxZ = math.floor(maxZ / cs)
    for cx = cellMinX, cellMaxX do
        for cz = cellMinZ, cellMaxZ do
            local wx = (cx + 0.5) * cs
            local wz = (cz + 0.5) * cs
            if csPointInPolygon(wx, wz, vx, vz, n) then
                local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, wx, 0, wz)
                if ok and h ~= nil then
                    count = count + 1
                    heights[count] = { cx = cx, cz = cz, h = h }
                end
            end
        end
    end
    if count == 0 then return end

    local meanH = 0
    for i = 1, count do meanH = meanH + heights[i].h end
    meanH = meanH / count

    local materialised = 0
    for i = 1, count do
        if materialised >= SoilMoistureSystem.CELL_BACKSTOP_CAP then break end
        local entry = heights[i]
        local offset = SoilMoistureSystem.CELL_SENS * (meanH - entry.h)
        if offset > SoilMoistureSystem.CELL_RELIEF_MAX then offset = SoilMoistureSystem.CELL_RELIEF_MAX end
        if offset < -SoilMoistureSystem.CELL_RELIEF_MAX then offset = -SoilMoistureSystem.CELL_RELIEF_MAX end
        if math.abs(offset) > SoilMoistureSystem.CELL_RELIEF_THRESHOLD then
            local cell = d.cells[entry.cx]
            if cell == nil then cell = {}; d.cells[entry.cx] = cell end
            cell[entry.cz] = { moisture = self:getFieldAggregate(d) }
            d.cellCount = d.cellCount + 1
            d.cellSum = d.cellSum + cell[entry.cz].moisture
            materialised = materialised + 1
        end
    end

    csLog(string.format("Moisture store: field %d materialised %d/%d relief cells (mean=%.2f)",
        fieldId, materialised, count, meanH))
end

-- ============================================================
-- SCS-018 PER-CELL WATER (brief 3.5)
-- Water lands on places, not fields. These apply a gain at a specific cell,
-- materialising it if needed (the materialisation door for water application).
-- ============================================================
function SoilMoistureSystem:applyWaterAtCell(fieldId, x, z, gain)
    local d = self.fieldData[fieldId]
    if d == nil or gain <= 0 then return end

    -- SCS-039: water lands on a PLACE, and on the map that place is a 2 m pixel
    -- instead of a 10-40 m cell. Read what is there, add the gain, write it back.
    -- No accumulator here: an irrigation gain at a point is a real quantity at a
    -- real spot, not a field-wide sub-step drift, and the pivot's own pass writes
    -- enough water to clear the floor.
    if self:mapActive() then
        self:migrateFieldToMap(fieldId)
        local current = self.valueMap:readValueAtWorld(x, z)
        if current == nil then current = self:getFieldAggregate(d) or 0 end
        local grain = self.valueMap:getGrainMetres() or 2
        self.valueMap:writeValueAtWorld(x, z, math.max(0.0, math.min(1.0, current + gain)), grain * 0.5)
        -- The field aggregate is re-derived from the map on the daily settle;
        -- a single pixel's gain is below the noise of the field mean until then.
        return
    end

    local cx, cz = self:worldToCell(x, z)
    local row = d.cells[cx]
    if row == nil then
        if (d.cellCount or 0) >= SoilMoistureSystem.CELL_BACKSTOP_CAP then return end
        row = {}
        d.cells[cx] = row
    end
    local cell = row[cz]
    if cell == nil then
        if (d.cellCount or 0) >= SoilMoistureSystem.CELL_BACKSTOP_CAP then return end
        cell = { moisture = self:getFieldAggregate(d) }
        row[cz] = cell
        d.cellCount = d.cellCount + 1
        d.cellSum = d.cellSum + cell.moisture
    end
    cell.moisture = math.max(0.0, math.min(1.0, cell.moisture + gain))
    d.cellSum = d.cellSum + gain
    if d.cellSum > d.cellCount then d.cellSum = d.cellCount end
    -- Vera F1 (BUILD 19:44): keep the field scalar level with the cell aggregate.
    -- Readers are split: getMoisture/getFieldAggregate compute from cells, but the
    -- Esc field table and CropStressNetworkSyncBridge:serializeFields both paint
    -- the raw d.moisture scalar. Without this line water lands, cells rise, and
    -- every surface the player actually looks at keeps showing the old number.
    d.moisture = self:getFieldAggregate(d)
end

-- ============================================================
-- SCS-018 DAILY SETTLE (brief 3.4): decay + drainage on the day cadence.
-- Settled once per elapsed in-game day via Time Guard (server) or the fallback
-- day-change hook. Decay conserves the field total exactly (measured).
-- ============================================================
function SoilMoistureSystem:settleDaily(boundariesCrossed)
    local days = math.max(1, boundariesCrossed or 1)

    -- SCS-039: on the map, the daily settle is also where the field scalar is
    -- RE-DERIVED from the ground rather than trusted. The hourly path keeps it
    -- exact for uniform shifts, but positional writes (a pivot wetting its
    -- circle) move the real mean by an area fraction we do not track per write.
    -- Re-deriving once a day makes the scalar self-correcting instead of
    -- slowly drifting away from the map it is supposed to describe.
    if self:mapActive() then
        -- Instrumented: the brief's one open measurement is the in-game frame
        -- cost of this pass, so it is measured rather than estimated. Read it
        -- with csMapStats.
        local t0 = (g_currentMission ~= nil and g_currentMission.time) or nil
        local fields, blocks = 0, 0
        for fieldId, d in pairs(self.fieldData) do
            local drained = self:_drainFieldOnMap(fieldId, days)
            if drained then
                fields = fields + 1
                blocks = blocks + (self._lastFieldBlocks or 0)
            end
            local vx, vz, n = self:_getFieldVerts(fieldId)
            if vx ~= nil then
                local mean = self.valueMap:readAverageOfPolygon(vx, vz, n)
                if mean ~= nil then d.moisture = mean end
            end
        end
        self._lastSettleFields = fields
        self._lastSettleBlocks = blocks
        if t0 ~= nil and g_currentMission.time ~= nil then
            self._lastSettleMs = g_currentMission.time - t0
        end
        self._lastSettledDay = (g_currentMission ~= nil and g_currentMission.environment ~= nil
            and g_currentMission.environment.currentMonotonicDay) or nil
        return
    end

    for fieldId, d in pairs(self.fieldData) do
        if d.cellCount ~= nil and d.cellCount > 0 then
            -- Drainage: bleed a fraction of each cell's moisture toward its
            -- downhill neighbours, conserving the field total (the write path
            -- keeps cellSum honest; drainage only moves water between cells).
            -- Simplest conserving form: a small uniform redistribution. This
            -- keeps "the hollow stays wetter" while conserving the total.
            local mean = d.cellSum / d.cellCount
            for cx, row in pairs(d.cells) do
                for cz, cell in pairs(row) do
                    local drift = (cell.moisture - mean) * SoilMoistureSystem.CELL_DRAIN_FRACTION
                    cell.moisture = math.max(0.0, math.min(1.0, cell.moisture - drift * days))
                end
            end
            -- Recompute the sum; conservation is exact because drift sums to ~0
            -- over the field (cells above mean give, cells below take).
            local sum = 0
            for cx, row in pairs(d.cells) do
                for cz, cell in pairs(row) do
                    sum = sum + cell.moisture
                end
            end
            d.cellSum = sum
            d.moisture = sum / d.cellCount
        end
    end
    self._lastSettledDay = (g_currentMission ~= nil and g_currentMission.environment ~= nil
        and g_currentMission.environment.currentMonotonicDay) or nil
end

-- ============================================================
-- SCS-039 CONSERVED DRAINAGE ON THE MAP (brief step 4 / the geometry audit's
-- build law). Water moves DOWNHILL and the field total does not change.
--
-- FRESH HEIGHT READS EVERY TIME, and that is the audit's law rather than a
-- preference: terrain is deformable (levelling placeables, rice fields), so a
-- cached relief picture goes stale the day a player reshapes the ground and
-- then drains water toward a hollow that no longer exists.
--
-- Conservation is by construction, the same additive shape the rest of this
-- work uses: every block's drift is measured against the block mean, so the
-- drifts sum to zero and the field total cannot move. Drainage only ever
-- REDISTRIBUTES; evaporation and rain are the hourly path's job.
-- ============================================================
SoilMoistureSystem.MAP_DRAIN_BLOCK      = 16     -- metres per sampled block
SoilMoistureSystem.MAP_DRAIN_MAX_BLOCKS = 400    -- per field, per settle

function SoilMoistureSystem:_drainFieldOnMap(fieldId, days)
    if not self:mapActive() then return false end
    if getTerrainHeightAtWorldPos == nil or g_terrainNode == nil then return false end
    local vx, vz, n = self:_getFieldVerts(fieldId)
    if vx == nil then return false end

    local step = SoilMoistureSystem.MAP_DRAIN_BLOCK
    local half = step * 0.5
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        if vx[i] < minX then minX = vx[i] end
        if vx[i] > maxX then maxX = vx[i] end
        if vz[i] < minZ then minZ = vz[i] end
        if vz[i] > maxZ then maxZ = vz[i] end
    end

    -- Pass 1: sample the ground and the water at each block centre inside the
    -- polygon. Both reads are fresh; neither is cached between settles.
    local bx, bz, bh, bm = {}, {}, {}, {}
    local count = 0
    local x = minX + half
    while x <= maxX and count < SoilMoistureSystem.MAP_DRAIN_MAX_BLOCKS do
        local z = minZ + half
        while z <= maxZ and count < SoilMoistureSystem.MAP_DRAIN_MAX_BLOCKS do
            if csPointInPolygon(x, z, vx, vz, n) then
                local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, x, 0, z)
                local m = self.valueMap:readValueAtWorld(x, z)
                if ok and h ~= nil and m ~= nil then
                    count = count + 1
                    bx[count], bz[count], bh[count], bm[count] = x, z, h, m
                end
            end
            z = z + step
        end
        x = x + step
    end
    self._lastFieldBlocks = count
    if count < 2 then return false end

    -- Pass 2: the drift. A block's share of the move is set by how far its
    -- GROUND sits from the field's mean ground, so water leaves high blocks and
    -- arrives at low ones; the amount it can give is bounded by how much water
    -- it holds relative to the field's mean water, so a dry ridge cannot donate
    -- water it does not have.
    local sumH, sumM = 0, 0
    for i = 1, count do
        sumH = sumH + bh[i]
        sumM = sumM + bm[i]
    end
    local meanH, meanM = sumH / count, sumM / count

    local frac = math.min(0.5, SoilMoistureSystem.CELL_DRAIN_FRACTION * math.max(1, days))

    -- TWO TERMS, AND EACH ONE SUMS TO ZERO ON ITS OWN, so their sum does too and
    -- conservation needs no correction pass to rescue it:
    --   waterTerm  = (meanM - m_i)  levels the water toward the field mean
    --   reliefTerm = (meanH - h_i) * CELL_SENS  pushes it downhill, positive for
    --                low ground, so a hollow gains and a ridge gives
    -- Both are deviations from a mean over the same block set, which is exactly
    -- why they are zero-sum for every possible field shape.
    for i = 1, count do
        local waterTerm  = (meanM - bm[i])
        local reliefTerm = (meanH - bh[i]) * SoilMoistureSystem.CELL_SENS
        local addition   = frac * (waterTerm + reliefTerm)
        -- The write clamps to 0..1. On a field already sitting at a bound the
        -- clamp absorbs part of the move, which is the known clamp residual and
        -- the one place conservation is approximate rather than exact.
        self.valueMap:writeValueAtWorld(bx[i], bz[i], bm[i] + addition, half)
    end
    return true
end

--- The drainage maths, pure and engine-free so the bench can prove the two
--- claims that matter: the additions sum to zero (the field total does not
--- move) and low ground gains while high ground gives.
---@param heights number[]   terrain height per block
---@param moistures number[] current moisture per block
---@param frac number        settle fraction for the elapsed days
---@return number[] additions  signed moisture change per block
function SoilMoistureSystem.computeDrainageAdditions(heights, moistures, frac)
    local n = heights and #heights or 0
    if n < 2 or moistures == nil or #moistures ~= n then return nil end
    local sumH, sumM = 0, 0
    for i = 1, n do
        sumH = sumH + heights[i]
        sumM = sumM + moistures[i]
    end
    local meanH, meanM = sumH / n, sumM / n
    local out = {}
    for i = 1, n do
        out[i] = frac * ((meanM - moistures[i])
                       + (meanH - heights[i]) * SoilMoistureSystem.CELL_SENS)
    end
    return out
end

-- ============================================================
-- SCS-039 MP DELIVERY: the server walks the map to a joining client a few rows
-- per frame. Never in one payload: a 2048x2048 map is 4 MB of raw bytes, and
-- sending it whole would stall the join for everyone already in the game.
-- ============================================================
SoilMoistureSystem.SYNC_ROWS_PER_FRAME = 8

--- Queue the whole map for a connection. Safe to call for each joining client.
function SoilMoistureSystem:queueMapSync(connection)
    if not self:mapActive() or connection == nil then return false end
    if g_server == nil then return false end
    self._syncQueue = self._syncQueue or {}
    self._syncQueue[#self._syncQueue + 1] = { conn = connection, nextRow = 0 }
    return true
end

--- Drive the queue. Called from the manager's per-frame update on the server.
--- Returns the number of rows sent this frame (0 when there is nothing to do),
--- which is also what makes the cost visible to the instrument below.
function SoilMoistureSystem:updateMapSync()
    local q = self._syncQueue
    if q == nil or #q == 0 then return 0 end
    if not self:mapActive() then
        self._syncQueue = nil
        return 0
    end

    local job = q[1]
    local total = self.valueMap:getSyncRowCount()
    local sent = 0
    while sent < SoilMoistureSystem.SYNC_ROWS_PER_FRAME and job.nextRow < total do
        local raw = self.valueMap:readSyncRow(job.nextRow)
        if raw ~= nil and CropStressMoistureRowEvent ~= nil then
            local packed = CropStressValueMap.packRow(raw)
            g_server:sendEvent(CropStressMoistureRowEvent.new(job.nextRow, packed),
                false, nil, job.conn)
        end
        job.nextRow = job.nextRow + 1
        sent = sent + 1
    end

    if job.nextRow >= total then
        table.remove(q, 1)
        csLog(string.format("Moisture map: delivered %d rows to a client", total))
    end
    self._syncTotalRowsSent = (self._syncTotalRowsSent or 0) + sent
    return sent
end

-- ============================================================
-- SCS-039 THE FRAME-COST INSTRUMENT (the brief's one named open measurement).
-- Nothing here changes behaviour; it makes the cost the brief asked K to
-- measure READABLE in-game instead of guessed at, via csMapStats.
-- ============================================================
function SoilMoistureSystem:getMapStats()
    local s = {
        active         = self:mapActive(),
        settleMs       = self._lastSettleMs,
        settleBlocks   = self._lastSettleBlocks,
        settleFields   = self._lastSettleFields,
        syncRowsSent   = self._syncTotalRowsSent or 0,
        syncPending    = (self._syncQueue ~= nil) and #self._syncQueue or 0,
        seededFields   = 0,
    }
    for _ in pairs(self._mapSeeded or {}) do s.seededFields = s.seededFields + 1 end
    if self.valueMap ~= nil and self.valueMap.getDebugStats ~= nil then
        s.map = self.valueMap:getDebugStats()
    end
    return s
end

-- Register the daily accrual with Time Guard when present (server only).
-- Returns true when registered, false when Time Guard is absent (fallback used).
function SoilMoistureSystem:registerDailyAccrual()
    if self._tgAccrualRegistered then return true end
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.registerAccrual) ~= "function" then
        return false
    end
    -- Version-skew guard (brief 3.4): an old Time Guard silently coerces an
    -- unknown flowClass to calendar. The simulation class shipped in TimeGuard
    -- 1.0.0.0; if it is absent, do not register against a mislabelled flow.
    if tg.flowClasses ~= nil and tg.flowClasses.simulation ~= true then
        csLog("Moisture store: Time Guard has no 'simulation' flow class; using fallback day hook")
        return false
    end
    if TimeGuardScheduler ~= nil and TimeGuardScheduler.FLOW_CLASSES ~= nil
        and TimeGuardScheduler.FLOW_CLASSES.simulation ~= true then
        csLog("Moisture store: TimeGuardScheduler has no 'simulation' flow class; using fallback day hook")
        return false
    end
    local ok, err = pcall(function()
        tg:registerAccrual(SoilMoistureSystem.DAILY_ACCURAL_ID, {
            cadence = "day",
            flowClass = "simulation",
            firstPeriodPolicy = "skip",
            priority = SoilMoistureSystem.DAILY_ACCURAL_PRIORITY,
            onSettle = function(ctx)
                self:settleDaily(ctx ~= nil and ctx.boundariesCrossed or 1)
            end,
        })
    end)
    if ok then
        self._tgAccrualRegistered = true
        csLog("Moisture store: registered daily settle with Time Guard")
        return true
    end
    csLog("Moisture store: Time Guard registration failed (%s); using fallback day hook", tostring(err))
    return false
end

-- Fallback day-change hook: called from CropStressManager on the day rollover
-- when Time Guard is absent. Accepts the known skipped-day limitation.
function SoilMoistureSystem:checkDayFallback()
    if self._tgAccrualRegistered then return end
    local env = g_currentMission ~= nil and g_currentMission.environment
    if env == nil then return end
    local day = env.currentMonotonicDay or env.currentDay or 0
    if self._lastSettledDay ~= nil and day ~= self._lastSettledDay then
        self:settleDaily(1)
    end
    self._lastSettledDay = day
end

-- ============================================================
-- SCS-018 SERIALIZATION HELPERS (brief 3.8)
-- One packed leaf per field for both StateLedger and the XML safety copy.
-- Format: "cx,cz:m;cx,cz:m;..." with moisture as an integer 0..10000.
-- ============================================================
function SoilMoistureSystem:packCells(fieldId)
    local d = self.fieldData[fieldId]
    if d == nil or d.cellCount == nil or d.cellCount == 0 then return nil end
    local parts = {}
    for cx, row in pairs(d.cells) do
        for cz, cell in pairs(row) do
            parts[#parts + 1] = string.format("%d,%d:%d", cx, cz, math.floor(cell.moisture * 10000 + 0.5))
        end
    end
    return table.concat(parts, ";")
end

function SoilMoistureSystem:unpackCells(fieldId, packed)
    local d = self.fieldData[fieldId]
    if d == nil or packed == nil or packed == "" then return end
    d.cells = {}
    d.cellSum = 0
    d.cellCount = 0
    for part in string.gmatch(packed, "[^;]+") do
        local cxStr, czStr, valStr = part:match("^(%d+),(%d+):(%d+)$")
        if cxStr ~= nil then
            local cx = tonumber(cxStr)
            local cz = tonumber(czStr)
            local val = tonumber(valStr)
            local row = d.cells[cx]
            if row == nil then row = {}; d.cells[cx] = row end
            row[cz] = { moisture = val / 10000 }
            d.cellCount = d.cellCount + 1
            d.cellSum = d.cellSum + val / 10000
        end
    end
    -- Sibling of the F1 path: rebuilding cells on load moves the aggregate, so the
    -- scalar has to follow or a reloaded save paints the pre-save number.
    d.moisture = self:getFieldAggregate(d)
end

-- Returns a sorted list of {fieldId, moisture, soilType} for HUD display
function SoilMoistureSystem:getFieldsSortedByMoisture()
    local list = {}
    for fieldId, data in pairs(self.fieldData) do
        table.insert(list, { fieldId = fieldId, moisture = data.moisture, soilType = data.soilType })
    end
    table.sort(list, function(a, b) return a.moisture < b.moisture end)
    return list
end

function SoilMoistureSystem:onIrrigationStarted(data)
    self.irrigationGains[data.fieldId] = (self.irrigationGains[data.fieldId] or 0) + data.ratePerHour
end

function SoilMoistureSystem:onIrrigationStopped(data)
    -- math.max ensures the gain never goes negative on a rate mismatch
    -- (e.g. if stopped fires twice or the rate differs from what was added).
    local remaining = math.max(0, (self.irrigationGains[data.fieldId] or 0) - data.ratePerHour)
    self.irrigationGains[data.fieldId] = (remaining > 0.001) and remaining or nil
end

-- Detect soil type from FS25 map metadata.
-- FS25 maps vary widely in what metadata they expose.
-- This uses a best-effort hierarchy; falls back to weighted random per field.
function SoilMoistureSystem:detectSoilType(field)
    -- 1. Try field's custom attribute if map author set it
    if field.soilType ~= nil then
        local s = tostring(field.soilType):lower()
        if SoilMoistureSystem.SOIL_PARAMS[s] ~= nil then return s end
    end

    -- 2. Try terrain detail layer at field center
    -- (Requires map support — many vanilla maps don't expose this)
    -- NOTE: If FS25 LUADOC documents getTerrainAttributeAtWorldPos, implement here.

    -- 3. Heuristic: use field position's biome/map region if available
    -- (Placeholder for future PF soil map support)

    -- 4. Weighted random seeded by field ID — consistent per field, no save needed.
    --    Distribution: sandy 20%, loamy 70%, clay 10% (realistic temperate farmland).
    local fid = (field.farmland and field.farmland.id) or 0
    local r = ((fid * 2654435761) % 1000) / 1000.0
    if r < 0.20 then return "sandy"
    elseif r < 0.90 then return "loamy"
    else return "clay" end
end

-- ============================================================
-- RW MOISTURE INTEGRATION (SCS-018 UNWIND)
-- SeasonalCropStress owns its whole moisture simulation on every map.
-- RealisticWeather remains a read-only WEATHER source (temperature, rain)
-- through WeatherIntegration; its moisture grid is neither read nor written.
-- setRWMoistureSystem is kept as a no-op clearing method so any existing
-- wiring site stays callable without touching RW's grid.
-- ============================================================
function SoilMoistureSystem:setRWMoistureSystem(rwSystem)
    self.rwMoistureSystem = nil
    if rwSystem ~= nil then
        csLog("SoilMoistureSystem: RW weather detected; moisture simulation stays ours (RW grid untouched)")
    end
end

function SoilMoistureSystem:delete()
    self.isInitialized = false
end

-- Set evapotranspiration multiplier from settings
function SoilMoistureSystem:setEvapMultiplier(multiplier)
    self.evapMultiplier = multiplier or 1.0
end

-- Set critical moisture threshold from settings
function SoilMoistureSystem:setCriticalThreshold(threshold)
    self.criticalMoisture = math.max(0.15, math.min(0.35, threshold or 0.25))
end

-- Override CRITICAL_MOISTURE for settings compatibility
function SoilMoistureSystem:getCriticalMoisture()
    return self.criticalMoisture or SoilMoistureSystem.CRITICAL_MOISTURE
end

-- (field enumeration is now handled by CropStressManager's addUpdateable init pattern)