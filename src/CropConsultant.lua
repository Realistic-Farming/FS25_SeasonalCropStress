-- ============================================================
-- CropConsultant.lua
-- Phase 3 implementation.
--
-- Subscribes to CS_CRITICAL_THRESHOLD events and generates
-- player-facing alerts at three severity levels.
-- Enforces a 12-in-game-hour cooldown per field to prevent spam.
--
-- In standalone mode:  shows blinkingWarning notifications.
-- With FS25_NPCFavor:  forwards alerts to NPCIntegration which
--                      presents them as NPC dialog from Alex Chen.
--
-- Alert severity levels:
--   INFO     (40-50% moisture) — "monitor conditions"          4s
--   WARNING  (25-40% moisture) — "irrigation recommended"      6s
--   CRITICAL (<25% moisture)  — "irrigate NOW!"               10s + auto-show HUD
-- ============================================================

CropConsultant = {}
CropConsultant.__index = CropConsultant

-- Severity thresholds (moisture fractions)
CropConsultant.SEVERITY_INFO_MAX     = 0.50   -- 40-50%: monitor
CropConsultant.SEVERITY_WARNING_MAX  = 0.40   -- 25-40%: recommend
CropConsultant.SEVERITY_CRITICAL_MAX = 0.25   -- <25%:   emergency

-- Alert display durations (milliseconds)
CropConsultant.DURATION_INFO     = 4000
CropConsultant.DURATION_WARNING  = 6000
CropConsultant.DURATION_CRITICAL = 10000

-- Cooldown: minimum in-game hours between alerts for the same field
CropConsultant.COOLDOWN_HOURS = 12

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
-- OWNERSHIP HELPER
-- Returns the local player's farmId, or nil if unavailable.
-- In singleplayer farmId is always 1; MP uses g_currentMission.player.farmId.
-- ============================================================
local function getLocalFarmId()
    if g_currentMission == nil then return nil end
    if not g_currentMission.missionDynamicInfo.isMultiplayer then
        return 1
    end
    local player = g_currentMission.player
    if player ~= nil and player.farmId ~= nil then
        return player.farmId
    end
    return nil
end

-- ============================================================
-- CONSTRUCTOR
-- ============================================================
function CropConsultant.new(manager)
    local self = setmetatable({}, CropConsultant)
    self.manager = manager

    -- fieldId_type → last alert hourKey (monotonic day * 24 + hour)
    self.alertCooldowns = {}

    -- Whether NPCFavor integration is delegating our alerts
    self.npcFavorMode = false

    self.isInitialized = false
    return self
end

-- ============================================================
-- INITIALIZE
-- Called by CropStressManager:initialize() after all subsystems exist.
-- ============================================================
function CropConsultant:initialize()
    if self.manager == nil or self.manager.eventBus == nil then
        csLog("CropConsultant: eventBus unavailable at init")
        self.isInitialized = true
        return
    end

    -- Subscribe to critical threshold events from SoilMoistureSystem
    self.manager.eventBus.subscribe("CS_CRITICAL_THRESHOLD", self.onCriticalThreshold, self)

    -- Subscribe to moisture updates for WARNING-level band-crossing detection
    self.manager.eventBus.subscribe("CS_MOISTURE_UPDATED", self.onMoistureUpdated, self)

    self.isInitialized = true
    csLog("CropConsultant initialized (standalone mode)")
end

-- ============================================================
-- ENABLE NPC FAVOR MODE
-- Called by CropStressManager:detectOptionalMods() when NPCFavor is present.
-- ============================================================
function CropConsultant:enableNPCFavorMode()
    self.npcFavorMode = true
    csLog("CropConsultant: NPCFavor mode enabled — alerts will route through Alex Chen")
end

-- ============================================================
-- OWNERSHIP CHECK
-- Returns true if the field is owned by the local player's farm.
-- Unowned fields (farmId == 0 or nil) and other-farm fields in MP
-- always return false.
-- ============================================================
function CropConsultant:isOwnedByLocalPlayer(fieldId)
    if self.manager == nil then return false end
    local field = self.manager.fieldById and self.manager.fieldById[fieldId]
    if field == nil then return false end
    local fl = field.farmland
    if fl == nil then return false end
    local farmId = getLocalFarmId()
    if farmId == nil then return false end
    return fl.farmId == farmId
end

-- ============================================================
-- HOURLY EVALUATE
-- Called by CropStressManager:onHourlyTick().
-- Proactively checks fields for INFO-level alerts (40-50% moisture
-- while a crop is in its critical window). CS_CRITICAL_THRESHOLD
-- only fires below 0.25, so this fills the gap.
-- ============================================================
function CropConsultant:hourlyEvaluate()
    if not self.isInitialized then return end
    -- Respect the alertsEnabled setting (nil = not yet set = default true)
    if self.alertsEnabled == false then return end
    if self.manager == nil or self.manager.soilSystem == nil then return end

    local env     = g_currentMission and g_currentMission.environment
    local hourKey = 0
    if env ~= nil then
        hourKey = (env.currentMonotonicDay or 0) * 24 + (env.currentHour or 0)
    end

    -- Use configured cooldown; fall back to class constant if not yet applied
    local cooldownHours = self.alertCooldown or CropConsultant.COOLDOWN_HOURS

    for fieldId, data in pairs(self.manager.soilSystem.fieldData) do
        -- Only alert for fields the local player owns
        if self:isOwnedByLocalPlayer(fieldId) then
            local moisture = data.moisture

            -- Only evaluate INFO range here (WARNING covered by band-crossing in onMoistureUpdated)
            if moisture >= CropConsultant.SEVERITY_WARNING_MAX
            and moisture <= CropConsultant.SEVERITY_INFO_MAX then
                -- Only alert if stress is actively accumulating (crop in critical window)
                local stress = 0
                if self.manager.stressModifier ~= nil then
                    stress = self.manager:getStress(fieldId)
                end

                if stress > 0.01 then
                    local cooldownKey = fieldId .. "_info"
                    local lastAlert   = self.alertCooldowns[cooldownKey] or -999
                    if (hourKey - lastAlert) >= cooldownHours then
                        self.alertCooldowns[cooldownKey] = hourKey
                        local cropName = self:getCropName(fieldId)
                        self:showAlert(fieldId, moisture, "INFO", cropName)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- EVENT HANDLER: CS_CRITICAL_THRESHOLD
-- Fires when moisture drops to or below 0.25.
-- ============================================================
function CropConsultant:onCriticalThreshold(data)
    if not self.isInitialized then return end
    if self.alertsEnabled == false then return end
    if data == nil or data.fieldId == nil then return end

    local fieldId = data.fieldId
    if not self:isOwnedByLocalPlayer(fieldId) then return end
    local env     = g_currentMission and g_currentMission.environment
    local hourKey = 0
    if env ~= nil then
        hourKey = (env.currentMonotonicDay or 0) * 24 + (env.currentHour or 0)
    end

    local cooldownHours = self.alertCooldown or CropConsultant.COOLDOWN_HOURS
    local cooldownKey = fieldId .. "_critical"
    local lastAlert   = self.alertCooldowns[cooldownKey] or -999
    if (hourKey - lastAlert) < cooldownHours then return end

    self.alertCooldowns[cooldownKey] = hourKey

    local moisture = data.moistureLevel or 0
    local cropName = self:getCropName(fieldId)
    self:showAlert(fieldId, moisture, "CRITICAL", cropName)
end

-- ============================================================
-- EVENT HANDLER: CS_MOISTURE_UPDATED
-- Watches for moisture entering the WARNING band from above.
-- ============================================================
function CropConsultant:onMoistureUpdated(data)
    if not self.isInitialized then return end
    if self.alertsEnabled == false then return end
    if data == nil then return end

    local fieldId  = data.fieldId
    if not self:isOwnedByLocalPlayer(fieldId) then return end
    local previous = data.previous or 1.0
    local current  = data.current  or 1.0

    -- Trigger when crossing INTO the warning band from healthy
    if previous >= CropConsultant.SEVERITY_WARNING_MAX
    and current  < CropConsultant.SEVERITY_WARNING_MAX
    and current  >= CropConsultant.SEVERITY_CRITICAL_MAX then
        local env     = g_currentMission and g_currentMission.environment
        local hourKey = 0
        if env ~= nil then
            hourKey = (env.currentMonotonicDay or 0) * 24 + (env.currentHour or 0)
        end

        local cooldownHours = self.alertCooldown or CropConsultant.COOLDOWN_HOURS
        local cooldownKey = fieldId .. "_warning"
        local lastAlert   = self.alertCooldowns[cooldownKey] or -999
        if (hourKey - lastAlert) < cooldownHours then return end
        self.alertCooldowns[cooldownKey] = hourKey

        local cropName = self:getCropName(fieldId)
        self:showAlert(fieldId, current, "WARNING", cropName)
    end
end

-- ============================================================
-- SHOW ALERT
-- Builds i18n message, shows blinking warning, optionally
-- forwards to NPCIntegration.
-- ============================================================
function CropConsultant:showAlert(fieldId, moisture, severity, cropName)
    if g_currentMission == nil then return end

    local msgKey   = "cs_alert_info"
    local duration = CropConsultant.DURATION_INFO

    if severity == "CRITICAL" then
        msgKey   = "cs_alert_critical"
        duration = CropConsultant.DURATION_CRITICAL
    elseif severity == "WARNING" then
        msgKey   = "cs_alert_warning"
        duration = CropConsultant.DURATION_WARNING
    end

    local template = (g_i18n ~= nil) and g_i18n:getText(msgKey) or msgKey
    local msg = string.format(template, fieldId, cropName or "?")

    g_currentMission:showBlinkingWarning(msg, duration)

    csLog(string.format("CropConsultant [%s] Field %d (%.0f%%): %s",
        severity, fieldId, moisture * 100, msg))

    -- CoursePlay context: if CP vehicles are on this stressed field, show a follow-up hint
    if self.manager ~= nil and self.manager.coursePlayIntegration ~= nil then
        local cpCtx = self.manager.coursePlayIntegration:getContextForField(fieldId)
        if cpCtx ~= nil then
            g_currentMission:showBlinkingWarning(cpCtx, 4000)
        end
    end

    -- AutoDrive context: for CRITICAL alerts, suggest setting up a water hauling route.
    -- Read through the manager facade (getCriticalAlertHint) rather than the subsystem.
    if severity == "CRITICAL" and self.manager ~= nil then
        local adHint = self.manager:getCriticalAlertHint()
        if adHint ~= nil then
            g_currentMission:showBlinkingWarning(adHint, 5000)
        end
    end

    -- Forward to NPC integration for dialog / favor generation
    if self.npcFavorMode
    and self.manager ~= nil
    and self.manager.npcIntegration ~= nil then
        self.manager.npcIntegration:sendConsultantAlert({
            fieldId  = fieldId,
            moisture = moisture,
            severity = severity,
            cropName = cropName,
        })
    end
end

-- ============================================================
-- HELPERS
-- ============================================================
-- Look up a field object by fieldId using the manager's pre-built map.
-- Falls back to a linear scan of getFields() if the map isn't ready yet
-- (e.g. called before lateInitialize completes on a slow-loading map).
--
-- WHY NOT getFieldByIndex(fieldId):
--   getFieldByIndex(n) returns fieldManager.fields[n] — the nth element
--   of the internal array. On any map where fields aren't in strict
--   fieldId order (custom maps, deleted fields, modded farmlands) it
--   silently returns the WRONG field. Confirmed on GDN forums + source.
function CropConsultant:getFieldObject(fieldId)
    -- Fast path: use the manager's cached map (O(1))
    if self.manager ~= nil and self.manager.fieldById ~= nil then
        local f = self.manager.fieldById[fieldId]
        if f ~= nil then return f end
    end

    -- Slow fallback: linear scan (map not built yet or field was added dynamically)
    if g_currentMission == nil or g_currentMission.fieldManager == nil then return nil end
    local ok, fields = pcall(function()
        return g_currentMission.fieldManager:getFields()
    end)
    if ok and fields ~= nil then
        for _, f in pairs(fields) do
            if f ~= nil and f.farmland ~= nil and f.farmland.id == fieldId then return f end
        end
    end
    return nil
end

-- Returns display name for the crop on a field, e.g. "Wheat", "Corn", "Fallow".
-- Uses FS25 getFieldState() API first (FS25-native), then legacy getFruitType()
-- as fallback for compatibility.
function CropConsultant:getCropName(fieldId)
    local field = self:getFieldObject(fieldId)
    if field == nil then return "?" end

    -- FS25 confirmed API: field.fieldState.fruitTypeIndex (no getter method exists)
    local fti = field.fieldState and field.fieldState.fruitTypeIndex
    if fti ~= nil and fti > 0 and g_fruitTypeManager ~= nil then
        local ft = g_fruitTypeManager:getFruitTypeByIndex(fti)
        if ft ~= nil and ft.name ~= nil then
            return self:formatCropName(ft.name)
        end
    end

    return "Fallow"
end

-- Format an internal fruit type name for display.
-- Capitalises first letter, lowercases rest; maps grass/weed/etc → "Fallow".
function CropConsultant:formatCropName(rawName)
    if rawName == nil then return "Fallow" end
    local name = rawName:lower()
    if name == "grass" or name == "drygrass" or name == "weed"
    or name == "stone" or name == "meadow" then
        return "Fallow"
    end
    return rawName:sub(1,1):upper() .. rawName:sub(2):lower()
end

-- ============================================================
-- CLEANUP
-- ============================================================
function CropConsultant:delete()
    if self.manager ~= nil and self.manager.eventBus ~= nil then
        self.manager.eventBus.unsubscribeAll(self)
    end
    self.alertCooldowns = {}
    self.isInitialized  = false
end

-- Set alerts enabled flag from settings
function CropConsultant:setAlertsEnabled(enabled)
    self.alertsEnabled = not not enabled
end

-- Set alert cooldown from settings
function CropConsultant:setAlertCooldown(hours)
    self.alertCooldown = math.max(4, math.min(24, hours or 12))
end