-- ============================================================
-- CropStressScheduleSyncEvent.lua
-- [BUILD 00:33] Server-authoritative pivot schedule plus Auto/Manual sync.
-- Client -> server: the Schedule dialog's Save (and only Save; the plus / minus /
-- day buttons keep mutating the local row for responsiveness) sends the whole
-- row: systemId, manualMode, startHour, endHour, activeDays[1..7].
-- Server: ownership check, clamp, write the authoritative system row, then
-- IrrigationManager:applyScheduleNow() so the pivot lands where the new window
-- says without waiting for the hour edge, then broadcast the accepted row.
-- Server -> client: write the local row so cards and dialogs agree.
-- Shape: CropStressPivotRemoteEvent (dot new, Event.new(mt), server-gated run).
-- ============================================================

CropStressScheduleSyncEvent = CropStressScheduleSyncEvent or {}
CropStressScheduleSyncEvent_mt = Class(CropStressScheduleSyncEvent, Event)

InitEventClass(CropStressScheduleSyncEvent, "CropStressScheduleSyncEvent")

local function clampHour(h)
    h = tonumber(h) or 0
    h = math.floor(h)
    if h < 0 then h = 0 end
    if h > 23 then h = 23 end
    return h
end

local function copyDays(days)
    local out = {}
    for i = 1, 7 do
        out[i] = type(days) == "table" and days[i] == true
    end
    return out
end

--- Same resolution as CropStressPivotRemoteEvent (BUILD 16:44): getPlayerByConnection
--- then the player's farm; the user manager as a second chance; the local farm for a
--- listen-server host (whose own sends arrive on the server connection).
local function farmIdFromConnection(connection)
    if connection ~= nil and type(connection.getIsServer) == "function" and not connection:getIsServer() then
        if g_currentMission ~= nil and type(g_currentMission.getPlayerByConnection) == "function" then
            local player = g_currentMission:getPlayerByConnection(connection)
            if player ~= nil then
                if type(player.getFarmId) == "function" then
                    local id = player:getFarmId()
                    if type(id) == "number" and id > 0 then
                        return id
                    end
                end
                if type(player.farmId) == "number" and player.farmId > 0 then
                    return player.farmId
                end
            end
        end
        if g_currentMission ~= nil and g_currentMission.userManager ~= nil
            and type(g_currentMission.userManager.getUserByConnection) == "function" then
            local user = g_currentMission.userManager:getUserByConnection(connection)
            if user ~= nil and type(user.farmId) == "number" and user.farmId > 0 then
                return user.farmId
            end
        end
    end
    local mgr = g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
    if mgr ~= nil and type(mgr.getLocalFarmId) == "function" then
        local id = mgr.getLocalFarmId()
        if type(id) == "number" and id > 0 then
            return id
        end
    end
    if g_currentMission ~= nil and g_currentMission.player ~= nil then
        local id = g_currentMission.player.farmId
        if type(id) == "number" and id > 0 then
            return id
        end
    end
    return nil
end

local function getIrrigationManager()
    local mgr = g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
    if mgr == nil then
        return nil
    end
    return mgr.irrigationManager
end

function CropStressScheduleSyncEvent.emptyNew()
    return Event.new(CropStressScheduleSyncEvent_mt)
end

--- Dot constructor (vanilla Event shape; see the colon-new trap noted in
--- CropStressPivotRemoteEvent).
function CropStressScheduleSyncEvent.new(systemId, manualMode, startHour, endHour, activeDays)
    local self = CropStressScheduleSyncEvent.emptyNew()
    self.systemId   = systemId or 0
    self.manualMode = manualMode == true
    self.startHour  = clampHour(startHour)
    self.endHour    = clampHour(endHour)
    self.activeDays = copyDays(activeDays)
    return self
end

--- Build the event from a live system row (server broadcast after an accepted
--- change, AUTO_MANUAL_TOGGLE). nil when there is no row.
function CropStressScheduleSyncEvent.fromSystem(system)
    if system == nil then
        return nil
    end
    local sched = system.schedule or {}
    return CropStressScheduleSyncEvent.new(system.id, system.manualMode == true,
        sched.startHour or 6, sched.endHour or 10, sched.activeDays)
end

function CropStressScheduleSyncEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.systemId or 0)
    streamWriteBool(streamId, self.manualMode == true)
    streamWriteUInt8(streamId, clampHour(self.startHour))
    streamWriteUInt8(streamId, clampHour(self.endHour))
    for i = 1, 7 do
        streamWriteBool(streamId, self.activeDays ~= nil and self.activeDays[i] == true)
    end
end

function CropStressScheduleSyncEvent:readStream(streamId, connection)
    self.systemId   = streamReadInt32(streamId)
    self.manualMode = streamReadBool(streamId)
    self.startHour  = clampHour(streamReadUInt8(streamId))
    self.endHour    = clampHour(streamReadUInt8(streamId))
    self.activeDays = {}
    for i = 1, 7 do
        self.activeDays[i] = streamReadBool(streamId) == true
    end
end

--- Write this event's row onto a system table. Shared by the server (after the
--- ownership check) and the client (the server copy is the truth).
function CropStressScheduleSyncEvent:applyToSystem(system)
    if system == nil then
        return false
    end
    if system.schedule == nil then
        system.schedule = { startHour = 6, endHour = 10, activeDays = {} }
    end
    system.schedule.startHour  = clampHour(self.startHour)
    system.schedule.endHour    = clampHour(self.endHour)
    system.schedule.activeDays = copyDays(self.activeDays)
    system.manualMode = self.manualMode == true
    return true
end

function CropStressScheduleSyncEvent:run(connection)
    local irr = getIrrigationManager()
    if irr == nil or irr.systems == nil then
        return
    end
    local system = irr.systems[self.systemId]
    if system == nil then
        return
    end

    if g_server ~= nil then
        local farmId = farmIdFromConnection(connection)
        local ownerId = system.ownerFarmId
        if (type(ownerId) ~= "number" or ownerId <= 0) and system.placeable ~= nil
            and type(system.placeable.getOwnerFarmId) == "function" then
            ownerId = system.placeable:getOwnerFarmId()
        end
        if farmId == nil or farmId == 0 or type(ownerId) ~= "number" or ownerId ~= farmId then
            print(string.format("[CropStress] schedule sync DENIED (ownership): owner=%s farmId=%s systemId=%s",
                tostring(ownerId), tostring(farmId), tostring(self.systemId)))
            return
        end
        self:applyToSystem(system)
        if type(irr.applyScheduleNow) == "function" then
            irr:applyScheduleNow()
        end
        local evt = CropStressScheduleSyncEvent.fromSystem(system)
        if evt ~= nil then
            g_server:broadcastEvent(evt, false)
        end
    else
        self:applyToSystem(system)
    end
end

--- Client helper (also the listen-server host): send the row to the server.
function CropStressScheduleSyncEvent.sendToServer(systemId, manualMode, startHour, endHour, activeDays)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    if systemId == nil or systemId == 0 then
        return false
    end
    g_client:getServerConnection():sendEvent(
        CropStressScheduleSyncEvent.new(systemId, manualMode, startHour, endHour, activeDays))
    return true
end
