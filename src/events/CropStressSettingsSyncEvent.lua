-- ============================================================
-- CropStressSettingsSyncEvent.lua
-- Network event for settings synchronization in multiplayer.
-- Two types: SINGLE (one key/value change) and BULK (all settings on join).
-- Server-authoritative, master-only changes.
-- ============================================================

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
-- EVENT CLASS DEFINITION
-- ============================================================
CropStressSettingsSyncEvent = {}
CropStressSettingsSyncEvent_mt = Class(CropStressSettingsSyncEvent, Event)

InitEventClass(CropStressSettingsSyncEvent, "CropStressSettingsSyncEvent")

--- BUILD 18:55: the engine's EVENT path calls emptyNew() and then readStream on
--- what it returns, so an event class without one is a nil call the moment its
--- packet arrives on a joining client. Vanilla shape, matching
--- CropStressPivotRemoteEvent: construct and return, nothing else.
--- No field defaults on purpose. readStream fills the instance, and pre-seeding
--- here would quietly paper over a short or mismatched read instead of failing.
function CropStressSettingsSyncEvent.emptyNew()
    local self = Event.new(CropStressSettingsSyncEvent_mt)
    return self
end

-- Event type constants
CropStressSettingsSyncEvent.TYPE_SINGLE = 1
CropStressSettingsSyncEvent.TYPE_BULK = 2

-- Number of settings written/read in a bulk event.
-- MUST match the number of writeSetting() calls in writeStream().
-- Intentionally 11 (not 12) — hudPanelX and hudPanelY are client-local
-- display preferences and must NOT be overwritten by a server-pushed sync.
-- If you add or remove a synced setting, update this constant and the
-- writeSetting() calls in writeStream() together.
CropStressSettingsSyncEvent.BULK_COUNT = 11

-- Value type constants for serialization
CropStressSettingsSyncEvent.VALUE_TYPE_BOOL = 1
CropStressSettingsSyncEvent.VALUE_TYPE_INT = 2
CropStressSettingsSyncEvent.VALUE_TYPE_FLOAT = 3
CropStressSettingsSyncEvent.VALUE_TYPE_STRING = 4

function CropStressSettingsSyncEvent.newSingle(key, value)
    local self = Event.new(CropStressSettingsSyncEvent_mt)
    self.eventType = CropStressSettingsSyncEvent.TYPE_SINGLE
    self.key = key
    self.value = value
    return self
end

function CropStressSettingsSyncEvent.newBulk(settingsTable)
    local self = Event.new(CropStressSettingsSyncEvent_mt)
    self.eventType = CropStressSettingsSyncEvent.TYPE_BULK
    self.settings = settingsTable
    return self
end

-- ============================================================
-- NETWORK SERIALIZATION
-- ============================================================
function CropStressSettingsSyncEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.eventType)
    
    if self.eventType == CropStressSettingsSyncEvent.TYPE_SINGLE then
        -- Write single key-value pair
        streamWriteString(streamId, self.key)
        self:writeValue(streamId, self.value)
        
    elseif self.eventType == CropStressSettingsSyncEvent.TYPE_BULK then
        -- Write all settings
        local settings = self.settings
        streamWriteUInt8(streamId, CropStressSettingsSyncEvent.BULK_COUNT)
        
        -- Write each setting with type tagging
        self:writeSetting(streamId, "enabled",            settings.enabled)
        self:writeSetting(streamId, "difficulty",         settings.difficulty)
        self:writeSetting(streamId, "hudVisible",         settings.hudVisible)
        self:writeSetting(streamId, "evapotranspiration", settings.evapotranspiration)
        self:writeSetting(streamId, "maxYieldLoss",       settings.maxYieldLoss)
        self:writeSetting(streamId, "criticalThreshold",  settings.criticalThreshold)
        self:writeSetting(streamId, "irrigationCosts",    settings.irrigationCosts)
        self:writeSetting(streamId, "alertsEnabled",      settings.alertsEnabled)
        self:writeSetting(streamId, "alertCooldown",      settings.alertCooldown)
        self:writeSetting(streamId, "debugMode",          settings.debugMode)
        self:writeSetting(streamId, "experimentalSystems", settings.experimentalSystems)
    end
end

function CropStressSettingsSyncEvent:readStream(streamId, connection)
    self.eventType = streamReadUInt8(streamId)
    
    if self.eventType == CropStressSettingsSyncEvent.TYPE_SINGLE then
        -- Read single key-value pair
        self.key = streamReadString(streamId)
        self.value = self:readValue(streamId)
        
    elseif self.eventType == CropStressSettingsSyncEvent.TYPE_BULK then
        -- Read all settings
        local count = streamReadUInt8(streamId)
        self.settings = {}
        
        for i = 1, count do
            local key, value = self:readSetting(streamId)
            if key then
                self.settings[key] = value
            end
        end
    end
    
    self:run(connection)
end

-- ============================================================
-- VALUE SERIALIZATION HELPERS
-- ============================================================
function CropStressSettingsSyncEvent:writeValue(streamId, value)
    if type(value) == "boolean" then
        streamWriteUInt8(streamId, CropStressSettingsSyncEvent.VALUE_TYPE_BOOL)
        streamWriteBool(streamId, value)
    elseif type(value) == "number" then
        if value == math.floor(value) then
            streamWriteUInt8(streamId, CropStressSettingsSyncEvent.VALUE_TYPE_INT)
            streamWriteInt32(streamId, value)
        else
            streamWriteUInt8(streamId, CropStressSettingsSyncEvent.VALUE_TYPE_FLOAT)
            streamWriteFloat32(streamId, value)
        end
    elseif type(value) == "string" then
        streamWriteUInt8(streamId, CropStressSettingsSyncEvent.VALUE_TYPE_STRING)
        streamWriteString(streamId, value)
    else
        -- Fallback to string
        streamWriteUInt8(streamId, CropStressSettingsSyncEvent.VALUE_TYPE_STRING)
        streamWriteString(streamId, tostring(value))
    end
end

function CropStressSettingsSyncEvent:readValue(streamId)
    local valueType = streamReadUInt8(streamId)
    
    if valueType == CropStressSettingsSyncEvent.VALUE_TYPE_BOOL then
        return streamReadBool(streamId)
    elseif valueType == CropStressSettingsSyncEvent.VALUE_TYPE_INT then
        return streamReadInt32(streamId)
    elseif valueType == CropStressSettingsSyncEvent.VALUE_TYPE_FLOAT then
        return streamReadFloat32(streamId)
    elseif valueType == CropStressSettingsSyncEvent.VALUE_TYPE_STRING then
        return streamReadString(streamId)
    end
    
    return nil
end

-- writeSetting: write a key + auto-typed value to the stream.
-- (expectedType was removed — writeValue() infers the type at runtime.)
function CropStressSettingsSyncEvent:writeSetting(streamId, key, value)
    streamWriteString(streamId, key)
    self:writeValue(streamId, value)
end

function CropStressSettingsSyncEvent:readSetting(streamId)
    local key = streamReadString(streamId)
    local value = self:readValue(streamId)
    return key, value
end

-- ============================================================
-- EVENT EXECUTION
-- ============================================================
function CropStressSettingsSyncEvent:run(connection)
    if g_cropStressManager == nil or g_cropStressManager.settings == nil then
        csLog("WARNING: CropStressManager or settings not available, ignoring settings sync event")
        return
    end
    
    if self.eventType == CropStressSettingsSyncEvent.TYPE_SINGLE then
        self:applySingleSetting(self.key, self.value, connection)
        
    elseif self.eventType == CropStressSettingsSyncEvent.TYPE_BULK then
        self:applyBulkSettings(self.settings, connection)
    end
end

-- ============================================================
-- SETTING APPLICATION
-- ============================================================
function CropStressSettingsSyncEvent:applySingleSetting(key, value, connection)
    if g_server ~= nil then
        -- Server: verify master rights before applying
        if not self:senderHasMasterRights(connection) then
            csLog("WARNING: Non-master player attempted to change settings, ignoring")
            -- Send current server settings back so the client's UI reverts to actual state
            if connection ~= nil then
                CropStressSettingsSyncEvent.sendAllToConnection(connection)
            end
            return
        end

        -- Apply setting and validate
        g_cropStressManager.settings[key] = value
        g_cropStressManager.settings:validateSettings()
        g_cropStressManager:applySettings()

        csLog("Setting applied: " .. key .. " = " .. tostring(value))

        -- Broadcast to all clients (including the sender) so everyone stays in sync
        g_server:broadcastEvent(CropStressSettingsSyncEvent.newSingle(key, value), false)

    else
        -- Client: apply setting directly (already validated by server)
        g_cropStressManager.settings[key] = value
        g_cropStressManager.settings:validateSettings()
        g_cropStressManager:applySettings()
        
        csLog("Setting received from server: " .. key .. " = " .. tostring(value))
    end
end

function CropStressSettingsSyncEvent:applyBulkSettings(settingsTable, connection)
    if g_server ~= nil then
        -- Server: verify master rights before applying
        if not self:senderHasMasterRights(connection) then
            csLog("WARNING: Non-master player attempted to send bulk settings, ignoring")
            return
        end
    end
    
    -- Apply all settings
    for key, value in pairs(settingsTable) do
        g_cropStressManager.settings[key] = value
    end
    
    g_cropStressManager.settings:validateSettings()
    g_cropStressManager:applySettings()
    
    csLog("Bulk settings applied from " .. (g_server and "server" or "client"))
end

-- ============================================================
-- MASTER RIGHTS VERIFICATION
-- ============================================================
function CropStressSettingsSyncEvent:senderHasMasterRights(connection)
    if g_userManager == nil or connection == nil then
        return false
    end

    -- Check if the connection belongs to a master user.
    -- Permission.MASTER_USER is guarded: it may be nil on console builds or older versions.
    if Permission == nil or Permission.MASTER_USER == nil then
        csLog("WARNING: Permission.MASTER_USER not available — defaulting to deny")
        return false
    end

    local user = g_userManager:getUserByConnection(connection)
    if user == nil then
        return false
    end

    return user:hasPermission(Permission.MASTER_USER)
end

-- ============================================================
-- STATIC HELPERS
-- ============================================================
function CropStressSettingsSyncEvent.sendSingleToServer(key, value)
    if g_client == nil then
        csLog("WARNING: Attempted to send settings to server but not in client mode")
        return
    end
    
    local event = CropStressSettingsSyncEvent.newSingle(key, value)
    g_client:getServerConnection():sendEvent(event)
end

function CropStressSettingsSyncEvent.sendAllToConnection(connection)
    if g_cropStressManager == nil or g_cropStressManager.settings == nil then
        csLog("WARNING: Cannot send settings to connection - manager or settings not available")
        return
    end
    
    local event = CropStressSettingsSyncEvent.newBulk(g_cropStressManager.settings)
    connection:sendEvent(event)
end