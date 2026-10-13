-- ============================================================
-- NPCIntegration.lua
-- Phase 3 implementation, repaired under RSF-F357 section 7.
--
-- Detects FS25_NPCFavor at runtime and pairs "Alex Chen, Agronomist"
-- with the host's fixed-token consultant person. When active, consultant
-- alerts are forwarded here to generate NPC dialog and favor hints.
--
-- RSF-F357: the host owns the consultant's identity. On a server this
-- caller CLAIMS her through the host's narrow door
-- (claimCropStressConsultant, the fixed token cs_alex_chen, a bounded
-- display name and a finite position) once, and keeps the durable number
-- the host returned. A pure client only READS the host's getter
-- (getCropStressConsultantId) after the host's roster is complete, about
-- once a second until found. Both clear a stale registration when the host
-- goes away, reads too old, or the consultant is absent, changed or in
-- conflict, and retry. No name adoption, no direct insert into the host's
-- tables, no trust floor: the legacy npcRelationship scalar this mod saved
-- is retained as unproven old evidence and never applied to the person.
--
-- IMPORTANT: All host accesses go through getNPCSystem() (defined below).
-- NPCFavor bridges its system via mission.npcFavorSystem (Mission00.load hook);
-- getfenv(0) is per-mod scoped in FS25 and NOT shared between mods.
-- If the host is absent or too old, integration stands aside SILENTLY and
-- the standalone consultant alerts in CropConsultant.lua continue.
-- ============================================================

-- Cross-mod accessor: NPCFavor writes npcSystem to mission.npcFavorSystem (Mission00.load hook).
-- g_currentMission is a true shared global visible to all mods.
local function getNPCSystem()
    return g_currentMission and g_currentMission.npcFavorSystem
end

NPCIntegration = NPCIntegration or {}
NPCIntegration.__index = NPCIntegration

-- NPC configuration for Alex Chen
NPCIntegration.NPC_ID   = "cs_alex_chen"       -- the host's fixed provider token (NPCPersonRoster.CONSULTANT_TOKEN)
NPCIntegration.NPC_NAME = "cs_consultant_name"  -- i18n key of the display name
NPCIntegration.NPC_NAME_FALLBACK = "Alex Chen, Agronomist"

-- The host capability this caller pairs with (NPCSystem.savedNeighbourIdentityVersion).
NPCIntegration.HOST_IDENTITY_VERSION = 1
-- A claim or a read is retried about once a second until the consultant is found.
NPCIntegration.RETRY_INTERVAL_MS = 1000
-- Alerts received before the consultant is proved are a presentation queue,
-- bounded to the latest 8; the oldest are dropped.
NPCIntegration.MAX_PENDING_ALERTS = 8

-- Identity availability (getConsultantIdentityView, brief section 9a)
NPCIntegration.AVAIL_READY    = "READY"      -- the unique live consultant on a complete authoritative roster
NPCIntegration.AVAIL_WAITING  = "WAITING"    -- host present and paired, consultant not proved yet (loading, waiting, absent on a client)
NPCIntegration.AVAIL_ABSENT   = "ABSENT"     -- no NPCFavor host
NPCIntegration.AVAIL_OLD_HOST = "OLD_HOST"   -- a host without the identity capability (no claim, no getter, another version)
NPCIntegration.AVAIL_CONFLICT = "CONFLICT"   -- more than one saved consultant record; nothing is linked

-- Favor type identifiers (must match keys expected by NPCFavor)
NPCIntegration.FAVOR_SOIL_SAMPLE      = "SOIL_SAMPLE"
NPCIntegration.FAVOR_IRRIGATION_CHECK = "IRRIGATION_CHECK"
NPCIntegration.FAVOR_EMERGENCY_WATER  = "EMERGENCY_WATER"
NPCIntegration.FAVOR_SEASONAL_PLAN    = "SEASONAL_PLAN"

-- Relationship threshold required to unlock each favor type
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

local function nowMs()
    return (g_currentMission ~= nil and g_currentMission.time) or 0
end

--- A localized text through the engine's own presence test first (the gate shape
--- since SoilFertilizer #973): hasText, then getText, then a type and empty check.
--- A key the engine does not have never becomes a name or a notice.
local function localizedText(key, fallback)
    if g_i18n ~= nil and type(g_i18n.hasText) == "function" then
        local okHas, has = pcall(g_i18n.hasText, g_i18n, key)
        if okHas and has == true then
            local ok, text = pcall(g_i18n.getText, g_i18n, key)
            if ok and type(text) == "string" and text ~= "" then
                return text
            end
        end
    end
    return fallback
end

--- The bounded display name the claim carries: the localized text when the
--- engine has it, else the English.
local function consultantDisplayName()
    return localizedText(NPCIntegration.NPC_NAME, NPCIntegration.NPC_NAME_FALLBACK)
end

-- ============================================================
-- CONSTRUCTOR
-- ============================================================
function NPCIntegration.new(manager)
    local self = setmetatable({}, NPCIntegration)
    self.manager = manager

    self.npcFavorActive      = false   -- set by CropStressManager:detectOptionalMods()
    self.consultantNPCId     = nil     -- the host's durable number for Alex Chen, held only while READY
    self.isRegistered        = false   -- true only while the host proves the unique live consultant
    self.isInitialized       = false
    self.pendingRegistration = false   -- true while the host has not proved her yet (polled each frame)

    -- The current identity availability and its reason key (see AVAIL_*).
    self.availability = NPCIntegration.AVAIL_ABSENT
    self.reasonKey    = "cs_consultant_host_absent"
    self.lastAttemptMs = nil

    -- Queue of alerts received before the consultant is proved (bounded, replayed on registration)
    self.pendingAlerts   = {}

    -- RSF-F357: the legacy npcRelationship scalar loaded from this mod's own save.
    -- Retained as unproven old evidence (it may have been saved from a namesake),
    -- re-emitted on save, never applied to the host's person. Nil when none.
    self.legacyTrust       = nil
    self.legacyTrustNoticed = false

    return self
end

-- ============================================================
-- INITIALIZE
-- Called by CropStressManager:initialize().
-- NPCFavor's roster is async: the host selects and installs its saved people
-- after the mission starts. This caller polls tryDeferredRegistration each
-- frame (CropStressManager:update) and claims or reads once the host is ready.
-- ============================================================
function NPCIntegration:initialize()
    if not self.npcFavorActive then
        self.isInitialized = true
        self.availability = NPCIntegration.AVAIL_ABSENT
        self.reasonKey = "cs_consultant_host_absent"
        csLog("NPCIntegration: FS25_NPCFavor not detected, running without NPC integration")
        return
    end

    self.pendingRegistration = true
    self.isInitialized = true
    self.availability = NPCIntegration.AVAIL_WAITING
    self.reasonKey = "cs_consultant_waiting"
    csLog("NPCIntegration: NPCFavor detected, Alex Chen will be claimed once the host's neighbours are ready")
end

-- ============================================================
-- HOST CAPABILITY
-- The host this caller pairs with publishes savedNeighbourIdentityVersion 1,
-- the server-only claim and the read-only getter. Anything else is an old host:
-- no name adoption, no direct model write, the standalone alerts continue.
-- ============================================================
function NPCIntegration:hostCapability()
    local sys = getNPCSystem()
    if sys == nil then
        return nil, NPCIntegration.AVAIL_ABSENT, "cs_consultant_host_absent"
    end
    if sys.savedNeighbourIdentityVersion ~= NPCIntegration.HOST_IDENTITY_VERSION
        or type(sys.claimCropStressConsultant) ~= "function"
        or type(sys.getCropStressConsultantId) ~= "function" then
        return sys, NPCIntegration.AVAIL_OLD_HOST, "cs_consultant_host_old"
    end
    return sys, nil, nil
end

--- The side this process is: the host's own flag when it has one, else the engine's.
function NPCIntegration:isServerSide(sys)
    if sys ~= nil and sys.isServer ~= nil then return sys.isServer == true end
    return g_server ~= nil
end

--- Clear a registration that no longer holds; the next attempt retries.
function NPCIntegration:clearRegistration(availability, reasonKey)
    if self.isRegistered then
        csLog(string.format("NPCIntegration: consultant registration cleared (%s), retrying", tostring(reasonKey)))
    end
    self.isRegistered    = false
    self.consultantNPCId = nil
    self.pendingRegistration = self.npcFavorActive
    self.availability = availability
    self.reasonKey    = reasonKey or ""
end

-- ============================================================
-- DEFERRED REGISTRATION POLL
-- Called every frame by CropStressManager:update(). The host's presence and
-- capability are checked every frame (cheap); a claim, a read or a re-check
-- of an existing registration runs about once a second.
-- ============================================================
function NPCIntegration:tryDeferredRegistration()
    if not self.isInitialized or not self.npcFavorActive then return end

    local sys, bad, badKey = self:hostCapability()
    if bad ~= nil then
        self:clearRegistration(bad, badKey)
        return
    end

    local now = nowMs()
    if self.lastAttemptMs ~= nil and now >= self.lastAttemptMs
        and now - self.lastAttemptMs < NPCIntegration.RETRY_INTERVAL_MS then
        return
    end
    self.lastAttemptMs = now

    if self.isRegistered then
        -- The host still proves the same person, or the registration is stale.
        local id = sys:getCropStressConsultantId()
        if id == self.consultantNPCId then return end
        self:clearRegistration(NPCIntegration.AVAIL_WAITING, "cs_consultant_waiting")
    end

    self:attemptRegistration(sys)
end

--- One claim (server) or one read (client) against the host.
---@return boolean registered
function NPCIntegration:attemptRegistration(sys)
    local id, why
    if self:isServerSide(sys) then
        -- A conflict (two saved consultant rows) cannot be resolved by claiming
        -- again: the host refuses and logs every time. While the last answer was
        -- CONFLICT, poll the silent getter and claim only once it stops saying so.
        if self.availability == NPCIntegration.AVAIL_CONFLICT then
            local _, stillWhy = sys:getCropStressConsultantId()
            if stillWhy == "npc_person_identity_conflict" then return false end
        end
        id, why = sys:claimCropStressConsultant(consultantDisplayName(), self:claimPosition(sys))
    else
        id, why = sys:getCropStressConsultantId()
    end

    if id ~= nil then
        self.consultantNPCId     = id
        self.isRegistered        = true
        self.pendingRegistration = false
        self.availability        = NPCIntegration.AVAIL_READY
        self.reasonKey           = ""
        csLog(string.format("NPCIntegration: Alex Chen linked to the host's person #%s", tostring(id)))
        self:noticeLegacyTrust()
        self:replayPendingAlerts()
        return true
    end

    self.consultantNPCId = nil
    self.isRegistered    = false
    if why == "npc_person_identity_conflict" then
        self.availability = NPCIntegration.AVAIL_CONFLICT
        self.reasonKey    = "cs_consultant_conflict"
    else
        self.availability = NPCIntegration.AVAIL_WAITING
        self.reasonKey    = "cs_consultant_waiting"
    end
    return false
end

--- Where a NEW consultant is created when the host has no saved one: near the
--- host's player when its position is known, else the world origin (finite).
function NPCIntegration:claimPosition(sys)
    if sys ~= nil and sys.playerPositionValid and type(sys.playerPosition) == "table" then
        local p = sys.playerPosition
        if type(p.x) == "number" and type(p.z) == "number" and p.x == p.x and p.z == p.z then
            return { x = p.x + 15, y = (type(p.y) == "number" and p.y == p.y) and p.y or 0, z = p.z + 15 }
        end
    end
    return { x = 0, y = 0, z = 0 }
end

-- ============================================================
-- LEGACY TRUST (this mod's own saved scalar)
-- Called by SaveLoadHandler after reading cropStressData.xml or the ledger
-- table. The value is RETAINED as unproven old evidence: it may have been
-- saved from a namesake, so it is never applied to the host's person and
-- never becomes a floor. It is re-emitted on save until an explicit later
-- migration decision.
-- ============================================================
function NPCIntegration:applyLoadedState(relationship)
    if type(relationship) == "number" and relationship == relationship and relationship > 0 then
        self.legacyTrust = math.floor(relationship)
        csLog(string.format("NPCIntegration: legacy consultant trust %d loaded; kept as old evidence, not applied", self.legacyTrust))
    end
end

--- The retained legacy scalar for the save writers, or nil when none.
function NPCIntegration:getRetainedLegacyTrust()
    return self.legacyTrust
end

--- Once the host proves a consultant while a legacy scalar is held, tell the
--- farmer the old trust could not be safely linked (never that it was recovered).
function NPCIntegration:noticeLegacyTrust()
    if self.legacyTrust == nil or self.legacyTrustNoticed then return end
    self.legacyTrustNoticed = true
    csLog(string.format("NPCIntegration: legacy consultant trust %d could not be safely linked to person #%s; kept aside",
        self.legacyTrust, tostring(self.consultantNPCId)))
    local text = localizedText("cs_consultant_legacy_trust_held",
        "Alex Chen's old trust could not be safely linked to this neighbour; it is kept aside, not applied")
    if g_currentMission ~= nil and type(g_currentMission.addIngameNotification) == "function"
        and FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO ~= nil then
        pcall(function() g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text) end)
    end
end

-- ============================================================
-- IDENTITY VIEW (brief section 9a)
-- A copied schema-1 view: availability, the proved person and her trust
-- only while READY, whether a legacy scalar is held, and a reason key.
-- Never a fake zero: an unavailable trust is nil.
-- ============================================================
function NPCIntegration:getConsultantIdentityView()
    local view = {
        schema = 1,
        availability = self.availability or NPCIntegration.AVAIL_ABSENT,
        personId = nil,
        trust = nil,
        legacyTrustHeld = self.legacyTrust ~= nil,
        reasonKey = self.reasonKey or "",
    }
    if self.isRegistered then
        view.personId = self.consultantNPCId
        view.trust = self:getRelationshipLevel()
    end
    return view
end

-- ============================================================
-- REPLAY PENDING ALERTS
-- ============================================================
function NPCIntegration:replayPendingAlerts()
    local queued = self.pendingAlerts
    self.pendingAlerts = {}
    for _, alertData in ipairs(queued) do
        self:forwardAlertToNPC(alertData)
    end
end

-- ============================================================
-- SEND CONSULTANT ALERT
-- Called by CropConsultant:showAlert() when in NPCFavor mode, after the
-- standalone warning has already been shown. Returns true when the alert
-- was forwarded or queued for the proved consultant, false when this caller
-- stands aside (no host, an old host): the standalone alerts continue.
-- ============================================================
function NPCIntegration:sendConsultantAlert(data)
    if not self.isInitialized then return false end
    if data == nil or data.fieldId == nil then return false end
    if not self.npcFavorActive then return false end
    if self.availability == NPCIntegration.AVAIL_ABSENT or self.availability == NPCIntegration.AVAIL_OLD_HOST then
        return false
    end

    if not self.isRegistered then
        -- A presentation queue bounded to the latest 8; the oldest are dropped.
        table.insert(self.pendingAlerts, data)
        while #self.pendingAlerts > NPCIntegration.MAX_PENDING_ALERTS do
            table.remove(self.pendingAlerts, 1)
        end
        return true
    end

    self:forwardAlertToNPC(data)
    return true
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
        pcall(function()
            npcSystem:showNotification(consultantDisplayName(), dialogText)
        end)
    end

    -- Log favor hint: NPCFavor's favor system is player-initiated; no push API exists.
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
    csLog(string.format("NPCIntegration: favor hint [%s] field=%s, player must interact with Alex Chen",
        favorType, tostring(favorData and favorData.fieldId or "?")))
end

-- ============================================================
-- GET RELATIONSHIP LEVEL
-- The proved consultant's trust (0-100) from the host's own person, only
-- while the host proves her; otherwise nil (never a fake zero).
-- ============================================================
function NPCIntegration:getRelationshipLevel()
    if not self.isRegistered or self.consultantNPCId == nil then return nil end
    local npcSystem = getNPCSystem()
    if npcSystem == nil or type(npcSystem.getNPCById) ~= "function" then return nil end

    local ok, npc = pcall(function()
        return npcSystem:getNPCById(self.consultantNPCId)
    end)
    if ok and npc ~= nil and type(npc.relationship) == "number" then return npc.relationship end
    return nil
end

-- ============================================================
-- FAVOR CALLBACK GLOBALS
-- NPCFavor may invoke these by name (via _G[onAccept](data)) when the
-- player accepts or completes a favor quest. These stubs are minimal
-- no-ops that prevent a nil-call crash. Full implementation is Phase 4
-- (requires verified NPCFavor callback API + field-level task tracking).
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
-- Alex Chen lives in the host's roster and is saved and restored by the
-- host's own persistence. Nothing of hers is removed here; only this
-- caller's transient references are cleared.
-- ============================================================
function NPCIntegration:delete()
    self.pendingAlerts       = {}
    self.pendingRegistration = false
    self.isRegistered        = false
    self.consultantNPCId     = nil
    self.isInitialized       = false
    self.availability        = NPCIntegration.AVAIL_ABSENT
    self.reasonKey           = "cs_consultant_host_absent"
    self.lastAttemptMs       = nil
    self.legacyTrust         = nil
    self.legacyTrustNoticed  = false
end
