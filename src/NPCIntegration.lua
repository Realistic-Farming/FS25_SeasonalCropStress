-- ============================================================
-- NPCIntegration.lua
-- Phase 3 implementation.
--
-- Detects FS25_NPCFavor at runtime and registers "Alex Chen,
-- Agronomist" as an external NPC. When active, consultant alerts
-- are forwarded here to generate NPC dialog and favor quests.
--
-- IMPORTANT: All g_NPCSystem accesses go through getNPCSystem() (defined below).
-- NPCFavor exports g_NPCSystem via getfenv(0)["g_NPCSystem"] into the shared game
-- environment; plain `g_NPCSystem` only sees our mod's own env and is always nil.
-- If the API differs, integration fails SILENTLY — the standalone
-- consultant alerts in CropConsultant.lua continue to work.
--
-- NPCFavor exports the global g_NPCSystem via getfenv(0) in NPCFavor/main.lua.
--
-- LUADOC NOTE: The following NPCFavor API calls need verification
-- against FS25_NPCFavor source before shipping:
--   • g_NPCSystem:registerExternalNPC(config)
--   • g_NPCSystem:generateFavor(npcId, favorType, data)
--   • g_NPCSystem:getRelationshipLevel(npcId)
--   • g_NPCSystem:sendNPCDialog(npcId, text, duration)
-- ============================================================

-- Cross-mod accessor: NPCFavor writes npcSystem to mission.npcFavorSystem (Mission00.load hook).
-- g_currentMission is a true shared global visible to all mods.
-- getfenv(0) is per-mod scoped in FS25 and NOT shared between mods — do NOT use it here.
local function getNPCSystem()
    return g_currentMission and g_currentMission.npcFavorSystem
end

NPCIntegration = {}
NPCIntegration.__index = NPCIntegration

-- NPC configuration for Alex Chen
NPCIntegration.NPC_ID   = "cs_alex_chen"
NPCIntegration.NPC_NAME = "cs_consultant_name"  -- i18n key

-- Favor type identifiers (must match keys expected by NPCFavor)
NPCIntegration.FAVOR_SOIL_SAMPLE      = "SOIL_SAMPLE"
NPCIntegration.FAVOR_IRRIGATION_CHECK = "IRRIGATION_CHECK"
NPCIntegration.FAVOR_EMERGENCY_WATER  = "EMERGENCY_WATER"
NPCIntegration.FAVOR_SEASONAL_PLAN    = "SEASONAL_PLAN"

-- Relationship threshold required to unlock each favor type
-- LUADOC NOTE: verify NPCFavor's relationship scale (likely 0-100)
NPCIntegration.REL_THRESHOLD_BASIC    = 0    -- always available
NPCIntegration.REL_THRESHOLD_ADVANCED = 30   -- requires some relationship
NPCIntegration.REL_THRESHOLD_EXPERT   = 60   -- requires strong relationship

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
-- CONSTRUCTOR
-- ============================================================
function NPCIntegration.new(manager)
    local self = setmetatable({}, NPCIntegration)
    self.manager = manager

    self.npcFavorActive      = false   -- set by CropStressManager:detectOptionalMods()
    self.consultantNPCId     = nil     -- integer id of Alex Chen in npcSystem.activeNPCs
    self.isRegistered        = false   -- true once NPC is in NPCFavor's activeNPCs
    self.isInitialized       = false
    self.pendingRegistration = false   -- true while waiting for npcSystem.isInitialized

    -- Queue of alerts received before NPC is registered (replayed on registration)
    self.pendingAlerts   = {}

    -- Relationship value loaded from save — applied in registerConsultantNPC()
    -- after NPCFavor finishes init. Nil means no saved state.
    self.pendingSavedRelationship = nil

    return self
end

-- ============================================================
-- INITIALIZE
-- Called by CropStressManager:initialize().
-- NPCFavor's NPC system is async — it defers actual NPC creation until
-- isMissionStarted + terrain are ready (can be minutes after loadMission00Finished).
-- We set a pending flag here and poll in tryDeferredRegistration() each frame.
-- ============================================================
function NPCIntegration:initialize()
    if not self.npcFavorActive then
        self.isInitialized = true
        csLog("NPCIntegration: FS25_NPCFavor not detected — running without NPC integration")
        return
    end

    self.pendingRegistration = true
    self.isInitialized = true
    csLog("NPCIntegration: NPCFavor detected — will register Alex Chen once NPCFavor finishes init")
end

-- ============================================================
-- DEFERRED REGISTRATION POLL
-- Called every frame by CropStressManager:update().
-- Waits for npcSystem.isInitialized, then runs registerConsultantNPC once.
-- ============================================================
function NPCIntegration:tryDeferredRegistration()
    if not self.pendingRegistration then return end

    local npcSystem = getNPCSystem()
    if npcSystem == nil or not npcSystem.isInitialized then return end

    self.pendingRegistration = false
    self:registerConsultantNPC()
end

-- ============================================================
-- APPLY LOADED STATE
-- Called by SaveLoadHandler after reading cropStressData.xml.
-- Stores the saved relationship value for application once the NPC
-- is registered (NPCFavor's init may not have fired yet at load time).
-- ============================================================
function NPCIntegration:applyLoadedState(relationship)
    if type(relationship) == "number" and relationship > 0 then
        self.pendingSavedRelationship = relationship
        csLog(string.format("NPCIntegration: saved relationship loaded (%d) — will apply after NPC init", relationship))
    end
end

-- ============================================================
-- REGISTER CONSULTANT NPC
-- Uses NPCFavor's real API: createNPCAtLocation + initializeNPCData.
-- First checks if Alex Chen was already restored from a saved game.
-- ============================================================
function NPCIntegration:registerConsultantNPC()
    local npcSystem = getNPCSystem()
    if npcSystem == nil then
        csLog("NPCIntegration: npcSystem nil at registration — skipping")
        return
    end

    local consultantName = (g_i18n ~= nil) and g_i18n:getText(NPCIntegration.NPC_NAME) or "Alex Chen"

    -- Check if Alex Chen was already restored from a saved game
    for _, existing in ipairs(npcSystem.activeNPCs or {}) do
        if existing.name == consultantName then
            self.consultantNPCId = existing.id
            self.isRegistered    = true
            self:applySavedRelationship(existing)
            csLog(string.format("NPCIntegration: Alex Chen adopted from save (id=%s, relationship=%d)",
                tostring(existing.id), existing.relationship or 0))
            self:replayPendingAlerts()
            return
        end
    end

    -- Not in save — create fresh using the real NPCFavor spawn API
    if type(npcSystem.createNPCAtLocation) ~= "function" then
        csLog("NPCIntegration: createNPCAtLocation not found — NPCFavor version mismatch?")
        return
    end

    -- Spawn near player if position is known, else world origin
    local spawnPos = {x = 0, y = 0, z = 0}
    if npcSystem.playerPositionValid and npcSystem.playerPosition then
        spawnPos = {
            x = npcSystem.playerPosition.x + 15,
            y = npcSystem.playerPosition.y,
            z = npcSystem.playerPosition.z + 15,
        }
    end

    local ok, npc = pcall(function()
        return npcSystem:createNPCAtLocation(spawnPos)
    end)

    if not ok or npc == nil then
        csLog(string.format("NPCIntegration: createNPCAtLocation failed — %s", tostring(npc)))
        return
    end

    -- Override generated name/role for Alex Chen
    npc.name         = consultantName
    npc.role         = "agronomist"
    npc.relationship = 10  -- slight head start so player isn't cold

    local npcIndex = #npcSystem.activeNPCs + 1
    local ok2, err = pcall(function()
        npcSystem:initializeNPCData(npc, spawnPos, npcIndex)
        table.insert(npcSystem.activeNPCs, npc)
        npcSystem.npcCount = npcSystem.npcCount + 1
    end)

    if ok2 then
        self.consultantNPCId = npc.id
        self.isRegistered    = true
        self:applySavedRelationship(npc)
        csLog(string.format("NPCIntegration: Alex Chen created (id=%s, relationship=%d)",
            tostring(npc.id), npc.relationship or 0))
        self:replayPendingAlerts()
    else
        csLog(string.format("NPCIntegration: NPC insert failed — %s", tostring(err)))
    end
end

-- ============================================================
-- APPLY SAVED RELATIONSHIP
-- Takes the higher of the NPC's current relationship and our saved
-- value — handles both cases where NPCFavor did/didn't persist the NPC.
-- ============================================================
function NPCIntegration:applySavedRelationship(npc)
    if npc == nil then return end
    if self.pendingSavedRelationship == nil then return end
    npc.relationship = math.max(npc.relationship or 0, self.pendingSavedRelationship)
    self.pendingSavedRelationship = nil
end

-- ============================================================
-- REPLAY PENDING ALERTS
-- ============================================================
function NPCIntegration:replayPendingAlerts()
    for _, alertData in ipairs(self.pendingAlerts) do
        self:forwardAlertToNPC(alertData)
    end
    self.pendingAlerts = {}
end

-- ============================================================
-- SEND CONSULTANT ALERT
-- Called by CropConsultant:showAlert() when in NPCFavor mode.
-- Routes the alert to NPC dialog and generates a favor quest.
-- ============================================================
function NPCIntegration:sendConsultantAlert(data)
    if not self.isInitialized then return end
    if data == nil or data.fieldId == nil then return end

    if not self.isRegistered then
        -- Queue for replay once NPC is registered
        table.insert(self.pendingAlerts, data)
        return
    end

    self:forwardAlertToNPC(data)
end

function NPCIntegration:forwardAlertToNPC(data)
    local npcSystem = getNPCSystem()
    if npcSystem == nil then return end
    if not self.isRegistered or self.consultantNPCId == nil then return end

    local severity = data.severity or "WARNING"
    local msgKey   = "cs_alert_warning"
    if severity == "CRITICAL" then msgKey = "cs_alert_critical"
    elseif severity == "INFO"  then msgKey = "cs_alert_info" end

    local template   = (g_i18n ~= nil) and g_i18n:getText(msgKey) or msgKey
    local dialogText = string.format(template, data.fieldId, data.cropName or "?")

    -- NPCFavor's confirmed notification API: showNotification(title, message)
    if type(npcSystem.showNotification) == "function" then
        local consultantName = (g_i18n ~= nil) and g_i18n:getText(NPCIntegration.NPC_NAME) or "Alex Chen"
        pcall(function()
            npcSystem:showNotification(consultantName, dialogText)
        end)
    end

    -- Log favor hint — NPCFavor's favor system is player-initiated; no push API exists.
    if severity == "CRITICAL" or severity == "WARNING" then
        self:generateFavor(NPCIntegration.FAVOR_EMERGENCY_WATER, {
            fieldId = data.fieldId,
            urgency = severity == "CRITICAL" and "high" or "normal",
        })
    end
end

-- ============================================================
-- GENERATE FAVOR
-- NPCFavor's favor system is entirely player-initiated (player walks up
-- to an NPC and interacts). There is no API to push a favor from outside.
-- This logs a hint for Phase 4 when NPCFavor adds an external favor API.
-- ============================================================
function NPCIntegration:generateFavor(favorType, favorData)
    if not self.isRegistered then return end
    csLog(string.format("NPCIntegration: favor hint [%s] field=%s — player must interact with Alex Chen",
        favorType, tostring(favorData and favorData.fieldId or "?")))
end

-- ============================================================
-- GET RELATIONSHIP LEVEL
-- Returns 0-100 relationship with Alex Chen.
-- Reads npc.relationship directly — confirmed field on NPCFavor NPC objects.
-- ============================================================
function NPCIntegration:getRelationshipLevel()
    local npcSystem = getNPCSystem()
    if npcSystem == nil then return 0 end
    if not self.isRegistered or self.consultantNPCId == nil then return 0 end
    if type(npcSystem.getNPCById) ~= "function" then return 0 end

    local ok, npc = pcall(function()
        return npcSystem:getNPCById(self.consultantNPCId)
    end)
    if ok and npc ~= nil then return npc.relationship or 0 end
    return 0
end

-- ============================================================
-- FAVOR CALLBACK GLOBALS
-- NPCFavor may invoke these by name (via _G[onAccept](data)) when the
-- player accepts or completes a favor quest. These stubs are minimal
-- no-ops that prevent a nil-call crash. Full implementation is Phase 4
-- (requires verified NPCFavor callback API + field-level task tracking).
--
-- If NPCFavor does not call globals by string name (unverified — see
-- LUADOC NOTEs above), these stubs are harmless dead code.
-- ============================================================
cs_favor_onSoilSample = function(data)
    csLog(string.format("cs_favor_onSoilSample called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onSoilSampleDone = function(data)
    csLog(string.format("cs_favor_onSoilSampleDone called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onIrrigationCheck = function(data)
    csLog(string.format("cs_favor_onIrrigationCheck called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onIrrigationCheckDone = function(data)
    csLog(string.format("cs_favor_onIrrigationCheckDone called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onEmergencyWater = function(data)
    csLog(string.format("cs_favor_onEmergencyWater called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onEmergencyWaterDone = function(data)
    csLog(string.format("cs_favor_onEmergencyWaterDone called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onSeasonalPlan = function(data)
    csLog(string.format("cs_favor_onSeasonalPlan called (field=%s)", tostring(data and data.fieldId)))
end
cs_favor_onSeasonalPlanDone = function(data)
    csLog(string.format("cs_favor_onSeasonalPlanDone called (field=%s)", tostring(data and data.fieldId)))
end

-- ============================================================
-- CLEANUP
-- Alex Chen lives in NPCFavor's activeNPCs and is saved/restored by
-- NPCFavor's own persistence. Don't remove him — just clear our refs.
-- ============================================================
function NPCIntegration:delete()
    self.pendingAlerts       = {}
    self.pendingRegistration = false
    self.isRegistered        = false
    self.consultantNPCId     = nil
    self.isInitialized       = false
end