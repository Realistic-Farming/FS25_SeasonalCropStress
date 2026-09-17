-- ============================================================
-- CropStressHeatRequestEvent.lua
-- SCS #191 follow-up (Design d3c0626): a client admin's Simulate Heat Wave.
-- Client -> server. Stream: UInt8 days.
-- The server trusts nothing from the stream: it re-checks master-user rights for
-- the sending connection itself (the engine's test for server actions,
-- UserManager:getIsConnectionMasterUser, as SaveEvent and CheatMoneyEvent use),
-- validates days (1-30), runs the host simulation and replies to that connection
-- only with CropStressHeatResultEvent. The engine calls readStream, never run, for
-- an incoming event (Server.lua:435-437), so readStream ends by calling run.
-- ============================================================

CropStressHeatRequestEvent = CropStressHeatRequestEvent or {}
CropStressHeatRequestEvent_mt = Class(CropStressHeatRequestEvent, Event)

InitEventClass(CropStressHeatRequestEvent, "CropStressHeatRequestEvent")

function CropStressHeatRequestEvent.emptyNew()
    return Event.new(CropStressHeatRequestEvent_mt)
end

function CropStressHeatRequestEvent.new(days)
    local self = CropStressHeatRequestEvent.emptyNew()
    self.days = days or 0
    return self
end

function CropStressHeatRequestEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, math.max(0, math.min(255, math.floor(tonumber(self.days) or 0))))
end

function CropStressHeatRequestEvent:readStream(streamId, connection)
    self.days = streamReadUInt8(streamId)
    self:run(connection)
end

--- True when the sending connection may run a server admin action.
function CropStressHeatRequestEvent.isAdminConnection(connection)
    if connection == nil or connection:getIsServer() then
        return false
    end
    if connection:getIsLocal() then
        return true
    end
    local userManager = g_currentMission ~= nil and g_currentMission.userManager or nil
    return userManager ~= nil and userManager:getIsConnectionMasterUser(connection) == true
end

function CropStressHeatRequestEvent:run(connection)
    if g_server == nil or g_cropStressManager == nil then
        return
    end
    local accepted, code = false, "NOT_ADMIN"
    local days = CropStressManager.validHeatDays(self.days)
    if CropStressHeatRequestEvent.isAdminConnection(connection) then
        if days == nil then
            code = "BAD_DAYS"
        else
            g_cropStressManager:runHeatSimulation(days)
            accepted, code = true, "OK"
        end
    end
    if connection ~= nil then
        connection:sendEvent(CropStressHeatResultEvent.new(accepted, code, days or 0))
    end
end

--- Client helper: send the request to the server. Returns true when it was sent.
function CropStressHeatRequestEvent.sendToServer(days)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    g_client:getServerConnection():sendEvent(CropStressHeatRequestEvent.new(days))
    return true
end
