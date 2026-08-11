-- ============================================================
-- CropStressManager.lua
-- Central coordinator. Owns all subsystems, manages the lifecycle
-- (initialize → hourly tick → draw → delete → save/load) and
-- exposes the global g_cropStressManager reference.
--
-- Also houses CropEventBus — a lightweight internal event emitter
-- used for loose coupling between subsystems. Avoids depending on
-- g_messageCenter's integer-mapped MessageType IDs.
-- ============================================================

-- ============================================================
-- LOGGING HELPER
-- g_logManager may be nil during early load or late delete.
-- ============================================================
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ============================================================
-- OWNERSHIP HELPERS
-- ============================================================

--- Returns the farmId of the local player.
local function getLocalFarmId()
    if g_currentMission == nil then return 1 end

    -- Multiplayer: use the local player's farmId
    if g_currentMission.player ~= nil then
        local id = g_currentMission.player.farmId
        if id ~= nil and id > 0 then return id end
    end

    -- Fallback: lookup via userManager for early join state
    if g_currentMission.userManager ~= nil and g_currentMission.playerUserId ~= nil then
        local user = g_currentMission.userManager:getUserByUserId(g_currentMission.playerUserId)
        if user ~= nil and user.farmId ~= nil and user.farmId > 0 then
            return user.farmId
        end
    end

    -- Singleplayer (or early MP): default to farm 1
    return 1
end

--- Returns true if the farmland is owned by the given farmId.
-- Uses g_farmlandManager.farmlandMapping — the authoritative FS25 ownership table.
local function isFarmlandOwnedByFarm(farmlandId, farmId)
    if g_farmlandManager == nil or g_farmlandManager.farmlandMapping == nil then
        return false
    end
    return g_farmlandManager.farmlandMapping[farmlandId] == farmId
end

-- ============================================================
-- CROP EVENT BUS
-- Simple publish/subscribe for mod-internal events.
-- Subscribers receive (context, data) where context is the
-- object registered as the listener's self/context.
-- ============================================================
CropEventBus = {}
CropEventBus.listeners = {}

function CropEventBus.subscribe(eventName, callback, context)
    if CropEventBus.listeners[eventName] == nil then
        CropEventBus.listeners[eventName] = {}
    end
    table.insert(CropEventBus.listeners[eventName], { cb = callback, ctx = context })
end

function CropEventBus.publish(eventName, data)
    local list = CropEventBus.listeners[eventName]
    if list == nil then return end
    for _, listener in ipairs(list) do
        listener.cb(listener.ctx, data)
    end
end

function CropEventBus.unsubscribeAll(context)
    for _, list in pairs(CropEventBus.listeners) do
        for i = #list, 1, -1 do
            if list[i].ctx == context then
                table.remove(list, i)
            end
        end
    end
end

-- ============================================================
-- CROP STRESS MANAGER
-- ============================================================
CropStressManager = {}
CropStressManager.__index = CropStressManager

-- RWE event id → stress rate multiplier applied during that event.
-- Values > 1.0 accelerate stress; < 1.0 suppress it.
CropStressManager.RWE_STRESS_MULTIPLIERS = {
    crop_yield_penalty  = 1.40,
    seed_growth_penalty = 1.30,
    harvest_penalty     = 1.20,
    fertilizer_penalty  = 1.20,
    crop_yield_bonus    = 0.80,
    fertilizer_bonus    = 0.85,
    harvest_bonus       = 0.85,
    seed_growth_bonus   = 0.85,
}

-- SCS-037 THE CAUGHT-UP HOUR.
-- The hourly tick is an EDGE DETECTOR: it fires once when the hour key changes,
-- however many hours the key jumped. A player sleeping three days used to get ONE
-- hour of evaporation, rain and irrigation, and the other 71 were discarded on the
-- line that computed the key. The count is now carried as a parameter and every
-- PER-HOUR term multiplies by it.
--
-- THE CAP is a deliberate ceiling on a single catch-up, not a tuning number: a
-- week of unattended weather is already a total answer for a field, and an
-- uncapped delta turns a corrupt or first-ever key into an unbounded simulation
-- step. One in-game week.
CropStressManager.MAX_CATCHUP_HOURS = 168

--- Hours elapsed between two hour keys, as the hourly path should charge them.
--- Pure and static so the bench can drive it without a mission.
--- Returns 1 (today's behaviour exactly) for the first tick, for a key that did
--- not advance, and for any key that moved backwards.
---@param lastKey number|nil  the previously seen key, or -1/nil before the first
---@param hourKey number      the key just observed
---@return number hours       1 .. MAX_CATCHUP_HOURS
function CropStressManager.elapsedHoursFrom(lastKey, hourKey)
    local last = tonumber(lastKey)
    local now  = tonumber(hourKey)
    if last == nil or now == nil or last < 0 then return 1 end
    local delta = now - last
    if delta < 1 then return 1 end
    if delta > CropStressManager.MAX_CATCHUP_HOURS then
        return CropStressManager.MAX_CATCHUP_HOURS
    end
    return math.floor(delta)
end


function CropStressManager.new()
    local self = setmetatable({}, CropStressManager)

    self.eventBus = CropEventBus

    -- Ownership helpers (exposed for other modules)
    self.getLocalFarmId          = getLocalFarmId
    self.isFarmlandOwnedByFarm   = isFarmlandOwnedByFarm

    -- State
    self.isInitialized = false
    self.debugMode     = false

    -- fieldId → field object lookup. Built by buildFieldMap() in installFieldReadyUpdater().
    -- All subsystems use this instead of getFieldByIndex() or linear scans.
    self.fieldById = {}

    -- Hourly tick tracking (monotonic day * 24 + hour)
    self.lastHourKey   = -1

    -- Settings (created here with defaults; loaded and applied in onStartMission)
    self.settings = CropStressSettings.new()

    -- Guard: WeatherIntegration must be loaded before CropStressManager (see main.lua phase order)
    if WeatherIntegration == nil then
        csLog("ERROR: WeatherIntegration is nil — check main.lua source() order")
        return nil
    end
    if WeatherIntegration.new == nil then
        csLog("ERROR: WeatherIntegration.new is nil — class definition incomplete")
        return nil
    end

    -- Subsystems (constructed here, initialized in :initialize() when g_currentMission is ready)
    self.weatherIntegration = WeatherIntegration.new(self)
    self.soilSystem         = SoilMoistureSystem.new(self)
    self.soilMoistureSystem = self.soilSystem   -- FarmTablet compatibility alias
    self.stressModifier     = CropStressModifier.new(self)
    self.irrigationManager  = IrrigationManager.new(self)       -- Phase 2 stub
    -- HUD removed: monitoring moved to the PDA screen (CsPDAScreen).
    self.hudOverlay = {
        initialize=function()end, update=function()end, draw=function()end,
        delete=function()end, toggle=function()end, onMouseEvent=function()end,
        isVisible=false, panelX=0, panelY=0,
    }
    self.consultant         = CropConsultant.new(self)
    self.moistureMapOverlay = CsMoistureMapOverlay ~= nil and CsMoistureMapOverlay.new(self) or nil
    self.npcIntegration     = NPCIntegration.new(self)
    self.financeIntegration = FinanceIntegration.new(self)      -- Phase 4 stub

    -- Phase 4 optional bridges — guarded so a missing source() doesn't crash the whole mod
    if UsedEquipmentMarketplace ~= nil then
        self.usedEquipmentMarketplace = UsedEquipmentMarketplace.new(self)
    else
        csLog("WARNING: UsedEquipmentMarketplace class not loaded — check main.lua source() order")
        self.usedEquipmentMarketplace = { initialize=function()end, delete=function()end, enableUsedPlusMode=function()end }
    end

    -- New optional mod bridges (loaded in main.lua)
    local function makeNoop(methods)
        local stub = {}
        for _, m in ipairs(methods) do
            if m == "isActive" then
                stub[m] = function() return false end
            elseif m == "getActiveVehicleCount" or m == "getDestinationCount" or m == "getWaterDestinationCount" then
                stub[m] = function() return 0 end
            else
                stub[m] = function() end
            end
        end
        return stub
    end

    if SoilFertilizerIntegration ~= nil then
        self.soilFertilizerIntegration = SoilFertilizerIntegration.new(self)
    else
        csLog("WARNING: SoilFertilizerIntegration class not loaded — check main.lua source() order")
        self.soilFertilizerIntegration = makeNoop({"initialize","delete","enableSoilFertilizerMode","hourlyRefresh","isActive","getFieldEvapMod","getFieldStressMod","getSummary"})
    end

    if CoursePlayIntegration ~= nil then
        self.coursePlayIntegration = CoursePlayIntegration.new(self)
    else
        csLog("WARNING: CoursePlayIntegration class not loaded — check main.lua source() order")
        self.coursePlayIntegration = makeNoop({"initialize","delete","enableCoursePlayMode","hourlyRefresh","isActive","getActiveVehicleCount","getVehiclesOnField","getContextForField"})
    end

    if AutoDriveIntegration ~= nil then
        self.autoDriveIntegration = AutoDriveIntegration.new(self)
    else
        csLog("WARNING: AutoDriveIntegration class not loaded — check main.lua source() order")
        self.autoDriveIntegration = makeNoop({"initialize","delete","enableAutoDriveMode","hourlyRefresh","isActive","getDestinationCount","getWaterDestinationCount","getCriticalAlertHint"})
    end

    if IrrigatorSectorIntegration ~= nil then
        self.irrigatorSectorIntegration = IrrigatorSectorIntegration.new(self)
    else
        csLog("WARNING: IrrigatorSectorIntegration class not loaded - check main.lua source() order")
        self.irrigatorSectorIntegration = makeNoop({"initialize","delete","update"})
    end
    if SprayerIntegration ~= nil then
        self.sprayerIntegration = SprayerIntegration.new(self)
    else
        csLog("WARNING: SprayerIntegration class not loaded — check main.lua source() order")
        self.sprayerIntegration = makeNoop({"initialize","delete"})
    end

    self.saveLoad           = SaveLoadHandler.new(self)

    -- Settings panel (custom-rendered overlay, opened with Shift+S)
    self.settingsPanel = CropStressSettingsPanel ~= nil
        and CropStressSettingsPanel.new(self)
        or nil

    return self
end

-- Called from Mission00.loadMission00Finished — g_currentMission is ready here
function CropStressManager:initialize()
    if g_currentMission == nil then
        csLog("CRITICAL: g_currentMission nil at initialize — aborting")
        return
    end

    -- Initialize subsystems in dependency order
    self.weatherIntegration:initialize()
    self.soilSystem:initialize()
    self.stressModifier:initialize()
    self.irrigationManager:initialize()
    self.hudOverlay:initialize()
    self.consultant:initialize()
    if self.moistureMapOverlay ~= nil then self.moistureMapOverlay:initialize() end

    -- Optional mod bridges — each checks for their mod's global at runtime
    self:detectOptionalMods()
    self.npcIntegration:initialize()
    self.financeIntegration:initialize()
    self.usedEquipmentMarketplace:initialize()
    self.soilFertilizerIntegration:initialize()
    self.coursePlayIntegration:initialize()
    self.autoDriveIntegration:initialize()
    self.sprayerIntegration:initialize()
    self.irrigatorSectorIntegration:initialize()

    -- Persistence handler
    self.saveLoad:initialize()

    -- Settings panel
    if self.settingsPanel ~= nil then
        self.settingsPanel:initialize()
    end

    -- Capture first hour key so hourly tick fires correctly from the start.
    -- env.currentHour is a direct property — not a method call.
    local env = g_currentMission.environment
    if env ~= nil then
        local day  = env.currentMonotonicDay or 0
        local hour = env.currentHour or 0
        self.lastHourKey = day * 24 + hour
    end

    -- NOTE: settings are NOT loaded or applied here.
    -- onStartMission fires after fields are populated and is the correct
    -- lifecycle point to load settings + call applySettings().
    -- (main.lua onStartMission hook handles both.)

    self.isInitialized = true

    csLog(string.format(
        "CropStressManager initialized. Fields tracked: %d",
        self.soilSystem:getFieldCount()
    ))
end

-- Called from loadMission00Finished. Installs a self-removing frame updater
-- (NPCFavor pattern) that polls g_currentMission.isMissionStarted and
-- g_fieldManager.fields each frame. When both are ready it enumerates fields,
-- builds the fieldId lookup map, and removes itself — no lifecycle hooks needed.
function CropStressManager:installFieldReadyUpdater()
    if not self.isInitialized then return end
    if self._fieldReadyUpdaterInstalled then return end
    self._fieldReadyUpdaterInstalled = true

    local manager = self
    local updater = {
        _done = false,
        update = function(u, dt)
            if u._done then return true end

            -- Wait for mission started AND g_fieldManager with at least one field
            if not g_currentMission or not g_currentMission.isMissionStarted then
                return false
            end
            if not g_fieldManager or not g_fieldManager.fields then
                return false
            end
            if next(g_fieldManager.fields) == nil then
                return false  -- fields table exists but is empty — keep waiting
            end

            -- Ready — enumerate and map fields exactly once
            u._done = true

            local found = manager.soilSystem:enumerateFields()
            csLog(string.format("CropStressManager fieldReady: enumerateFields found %d fields", found))

            local mapped = manager:buildFieldMap()
            csLog(string.format("CropStressManager fieldReady: buildFieldMap mapped %d fields", mapped))

            -- SCS-039: stand the 2m value map up FIRST, because whether it is
            -- carrying the truth decides whether the relief pass below runs at
            -- all. Terrain is available by this point, which is what the map
            -- needs. Declines quietly on any install the engine cannot carry.
            local mapLive = false
            if manager.soilSystem.initValueMap ~= nil then
                local sgDir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
                    and g_currentMission.missionInfo.savegameDirectory or nil
                mapLive = manager.soilSystem:initValueMap(sgDir)
            end

            -- SCS-018: once fields are ready, materialise relief cells (one pass,
            -- terrain is available after mission start) and register the daily
            -- settle with Time Guard (server). The store's relief pass and the
            -- fallback day hook handle absence.
            --
            -- UNDER THE MAP DEFAULT THE RELIEF PASS IS FALLBACK-ONLY, per the
            -- moisture brief's ratified rebase addendum: the materialisation
            -- machinery (threshold, relief trigger, backstop cap) is text that
            -- only applies when the map is absent. Running it anyway would build
            -- a second store nothing reads and pay for it every load.
            if not mapLive and manager.soilSystem.materialiseRelief ~= nil then
                for fieldId in pairs(manager.soilSystem.fieldData) do
                    manager.soilSystem:materialiseRelief(fieldId)
                end
            end
            if g_server ~= nil and manager.soilSystem.registerDailyAccrual ~= nil then
                manager.soilSystem:registerDailyAccrual()
            end

            if found == 0 then
                csLog("CropStressManager fieldReady: WARNING — enumerateFields returned 0. Check g_fieldManager.fields.")
            end

            -- Signal that fieldData is now populated.
            -- Two possible orderings depending on map/machine load time:
            --   A) updater fires BEFORE onStartMission  → xmlFile not available yet,
            --      so we set the flag and let onStartMission call loadFromXMLFile().
            --   B) updater fires AFTER onStartMission   → onStartMission already ran
            --      but skipped the load (fields weren't ready), so we call it now.
            manager._fieldsEnumerated = true
            if manager._onStartMissionRan then
                manager:loadFromXMLFile()
                csLog("CropStressManager fieldReady: save data restored (post-onStartMission)")
            else
                csLog("CropStressManager fieldReady: fields ready, awaiting onStartMission for xmlFile")
            end

            return true  -- remove updater
        end
    }

    if g_currentMission and g_currentMission.addUpdateable then
        g_currentMission:addUpdateable(updater)
        csLog("CropStressManager: field-ready updater installed")
    else
        csLog("CropStressManager: WARNING — addUpdateable not available, attempting immediate enumeration")
        manager.soilSystem:enumerateFields()
        manager:buildFieldMap()
    end
end

-- ============================================================
-- FIELD ID MAP
-- Builds a fieldId → field object lookup table.
-- Must be called AFTER g_fieldManager.fields is populated
-- (installFieldReadyUpdater handles the correct timing).
--
-- Why: getFieldByIndex(n) returns fields[n] — the nth element
-- of an internal array — NOT the field whose field.fieldId == n.
-- On custom maps, deleted/renumbered fields, or any map that
-- loads fields in a different order, getFieldByIndex(fieldId)
-- silently returns the WRONG field. The only correct approach
-- is to iterate getFields() once, build a hash map keyed by
-- field.fieldId, and do all subsequent lookups in O(1).
--
-- Pattern confirmed by every production FS22/FS25 mod (AdditionalFieldInfo,
-- CropRotation, CoursePlay) and explicitly documented on GDN forums.
-- ============================================================
function CropStressManager:buildFieldMap()
    self.fieldById = {}
    if g_fieldManager == nil or g_fieldManager.fields == nil then
        csLog("buildFieldMap: g_fieldManager unavailable — map will be empty")
        return 0
    end

    local count = 0
    for _, field in pairs(g_fieldManager.fields) do
        -- FS25: fields are keyed by farmland ID. field.fieldId does not exist.
        local fid = field ~= nil and field.farmland and field.farmland.id
        if fid ~= nil then
            self.fieldById[fid] = field
            count = count + 1
        end
    end

    csLog(string.format("buildFieldMap: %d fields mapped by fieldId", count))
    return count
end

-- Apply current settings to all subsystems.
-- NOTE: settings.enabled is NOT pushed here; it is honoured as an early-return
-- guard in onHourlyTick() and draw() so the simulation simply stops running.
function CropStressManager:applySettings()
    if not self.isInitialized then return end
    if self.settings == nil then return end

    -- Apply settings to subsystems.
    -- Use toggle() to reach the desired visibility state so that all side-effects
    -- fire (rebuildDisplayRows, firstRunShown, forecast init, etc.).  Direct
    -- assignment to isVisible skips those and leaves the HUD rendering blank even
    -- though the flag is set — the symptom reported in issue #48 follow-up where
    -- pressing the keybind logged "toggled" but nothing appeared.
    if self.hudOverlay.isVisible ~= self.settings.hudVisible then
        self.hudOverlay:toggle()
    end
    self.soilSystem:setEvapMultiplier(self.settings:getTotalEvapMultiplier())
    self.soilSystem:setCriticalThreshold(self.settings.criticalThreshold)
    self.stressModifier:setRateMultiplier(self.settings:getDifficultyStressMultiplier())
    self.stressModifier:setMaxYieldLoss(self.settings.maxYieldLoss)
    self.irrigationManager:setCostsEnabled(self.settings.irrigationCosts)
    self.consultant:setAlertsEnabled(self.settings.alertsEnabled)
    self.consultant:setAlertCooldown(self.settings.alertCooldown)
    self.debugMode = self.settings.debugMode

    -- Push persisted HUD position (client-local display preference, not synced to MP)
    self.hudOverlay.panelX = self.settings.hudPanelX
    self.hudOverlay.panelY = self.settings.hudPanelY

    csLog("Settings applied to all subsystems")
end

-- ============================================================
-- PER-FRAME UPDATE (called from FSBaseMission.update hook)
-- ============================================================
function CropStressManager:update(dt)
    if not self.isInitialized then return end
    if g_currentMission == nil then return end

    -- NPCFavor deferred registration: poll each frame until npcSystem.isInitialized
    if self.npcIntegration ~= nil then
        self.npcIntegration:tryDeferredRegistration()
    end

    -- SCS-039: walk any queued moisture-map delivery a few rows per frame.
    -- Returns immediately when the queue is empty, which is the normal case.
    if g_server ~= nil and self.soilSystem ~= nil and self.soilSystem.updateMapSync ~= nil then
        self.soilSystem:updateMapSync()
    end

    -- Vehicle irrigator sector tick (server only; self-throttled to 500 ms).
    -- Placed above the environment early-return so a nil environment cannot
    -- silently stop irrigation while the rest of the mod carries on.
    if self.irrigatorSectorIntegration ~= nil then
        self.irrigatorSectorIntegration:update(dt)
    end

    local env = g_currentMission.environment
    if env == nil then return end

    -- Hourly tick detection
    -- env.currentHour is a direct property, not a method
    local day     = env.currentMonotonicDay or 0
    local hour    = env.currentHour or 0
    local hourKey = day * 24 + hour

    if hourKey ~= self.lastHourKey then
        -- SCS-037: the delta this detector already holds is the elapsed count.
        -- Read it BEFORE the key is advanced, or it is gone.
        local elapsedHours = CropStressManager.elapsedHoursFrom(self.lastHourKey, hourKey)
        self.lastHourKey = hourKey
        self:onHourlyTick(elapsedHours)
    end

    -- HUD frame update (handles auto-show, input response)
    self.hudOverlay:update(dt)

    -- Settings panel update (camera freeze, cursor, auto-close)
    if self.settingsPanel ~= nil then
        self.settingsPanel:update(dt)
    end
end

--- SCS-037: `elapsedHours` is how many in-game hours this one tick stands for.
--- It defaults to 1, which is arithmetically identical to what shipped, so every
--- caller that does not care (the console heat simulator, any future direct call)
--- keeps exactly today's behaviour.
---
--- WHAT MULTIPLIES AND WHAT DOES NOT. The three PER-HOUR consumers multiply:
--- evaporation/rain/irrigation gain (SoilMoistureSystem), stress accrual
--- (CropStressModifier) and irrigation running cost (FinanceIntegration).
--- The DAILY DRAINAGE SETTLE DOES NOT: it rides its own day accrual and already
--- honours `boundariesCrossed`, and the one-clock rule says a quantity is charged
--- by exactly one clock. Weather is polled once and held: temperature and humidity
--- are last-known sky across the whole span, which is the stated approximation.
---@param elapsedHours number|nil  hours this tick covers (default 1)
function CropStressManager:onHourlyTick(elapsedHours)
    -- Respect the player's master on/off toggle
    if not self.settings.enabled then return end

    local hours = math.max(1, math.floor(tonumber(elapsedHours) or 1))

    -- Rebuild field map once per in-game day so newly bought/sold fields are tracked
    local env = g_currentMission and g_currentMission.environment
    local today = env and env.currentDay or 0
    if today ~= (self.lastFieldMapDay or -1) then
        self.lastFieldMapDay = today
        self.soilSystem:enumerateFields()
        self:buildFieldMap()
    end

    -- 1. Poll current weather state
    self.weatherIntegration:update()

    -- 2a. Refresh optional mod data caches before the simulation tick
    self.soilFertilizerIntegration:hourlyRefresh()  -- pH + OM modifiers per field
    self.coursePlayIntegration:hourlyRefresh()        -- CP vehicle positions
    self.autoDriveIntegration:hourlyRefresh()         -- AutoDrive destination count

    -- Simulation runs on the server (or single-player host) only.
    -- Clients receive updated values via CropStressMoistureInitEvent broadcast.
    if g_server ~= nil then
        -- 2b. Activate/deactivate irrigation systems BEFORE moisture update so
        --     gains set by activateSystem() are included in this tick.
        self.irrigationManager:hourlyScheduleCheck()

        -- SCS-018: when Time Guard is absent, the daily settle rides the
        -- fallback day-change hook (accepts the known skipped-day limitation).
        if self.soilSystem.checkDayFallback ~= nil then
            self.soilSystem:checkDayFallback()
        end

        -- 2c. Advance soil moisture simulation
        -- SCS-037 round 2: when SoilFertilizer's Water Record is reachable, the
        -- rain switch is reconstructed per skipped day rather than held at the
        -- last-known sky. nil (the case today) means round-1 behaviour exactly.
        self.soilSystem:hourlyUpdate(self.weatherIntegration, hours, self:getSkipRainHours(hours))

        -- 3. Apply RWE world-event stress multiplier (no-op when RWE not loaded)
        if self.rweManager then
            local activeEvent = self.rweManager.EVENT_STATE and self.rweManager.EVENT_STATE.activeEvent
            self.stressModifier:setRWEMultiplier(CropStressManager.RWE_STRESS_MULTIPLIERS[activeEvent] or 1.0)
        end

        -- 4. Accumulate crop stress where moisture is critical
        self.stressModifier:hourlyUpdate(hours)

        self.financeIntegration:chargeHourlyCosts(hours)

        -- Push updated moisture/stress to all connected clients. When the
        -- NetworkSync bridge is active the whole field map batches through its 1Hz
        -- tick (markFieldDirty); otherwise broadcast the moisture event directly.
        if CropStressNetworkSyncBridge ~= nil and CropStressNetworkSyncBridge.active then
            CropStressNetworkSyncBridge.markFieldDirty()
        else
            g_server:broadcastEvent(CropStressMoistureInitEvent.new(
                self.soilSystem.fieldData,
                self.stressModifier.fieldStress
            ), false)
        end
    end

    -- Consultant alert evaluation runs everywhere (reads synced field data)
    self.consultant:hourlyEvaluate()

    if self.debugMode then
        local seasonName = WeatherIntegration.SEASON_NAMES[self.weatherIntegration:getCurrentSeason()]
            or tostring(self.weatherIntegration:getCurrentSeason())
        csLog(string.format(
            "Hourly tick complete (%dh). Season=%s Temp=%.1f Rain=%s",
            hours,
            seasonName,
            self.weatherIntegration:getCurrentTemp(),
            tostring(self.weatherIntegration.isRaining)
        ))
    end
end

-- ============================================================
-- SCS-037 ROUND 2: THE RAIN SWITCH ACROSS A SKIP
--
-- Round 1 holds the sky at its last-known state for the whole span, so a skip
-- that ends in rain charges the field rain for every skipped hour and a skip that
-- ends dry charges none. SoilFertilizer's Water Record (SF-49) already freezes ONE
-- VERDICT PER DAY, did water arrive, from any source, which is exactly the
-- switch needed to reconstruct those hours instead of guessing them.
--
-- LIVE since 2026-08-10. The delegate `getWaterDaysInLast(days, throughDay)` is
-- published on `g_currentMission.soilFertilityManager`, so we bind to a METHOD ON
-- THE MANAGER and nothing else, per SoilFertilizer's own cross-boundary rule (its
-- `getCellGrowthInfo` / `getFieldGrowthSummary` delegates, 2026-08-09), so a
-- refactor there cannot rename this read out from under us. Before the delegate
-- existed we probed for it and took round-1 behaviour; the nil paths in
-- `getSkipRainHours` below are kept because they are still the honest answer
-- when the record is absent or the ground_material gate is closed.
--
-- Temperature and humidity stay last-known sky either way; only the rain switch
-- is reconstructable, because only the rain switch is recorded.
-- ============================================================

--- Rain-bearing hours within a catch-up span, or nil when unknowable.
--- nil is the normal answer and means "use `hours`", i.e. round-1 behaviour.
---@param hours number  the elapsed span this tick covers
---@return number|nil rainHours
function CropStressManager:getSkipRainHours(hours)
    -- A single hour has nothing to reconstruct: the sky IS current.
    if hours == nil or hours <= 1 then return nil end

    local sfm = g_currentMission ~= nil and g_currentMission.soilFertilityManager
    if sfm == nil or type(sfm.getWaterDaysInLast) ~= "function" then return nil end

    local env = g_currentMission.environment
    local throughDay = env ~= nil and (env.currentMonotonicDay or env.currentDay) or nil
    if throughDay == nil then return nil end

    -- Ceil: a span of 30 hours touches two calendar days, both of which have a verdict.
    local days = math.ceil(hours / 24)

    local ok, wet, known = pcall(function() return sfm:getWaterDaysInLast(days, throughDay) end)
    if not ok or type(wet) ~= "number" or type(known) ~= "number" or known <= 0 then
        return nil
    end

    -- Scale the span by the fraction of KNOWN days that brought water. Days the
    -- record does not reach back to are not counted as dry — they are not counted
    -- at all, which is why the divisor is `known` and not `days`.
    return hours * (wet / known)
end

-- ============================================================
-- DRAW (called from FSBaseMission.draw hook)
-- ============================================================
function CropStressManager:draw()
    if not self.isInitialized then return end
    -- Settings panel draws regardless of mod enabled state (user needs to be able to re-enable)
    if self.settingsPanel ~= nil then
        self.settingsPanel:draw()
    end
    if not self.settings.enabled then return end
    self.hudOverlay:draw()
end

-- ============================================================
-- SAVE / LOAD
-- ============================================================
function CropStressManager:saveToXMLFile(xmlFile)
    if not self.isInitialized then return end
    self.saveLoad:saveToXMLFile(xmlFile)
end

function CropStressManager:loadFromXMLFile()
    if not self.isInitialized then return end
    -- StateLedger is the load source of truth when present and it delivered a
    -- block; careerSavegame.xml is the fallback (new save, or ledger absent).
    -- Composed here so both load sites (onStartMission and the field-ready
    -- updater) get the ledger choice.
    if CropStressStateLedgerBridge ~= nil and CropStressStateLedgerBridge.hasLedgerState() then
        CropStressStateLedgerBridge.applyState(self)
    else
        self.saveLoad:loadFromXMLFile()
    end
end

-- ============================================================
-- MULTIPLAYER
-- ============================================================
function CropStressManager:sendInitialClientState(connection)
    if not self.isInitialized then return end
    if g_server == nil then return end  -- only server sends

    -- 1. Push settings so the client stays in sync with host configuration
    CropStressSettingsSyncEvent.sendAllToConnection(connection)

    -- 2. Push full field moisture + stress snapshot so the client HUD is
    --    populated immediately on join rather than showing an empty screen
    local moistureEvent = CropStressMoistureInitEvent.new(
        self.soilSystem.fieldData,
        self.stressModifier.fieldStress
    )
    connection:sendEvent(moistureEvent)

    -- 3. SCS-039: queue the 2m map for this client. The snapshot above already
    --    gave them every field SCALAR, so their HUD is correct immediately; the
    --    map rows fill in the sub-field detail behind it, a few per frame. A
    --    client that disconnects mid-walk simply stops receiving rows.
    if self.soilSystem.queueMapSync ~= nil then
        self.soilSystem:queueMapSync(connection)
    end

    local fieldCount = 0
    for _ in pairs(self.soilSystem.fieldData) do fieldCount = fieldCount + 1 end
    csLog(string.format("MP: sent settings + moisture snapshot (%d fields) to new client", fieldCount))
end

-- ============================================================
-- COMPANION READ API
-- The single, stable read path for a field's moisture / stress. External
-- companions (CropDisease, RandomWorldEvents, MarketDynamics, FarmTablet)
-- and the bedrock bridges call these on g_cropStressManager rather than
-- reaching into the subsystems, so the internal wiring can change without
-- breaking readers. Mirrors SoilFertilizer's getFieldInfo read contract.
-- ============================================================

-- Moisture (0.0-1.0) for a field, or nil if the field is not tracked.
-- With a world position (fieldId, x, z) returns the per-cell moisture where a
-- cell exists, else the field aggregate (SCS-018 positional read; never nil).
function CropStressManager:getMoisture(fieldId, x, z)
    if self.soilSystem == nil then return nil end
    return self.soilSystem:getMoisture(fieldId, x, z)
end

-- Stress (0.0-1.0) for a field; 0.0 if the field is not tracked.
-- NOTE: this is a MOISTURE-DROUGHT scalar ONLY. CropStressModifier accumulates
-- it purely from moisture deficit inside critical growth windows and folds NO
-- temperature term, so a well-irrigated field in a heatwave reports ~0.0.
-- Heat-driven consumers (SCS-010 market heat, SCS-013 livestock heat) must read
-- getTemperature/getEvaporativeDemand below, never getStress, for heat.
function CropStressManager:getStress(fieldId)
    if self.stressModifier == nil then return 0.0 end
    return self.stressModifier:getStress(fieldId)
end

-- Yield KEEP-factor (0.0-1.0) that our harvest hook actually applies to a field's
-- grain: 1.0 = no drought reduction, 0.75 = a quarter of the crop lost to stress.
-- This is the single number a cross-mod consumer needs to reason about SCS's share
-- of the final yield, and it is derived from the same stress + maxYieldLoss the
-- CropStressModifier harvest hook uses, so the two can never disagree.
--
-- Promoted deliberately rather than leaving consumers to compute stress*maxLoss
-- themselves: that formula (and the RW stand-down below) must live in ONE place,
-- or a tuning change here silently desyncs every reader.
--
-- Returns 1.0 (neutral) when there is no stressModifier, or when RW mode is active
-- -- in RW mode our Cutter.processCutterArea reduction steps aside entirely and
-- FS25_RealisticWeather owns the yield penalty, so SCS contributes nothing to fold.
function CropStressManager:getYieldKeepFactor(fieldId)
    local sm = self.stressModifier
    if sm == nil then return 1.0 end
    if sm.rwModeActive then return 1.0 end
    local keep = 1.0 - (sm:getStress(fieldId) * sm:getMaxYieldLoss())
    if keep < 0.0 then return 0.0 end
    if keep > 1.0 then return 1.0 end
    return keep
end

-- ── Irrigation & water (B3.2b) ──────────────────────────────
-- Irrigation-ops + economy consumers (SCS-006/007/008/009/011/012/015/016)
-- read irrigation state through these getters instead of reaching into
-- IrrigationManager, so the internal system model can change without breaking
-- them. All read-only and nil/neutral-safe, mirroring getMoisture.

-- Irrigation moisture-gain rate per in-game hour applied to a field by ALL
-- active systems combined (the irrigation contribution). 0.0 if not irrigated
-- or no manager. Compare with getMoisture(fieldId) (the total level) to reason
-- about irrigation-vs-natural water on a field.
function CropStressManager:getIrrigationRate(fieldId)
    if self.irrigationManager == nil then return 0.0 end
    return self.irrigationManager:getIrrigationRateForField(fieldId) or 0.0
end

-- True when at least one active irrigation system is watering the field.
function CropStressManager:isFieldIrrigated(fieldId)
    return self:getIrrigationRate(fieldId) > 0.0
end

-- Read-only snapshot list of registered irrigation systems. Each entry is a
-- COPY, never a live internal table:
--   { id, type, isActive,
--     coveredFields = { farmlandId, ... },  -- ARRAY, iterate with ipairs
--     schedule = { startHour, endHour, activeDays = {bool x7} } or nil,
--     flowRatePerHour, operationalCostPerHour }
-- Empty table if no systems / no manager. Mutating the result cannot affect the
-- live simulation, and the coveredFields ipairs-array contract is preserved.
function CropStressManager:getIrrigationSystems()
    local out = {}
    local irrMgr = self.irrigationManager
    if irrMgr == nil or irrMgr.systems == nil then return out end
    for _, sys in pairs(irrMgr.systems) do
        local covered = {}
        if sys.coveredFields ~= nil then
            for i = 1, #sys.coveredFields do covered[i] = sys.coveredFields[i] end
        end
        local schedule = nil
        if sys.schedule ~= nil then
            local days = {}
            if sys.schedule.activeDays ~= nil then
                for i = 1, #sys.schedule.activeDays do days[i] = sys.schedule.activeDays[i] end
            end
            schedule = {
                startHour  = sys.schedule.startHour,
                endHour    = sys.schedule.endHour,
                activeDays = days,
            }
        end
        out[#out + 1] = {
            id                     = sys.id,
            type                   = sys.type,
            isActive               = sys.isActive == true,
            coveredFields          = covered,
            schedule               = schedule,
            flowRatePerHour        = sys.flowRatePerHour,
            operationalCostPerHour = sys.operationalCostPerHour,
        }
    end
    return out
end

-- Active irrigation schedule covering a field: a COPY of
-- {startHour, endHour, activeDays} from the first active system whose
-- coveredFields include the field, or nil when nothing active covers it.
function CropStressManager:getIrrigationSchedule(fieldId)
    local irrMgr = self.irrigationManager
    if irrMgr == nil or irrMgr.systems == nil then return nil end
    for _, sys in pairs(irrMgr.systems) do
        if sys.isActive and sys.coveredFields ~= nil and sys.schedule ~= nil then
            for _, fid in ipairs(sys.coveredFields) do
                if fid == fieldId then
                    local days = {}
                    if sys.schedule.activeDays ~= nil then
                        for i = 1, #sys.schedule.activeDays do days[i] = sys.schedule.activeDays[i] end
                    end
                    return {
                        startHour  = sys.schedule.startHour,
                        endHour    = sys.schedule.endHour,
                        activeDays = days,
                    }
                end
            end
        end
    end
    return nil
end

-- Field polygon in world space for coverage / area math: returns vx, vz, n
-- (arrays of vertex world coords + count), or nil when unavailable. Promotes
-- IrrigationManager:getFieldPolygonWorld — the real field polygon, never a
-- label-point box.
function CropStressManager:getFieldPolygonWorld(field)
    if self.irrigationManager == nil then return nil end
    return self.irrigationManager:getFieldPolygonWorld(field)
end

-- ── Advisory / alert hint (B3.2b) ───────────────────────────
-- Short localised critical-stress hint (e.g. an AutoDrive water-hauling
-- suggestion), or nil when no advisory applies. Read-only.
function CropStressManager:getCriticalAlertHint()
    if self.autoDriveIntegration == nil then return nil end
    return self.autoDriveIntegration:getCriticalAlertHint()
end

-- ── Heat / drought (B3.2b, SCS-010 / SCS-013) ───────────────
-- getStress does NOT fold heat (see its note above), so heat consumers read
-- these instead. Both promote existing WeatherIntegration reads — no new heat
-- mechanic is introduced; they are map-wide signals, not per-field.

-- Current ambient temperature in °C (weather-driven). Neutral 15.0 without
-- weather data.
function CropStressManager:getTemperature()
    if self.weatherIntegration == nil then return 15.0 end
    return self.weatherIntegration:getCurrentTemp() or 15.0
end

-- Evaporative demand for the current hour: the temperature+season evaporation
-- multiplier (typically ~0.2 cool/humid .. ~2.5 hot/dry; ~90% lower while
-- raining). The map-wide heat/drought pressure signal for SCS-010/013 to
-- compose their own response from. Neutral 1.0 without weather data.
function CropStressManager:getEvaporativeDemand()
    if self.weatherIntegration == nil then return 1.0 end
    return self.weatherIntegration:getHourlyEvapMultiplier() or 1.0
end

-- True when SCS is charging irrigation operating costs (the player has not disabled
-- them). Mirrors FinanceIntegration's own gate: enabled unless costsEnabled is
-- explicitly false. Lets a cost-mirroring consumer (e.g. TaxMod's irrigation expense
-- line) avoid reporting a charge the player is not actually paying. Neutral true when
-- no irrigation manager is present (no systems means nothing is charged anyway).
function CropStressManager:getIrrigationCostsEnabled()
    if self.irrigationManager == nil then return true end
    return self.irrigationManager.costsEnabled ~= false
end

-- ============================================================
-- OPTIONAL MOD DETECTION
-- ============================================================
function CropStressManager:detectOptionalMods()
    -- Cross-mod globals MUST be read via getfenv(0)["name"]. FS25 mod sandboxing
    -- means plain global access (e.g. g_NPCSystem) only sees our own mod environment.
    -- Other mods export globals via getfenv(0)["x"] = val (game shared env), so we
    -- must read them the same way. Confirmed: NPCFavor/NPCAI.lua uses getfenv(0)["g_NPCSystem"].
    -- NPCFavor detection: getfenv(0) is per-mod scoped in FS25 — NOT shared between mods.
    -- NPCFavor bridges its system via mission.npcFavorSystem (set in Mission00.load hook).
    -- g_currentMission == mission at this point (loadMission00Finished).
    if g_currentMission ~= nil and g_currentMission.npcFavorSystem ~= nil then
        csLog("FS25_NPCFavor detected — enabling NPC integration")
        self.npcIntegration.npcFavorActive = true
        -- Also enable NPCFavor mode on the consultant so alerts route through Alex Chen
        self.consultant:enableNPCFavorMode()
    end

    -- UsedPlus detection: primary path is g_currentMission.usedPlusAPI (set in UP v2.15.4.96+
    -- onStartMission — the only reliable cross-mod path in FS25's sandboxed environment).
    -- Bare UsedPlusAPI / g_usedPlusManager globals are kept as fallbacks for older versions.
    --
    -- F154: THE FINANCE ARM IS GONE. FinanceIntegration no longer reads UsedPlus at
    -- all, so arming it here would be detecting a mod that nothing reads.
    --
    -- THE DETECTION ITSELF SURVIVES ONLY BECAUSE THE MARKETPLACE STILL CONSUMES IT.
    -- The F154 fix doc names FinanceIntegration as this site's only consumer; it is
    -- not, and UsedEquipmentMarketplace is a second one that the doc does not
    -- otherwise scope. Retiring a whole listings feature is a wider decision than
    -- retiring a dead wear probe, so it is reported rather than taken here. If that
    -- decision lands as "retire", this whole block goes with it.
    local upApi = (g_currentMission and g_currentMission.usedPlusAPI) or UsedPlusAPI or g_usedPlusManager
    if upApi ~= nil then
        csLog("FS25_UsedPlus detected — enabling used-equipment marketplace")
        self.usedEquipmentMarketplace:enableUsedPlusMode()
    end

    -- FS25_SoilFertilizer (sibling mod by same author)
    -- Bridge: mission.soilFertilityManager is set by SoilFertilizer in its Mission00.load hook.
    -- g_SoilFertilityManager is per-mod scoped (getfenv(0)) and NOT cross-mod accessible.
    local sfm = g_currentMission and g_currentMission.soilFertilityManager
    if sfm ~= nil then
        csLog("FS25_SoilFertilizer detected — soil pH and organic matter will affect moisture simulation")
        self.soilFertilizerIntegration:enableSoilFertilizerMode()
    end

    -- CoursePlay FS25
    -- Global: g_Courseplay (capital P — confirmed from Courseplay.lua; FS22 used lowercase g_courseplay)
    if g_Courseplay ~= nil then
        csLog("CoursePlay detected — CP vehicle activity will appear in stress alerts")
        self.coursePlayIntegration:enableCoursePlayMode()
    end

    -- AutoDrive FS25
    -- Global: AutoDrive (no g_ prefix — confirmed from AutoDrive.lua; FS22 used g_autoDrive)
    if AutoDrive ~= nil then
        csLog("AutoDrive detected — water destination hints will appear in critical alerts")
        self.autoDriveIntegration:enableAutoDriveMode()
    end

    -- FS25_RealisticWeather: WEATHER source only (temperature, rain) through
    -- WeatherIntegration. SCS-018 unwind: its moisture grid is neither read nor
    -- written; SCS owns its whole moisture simulation on every map. The wiring
    -- calls below are kept (no-op clears) so the detection stays truthful about
    -- weather without touching RW's moisture state.
    local rwMs = g_currentMission and g_currentMission.moistureSystem
    if rwMs ~= nil and type(rwMs.getValuesAtCoords) == "function" then
        csLog("FS25_RealisticWeather detected as WEATHER source; SCS moisture simulation stays ours (RW grid untouched)")
        self.soilSystem:setRWMoistureSystem(nil)
        self.stressModifier:setRWMode(false)
    end

    -- FS25_MoistureSystem (by Ozz) detection
    -- We check for the mod name and its likely global/manager.
    -- Ozz's mod also uses Shift+M, so we log a warning for the user.
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_MoistureSystem"] then
        csLog("FS25_MoistureSystem (Ozz) detected — WARNING: Keybind conflict detected (Shift+M). You may need to rebind your keys in the options menu.")
        -- If it also provides a moisture system, we should ideally sync with it,
        -- but since we don't have its API yet, we at least warn the user.
    end

    -- FS25_RandomWorldEvents (via mission bridge set in RWE's Mission00.load hook)
    -- Field events (crop_yield_penalty, harvest_penalty, etc.) scale the stress rate multiplier.
    local rwe = g_currentMission and g_currentMission.randomWorldEvents
    if rwe ~= nil then
        csLog("FS25_RandomWorldEvents detected — field events will modulate stress accumulation rate")
        self.rweManager = rwe
    end
end

-- ============================================================
-- INPUT EVENT — CONSULTANT DIALOG
-- ============================================================
function CropStressManager:onOpenConsultantDialog()
    -- CsDialogLoader lazily loads the dialog on first call, then shows it.
    -- No data setter needed — CropConsultantDialog.onOpen() reads live data.
    CsDialogLoader.show("CropConsultantDialog")
end

-- ============================================================
-- INPUT EVENT — HUD TOGGLE
-- ============================================================
function CropStressManager:onToggleHUD()
    self.hudOverlay:toggle()
    -- Keep settings in sync so the next save/load persists the player's preference.
    if self.settings ~= nil then
        self.settings.hudVisible = self.hudOverlay.isVisible
    end
end

-- ============================================================
-- INPUT EVENT — SETTINGS PANEL TOGGLE
-- ============================================================
function CropStressManager:onToggleSettings()
    if self.settingsPanel ~= nil then
        self.settingsPanel:toggle()
    end
end

function CropStressManager:onOpenIrrigationDialog(systemId)
    local irrMgr = self.irrigationManager
    if irrMgr == nil then return end

    -- Cross-mod entry point. Callers in OTHER mods (e.g. a Reinke pivot reached
    -- via g_currentMission.cropStressManager) can pass their own system id so the
    -- dialog opens for THAT pivot. A bare CsDialogLoader global is only visible
    -- inside this mod's environment, so external mods must route through here.
    -- When systemId is nil/unknown, fall back to the first registered system
    -- (existing in-mod callers pass nothing, so their behaviour is unchanged).
    local firstId = systemId
    if firstId == nil or irrMgr.systems[firstId] == nil then
        firstId = nil
        for id, _ in pairs(irrMgr.systems) do
            firstId = id
            break
        end
    end

    if firstId ~= nil then
        -- CsDialogLoader.show() calls setSystemId(firstId) BEFORE showDialog(),
        -- so onOpen() sees a valid systemId when it fires.
        CsDialogLoader.show("IrrigationScheduleDialog", "setSystemId", firstId)
    else
        if g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(
                (g_i18n ~= nil and g_i18n:getText("cs_no_irrigation_systems"))
                or "No irrigation systems registered.", 3000)
        end
    end
end

-- ============================================================
-- CLEANUP
-- ============================================================
function CropStressManager:delete()
    -- Unsubscribe all event bus listeners
    CropEventBus.listeners = {}

    -- Subsystem cleanup (reverse order of init)
    self.sprayerIntegration:delete()
    self.irrigatorSectorIntegration:delete()
    self.autoDriveIntegration:delete()
    self.coursePlayIntegration:delete()
    self.soilFertilizerIntegration:delete()
    self.usedEquipmentMarketplace:delete()
    self.financeIntegration:delete()
    self.npcIntegration:delete()
    self.consultant:delete()
    self.hudOverlay:delete()
    if self.moistureMapOverlay ~= nil then self.moistureMapOverlay:delete() end
    self.irrigationManager:delete()
    self.stressModifier:delete()
    self.soilSystem:delete()
    self.weatherIntegration:delete()
    self.saveLoad:delete()

    if self.settingsPanel ~= nil then
        self.settingsPanel:delete()
    end

    self.isInitialized = false
    csLog("CropStressManager deleted")
end

-- ============================================================
-- DEBUG CONSOLE COMMANDS
-- ============================================================
function CropStressManager:consoleHelp()
    print("=== FS25_SeasonalCropStress Debug Commands ===")
    print("  csStatus               — Print system status overview")
    print("  csSetMoisture <id> <v> — Set field moisture (0.0-1.0)")
    print("  csForceStress <id>     — Force max stress on a field")
    print("  csSimulateHeat <days>  — Simulate heat wave for N in-game days")
    print("  csDebug                — Toggle verbose debug logging")
    print("  csConsultant           — Open the Crop Consultant dialog")
    print("==============================================")
end

function CropStressManager:consoleStatus()
    print("=== CropStress Status ===")
    print(string.format("  Initialized: %s", tostring(self.isInitialized)))
    print(string.format("  Debug mode:  %s", tostring(self.debugMode)))

    if self.weatherIntegration ~= nil then
        local seas = WeatherIntegration.SEASON_NAMES[self.weatherIntegration.currentSeason] or "?"
        print(string.format("  Season: %s  Temp: %.1f°C  Raining: %s",
            seas, self.weatherIntegration.currentTemp,
            tostring(self.weatherIntegration.isRaining)))
    end

    print(string.format("  Fields tracked: %d", self.soilSystem:getFieldCount()))

    -- Optional mod integration status
    print("  Optional integrations:")
    print(string.format("    NPCFavor:       %s", tostring(self.npcIntegration and self.npcIntegration.npcFavorActive or false)))
    -- F154: reports the marketplace, which is now UsedPlus's only consumer here.
    print(string.format("    UsedPlus:       %s", tostring(self.usedEquipmentMarketplace and self.usedEquipmentMarketplace.usedPlusActive or false)))
    print(string.format("    SoilFertilizer: %s", tostring(self.soilFertilizerIntegration and self.soilFertilizerIntegration.sfActive or false)))
    print(string.format("    CoursePlay:     %s (vehicles active: %d)",
        tostring(self.coursePlayIntegration and self.coursePlayIntegration.cpActive or false),
        self.coursePlayIntegration and self.coursePlayIntegration:getActiveVehicleCount() or 0))
    print(string.format("    AutoDrive:      %s (destinations: %d, water: %d)",
        tostring(self.autoDriveIntegration and self.autoDriveIntegration.adActive or false),
        self.autoDriveIntegration and self.autoDriveIntegration:getDestinationCount()      or 0,
        self.autoDriveIntegration and self.autoDriveIntegration:getWaterDestinationCount() or 0))

    -- Print top 5 driest fields
    local sorted = self.soilSystem:getFieldsSortedByMoisture()
    print("  Driest fields:")
    for i = 1, math.min(5, #sorted) do
        local f = sorted[i]
        local stress = self:getStress(f.fieldId)
        print(string.format("    Field %d: %.1f%% moisture, stress %.2f",
            f.fieldId, f.moisture * 100, stress))
    end
end

--- SCS-039 THE FRAME-COST INSTRUMENT. The brief left in-game frame cost as its
--- one open measurement; this makes it readable rather than guessed at.
function CropStressManager:consoleMapStats()
    local soil = self.soilSystem
    if soil == nil or soil.getMapStats == nil then
        print("Moisture map: unavailable (soil system not ready)")
        return
    end
    local s = soil:getMapStats()
    print("=== Moisture value map (SCS-039) ===")
    if not s.active then
        print("  ACTIVE: no - the sparse-cell store is carrying moisture")
        print("  (engine incapable, release-gated off, or the map declined to load)")
        return
    end
    local m = s.map or {}
    print(string.format("  ACTIVE: yes   grain %.2f m/px   %dx%d   %s",
        m.grainMetres or 0, m.resolution or 0, m.resolution or 0,
        m.fromSave and "restored from savegame" or "fresh"))
    print(string.format("  one raw step = %.5f moisture (the quantisation floor)", m.unitsPerRaw or 0))
    print(string.format("  fields seeded onto the map: %d", s.seededFields or 0))
    print(string.format("  last daily settle: %s ms over %d fields / %d sampled blocks",
        tostring(s.settleMs or "n/a"), s.settleFields or 0, s.settleBlocks or 0))
    print(string.format("  MP rows sent: %d   deliveries pending: %d",
        s.syncRowsSent or 0, s.syncPending or 0))
    print(string.format("  engine paths: executeAdd=%s polygonOps=%s",
        tostring(m.executeAdd), tostring(m.polygonOps)))
end

function CropStressManager:consoleRelease()
    if not ReleaseGate then
        print("[CropStress] Release gate not loaded")
        return
    end
    local optIn = self.settings ~= nil and self.settings.experimentalSystems == true or nil
    print(ReleaseGate.status(optIn))
end

function CropStressManager:consoleSetMoisture(fieldIdStr, valueStr)
    local fieldId = tonumber(fieldIdStr)
    local value   = tonumber(valueStr)
    if fieldId == nil or value == nil then
        print("Usage: csSetMoisture <fieldId> <0.0-1.0>")
        return
    end
    value = math.max(0.0, math.min(1.0, value))
    if self.soilSystem:setMoisture(fieldId, value) then
        print(string.format("Field %d moisture set to %.1f%%", fieldId, value * 100))
    else
        print(string.format("Field %d not found in moisture data", fieldId))
    end
end

function CropStressManager:consoleForceStress(fieldIdStr)
    local fieldId = tonumber(fieldIdStr)
    if fieldId == nil then
        print("Usage: csForceStress <fieldId>")
        return
    end
    self.stressModifier.fieldStress[fieldId] = 1.0
    print(string.format("Field %d stress forced to maximum (1.0)", fieldId))
end

function CropStressManager:consoleSimulateHeat(daysStr)
    local days = tonumber(daysStr) or 1
    if days < 1 or days > 30 then
        print("Usage: csSimulateHeat <1-30>")
        return
    end

    -- Temporarily override weather state for the simulation
    local savedTemp = self.weatherIntegration.currentTemp
    local savedRain = self.weatherIntegration.hourlyRainAmount

    self.weatherIntegration.currentTemp      = 38.0  -- extreme heat
    self.weatherIntegration.hourlyRainAmount = 0.0   -- no rain

    for _ = 1, days do
        for _ = 1, 24 do
            self.soilSystem:hourlyUpdate(self.weatherIntegration)
            self.stressModifier:hourlyUpdate()
        end
    end

    self.weatherIntegration.currentTemp      = savedTemp
    self.weatherIntegration.hourlyRainAmount = savedRain

    print(string.format("Simulated %d-day heat wave. Check csStatus for field state.", days))
end


function CropStressManager:consoleConsultant()
    local shown = CsDialogLoader.show("CropConsultantDialog")
    if shown then
        print("CropStress: CropConsultant dialog opened")
    else
        print("CropStress: CropConsultant dialog failed to open — check log for CsDialogLoader errors")
    end
end

function CropStressManager:consoleToggleDebug()
    self.debugMode = not self.debugMode
    print(string.format("CropStress debug mode: %s", tostring(self.debugMode)))
end