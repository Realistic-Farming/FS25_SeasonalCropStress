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
-- SCS-039 v2.1 (SDS 3.6): the per-frame redistribution budget for an open daily
-- plan. 400 is the same technical precedent as MAP_DRAIN_MAX_BLOCKS (Group A10
-- / Group I16 pin it); it is a frame ceiling, never a total work cap.
SoilMoistureSystem.DAILY_OPS_PER_FRAME     = 400

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

    -- SCS-039 v2.1 (SDS 3.6): one open daily plan at a time, pinned to its
    -- target day, due count, base provider revision, carrier identity and field
    -- fingerprints. It advances under DAILY_OPS_PER_FRAME and commits once;
    -- an authoritative replacement, provider transition or geometry mismatch
    -- aborts it without moving the cursor. Save, reload and teardown discard it.
    self._dailyPlan = nil

    -- SCS-039 v2.1 (SDS 3.7): the client fine-snapshot currentness engine
    -- (staging + delta barrier). Server instances carry it inert; only a client
    -- stages rows and publishes once at COMPLETE.
    self.fineSnapshot = (SoilFineSnapshot ~= nil) and SoilFineSnapshot.new() or nil
    self._syncSnapshotGeneration = 0

    -- SCS-039: the vendored 2 m value map. nil until initValueMap runs, and
    -- still inert afterwards on any install where the engine cannot carry it.
    -- Every branch below tests mapActive(); when it is false NOTHING changes and
    -- the sparse-cell store above is the whole system, bit for bit.
    self.valueMap = nil
    self._fieldVerts = {}      -- fieldId -> {vx, vz, n}, cached polygon
    self._mapSeeded  = {}      -- fieldId -> true once migrated onto the map
    -- SCS-039 quantisation remainders for positional water writes, keyed
    -- fieldId -> [pixelKey] -> pending sub-step moisture. The cell store holds
    -- a float so it never floors; the 2 m map has 254 raw steps, so a single
    -- irrigator tick's gain (liters over the whole sector) must accumulate here
    -- and spend only whole raw steps, or water lands on the map as nothing.
    -- Two key kinds coexist without collision (SDS 3.4):
    --   resolved    [px*4096+pz] (a number)      = sub-step remainder
    --   unresolved  ["WORLD:x,z"] (a string)     = {status, worldX, worldZ,
    --                                               sourceWidth, amount} leaf
    -- packMapWaterPending / unpackMapWaterPending persist both deterministically.
    self._mapWaterPending = {} -- fieldId -> resolved [px*4096+pz]=remainder | unresolved ["WORLD:x,z"]=leaf

    -- SCS-039 v2.1: the persisted server integer that stamps every readable
    -- moisture answer. Advanced ONCE per successful readable mutation (native or
    -- zone write, whole-field replacement, committed settle, migration). A
    -- pending-only sub-step remainder does not advance it. Clients adopt the
    -- server value through the sync path and never mint their own.
    self.moistureRevision = 1
    -- The frozen per-mission carrier decision: "TRUTH" (the native 2 m map is
    -- the current authority) or "ZONE" (the sparse cell store is). nil until
    -- initValueMap runs and makes the one-way choice.
    self.providerMode = nil

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
    -- SCS-039 v2.1: default the carrier to ZONE. Every decline path below leaves
    -- it here; only a live native map promotes it to TRUTH. The choice is frozen
    -- for the mission once made.
    self.providerMode = "ZONE"
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
        self.providerMode = "TRUTH"
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
--- SCS-039 v2.1 (SDS 3.3): a provider that has failed closed for the mission
--- answers false here, so getMoisture, the overlay and every native read path
--- detach from the fine map without the handle being nil-ed (teardown still
--- releases the carrier). The one-way choice is only reset by the next load.
function SoilMoistureSystem:mapActive()
    return self.valueMap ~= nil and self.valueMap.available == true
        and self.providerMode ~= "UNAVAILABLE_PENDING_RELOAD"
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
--- Relief variation is painted over the aggregate base coat so a field does not
--- read as one flat average.
---@return integer number of fields painted
function SoilMoistureSystem:seedMapFromStore()
    if not self:mapActive() then return 0 end
    if self.valueMap.loadedFromSave then return 0 end
    local count = 0
    local varied = 0
    for fid in pairs(self.fieldData) do
        if self:migrateFieldToMap(fid) then
            count = count + 1
            local d = self.fieldData[fid]
            local vx, vz, n = self:_getFieldVerts(fid)
            if vx ~= nil then
                local base = self:getFieldAggregate(d) or 0.5
                if self:_seedMapRelief(vx, vz, n, base) > 0 then
                    varied = varied + 1
                end
            end
        end
    end
    if count > 0 then
        csLog(string.format("Moisture map: seeded %d fields from the store (%d with relief variation)", count, varied))
    end
    return count
end

--- Paint per-pixel relief variation over a field's aggregate base coat so the
--- moisture map is not one flat average per field. Low ground reads wetter by
--- the same SENS/MAX the store's relief pass uses, and the offsets sum to about
--- zero over the field, so the derived field mean is unchanged. Sampled on a
--- coarse grid to bound the one-time load cost.
---@param vx number[] polygon x
---@param vz number[] polygon z
---@param n integer vertex count
---@param base number field aggregate moisture
---@return integer number of varied regions painted
function SoilMoistureSystem:_seedMapRelief(vx, vz, n, base)
    if not self:mapActive() then return 0 end
    if getTerrainHeightAtWorldPos == nil or g_terrainNode == nil then return 0 end
    local grain = self.valueMap:getGrainMetres() or 2
    local step = math.max(grain * 4, 8)
    local half = step * 0.5
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        if vx[i] < minX then minX = vx[i] end
        if vx[i] > maxX then maxX = vx[i] end
        if vz[i] < minZ then minZ = vz[i] end
        if vz[i] > maxZ then maxZ = vz[i] end
    end
    if minX == math.huge then return 0 end
    local samples, count = {}, 0
    local limit = SoilMoistureSystem.MAP_DRAIN_MAX_BLOCKS
    local x = minX + half
    while x <= maxX and count < limit do
        local z = minZ + half
        while z <= maxZ and count < limit do
            if csPointInPolygon(x, z, vx, vz, n) then
                local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, x, 0, z)
                if ok and h ~= nil then
                    count = count + 1
                    samples[count] = { x = x, z = z, h = h }
                end
            end
            z = z + step
        end
        x = x + step
    end
    if count < 4 then return 0 end
    local meanH = 0
    for i = 1, count do meanH = meanH + samples[i].h end
    meanH = meanH / count
    local SENS = SoilMoistureSystem.CELL_SENS
    local MAX = SoilMoistureSystem.CELL_RELIEF_MAX
    local written = 0
    for i = 1, count do
        local offset = SENS * (meanH - samples[i].h)
        if offset > MAX then offset = MAX elseif offset < -MAX then offset = -MAX end
        if math.abs(offset) >= 0.001 then
            local m = math.max(0.0, math.min(1.0, base + offset))
            self.valueMap:writeValueAtWorld(samples[i].x, samples[i].z, m, half)
            written = written + 1
        end
    end
    return written
end

function SoilMoistureSystem:initialize()
    -- Subscribe to irrigation events immediately (don't depend on fieldManager being ready)
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.subscribe("CS_IRRIGATION_STARTED", self.onIrrigationStarted, self)
        self.manager.eventBus.subscribe("CS_IRRIGATION_STOPPED", self.onIrrigationStopped, self)
    end

    -- SCS-039 v2.1 (SDS 3.4): server-side farmland ownership change revalidates
    -- pending positional membership. The engine installs the new ownership and
    -- publishes (farmlandId, farmId, loadFromSavegame) after it, which is when
    -- our cached field polygons go stale. Subscription is capability-guarded so
    -- an engine without the message (or a client peer) never subscribes.
    if g_server ~= nil and g_messageCenter ~= nil and MessageType ~= nil
       and MessageType.FARMLAND_OWNER_CHANGED ~= nil
       and g_messageCenter.subscribe ~= nil then
        g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
        self._farmlandSubscribed = true
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
function SoilMoistureSystem:hourlyUpdate(weather, elapsedHours, rainHours, positionalScheduleApplied, fieldDispositions)
    if not self.isInitialized then return end
    if weather == nil then return end
    local hours = math.max(1, math.floor(elapsedHours or 1))
    -- SCS-023: when the finite planner's positional pass already delivered the
    -- scheduled moisture, the incumbent field-wide accumulator is suppressed.
    -- Finite mode controls pump scarcity, not spatial truth. SDS 5.2: the
    -- suppression is PER FIELD when a disposition map is supplied (Accepted and
    -- Refused fields only); the whole-act bool remains for legacy callers that
    -- pass no map.
    self._positionalScheduleApplied = positionalScheduleApplied == true
    self._positionalFieldDispositions = fieldDispositions
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
        -- SCS-023 v2.3 (SDS 5.2): a per-field disposition map suppresses ONLY the
        -- fields the positional pass accepted or refused this act; every other
        -- field keeps its incumbent field-wide accumulator. Legacy callers with
        -- no map keep the whole-act bool suppression.
        local suppressForField = false
        if self._positionalFieldDispositions ~= nil then
            suppressForField = self._positionalFieldDispositions[fieldId] == true
        else
            suppressForField = self._positionalScheduleApplied
        end
        local irrigGain = suppressForField
            and 0.0
            or ((self.irrigationGains[fieldId] or 0.0) * hours)

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
    -- SCS-039 v2.1: the third return is the provider revision. It is additive, so
    -- one- and two-value callers (FarmTablet, SoilFertilizer) stay compatible.
    local rev = self.moistureRevision or 1
    local d = self.fieldData[fieldId]
    if d == nil then return nil, nil, rev end

    if x ~= nil and z ~= nil then
        if self:mapActive() then
            -- SCS-039 v2.1 (SDS 3.2/3.3): the point read is TYPED. A written
            -- pixel answers with its ACTUAL carrier grain; a benign unwritten or
            -- out-of-range pixel keeps the aggregate fallback at nil grain; a
            -- genuine native refusal (pcall threw) fails the provider closed for
            -- the mission, exactly like the polygon-aggregate refusal.
            local v, grain, outcome = self.valueMap:readValueAtWorld(x, z)
            if v ~= nil then return v, grain, rev end
            if outcome == "PROVIDER_REFUSAL" then
                self:_failNativeClosed("native point-read refusal")
                -- Fall through to the retained cell store below, which answers
                -- exactly as a ZONE read would for the rest of the mission.
            else
                self:_refreshFieldAggregate(fieldId, d)
                return d.moisture, nil, rev
            end
        end
        local cx, cz = self:worldToCell(x, z)
        local row = d.cells and d.cells[cx]
        local cell = row and row[cz]
        if cell ~= nil then return cell.moisture, self:getCellSize(), rev end
        return self:getFieldAggregate(d), self:getCellSize(), rev
    end

    -- Field-level read.
    if self:mapActive() then
        -- SCS-039 v2.1 (SDS 3.2): under the native map the field scalar is the
        -- revisioned polygon aggregate, refreshed when a positional write marked
        -- it dirty. It is NEVER derived from the retained zone cells.
        self:_refreshFieldAggregate(fieldId, d)
        return d.moisture, nil, rev
    end
    return self:getFieldAggregate(d), nil, rev
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

--- SCS-039 v2.1 (SDS 3.2): refresh the cached native field aggregate when a
--- positional write has marked it dirty. Under TRUTH the scalar `d.moisture`
--- holds the polygon mean read from the map, never a mean of the zone cells. A
--- nil native answer leaves the last cached scalar in place rather than zeroing.
function SoilMoistureSystem:_refreshFieldAggregate(fieldId, d)
    if not self:mapActive() then return end
    if d.aggregateDirty == false then return end
    if self.valueMap.readAverageOfPolygon == nil then return end
    local vx, vz, n = self:_getFieldVerts(fieldId)
    if vx == nil then return end
    -- SCS-039 v2.1 (SDS 3.2/3.3): typed outcome. Only OK re-derives the scalar and
    -- clears the dirty flag; a genuine PROVIDER_REFUSAL fails the provider closed
    -- for the mission; EMPTY and INVALID_FIELD_GEOMETRY are not refusals and leave
    -- the last cached scalar (and the dirty flag) exactly as they were.
    local outcome, mean = self.valueMap:readAverageOfPolygon(vx, vz, n)
    if outcome == "OK" then
        d.moisture = mean
        d.aggregateDirty = false
    elseif outcome == "PROVIDER_REFUSAL" then
        self:_failNativeClosed("polygon-aggregate refusal on field refresh")
    end
end

-- ============================================================
-- SCS-039 v2.1: PROVIDER REVISION AND HONEST PUBLIC READS (SDS 3.2).
-- The revision is one persisted server integer; every readable answer carries
-- it so an aggregate and a fine consumer can agree on which ground they saw.
-- ============================================================

--- The current server provider revision. Consumers stamp their reads with it and
--- a client never mints its own; it adopts the server value through the sync path.
function SoilMoistureSystem:getMoistureRevision()
    return self.moistureRevision or 1
end

--- True only while the native 2 m map is the current authority. A ZONE carrier,
--- an absent map, or a native provider that has failed closed for the mission all
--- answer false, so a consumer never draws a stale or partial fine map as current.
function SoilMoistureSystem:isMoistureMapCurrent()
    return self:mapActive() and self.providerMode == "TRUTH"
end

--- The live native map, and ONLY while it is current. nil otherwise, so the host
--- overlay falls back to the aggregate rather than drawing non-current bytes.
function SoilMoistureSystem:getMoistureDisplayMap()
    if not self:isMoistureMapCurrent() then return nil end
    return self.valueMap
end

--- Advance the persisted revision exactly once for a successful readable mutation.
--- A pending-only sub-step remainder must never call this.
function SoilMoistureSystem:_advanceMoistureRevision()
    self.moistureRevision = (self.moistureRevision or 1) + 1
    return self.moistureRevision
end

--- SCS-039 v2.1 (SDS 3.3): a native refusal AFTER TRUTH became the current
--- authority is a ONE-WAY transition for the rest of the mission. A native point
--- read, valid-polygon aggregate read, region write or native save that refuses
--- calls this one path. It changes the mode exactly once, makes the fine map
--- non-current and detaches it from public reads and the overlay (mapActive() now
--- answers false), HOLDS the readable revision, leaves BOTH accepted-water pending
--- stores intact, and never promotes the retained zone cells. Only the next
--- mission load selects a readable TRUTH or ZONE carrier again. Invalid geometry
--- and an empty polygon are NOT provider refusals and must never call this.
function SoilMoistureSystem:_failNativeClosed(reason)
    if self.providerMode ~= "TRUTH" then return end   -- once only, from current TRUTH
    self.providerMode = "UNAVAILABLE_PENDING_RELOAD"
    self._nativeFailedReason = reason
    -- The revision is intentionally NOT advanced and the pending stores are left
    -- exactly as they are. The native handle is retained (not nil-ed) so teardown
    -- can still release the carrier; mapActive() is what detaches the reads.
    if csLog ~= nil then
        csLog("Moisture: native provider failed closed (" .. tostring(reason) ..
            "); reads fall to the aggregate then the cell store until the next load")
    end
end

--- SCS-039 v2.1 (SDS 3.3): the native-save call site. saveToSavegame already
--- requires the engine's inner true (slice 1); this routes its refusal through
--- the one fail-closed path so a save that never reached disk cannot leave the
--- mission still trusting the fine map. The per-field scalar rows the save
--- handler writes next are the honest degrade layer, and the next load re-selects
--- a readable TRUTH or ZONE carrier. Returns the literal save receipt.
function SoilMoistureSystem:saveNativeMap(savegameDir, generation)
    if self.valueMap == nil or not self.valueMap.available then return false end
    local savedOk = self.valueMap:saveToSavegame(savegameDir, generation) == true
    if not savedOk then
        self:_failNativeClosed("native save refusal")
    end
    return savedOk
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
        -- SCS-039 v2.1: a whole-field replacement supersedes BOTH pending stores
        -- together, the field-wide carry and every positional leaf, or a stale
        -- leaf would re-spend onto ground the replacement already overwrote.
        d.mapPending = 0
        self._mapWaterPending[fieldId] = nil
        d.moisture = newValue
        -- A uniform paint makes the polygon mean exactly newValue: cache is clean.
        d.aggregateDirty = false
        self:_advanceMoistureRevision()
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
    -- ZONE whole-field replacement is a readable mutation too.
    self:_advanceMoistureRevision()
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
    -- SCS-039 v2.1: return a literal boolean receipt. true = the accepted water
    -- joined its store (even a sub-step amount that floored to no write yet);
    -- false = an invalid field, non-positive gain or an unresolved position.
    -- SCS-023's COVER step consumes only this boolean.
    local d = self.fieldData[fieldId]
    if d == nil or type(gain) ~= "number" or gain <= 0 then return false end

    -- SCS-039: water lands on a PLACE, and on the map that place is a 2 m pixel
    -- instead of a 10-40 m cell. Read what is there, add the gain, write it back.
    -- QUANTISATION LAW (CropStressValueMap): the tick's gain, spread over the
    -- whole sector area, is far below one raw step (~0.0039 moisture). Writing
    -- it straight through floors to nothing and the map never moves while the
    -- cell store does. Accumulate per pixel and spend only whole raw steps, the
    -- same shape as the hourly weather path's mapPending.
    if self:mapActive() then
        self:migrateFieldToMap(fieldId)
        local px, pz = self.valueMap:worldToPixel(x, z)
        if px == nil then
            -- SCS-039 v2.1 (SDS 3.4): a member position whose native pixel cannot
            -- yet resolve is NOT dropped. Accepted water is never lost. Keep it as
            -- an UNRESOLVED positional leaf keyed by canonical world coordinates
            -- (never a fabricated pixel id) and carrying the source grain, so a
            -- later membership revalidation can re-key it onto a real pixel. This
            -- is pending-only: the readable revision does not advance.
            -- (Deterministic persistence + geometry-change re-key are a later slice.)
            local grain = (type(self.valueMap.getGrainMetres) == "function"
                and self.valueMap:getGrainMetres()) or 2
            local fieldAcc = self._mapWaterPending[fieldId]
            if fieldAcc == nil then fieldAcc = {}; self._mapWaterPending[fieldId] = fieldAcc end
            local leafKey = "WORLD:" .. x .. "," .. z
            local leaf = fieldAcc[leafKey]
            if leaf == nil then
                leaf = { status = "UNRESOLVED", worldX = x, worldZ = z, sourceWidth = grain, amount = 0 }
                fieldAcc[leafKey] = leaf
            end
            leaf.amount = leaf.amount + gain
            return true
        end
        local fieldAcc = self._mapWaterPending[fieldId]
        if fieldAcc == nil then fieldAcc = {}; self._mapWaterPending[fieldId] = fieldAcc end
        local key = px * 4096 + pz
        local pending = (fieldAcc[key] or 0) + gain
        local applied, remainder = CropStressValueMap.quantiseDelta(pending)
        if applied ~= 0 then
            -- SCS-039 v2.1 (SDS 3.4): debit pending only after the destination
            -- READ and WRITE both succeed exactly. A genuine native refusal at
            -- either point (SDS 3.3: a point-read or region-write refusal while
            -- TRUTH is current) fails the provider closed for the mission and
            -- keeps the FULL pre-spend amount in the pending store, so accepted
            -- water is never lost and no false revision is minted. The water was
            -- accepted into pending before the spend, so the receipt stays true.
            local current, _, readOutcome = self.valueMap:readValueAtWorld(x, z)
            if readOutcome == "PROVIDER_REFUSAL" then
                fieldAcc[key] = pending
                self:_failNativeClosed("native destination-read refusal on water spend")
                return true
            end
            if current == nil then current = self:getFieldAggregate(d) or 0 end
            local grain = self.valueMap:getGrainMetres() or 2
            local _, writeOutcome = self.valueMap:writeValueAtWorld(x, z,
                math.max(0.0, math.min(1.0, current + applied)), grain * 0.5)
            if writeOutcome == "PROVIDER_REFUSAL" then
                fieldAcc[key] = pending
                self:_failNativeClosed("native region-write refusal on water spend")
                return true
            end
            fieldAcc[key] = remainder
            -- A whole-raw-step spend moved readable ground: the cached field
            -- aggregate is now stale, and the revision advances once.
            d.aggregateDirty = true
            self:_advanceMoistureRevision()
        else
            fieldAcc[key] = remainder
        end
        -- Accepted. The field aggregate is re-derived from the map on the daily
        -- settle; a single pixel's gain is below the field-mean noise until then.
        return true
    end

    local cx, cz = self:worldToCell(x, z)
    local row = d.cells[cx]
    if row == nil then
        if (d.cellCount or 0) >= SoilMoistureSystem.CELL_BACKSTOP_CAP then
            -- SCS-039 v2.1 (SDS 3.4): at the relief cap we cannot materialise a new
            -- cell, but accepted water is NEVER discarded. Keep it as field-wide
            -- pending so a later flush can spend it once cells free up. Pending-only
            -- does not advance the readable revision.
            d.mapPending = (d.mapPending or 0) + gain
            return true
        end
        row = {}
        d.cells[cx] = row
    end
    local cell = row[cz]
    if cell == nil then
        if (d.cellCount or 0) >= SoilMoistureSystem.CELL_BACKSTOP_CAP then
            -- SCS-039 v2.1 (SDS 3.4): at the relief cap we cannot materialise a new
            -- cell, but accepted water is NEVER discarded. Keep it as field-wide
            -- pending so a later flush can spend it once cells free up. Pending-only
            -- does not advance the readable revision.
            d.mapPending = (d.mapPending or 0) + gain
            return true
        end
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
    -- ZONE positional water moved readable ground: advance the revision and
    -- return the accept receipt.
    self:_advanceMoistureRevision()
    return true
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
                -- SCS-039 v2.1 (SDS 3.2/3.3): only OK re-derives the scalar. A
                -- genuine native refusal fails the provider closed for the mission
                -- and stops trusting the fine map this settle; EMPTY and invalid
                -- geometry are not refusals and leave the scalar in place.
                local outcome, mean = self.valueMap:readAverageOfPolygon(vx, vz, n)
                if outcome == "OK" then
                    d.moisture = mean
                elseif outcome == "PROVIDER_REFUSAL" then
                    self:_failNativeClosed("polygon-aggregate refusal on daily settle")
                    break
                end
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
--- SDS 3.7: each join is one immutable snapshot generation of its own.
function SoilMoistureSystem:queueMapSync(connection)
    if not self:mapActive() or connection == nil then return false end
    if g_server == nil then return false end
    self._syncQueue = self._syncQueue or {}
    self._syncSnapshotGeneration = (self._syncSnapshotGeneration or 0) + 1
    self._syncQueue[#self._syncQueue + 1] = {
        conn = connection,
        nextRow = 0,
        snapshotGeneration = self._syncSnapshotGeneration,
        baseRevision = self.moistureRevision or 1,
        controlSent = false,
    }
    return true
end

--- Drive the queue. Called from the manager's per-frame update on the server.
--- Returns the number of rows sent this frame (0 when there is nothing to do),
--- which is also what makes the cost visible to the instrument below.
--- SDS 3.7: CONTROL START opens the client snapshot before the first row and
--- CONTROL COMPLETE is the publish barrier after the final row.
function SoilMoistureSystem:updateMapSync()
    local q = self._syncQueue
    if q == nil or #q == 0 then return 0 end
    if not self:mapActive() then
        self._syncQueue = nil
        return 0
    end

    local job = q[1]
    local total = self.valueMap:getSyncRowCount()
    if not job.controlSent then
        if CropStressMoistureControlEvent ~= nil then
            g_server:sendEvent(CropStressMoistureControlEvent.new(
                CropStressMoistureControlEvent.KIND_START,
                job.snapshotGeneration, job.baseRevision, total,
                self.valueMap.resolution or 0), false, nil, job.conn)
        end
        job.controlSent = true
    end

    local sent = 0
    while sent < SoilMoistureSystem.SYNC_ROWS_PER_FRAME and job.nextRow < total do
        local raw = self.valueMap:readSyncRow(job.nextRow)
        if raw ~= nil and CropStressMoistureRowEvent ~= nil then
            local packed = CropStressValueMap.packRow(raw)
            g_server:sendEvent(CropStressMoistureRowEvent.new(job.nextRow, packed,
                job.snapshotGeneration), false, nil, job.conn)
        end
        job.nextRow = job.nextRow + 1
        sent = sent + 1
    end

    if job.nextRow >= total then
        if CropStressMoistureControlEvent ~= nil then
            g_server:sendEvent(CropStressMoistureControlEvent.new(
                CropStressMoistureControlEvent.KIND_COMPLETE,
                job.snapshotGeneration, job.baseRevision, total,
                self.valueMap.resolution or 0), false, nil, job.conn)
        end
        table.remove(q, 1)
        csLog(string.format("Moisture map: delivered %d rows to a client (snapshot gen %d)",
            total, job.snapshotGeneration))
    end
    self._syncTotalRowsSent = (self._syncTotalRowsSent or 0) + sent
    return sent
end

--- SCS-039 v2.1 (SDS 3.7): the client publish barrier. Applies the staged raw
--- rows of a completed snapshot to the live map, then stamps the published
--- absolute per-pixel delta values, exactly once.
function SoilMoistureSystem:_publishFineSnapshot(snapshot)
    local vm = self.valueMap
    if vm == nil or not vm.available then return end
    local width = (snapshot.mapWidth and snapshot.mapWidth > 0) and snapshot.mapWidth
        or (vm.resolution or 0)
    if width <= 0 then return end
    for index = 0, snapshot.totalRows - 1 do
        local packed = snapshot.rows[index]
        if packed ~= nil then
            local row = CropStressValueMap.unpackRow(packed, width)
            vm:applySyncRow(index, row)
        end
    end
    for pixelKey, value in pairs(snapshot.pixelValues or {}) do
        if type(vm.writePixelValue) == "function" then
            vm:writePixelValue(pixelKey, value)
        end
    end
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
-- SCS-039 v2.1 (SDS 3.6): THE DAILY PLAN CORE.
--
-- One open plan at a time handles positive due day spans. It is pinned to its
-- target day, due count, base provider revision, carrier identity and the
-- current field fingerprints, advances at most DAILY_OPS_PER_FRAME operations
-- per frame, and commits once. Staging never mutates live moisture; the commit
-- moves the settled-day cursor and advances the readable revision once.
-- Authoritative replacement, provider transition or geometry mismatch abort
-- the plan without moving the cursor, so the unchanged cursor reoffers the
-- work. The runtime mapping of plan operations to per-field redistribution
-- work, the Time Guard subscribeTick registration and the retirement of the
-- accrual registration are the follow-on wiring slices; this is the engine-free
-- state machine (Group J mirrors the same contract).
-- ============================================================

--- Pure due-span: how many whole days are owed between the settled cursor and
--- the current monotonic day. A missing, zero, negative, duplicate or
--- non-finite span owes nothing and moves no cursor.
function SoilMoistureSystem.computeDueDays(cursor, currentDay)
    if type(cursor) ~= "number" or type(currentDay) ~= "number" then return 0 end
    if cursor ~= cursor or currentDay ~= currentDay then return 0 end
    if math.abs(cursor) == math.huge or math.abs(currentDay) == math.huge then return 0 end
    local due = currentDay - cursor
    if due <= 0 then return 0 end
    return math.floor(due)
end

--- Stable combined signature of every current field polygon fingerprint, used
--- as one pin so a geometry change aborts an open plan.
function SoilMoistureSystem:fieldFingerprintSignature()
    local parts = {}
    for fieldId in pairs(self.fieldData) do
        parts[#parts + 1] = tostring(fieldId) .. ":" .. tostring(self:fieldGeometryFingerprint(fieldId))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

--- Wake the daily plan for a current monotonic day. Returns:
---   "INVALID"  non-finite current day
---   "SEEDED"   first ever wake: the cursor seeds to the current day, no work
---   "IDLE"     zero, negative or duplicate span; nothing owed
---   "PENDING"  positive due work; opens or resumes the pinned daily plan
function SoilMoistureSystem:wakeDailyPlan(currentDay, totalOps)
    if type(currentDay) ~= "number" or currentDay ~= currentDay
       or math.abs(currentDay) == math.huge then
        return "INVALID"
    end
    if self._lastSettledDay == nil then
        self._lastSettledDay = currentDay
        return "SEEDED"
    end
    local due = SoilMoistureSystem.computeDueDays(self._lastSettledDay, currentDay)
    if due <= 0 then return "IDLE" end
    if self._dailyPlan == nil then
        self._dailyPlan = {
            due          = due,
            targetDay    = currentDay,
            baseRevision = self.moistureRevision or 1,
            carrier      = self.providerMode,
            fingerprint  = self:fieldFingerprintSignature(),
            totalOps     = totalOps or (due * SoilMoistureSystem.DAILY_OPS_PER_FRAME),
            cursor       = 0,
        }
    end
    return "PENDING"
end

--- Advance the open plan by at most `budget` operations. Returns step, status:
---   step    operations performed this frame
---   "IDLE"      no plan open
---   "ABORTED"   a pin broke (revision, carrier or geometry moved); plan cleared,
---               cursor unchanged, the unchanged cursor reoffers the work
---   "PAUSED"    zero budget; nothing done, nothing claimed
---   "PENDING"   more work remains next frame
---   "COMMITTED" the plan finished this frame: cursor moves to the target day
---               and the readable revision advances once
function SoilMoistureSystem:advanceDailyPlan(currentDay, budget)
    local plan = self._dailyPlan
    if plan == nil then return 0, "IDLE" end
    if plan.targetDay ~= currentDay
       or plan.baseRevision ~= (self.moistureRevision or 1)
       or plan.carrier ~= self.providerMode
       or plan.fingerprint ~= self:fieldFingerprintSignature() then
        self._dailyPlan = nil
        return 0, "ABORTED"
    end
    if budget == nil or budget <= 0 then return 0, "PAUSED" end
    local step = math.min(budget, plan.totalOps - plan.cursor)
    plan.cursor = plan.cursor + step
    if plan.cursor < plan.totalOps then return step, "PENDING" end
    self._lastSettledDay = plan.targetDay
    self:_advanceMoistureRevision()
    self._dailyPlan = nil
    return step, "COMMITTED"
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

-- ============================================================
-- SCS-039 v2.1 POSITIONAL PENDING PERSISTENCE (SDS 3.4 tail, slice 8)
--
-- The accepted-water store (_mapWaterPending) held resolved pixel remainders and
-- UNRESOLVED world leaves in-mission only; slice 3 preserved the leaves until a
-- reload but nothing wrote them to the save. These seams pack the store into a
-- deterministic ordered row list (and a string form for the own-XML path) so no
-- accepted water is lost across save and reload. The rows are what the later
-- SDS 3.5 compact envelope will pack, so this is not throwaway work.
--
-- ORDER (SDS 3.4): resolved leaves ascend by field id then pixel key, then
-- unresolved leaves ascend by field id then canonical world coordinates. Only
-- non-zero amounts are emitted and there is no 1024-entry ceiling (Group C).
-- ============================================================

--- Pack the whole positional pending store into a deterministic row array.
---@return table rows  {fieldId, status, ...} sorted; empty array when nothing
---  is pending. RESOLVED rows carry pixelKey + amount; UNRESOLVED rows carry
---  worldX, worldZ, sourceWidth + amount.
function SoilMoistureSystem:packMapWaterPending()
    local rows = {}
    if type(self._mapWaterPending) ~= "table" then return rows end
    local fieldIds = {}
    for fieldId in pairs(self._mapWaterPending) do fieldIds[#fieldIds + 1] = fieldId end
    table.sort(fieldIds)
    for i = 1, #fieldIds do
        local fieldId = fieldIds[i]
        local acc = self._mapWaterPending[fieldId]
        local resolved, unresolved = {}, {}
        for key, value in pairs(acc or {}) do
            if type(key) == "number" then
                if value ~= nil and value ~= 0 then
                    resolved[#resolved + 1] = { pixelKey = key, amount = value }
                end
            elseif type(key) == "string" and type(value) == "table" then
                if value.amount ~= nil and value.amount ~= 0 then
                    unresolved[#unresolved + 1] = {
                        worldX = value.worldX, worldZ = value.worldZ,
                        sourceWidth = value.sourceWidth, amount = value.amount,
                    }
                end
            end
        end
        table.sort(resolved, function(a, b) return a.pixelKey < b.pixelKey end)
        table.sort(unresolved, function(a, b)
            local ax = tostring(a.worldX)
            local az = tostring(a.worldZ)
            local bx = tostring(b.worldX)
            local bz = tostring(b.worldZ)
            return ax .. "," .. az < bx .. "," .. bz
        end)
        for j = 1, #resolved do
            rows[#rows + 1] = {
                fieldId = fieldId, status = "RESOLVED",
                pixelKey = resolved[j].pixelKey, amount = resolved[j].amount,
            }
        end
        for j = 1, #unresolved do
            rows[#rows + 1] = {
                fieldId = fieldId, status = "UNRESOLVED",
                worldX = unresolved[j].worldX, worldZ = unresolved[j].worldZ,
                sourceWidth = unresolved[j].sourceWidth, amount = unresolved[j].amount,
            }
        end
    end
    return rows
end

--- Rebuild the whole positional pending store from a packMapWaterPending row
--- array. The store is replaced, mirroring unpackCells (a load is a fresh
--- mission store). Returns the number of leaves restored.
function SoilMoistureSystem:unpackMapWaterPending(rows)
    self._mapWaterPending = {}
    if type(rows) ~= "table" then return 0 end
    local count = 0
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == "table" and r.fieldId ~= nil then
            local acc = self._mapWaterPending[r.fieldId]
            if acc == nil then acc = {}; self._mapWaterPending[r.fieldId] = acc end
            if r.status == "RESOLVED" and type(r.pixelKey) == "number" then
                acc[r.pixelKey] = r.amount
                count = count + 1
            elseif r.status == "UNRESOLVED" and r.worldX ~= nil and r.worldZ ~= nil then
                local leafKey = "WORLD:" .. tostring(r.worldX) .. "," .. tostring(r.worldZ)
                acc[leafKey] = {
                    status = "UNRESOLVED", worldX = r.worldX, worldZ = r.worldZ,
                    sourceWidth = r.sourceWidth, amount = r.amount,
                }
                count = count + 1
            end
        end
    end
    return count
end

--- String form of packMapWaterPending for the own-XML save path. Rows are
--- ';'-separated and fields '|'-separated; numbers use tostring/tonumber, so a
--- load returns the exact same doubles the save captured. nil when empty.
function SoilMoistureSystem:packMapWaterPendingString()
    local rows = self:packMapWaterPending()
    if #rows == 0 then return nil end
    local parts = {}
    for i = 1, #rows do
        local r = rows[i]
        if r.status == "RESOLVED" then
            parts[#parts + 1] = table.concat(
                { "R", tostring(r.fieldId), tostring(r.pixelKey), tostring(r.amount) }, "|")
        else
            parts[#parts + 1] = table.concat(
                { "U", tostring(r.fieldId), tostring(r.worldX), tostring(r.worldZ),
                  tostring(r.sourceWidth), tostring(r.amount) }, "|")
        end
    end
    return table.concat(parts, ";")
end

--- Inverse of packMapWaterPendingString. Returns the number of leaves restored.
function SoilMoistureSystem:unpackMapWaterPendingString(packed)
    if packed == nil or packed == "" then return 0 end
    local rows = {}
    for part in string.gmatch(packed, "[^;]+") do
        local fields = {}
        for token in string.gmatch(part, "[^|]+") do fields[#fields + 1] = token end
        if fields[1] == "R" and #fields == 4 then
            rows[#rows + 1] = {
                status = "RESOLVED", fieldId = tonumber(fields[2]),
                pixelKey = tonumber(fields[3]), amount = tonumber(fields[4]),
            }
        elseif fields[1] == "U" and #fields == 6 then
            rows[#rows + 1] = {
                status = "UNRESOLVED", fieldId = tonumber(fields[2]),
                worldX = tonumber(fields[3]), worldZ = tonumber(fields[4]),
                sourceWidth = tonumber(fields[5]), amount = tonumber(fields[6]),
            }
        end
    end
    return self:unpackMapWaterPending(rows)
end

-- ============================================================
-- SCS-039 v2.1 GEOMETRY-CHANGE RE-KEY (SDS 3.4 tail, slice 9)
--
-- On a farmland ownership/geometry change the engine installs the new state and
-- publishes FARMLAND_OWNER_CHANGED. Our cached field polygons go stale, so the
-- handler invalidates them and revalidates every pending positional leaf against
-- the CURRENT geometry. Accepted water is never lost and never moves by
-- identifier accident: a leaf re-keys only when exactly one current field owns
-- its world position. Ambiguous or missing membership stays an UNRESOLVED
-- world leaf (a resolved pixel leaf whose membership vanished is demoted to
-- one), so it is never applied to the wrong field.
-- ============================================================

--- Ordered polygon fingerprint for a field, as a stable string of the vertex
--- world coordinates. Two equal polygons produce equal strings; a geometry
--- change changes the string (the SDS 3.6 daily-plan pinning compares these).
--- nil when the field has no resolvable polygon.
function SoilMoistureSystem:fieldGeometryFingerprint(fieldId)
    local vx, vz, n = self:_getFieldVerts(fieldId)
    if vx == nil then return nil end
    local parts = {}
    for i = 1, n do
        parts[i] = string.format("%.2f,%.2f", vx[i], vz[i])
    end
    return table.concat(parts, ";")
end

--- Exactly one current field contains the world position, else nil. A field
--- whose polygon cannot be resolved (deleted farmland still in fieldData) can
--- never own a point, and a point inside two fields is ambiguous, so neither
--- answers.
function SoilMoistureSystem:_uniqueFieldOwnerAt(worldX, worldZ)
    local owner, count = nil, 0
    for fieldId in pairs(self.fieldData) do
        local vx, vz, n = self:_getFieldVerts(fieldId)
        if vx ~= nil and csPointInPolygon(worldX, worldZ, vx, vz, n) then
            count = count + 1
            owner = fieldId
        end
    end
    if count == 1 then return owner end
    return nil
end

--- Revalidate every pending positional leaf against current field geometry and
--- re-key the ones that now belong to a different field. Returns the number of
--- leaves whose home changed (bucket move or a resolved demotion to unresolved).
function SoilMoistureSystem:rekeyPositionalWaterForOwnership()
    if type(self._mapWaterPending) ~= "table" then return 0 end

    local m = self.valueMap
    local hasPixelMap = m ~= nil and m.available == true
        and type(m.resolution) == "number" and m.resolution > 0
        and type(m.terrainSize) == "number" and m.terrainSize > 0
    local function pixelToWorld(px, pz)
        local g = m.terrainSize / m.resolution
        local half = m.terrainSize * 0.5
        return (px + 0.5) * g - half, (pz + 0.5) * g - half, g
    end

    local newStore = {}
    local moved = 0
    for fieldId, acc in pairs(self._mapWaterPending) do
        for key, value in pairs(acc) do
            local isResolved = type(key) == "number"
            local amount = isResolved and value or (value ~= nil and value.amount) or 0
            if amount == 0 then
                -- Zero carries no water; pack never emits it, and re-key need not
                -- preserve an empty remainder.
            else
                local worldX, worldZ, grain = nil, nil, nil
                if isResolved then
                    if not hasPixelMap then
                        -- A resolved remainder without the map cannot be
                        -- reconstructed to a world position: keep it exactly
                        -- where it is rather than guess at a home.
                        local acc2 = newStore[fieldId]
                        if acc2 == nil then acc2 = {}; newStore[fieldId] = acc2 end
                        acc2[key] = value
                    else
                        local px = math.floor(key / 4096)
                        local pz = key - px * 4096
                        worldX, worldZ, grain = pixelToWorld(px, pz)
                    end
                else
                    worldX, worldZ = value.worldX, value.worldZ
                    grain = value.sourceWidth
                end
                if worldX == nil then
                    -- handled above for the no-map resolved case
                else
                    local owner = self:_uniqueFieldOwnerAt(worldX, worldZ)
                    local destField = owner or fieldId
                    local demote = (owner == nil and isResolved)
                    if destField ~= fieldId or demote then moved = moved + 1 end
                    local acc2 = newStore[destField]
                    if acc2 == nil then acc2 = {}; newStore[destField] = acc2 end
                    if isResolved and not demote then
                        acc2[key] = (acc2[key] or 0) + amount
                    else
                        local leafKey = "WORLD:" .. tostring(worldX) .. "," .. tostring(worldZ)
                        local leaf = acc2[leafKey]
                        if leaf == nil then
                            leaf = { status = "UNRESOLVED", worldX = worldX, worldZ = worldZ,
                                     sourceWidth = grain, amount = 0 }
                            acc2[leafKey] = leaf
                        end
                        leaf.amount = leaf.amount + amount
                    end
                end
            end
        end
    end
    self._mapWaterPending = newStore
    return moved
end

--- Farmland ownership/geometry change handler (server). The engine installs the
--- new ownership before publishing, which is exactly when our cached field
--- polygons become stale. Replays during load (loadFromSavegame) only invalidate
--- caches; the load door restores a fresh pending store afterwards, so re-keying
--- now would run against the previous mission's leaves.
function SoilMoistureSystem:onFarmlandOwnerChanged(farmlandId, farmId, loadFromSavegame)
    if g_server == nil then return end
    self._fieldVerts = {}
    if loadFromSavegame then return end
    local moved = self:rekeyPositionalWaterForOwnership()
    if moved > 0 and csLog ~= nil then
        csLog(string.format("Moisture: farmland change re-keyed %d positional water leaves (field %s)",
            moved, tostring(farmlandId)))
    end
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
    -- SCS-039 v2.1: release the native carrier so its engine handle is freed and a
    -- teardown or same-process reload starts from a clean map, not a stale one.
    if self.valueMap ~= nil and self.valueMap.delete ~= nil then
        self.valueMap:delete()
    end
    -- SCS-039 v2.1 (SDS 3.4): drop the farmland-ownership subscription so a
    -- same-process reload does not keep a stale handler attached to the mission.
    if g_messageCenter ~= nil and g_messageCenter.unsubscribeAll ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
    self._farmlandSubscribed = false
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