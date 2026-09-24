--!load: tools/test/fixtures/npcfavor_host/src/utils/NPCFarmIdentity.lua, tools/test/fixtures/npcfavor_host/src/settings/NPCSettings.lua, tools/test/fixtures/npcfavor_host/src/scripts/NPCPersonRoster.lua, tools/test/fixtures/npcfavor_host/src/scripts/NPCRelationshipManager.lua, tools/test/fixtures/npcfavor_host/src/scripts/NPCFavorSystem.lua, tools/test/fixtures/npcfavor_host/src/scripts/NPCFavorRecovery.lua, tools/test/fixtures/npcfavor_host/src/scripts/NPCFieldWork.lua, tools/test/fixtures/npcfavor_host/src/scripts/NPCAI.lua, tools/test/fixtures/npcfavor_host/src/scripts/ContractorModBridge.lua, tools/test/fixtures/npcfavor_host/src/events/NPCStateSyncEvent.lua, tools/test/fixtures/npcfavor_host/src/integrations/NPCStateLedgerBridge.lua, tools/test/fixtures/npcfavor_host/src/integrations/NPCNetworkSyncBridge.lua, tools/test/fixtures/npcfavor_host/src/NPCSystem.lua, tools/test/lua/f357_host_world.lua, src/maps/CropStressValueMap.lua, tools/test/lua/f245_harness.lua, src/SoilMoistureSystem.lua, src/SoilMoistureGround.lua, src/SaveLoadHandler.lua, src/events/CropStressMoistureInitEvent.lua, src/integrations/CropStressNetworkSyncBridge.lua, src/CropStressManager.lua, src/CropConsultant.lua, src/NPCIntegration.lua, src/ui/CsRfPdaGuest.lua
-- RSF-F357 section 7, the SCS caller: Alex Chen is the host's fixed-token person.
--
-- THE ENTRY-POINT BAR. The host is the REAL FS25_NPCFavor host (the vendored copy
-- at tools/test/fixtures/npcfavor_host, pinned in PIN.md), booted through its own
-- entry point (NPCSystem.new, onMissionLoaded, the first-frame init updater) and
-- exposed on the mission handle exactly as its main.lua does. The caller is the
-- REAL NPCIntegration on a bare CropStressManager: detection through the real
-- detectOptionalMods, initialize, then tryDeferredRegistration per frame, which is
-- the one call CropStressManager:update makes (:551-553). Every consultant comes from
-- the host's claim or getter; nothing here sets an id, a token, a registration or a
-- trust by hand. The pure client becomes READY from the host's own snapshot page
-- through NPCStateSyncEvent's stream round trip. The save writers are the real
-- SaveLoadHandler over the F245 bare manager.
--
-- Groups: S server claim; N no name adoption; R reload wakes the same person; X the
-- conflict; C pure client; W a waiting host; A the alert queue; O old and absent
-- hosts; L the retained legacy scalar and the save writers; P the PDA reader.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
end

--- A bare manager with the real consultant and the real integration; the host is
--- detected through the real detectOptionalMods (mission.npcFavorSystem).
local function caller()
    local mgr = setmetatable({}, CropStressManager)
    mgr.consultant = CropConsultant.new(mgr)
    mgr.npcIntegration = NPCIntegration.new(mgr)
    mgr:detectOptionalMods()
    mgr.npcIntegration:initialize()
    return mgr, mgr.npcIntegration
end
--- One frame: the clock moves and CropStressManager:update's one call runs.
local function tick(mgr, ms)
    g_currentMission.time = g_currentMission.time + (ms or 16)
    mgr.npcIntegration:tryDeferredRegistration()
end
--- A recording wrapper over one host method: counts the calls and delegates.
local function spy(obj, name)
    local n = 0
    local real = obj[name]
    obj[name] = function(self, ...) n = n + 1 return real(self, ...) end
    return function() return n end
end
local NAME = "Alex Chen, Agronomist"

-- =========================================================
-- S: the server claim, through the host's door
-- =========================================================
group("S server claim", function()
    local host = F357Host.boot({ placeables = F357Host.town(4), maxNPCs = 3, dir = "s" })
    local claims = spy(host, "claimCropStressConsultant")
    local mgr, int = caller()
    T.eq("S1 [reached] the host is detected through the mission handle; the caller waits for it; alerts route to it", tostring(int.npcFavorActive) .. "/" .. int.availability .. "/" .. tostring(mgr.consultant.npcFavorMode), "true/WAITING/true")
    tick(mgr)
    T.eq("S2 the first poll claims once through the host's door: the host created her, numbered by its allocator", claims() .. "/" .. tostring(int.consultantNPCId) .. "/" .. tostring(int.isRegistered), "1/4/true")
    local alex = host:getNPCById(4)
    T.eq("S3 the host's person: the fixed token, the consultant origin, the agronomist role, the bounded display name", alex.providerToken .. "/" .. alex.origin .. "/" .. alex.role .. "/" .. alex.name, "cs_alex_chen/consultant/agronomist/" .. NAME)
    T.ok("S4 her trust is the host's normal starting trust, not a caller value", alex.relationship >= 5 and alex.relationship <= 35)
    T.eq("S5 the town is untouched: three town people plus her, nothing inserted by this mod", #host.activeNPCs .. "/" .. host.people:count() .. "/" .. tostring(host.people:getPerson(4) == alex), "4/4/true")
    local v = int:getConsultantIdentityView()
    T.eq("S6 the identity view: schema 1, READY, her number, her trust, no legacy held, no reason", v.schema .. "/" .. v.availability .. "/" .. tostring(v.personId) .. "/" .. tostring(v.trust == alex.relationship) .. "/" .. tostring(v.legacyTrustHeld) .. "/" .. v.reasonKey, "1/READY/4/true/false/")
    tick(mgr)
    tick(mgr)
    T.eq("S7 further frames inside the second claim nothing", claims(), 1)
    local reads = spy(host, "getCropStressConsultantId")
    tick(mgr, 1000)
    T.eq("S8 a second later the registration is re-checked through the getter and nothing is claimed again", claims() .. "/" .. reads() .. "/" .. tostring(int.consultantNPCId), "1/1/4")
    alex.relationship = 61
    T.eq("S9 getRelationshipLevel is the host person's own trust, read live, no local copy", int:getRelationshipLevel(), 61)
    -- She is put to wait on the host while this caller is present: the re-check a
    -- second later finds the getter empty, clears, and the caller's own claim wakes
    -- her again as the same person (the brief: the host wakes her when the caller is present).
    host:setPersonLive(alex, false, "npc_person_waiting_count")
    T.eq("S10 [world] the host stopped proving her", tostring(alex.live) .. "/" .. tostring(host:getCropStressConsultantId()), "false/nil")
    tick(mgr, 1000)
    T.eq("S10b the re-check saw it and the caller's claim woke the same person: one more claim, no second person", tostring(int.isRegistered) .. "/" .. tostring(int.consultantNPCId) .. "/" .. claims() .. "/" .. tostring(alex.live) .. "/" .. host.people:count(), "true/4/2/true/4")
    tick(mgr, 1000)
    T.eq("S11 while she stays proved nothing is claimed again", claims() .. "/" .. int.availability, "2/READY")
    T.eq("S12 the pending flag is down while she is proved", int.pendingRegistration, false)
end)

-- =========================================================
-- N: no name adoption
-- =========================================================
group("N no name adoption", function()
    local host = F357Host.boot({ placeables = F357Host.town(4), maxNPCs = 3, dir = "n" })
    local namesake = host.activeNPCs[1]
    namesake.name = NAME
    local mgr, int = caller()
    tick(mgr)
    T.eq("N1 a town person with the consultant's name is never adopted: the host created the consultant with the token", tostring(int.consultantNPCId) .. "/" .. tostring(namesake.providerToken) .. "/" .. tostring(host:getNPCById(4).providerToken), "4/nil/cs_alex_chen")
    T.eq("N2 the namesake keeps her own trust and row", namesake.id .. "/" .. tostring(host.people:getPerson(1) == namesake), "1/true")
end)

-- =========================================================
-- R: reload wakes the same person
-- =========================================================
group("R reload", function()
    local placeables = F357Host.town(4)
    local host = F357Host.boot({ placeables = placeables, maxNPCs = 3, dir = "r" })
    local mgr, int = caller()
    tick(mgr)
    host:getNPCById(4).relationship = 42
    host:saveToXMLFile(g_currentMission.missionInfo)
    T.eq("R1 the host saved her with the provider token", F357Host.fileAt("r")["npcFavor.npcs.npc(3)#providerToken"], "cs_alex_chen")
    local re = F357Host.boot({ placeables = placeables, maxNPCs = 3, dir = "r" })
    local claims = spy(re, "claimCropStressConsultant")
    T.eq("R2 after the reload she waits for her companion and the town did not wait for her", tostring(re:resolveRetainedPerson(4).live) .. "/" .. #re.activeNPCs, "false/3")
    local mgr2, int2 = caller()
    tick(mgr2)
    T.eq("R3 the caller's claim wakes the same person with her saved trust, no caller floor, no third person", claims() .. "/" .. tostring(int2.consultantNPCId) .. "/" .. re:getNPCById(4).relationship .. "/" .. re.people:count(), "1/4/42/4")
    T.eq("R4 getRelationshipLevel is her saved trust", int2:getRelationshipLevel(), 42)
end)

-- =========================================================
-- X: the conflict
-- =========================================================
group("X conflict", function()
    local placeables = F357Host.town(4)
    local host = F357Host.boot({ placeables = placeables, maxNPCs = 3, dir = "x" })
    local mgr, int = caller()
    tick(mgr)
    host:saveToXMLFile(g_currentMission.missionInfo)
    local f = F357Host.fileAt("x")
    f["npcFavor.npcs.npc(1)#providerToken"] = "cs_alex_chen"
    local dup = F357Host.boot({ placeables = placeables, maxNPCs = 3, dir = "x" })
    local mgr2, int2 = caller()
    tick(mgr2)
    local v = int2:getConsultantIdentityView()
    T.eq("X1 two saved rows with the token: CONFLICT, nobody linked, no lower-number winner", v.availability .. "/" .. tostring(v.personId) .. "/" .. tostring(v.trust) .. "/" .. v.reasonKey .. "/" .. tostring(int2.isRegistered), "CONFLICT/nil/nil/cs_consultant_conflict/false")
    T.eq("X2 every row is kept on the host", dup.people:count(), 4)
    T.eq("X3 the trust read is nil, never a fake zero", int2:getRelationshipLevel(), nil)
end)

-- =========================================================
-- C: the pure client reads the getter after a complete roster
-- =========================================================
group("C pure client", function()
    local placeables = F357Host.town(4)
    local server, serverMission = F357Host.boot({ placeables = placeables, maxNPCs = 3, dir = "c" })
    local mgrS = caller()
    tick(mgrS)
    T.eq("C1 [reached] the server's caller claimed her", tostring(server:getCropStressConsultantId()), "4")
    local client = F357Host.boot({ placeables = placeables, maxNPCs = 3, dir = "c", server = false })
    local claims = spy(client, "claimCropStressConsultant")
    local mgr, int = caller()
    tick(mgr)
    T.eq("C2 client before a complete roster: WAITING, nothing claimed, nothing registered", int.availability .. "/" .. claims() .. "/" .. tostring(int.isRegistered), "WAITING/0/false")
    F357Host.deliverSnapshot(server, client)
    tick(mgr, 1000)
    local v = int:getConsultantIdentityView()
    T.eq("C3 after the host's snapshot the client reads her number and her synced trust through the getter alone", v.availability .. "/" .. tostring(v.personId) .. "/" .. tostring(v.trust == server:getNPCById(4).relationship) .. "/" .. claims(), "READY/4/true/0")
    -- She goes waiting on the server: the next snapshot clears the client's registration.
    local saved = { g_server, g_NPCSystem, g_currentMission }
    g_server, g_NPCSystem, g_currentMission = { broadcastEvent = function() end }, server, serverMission
    server:setPersonLive(server:getNPCById(4), false, "npc_person_waiting_count")
    g_server, g_NPCSystem, g_currentMission = saved[1], saved[2], saved[3]
    F357Host.deliverSnapshot(server, client)
    tick(mgr, 1000)
    T.eq("C4 when the snapshot no longer proves her the client clears and waits", int.availability .. "/" .. tostring(int.consultantNPCId) .. "/" .. tostring(int:getRelationshipLevel()), "WAITING/nil/nil")
    g_server, g_NPCSystem, g_currentMission = { broadcastEvent = function() end }, server, serverMission
    server:setPersonLive(server:resolveRetainedPerson(4), true)
    g_server, g_NPCSystem, g_currentMission = saved[1], saved[2], saved[3]
    F357Host.deliverSnapshot(server, client)
    tick(mgr, 1000)
    T.eq("C5 live again in the next snapshot: the same number returns", tostring(int.consultantNPCId) .. "/" .. int.availability, "4/READY")
end)

-- =========================================================
-- W, A: a host still loading; the bounded alert queue
-- =========================================================
group("W waiting host and A alerts", function()
    local ledger = F357Host.newLedger(nil, true)
    local host = F357Host.boot({ placeables = F357Host.town(4), maxNPCs = 3, dir = "w", ledger = ledger })
    T.eq("W1 [world] the host waits for its ledger", host.people:getLoadState(), "WAITING")
    local claims = spy(host, "claimCropStressConsultant")
    local notes = spy(host, "showNotification")
    local mgr, int = caller()
    tick(mgr)
    T.eq("W2 the claim on a waiting host is refused as loading and the caller waits", claims() .. "/" .. int.availability .. "/" .. tostring(int.isRegistered), "1/WAITING/false")
    tick(mgr, 500)
    tick(mgr, 500)
    T.eq("W3 it retries about once a second, not every frame", claims(), 2)
    for i = 1, 9 do int:sendConsultantAlert({ fieldId = i, severity = "WARNING", cropName = "wheat" }) end
    T.eq("A1 alerts before she is proved queue, bounded to the latest 8 with the oldest dropped", #int.pendingAlerts .. "/" .. int.pendingAlerts[1].fieldId .. "/" .. int.pendingAlerts[8].fieldId, "8/2/9")
    T.eq("A2 nothing was shown yet", notes(), 0)
    ledger:deliver()
    tick(mgr, 1000)
    T.eq("W4 once the host is READY the next attempt claims her", int.availability .. "/" .. tostring(int.consultantNPCId), "READY/4")
    T.eq("A3 the eight queued alerts replay to the host once, the queue is empty", notes() .. "/" .. #int.pendingAlerts, "8/0")
    T.eq("A4 a later alert forwards at once", tostring(int:sendConsultantAlert({ fieldId = 10, severity = "CRITICAL", cropName = "barley" })) .. "/" .. notes(), "true/9")
end)

-- =========================================================
-- O: an old host, a host with another version, no host
-- =========================================================
group("O old and absent hosts", function()
    F357Host.boot({ placeables = F357Host.town(3), maxNPCs = 2, dir = "o" })
    -- An old host: the pre-F357 surface (activeNPCs, createNPCAtLocation, no claim, no getter, no version).
    local created = 0
    local oldHost = { isInitialized = true, isServer = true, npcCount = 1,
        activeNPCs = { { id = 1, name = NAME, relationship = 50, isActive = true } },
        createNPCAtLocation = function() created = created + 1 return { id = 2 } end,
        initializeNPCData = function() end,
        showNotification = function() end }
    g_currentMission.npcFavorSystem = oldHost
    local mgr, int = caller()
    tick(mgr)
    tick(mgr, 1000)
    local v = int:getConsultantIdentityView()
    T.eq("O1 an old host: OLD_HOST, nothing adopted, nothing created, nothing registered", v.availability .. "/" .. v.reasonKey .. "/" .. tostring(int.consultantNPCId) .. "/" .. created .. "/" .. #oldHost.activeNPCs, "OLD_HOST/cs_consultant_host_old/nil/0/1")
    T.eq("O2 the trust read is nil on an old host", int:getRelationshipLevel(), nil)
    T.eq("O3 the caller stands aside for alerts: the standalone consultant keeps them", tostring(int:sendConsultantAlert({ fieldId = 3, severity = "CRITICAL", cropName = "wheat" })) .. "/" .. #int.pendingAlerts, "false/0")
    local warnings = 0
    g_currentMission.showBlinkingWarning = function() warnings = warnings + 1 end
    mgr.getCriticalAlertHint = function() return nil end
    mgr.consultant:showAlert(3, 0.2, "CRITICAL", "wheat")
    T.eq("O4 the standalone warning still shows on an old host", warnings, 1)
    -- A host with the functions but another identity version is an old host too.
    g_currentMission.npcFavorSystem = { isInitialized = true, isServer = true, savedNeighbourIdentityVersion = 2,
        claimCropStressConsultant = function() created = created + 1 return 9 end, getCropStressConsultantId = function() return 9 end }
    local mgr2, int2 = caller()
    tick(mgr2)
    T.eq("O5 another identity version is not the contract this caller pairs with: OLD_HOST, no claim", int2.availability .. "/" .. created .. "/" .. tostring(int2.isRegistered), "OLD_HOST/0/false")
    -- No host at all.
    g_currentMission.npcFavorSystem = nil
    local mgr3, int3 = caller()
    tick(mgr3)
    T.eq("O6 no host: ABSENT, the consultant stays standalone, alerts are not queued", int3.availability .. "/" .. tostring(mgr3.consultant.npcFavorMode) .. "/" .. tostring(int3:sendConsultantAlert({ fieldId = 1 })) .. "/" .. tostring(int3:getRelationshipLevel()), "ABSENT/false/false/nil")
    T.eq("O7 the view is honest about it", int3:getConsultantIdentityView().availability .. "/" .. tostring(int3:getConsultantIdentityView().trust), "ABSENT/nil")
end)

-- =========================================================
-- L: the retained legacy scalar and the save writers
-- =========================================================
group("L legacy scalar", function()
    local host = F357Host.boot({ placeables = F357Host.town(4), maxNPCs = 3, dir = "l" })
    local mgr, int = caller()
    -- The mod's own save carried a scalar (this mod's SaveLoadHandler hands it over at load).
    int:applyLoadedState(42)
    T.eq("L1 the scalar is retained as old evidence, nothing applied yet", tostring(int.legacyTrust) .. "/" .. tostring(int:getConsultantIdentityView().legacyTrustHeld), "42/true")
    tick(mgr)
    local alex = host:getNPCById(4)
    T.eq("L2 once the host proves her, her trust is the host's own, never the scalar as a floor", tostring(alex.relationship ~= 42 and alex.relationship <= 35) .. "/" .. tostring(int:getRelationshipLevel() == alex.relationship), "true/true")
    T.eq("L3 the farmer is told once that the old trust could not be safely linked", #(g_currentMission.notices or {}) .. "/" .. tostring(g_currentMission.notices[1]), "1/cs_consultant_legacy_trust_held")
    tick(mgr, 1000)
    T.eq("L4 the notice is not repeated", #g_currentMission.notices, 1)
    -- Even a re-registration (she waited, the server's claim woke her again) says it only once.
    host:setPersonLive(alex, false, "npc_person_waiting_count")
    tick(mgr, 1000)
    T.eq("L4b a re-registration after she waited does not repeat it", tostring(int.isRegistered) .. "/" .. #g_currentMission.notices, "true/1")
    -- The save writers re-emit the retained scalar, never the live host score.
    local z = SoilMoistureSystem.new({})
    z.providerMode = "ZONE"
    local saveMgr = { soilSystem = z, stressModifier = { fieldStress = {}, getStress = function() return 0 end }, npcIntegration = int,
        ensureMissionWaterSaveCut = function() return { mode = "ZONE" } end }
    local sh = SaveLoadHandler.new(saveMgr)
    sh.isInitialized = true
    alex.relationship = 77
    local out = sh:buildStateTable()
    T.eq("L5 the ledger table carries the retained scalar, not the live trust", tostring(out.npcRelationship), "42")
    local handle = {}
    local ok = pcall(function() sh:saveToXMLFile(handle) end)
    T.eq("L6 the own XML carries the retained scalar, not the live trust", tostring(ok) .. "/" .. tostring(handle["careerSavegame.cropStress.npc#relationship"]), "true/42")
    -- Without a legacy scalar nothing is written, even while READY with a live trust.
    local mgrB, intB = caller()
    tick(mgrB)
    saveMgr.npcIntegration = intB
    local outB = sh:buildStateTable()
    local handleB = {}
    pcall(function() sh:saveToXMLFile(handleB) end)
    T.eq("L7 no scalar loaded: nothing written on either path, the live trust is not a new scalar", tostring(outB.npcRelationship) .. "/" .. tostring(handleB["careerSavegame.cropStress.npc#relationship"]), "nil/nil")
    -- The real load path hands the scalar over.
    local intC = NPCIntegration.new({})
    local loader = SaveLoadHandler.new({ soilSystem = SoilMoistureSystem.new({}), npcIntegration = intC })
    loader.isInitialized = true
    local data = { ["careerSavegame.cropStress.npc#relationship"] = 33 }
    local x = { data = data }
    function x:getInt(key) return self.data[key] end
    function x:getBool(key) return self.data[key] end
    function x:getString(key) return self.data[key] end
    function x:getFloat(key) return self.data[key] end
    function x:hasProperty(key) return self.data[key] ~= nil end
    loader:loadFromXMLFile(x)
    T.eq("L8 the XML load retains the scalar through applyLoadedState", tostring(intC.legacyTrust), "33")
end)

-- =========================================================
-- P: the PDA reader
-- =========================================================
group("P PDA reader", function()
    local host = F357Host.boot({ placeables = F357Host.town(4), maxNPCs = 3, dir = "p" })
    local mgr, int = caller()
    T.eq("P1 waiting: the availability's own line, no number", CsRfPdaGuest.consultantRelationText(mgr, "cs_rf_pda_agro_relation", "Alex Chen - %d / 100"), "Alex Chen is not linked yet")
    tick(mgr)
    host:getNPCById(4).relationship = 61
    T.eq("P2 ready: the proved trust through the surface's own format", CsRfPdaGuest.consultantRelationText(mgr, "cs_rf_pda_agro_relation", "Alex Chen - %d / 100"), "Alex Chen - 61 / 100")
    int:applyLoadedState(20)
    T.eq("P3 ready with an old scalar kept aside: the note rides along, the number is the host's", CsRfPdaGuest.consultantRelationText(mgr, "cs_rf_pda_cons_relation", "With Alex: %d / 100"), "With Alex: 61 / 100 (old trust kept aside)")
    g_currentMission.npcFavorSystem = nil
    local mgr2 = caller()
    T.eq("P4 no host: nothing at all, never a fake 0 / 100", CsRfPdaGuest.consultantRelationText(mgr2, "cs_rf_pda_agro_relation", "Alex Chen - %d / 100"), nil)
    g_currentMission.npcFavorSystem = { isInitialized = true }
    local mgr3 = caller()
    tick(mgr3)
    T.eq("P5 an old host: its explanation, no number", CsRfPdaGuest.consultantRelationText(mgr3, "cs_rf_pda_agro_relation", "Alex Chen - %d / 100"), "Alex Chen is not linked yet")
end)
