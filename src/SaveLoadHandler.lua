-- ============================================================
-- SaveLoadHandler.lua
-- Handles persistence of mod state into the FS25 career savegame.
--
-- FS25 API NOTE:
--   The xmlFile handle passed to FSCareerMissionInfo.saveToXMLFile is an
--   XMLFile OBJECT (FS25 OOP style). Use method calls:
--     xmlFile:setInt(key, val)    xmlFile:getInt(key)
--     xmlFile:setFloat(key, val)  xmlFile:getFloat(key)
--     xmlFile:setBool(key, val)   xmlFile:getBool(key)
--     xmlFile:setString(key, val) xmlFile:getString(key)
--   NOT the legacy globals setXMLInt / getXMLInt etc.
--
-- Save layout inside careerSavegame XML:
--   <cropStress>
--     <fields>
--       <field id="1" moisture="0.62" stress="0.00"/>
--       ...
--     </fields>
--     <hud visible="true" firstRunShown="true"/>
--     <irrigation>
--       <system id="42" startHour="6" endHour="10" isActive="false"
--               activeDays="1,1,1,1,1,0,0" manualMode="false"/>
--       ...
--     </irrigation>
--     <npc relationship="35"/>
--   </cropStress>
-- ============================================================

SaveLoadHandler = SaveLoadHandler or {}
SaveLoadHandler.__index = SaveLoadHandler

local function csLog(msg)
    if g_logManager ~= nil then g_logManager:devInfo("[CropStress]", msg)
    else print("[CropStress] " .. tostring(msg)) end
end

function SaveLoadHandler.new(manager)
    local self = setmetatable({}, SaveLoadHandler)
    self.manager = manager
    self.isInitialized = false
    self._saveDataLoaded = false  -- set true once we successfully read from xmlFile

    -- SCS-039 v2.1 (SDS 3.5): the two retained COMPLETE generations. Generation 0
    -- is the legacy/fresh baseline (a pre-feature .grle is imported as generation
    -- 0); a COMPLETE commit advances it only after the native write AND the
    -- compact write both succeed. A native failure with a usable compact write
    -- records one PENDING_ONLY payload bound to the base generation instead.
    self._completePair = {
        current  = { generation = 0, digest = nil, revision = 1, lastSettledMonotonicDay = nil },
        previous = nil,
    }
    self._pendingOnly = nil
    self._saveEnvelopeSchema = 2
    return self
end

function SaveLoadHandler:initialize()
    self.isInitialized = true
end

-- ============================================================
-- SAVE
-- xmlFile is the XMLFile OBJECT provided by FS25 (method API, not globals).
-- Fallback to global functions if object methods don't exist.
-- ============================================================
function SaveLoadHandler:saveToXMLFile(xmlFile)
    if not self.isInitialized then return end
    if xmlFile == nil then return end

    -- SCS-039: the value map SAVES NATIVELY, per the ratified persistence
    -- posture. The per-field scalar rows written below stay exactly as they are
    -- and become the DEGRADE layer: if the .grle is missing or refuses to load,
    -- the field scalars still restore and the cell store carries the save.
    local nativeSaveOk = false
    local soilSystemForMap = self.manager ~= nil and self.manager.soilSystem or nil
    if soilSystemForMap ~= nil and soilSystemForMap.valueMap ~= nil
       and soilSystemForMap.valueMap.available then
        local sgDir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
            and g_currentMission.missionInfo.savegameDirectory or nil
        if sgDir ~= nil then
            -- SCS-039 v2.1 (SDS 3.3): route the native save through the soil system
            -- so a refusal fails the provider closed. The scalar rows written below
            -- then carry the save as the honest degrade layer, and the next load
            -- re-selects a readable carrier rather than trusting bytes that never
            -- reached disk.
            nativeSaveOk = soilSystemForMap:saveNativeMap(sgDir) == true
        end
    end

    local root = "careerSavegame.cropStress"

    -- Helper functions that work with both object and global APIs
    local function setInt(key, value)
        if xmlFile.setInt then
            xmlFile:setInt(key, value)
        else
            setXMLInt(xmlFile, key, value)
        end
    end
    
    local function setFloat(key, value)
        if xmlFile.setFloat then
            xmlFile:setFloat(key, value)
        else
            setXMLFloat(xmlFile, key, value)
        end
    end
    
    local function setBool(key, value)
        if xmlFile.setBool then
            xmlFile:setBool(key, value)
        else
            setXMLBool(xmlFile, key, value)
        end
    end
    
    local function setString(key, value)
        if xmlFile.setString then
            xmlFile:setString(key, value)
        else
            setXMLString(xmlFile, key, value)
        end
    end

    -- Field moisture & stress
    local soilSystem = self.manager.soilSystem
    if soilSystem ~= nil then
        local i = 0
        for fieldId, data in pairs(soilSystem.fieldData) do
            local key = string.format("%s.fields.field(%d)", root, i)
            setInt(   key .. "#id",       fieldId)
            setFloat( key .. "#moisture", data.moisture)
            setFloat( key .. "#stress",   self.manager.stressModifier:getStress(fieldId))
            setString(key .. "#soilType", data.soilType or "loamy")
            -- SCS-018 3.8: packed cell leaf per field (nil when no cells exist).
            if soilSystem.packCells ~= nil then
                local packed = soilSystem:packCells(fieldId)
                if packed ~= nil then
                    setString(key .. "#cells", packed)
                end
            end
            -- SCS-039 v2.1 (SDS 3.5 capture groundwork): the field-wide pending
            -- sub-step carry is accepted water that must survive save and reload
            -- like the positional store. Zero is written explicitly so a cleared
            -- carry is not mistaken for a pre-feature save.
            setFloat(key .. "#mapPending", data.mapPending or 0)
            i = i + 1
        end

        -- SCS-039 v2.1 (SDS 3.2/3.5): the provider revision and the settled-day
        -- cursor are persisted server integers. Clients adopt them on load and
        -- never mint their own; the SDS 3.5 COMPLETE envelope carries them. The
        -- cursor is written only once seeded, so a fresh save keeps nil and the
        -- first wake seeds the current day without inventing history.
        setInt(root .. "#moistureRevision", soilSystem.moistureRevision or 1)
        if soilSystem._lastSettledDay ~= nil then
            setInt(root .. "#lastSettledDay", soilSystem._lastSettledDay)
        end

        -- SCS-039 v2.1 (SDS 3.4): persist the positional accepted-water store
        -- deterministically, so slice-3 UNRESOLVED world leaves and resolved
        -- pixel remainders survive save and reload instead of dying in-mission.
        -- nil when nothing is pending; the string form round-trips exactly.
        if soilSystem.packMapWaterPendingString ~= nil then
            local pendingPacked = soilSystem:packMapWaterPendingString()
            if pendingPacked ~= nil then
                setString(root .. "#mapWaterPending", pendingPacked)
            end
        end

        -- SCS-039 v2.1 (SDS 3.5): when the native carrier is current, capture one
        -- immutable envelope at this save's revision and commit it against the
        -- native and compact write receipts. The compact write (this own-XML
        -- block) is what just succeeded; the generation advances only when the
        -- native write did too, and a native failure records a PENDING_ONLY
        -- bound to the base generation. The current generation is persisted so
        -- the next load knows which pair to reconcile against. ZONE missions
        -- (no native map) keep the scalar carrier and no generation bookkeeping.
        if soilSystem.valueMap ~= nil and soilSystem.valueMap.available
           and self.captureMoistureEnvelope ~= nil and self.commitMoistureEnvelope ~= nil then
            local capture = self:captureMoistureEnvelope()
            if capture ~= nil then
                local outcome = self:commitMoistureEnvelope(capture, nativeSaveOk, true)
                if outcome == "COMPLETE" or outcome == "PENDING_ONLY" then
                    setInt(root .. "#saveGeneration", self._completePair.current.generation)
                end
            end
        end
    end

    -- HUD state
    local hud = self.manager.hudOverlay
    if hud ~= nil then
        setBool(root .. ".hud#visible",       hud.isVisible or false)
        setBool(root .. ".hud#firstRunShown", hud.firstRunShown or false)
    end

    -- Irrigation schedules
    local irrMgr = self.manager.irrigationManager
    if irrMgr ~= nil then
        local i = 0
        for sysId, system in pairs(irrMgr.systems) do
            local key = string.format("%s.irrigation.system(%d)", root, i)
            setInt(   key .. "#id",        sysId)
            setInt(   key .. "#startHour", system.schedule.startHour)
            setInt(   key .. "#endHour",   system.schedule.endHour)
            setBool(  key .. "#isActive",  system.isActive or false)
            -- [BUILD 00:33] Auto/Manual; absent on load = Auto.
            setBool(  key .. "#manualMode", system.manualMode == true)
            local dayStrs = {}
            for _, v in ipairs(system.schedule.activeDays) do
                table.insert(dayStrs, v and "1" or "0")
            end
            setString(key .. "#activeDays", table.concat(dayStrs, ","))
            i = i + 1
        end
    end

    -- NPC relationship (Alex Chen / Agronomist)
    local npcInt = self.manager.npcIntegration
    if npcInt ~= nil and npcInt.npcFavorActive then
        local rel = npcInt:getRelationshipLevel()
        if rel > 0 then
            setInt(root .. ".npc#relationship", rel)
        end
    end

    csLog("SaveLoadHandler: state saved")
end

-- ============================================================
-- LOAD
-- xmlFile is the XMLFile OBJECT on missionInfo (method API, not globals).
-- Fallback to global functions if object methods don't exist.
-- ============================================================
-- Optional xmlFile argument: if provided, use it directly instead of reading
-- from missionInfo. This is used by the bootstrap path in main.lua where the
-- save hook passes the xmlFile object it already holds (missionInfo.xmlFile
-- may still be a legacy integer handle at that point and cannot be indexed).
function SaveLoadHandler:loadFromXMLFile(xmlFile)
    if not self.isInitialized then return end

    if xmlFile == nil then
        if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
            xmlFile = g_currentMission.missionInfo.xmlFile
        end
    end
    if xmlFile == nil or type(xmlFile) == "number" then
        csLog("SaveLoadHandler: no xmlFile available — skipping load (fresh game)")
        return
    end

    self._saveDataLoaded = true

    local root = "careerSavegame.cropStress"

    -- Helper functions that work with both object and global APIs
    local function getInt(key, default)
        if xmlFile.getInt then
            return xmlFile:getInt(key) or default
        else
            return getXMLInt(xmlFile, key) or default
        end
    end
    
    local function getFloat(key, default)
        if xmlFile.getFloat then
            return xmlFile:getFloat(key) or default
        else
            return getXMLFloat(xmlFile, key) or default
        end
    end
    
    local function getBool(key, default)
        if xmlFile.getBool then
            local v = xmlFile:getBool(key)
            return v == nil and default or v
        else
            return getXMLBool(xmlFile, key) or default
        end
    end
    
    local function getString(key, default)
        if xmlFile.getString then
            return xmlFile:getString(key) or default
        else
            return getXMLString(xmlFile, key) or default
        end
    end

    -- Field moisture & stress
    local soilSystem     = self.manager.soilSystem
    local stressModifier = self.manager.stressModifier
    if soilSystem ~= nil then
        local i = 0
        while true do
            local key     = string.format("%s.fields.field(%d)", root, i)
            local fieldId = getInt(key .. "#id", nil)
            if fieldId == nil then break end
            local moisture = getFloat(key .. "#moisture", 0.50)
            local stress   = getFloat(key .. "#stress",   0.0)
            local soilType = getString(key .. "#soilType", nil)
            if soilSystem.fieldData[fieldId] ~= nil then
                soilSystem.fieldData[fieldId].moisture = math.max(0.0, math.min(1.0, moisture))
                if stressModifier ~= nil then
                    stressModifier.fieldStress[fieldId] = math.max(0.0, math.min(1.0, stress))
                end
                if soilType ~= nil and SoilMoistureSystem.SOIL_PARAMS[soilType] ~= nil then
                    soilSystem.fieldData[fieldId].soilType = soilType
                end
                -- SCS-018 3.8: install cells from the packed leaf (both load doors).
                local cellsStr = getString(key .. "#cells", nil)
                if cellsStr ~= nil and soilSystem.unpackCells ~= nil then
                    soilSystem:unpackCells(fieldId, cellsStr)
                end
                -- SCS-039 v2.1 (SDS 3.5): restore the field-wide pending carry.
                local mapPending = getFloat(key .. "#mapPending", nil)
                if mapPending ~= nil then
                    soilSystem.fieldData[fieldId].mapPending = mapPending
                end
            end
            i = i + 1
        end

        -- SCS-039 v2.1 (SDS 3.2/3.5): adopt the persisted provider revision and
        -- settled-day cursor on the server. Clients adopt the server value via
        -- the sync path and never mint their own.
        local revision = getInt(root .. "#moistureRevision", nil)
        if revision ~= nil then
            soilSystem.moistureRevision = revision
            self._completePair.current.revision = revision
        end
        local settledDay = getInt(root .. "#lastSettledDay", nil)
        if settledDay ~= nil then
            soilSystem._lastSettledDay = settledDay
            self._completePair.current.lastSettledMonotonicDay = settledDay
        end
        -- SCS-039 v2.1 (SDS 3.5): resume the retained-pair bookkeeping at the
        -- persisted generation so the next COMPLETE commit builds on it.
        local saveGeneration = getInt(root .. "#saveGeneration", nil)
        if saveGeneration ~= nil then
            self._completePair.current.generation = saveGeneration
        end

        -- SCS-039 v2.1 (SDS 3.4): restore the positional accepted-water store.
        -- The leaves are pending-only (nothing spends them until the provider
        -- accepts water again), so restoring before the map is seeded is safe
        -- and nothing is lost even if the reload selects a ZONE carrier.
        local pendingPacked = getString(root .. "#mapWaterPending", nil)
        if pendingPacked ~= nil and soilSystem.unpackMapWaterPendingString ~= nil then
            local restored = soilSystem:unpackMapWaterPendingString(pendingPacked)
            if restored > 0 then
                csLog(string.format("SaveLoadHandler: restored %d positional water leaves", restored))
            end
        end
        csLog(string.format("SaveLoadHandler: loaded moisture/stress for %d fields", i))
    end

    -- HUD state
    local hud = self.manager.hudOverlay
    if hud ~= nil then
        hud.isVisible     = getBool(root .. ".hud#visible",       false)
        hud.firstRunShown = getBool(root .. ".hud#firstRunShown", false)
    end

    -- Irrigation schedules
    local irrMgr = self.manager.irrigationManager
    if irrMgr ~= nil then
        local i = 0
        local restored = 0
        while true do
            local key   = string.format("%s.irrigation.system(%d)", root, i)
            local sysId = getInt(key .. "#id", nil)
            if sysId == nil then break end
            local system = irrMgr.systems[sysId]
            if system ~= nil then
                system.schedule.startHour = getInt(key .. "#startHour", system.schedule.startHour)
                system.schedule.endHour   = getInt(key .. "#endHour",   system.schedule.endHour)
                local daysStr = getString(key .. "#activeDays", nil)
                if daysStr ~= nil then
                    local days = {}
                    for v in string.gmatch(daysStr, "[^,]+") do
                        table.insert(days, tonumber(v) ~= 0)
                    end
                    if #days == 7 then system.schedule.activeDays = days end
                end
                -- [BUILD 00:33] Absent flag = AUTO (false).
                system.manualMode = getBool(key .. "#manualMode", false) == true
                local wasActive = getBool(key .. "#isActive", false)
                if wasActive and not system.isActive then
                    irrMgr:activateSystem(sysId)
                end
                restored = restored + 1
            end
            i = i + 1
        end
        csLog(string.format("SaveLoadHandler: restored schedules for %d/%d irrigation systems", restored, i))
    end

    -- NPC relationship (Alex Chen / Agronomist)
    -- Applied via applyLoadedState() which stores it until NPCFavor finishes init.
    local npcInt = self.manager.npcIntegration
    if npcInt ~= nil then
        local rel = getInt(root .. ".npc#relationship", 0)
        if rel > 0 then
            npcInt:applyLoadedState(rel)
        end
    end
end

-- ============================================================
-- TABLE SERIALIZE / APPLY (StateLedger bridge path)
-- These mirror the XML save/load above field-for-field, but as a plain Lua
-- table instead of XML keys. The StateLedger bridge uses them so the master
-- save file carries the same state careerSavegame.xml does. If you add a field
-- to the XML path above, add it here too (and vice versa) or the two save
-- surfaces drift.
-- ============================================================
function SaveLoadHandler:buildStateTable()
    local out = { fields = {}, irrigation = {} }

    -- Field moisture & stress
    local soilSystem     = self.manager.soilSystem
    local stressModifier = self.manager.stressModifier
    if soilSystem ~= nil then
        for fieldId, data in pairs(soilSystem.fieldData) do
            local entry = {
                moisture = data.moisture,
                stress   = (stressModifier ~= nil) and stressModifier:getStress(fieldId) or 0.0,
                soilType = data.soilType or "loamy",
            }
            -- SCS-039 v2.1 (SDS 3.5): carry the field-wide pending sub-step
            -- remainder on the ledger table mirror (own-XML writes it too).
            if data.mapPending ~= nil and data.mapPending ~= 0 then
                entry.mapPending = data.mapPending
            end
            -- SCS-018 3.8: packed cell leaf rides the ledger table (nil when no cells).
            if soilSystem.packCells ~= nil then
                entry.cells = soilSystem:packCells(fieldId)
            end
            out.fields[fieldId] = entry
        end

        -- SCS-039 v2.1 (SDS 3.2/3.5): the revision and settled-day cursor ride
        -- the ledger so the mirror matches the own-XML carrier. The cursor is
        -- carried only once seeded (nil otherwise, mirroring the XML path).
        out.moistureRevision = soilSystem.moistureRevision or 1
        if soilSystem._lastSettledDay ~= nil then
            out.lastSettledDay = soilSystem._lastSettledDay
        end

        -- SCS-039 v2.1 (SDS 3.4): the deterministic positional row array rides
        -- the ledger table so StateLedger mirrors the own-XML pending store.
        if soilSystem.packMapWaterPending ~= nil then
            local pendingRows = soilSystem:packMapWaterPending()
            if #pendingRows > 0 then out.mapWaterPending = pendingRows end
        end
    end

    -- HUD state
    local hud = self.manager.hudOverlay
    if hud ~= nil then
        out.hud = { visible = hud.isVisible or false, firstRunShown = hud.firstRunShown or false }
    end

    -- Irrigation schedules
    local irrMgr = self.manager.irrigationManager
    if irrMgr ~= nil then
        for sysId, system in pairs(irrMgr.systems) do
            local days = {}
            for _, v in ipairs(system.schedule.activeDays) do days[#days + 1] = v and 1 or 0 end
            out.irrigation[sysId] = {
                startHour  = system.schedule.startHour,
                endHour    = system.schedule.endHour,
                isActive   = system.isActive or false,
                manualMode = system.manualMode == true,
                activeDays = days,
            }
        end
    end

    -- NPC relationship (only when NPCFavor is active, same guard as the XML path)
    local npcInt = self.manager.npcIntegration
    if npcInt ~= nil and npcInt.npcFavorActive then
        local rel = npcInt:getRelationshipLevel()
        if rel ~= nil and rel > 0 then out.npcRelationship = rel end
    end

    return out
end

-- Apply a table produced by buildStateTable back into the live subsystems.
-- Same clamps and field-existence guards as loadFromXMLFile. Returns true when
-- a real table was applied.
function SaveLoadHandler:applyStateTable(data)
    if type(data) ~= "table" then return false end
    self._saveDataLoaded = true

    -- Field moisture & stress
    local soilSystem     = self.manager.soilSystem
    local stressModifier = self.manager.stressModifier
    if soilSystem ~= nil and type(data.fields) == "table" then
        local n = 0
        for fieldId, f in pairs(data.fields) do
            if soilSystem.fieldData[fieldId] ~= nil then
                soilSystem.fieldData[fieldId].moisture = math.max(0.0, math.min(1.0, f.moisture or 0.50))
                if stressModifier ~= nil then
                    stressModifier.fieldStress[fieldId] = math.max(0.0, math.min(1.0, f.stress or 0.0))
                end
                if f.soilType ~= nil and SoilMoistureSystem.SOIL_PARAMS[f.soilType] ~= nil then
                    soilSystem.fieldData[fieldId].soilType = f.soilType
                end
                -- SCS-039 v2.1 (SDS 3.5): restore the field-wide pending carry.
                if f.mapPending ~= nil then
                    soilSystem.fieldData[fieldId].mapPending = f.mapPending
                end
                -- SCS-018 3.8: install cells from the ledger-packed leaf.
                if f.cells ~= nil and soilSystem.unpackCells ~= nil then
                    soilSystem:unpackCells(fieldId, f.cells)
                end
                n = n + 1
            end
        end

        -- SCS-039 v2.1 (SDS 3.2/3.5): adopt the ledger revision and cursor.
        if data.moistureRevision ~= nil then soilSystem.moistureRevision = data.moistureRevision end
        if data.lastSettledDay ~= nil then soilSystem._lastSettledDay = data.lastSettledDay end

        -- SCS-039 v2.1 (SDS 3.4): restore the positional pending store from the
        -- ledger-packed row array (mirror of the own-XML string path above).
        if soilSystem.unpackMapWaterPending ~= nil
           and type(data.mapWaterPending) == "table" then
            local restored = soilSystem:unpackMapWaterPending(data.mapWaterPending)
            if restored > 0 then
                csLog(string.format("SaveLoadHandler: restored %d ledger positional water leaves", restored))
            end
        end
        csLog(string.format("SaveLoadHandler: applied ledger moisture/stress for %d fields", n))
    end

    -- HUD state
    local hud = self.manager.hudOverlay
    if hud ~= nil and type(data.hud) == "table" then
        hud.isVisible     = data.hud.visible or false
        hud.firstRunShown = data.hud.firstRunShown or false
    end

    -- Irrigation schedules
    local irrMgr = self.manager.irrigationManager
    if irrMgr ~= nil and type(data.irrigation) == "table" then
        for sysId, s in pairs(data.irrigation) do
            local system = irrMgr.systems[sysId]
            if system ~= nil then
                system.schedule.startHour = s.startHour or system.schedule.startHour
                system.schedule.endHour   = s.endHour   or system.schedule.endHour
                if type(s.activeDays) == "table" and #s.activeDays == 7 then
                    local days = {}
                    for _, v in ipairs(s.activeDays) do days[#days + 1] = (tonumber(v) ~= 0) end
                    system.schedule.activeDays = days
                end
                -- [BUILD 00:33] Absent flag = AUTO (false).
                system.manualMode = s.manualMode == true
                if s.isActive and not system.isActive then
                    irrMgr:activateSystem(sysId)
                end
            end
        end
    end

    -- NPC relationship
    local npcInt = self.manager.npcIntegration
    if npcInt ~= nil and data.npcRelationship ~= nil and data.npcRelationship > 0 then
        npcInt:applyLoadedState(data.npcRelationship)
    end

    return true
end

-- ============================================================
-- SCS-039 v2.1 (SDS 3.5): SYNCHRONOUS IMMUTABLE SAVE CAPTURE.
--
-- The save act freezes ONE envelope at the current provider revision (revision,
-- settled-day cursor, refreshed aggregates, both pending packs) and commits it
-- as a new COMPLETE generation ONLY after the native write AND the compact
-- write both succeed exactly. A native failure with a usable compact write
-- records one PENDING_ONLY payload bound to the base generation; it names no
-- native file and never advances the generation. On load, candidates from the
-- mirrors are grouped by generation and canonical digest, identical mirrors
-- deduplicate, conflicting digests reject that generation, and the highest
-- valid COMPLETE native pair wins (Group D and Group K mirror this contract).
-- The generation-qualified native FILE names, on-disk retention of both pairs
-- and interrupted-file cleanup are wired by the follow-on slices; this core is
-- the engine-free state machine the file layer will drive.
-- ============================================================

--- Deterministic canonical digest of one envelope's logical payload. Two
--- identical logical payloads produce the same string; any drift (revision,
--- cursor, aggregate, pending amount) changes it. Used to reconcile identical
--- mirrors and reject conflicting ones at the same generation.
function SaveLoadHandler:compactDigest(env)
    if env == nil then return nil end
    local parts = {}
    parts[#parts + 1] = "s=" .. tostring(env.schema)
    parts[#parts + 1] = "p=" .. tostring(env.payloadKind)
    parts[#parts + 1] = "g=" .. tostring(env.generation)
    parts[#parts + 1] = "r=" .. tostring(env.moistureRevision)
    parts[#parts + 1] = "d=" .. tostring(env.lastSettledMonotonicDay or -1)
    local aggKeys, fpKeys = {}, {}
    for fieldId in pairs(env.aggregates or {}) do aggKeys[#aggKeys + 1] = fieldId end
    for fieldId in pairs(env.fieldPending or {}) do fpKeys[#fpKeys + 1] = fieldId end
    table.sort(aggKeys)
    table.sort(fpKeys)
    for i = 1, #aggKeys do
        parts[#parts + 1] = string.format("a%d=%.6f", aggKeys[i], env.aggregates[aggKeys[i]] or 0)
    end
    for i = 1, #fpKeys do
        parts[#parts + 1] = string.format("f%d=%.6f", fpKeys[i], env.fieldPending[fpKeys[i]] or 0)
    end
    local rows = env.positionalRows or {}
    -- SCS-039 v2.1 (Iris fix 5): the digest binds the FULL canonical positional
    -- payload, not just count and total. Each leaf's field, status, coordinates
    -- (pixel key or canonical world position), source grain and amount appear in
    -- the pack's deterministic order, so two equal-sized leaves at different
    -- positions never produce the same digest.
    for i = 1, #rows do
        local r = rows[i]
        local where
        if r.status == "RESOLVED" then
            where = "p" .. tostring(r.pixelKey)
        else
            where = "w" .. tostring(r.worldX) .. "," .. tostring(r.worldZ)
        end
        parts[#parts + 1] = string.format("l%d=%s/%s/%s/%s/%.6f", i,
            tostring(r.fieldId), tostring(r.status), where,
            tostring(r.sourceWidth or "nil"), r.amount or 0)
    end
    parts[#parts + 1] = "lc=" .. tostring(#rows)
    return table.concat(parts, "|")
end

--- Capture one immutable COMPLETE envelope at the current provider revision.
--- Returns nil when there is no soil system to capture.
function SaveLoadHandler:captureMoistureEnvelope()
    local soil = self.manager ~= nil and self.manager.soilSystem or nil
    if soil == nil or type(soil.fieldData) ~= "table" then return nil end
    local base = self._completePair.current
    local env = {
        schema   = self._saveEnvelopeSchema or 2,
        payloadKind = "COMPLETE",
        generation = base.generation or 0,
        filename   = nil,
        mapWidth   = nil,
        grain      = nil,
        moistureRevision = soil.moistureRevision or 1,
        lastSettledMonotonicDay = soil._lastSettledDay,
        aggregates = {},
        fieldPending = {},
        positionalRows = {},
    }
    local vm = soil.valueMap
    if vm ~= nil and vm.available then
        env.mapWidth = vm.resolution
        if type(vm.getGrainMetres) == "function" then
            env.grain = vm:getGrainMetres()
        end
    end
    for fieldId, d in pairs(soil.fieldData) do
        -- SCS-039 v2.1 (Iris fix 6): refresh a dirty native aggregate BEFORE it is
        -- frozen into the envelope, so the capture never pairs the new revision
        -- with a stale mean from an earlier positional write.
        if d.aggregateDirty == true and soil.valueMap ~= nil and soil.valueMap.available
           and type(soil._refreshFieldAggregate) == "function" then
            soil:_refreshFieldAggregate(fieldId, d)
        end
        env.aggregates[fieldId] = d.moisture
        if d.mapPending ~= nil and d.mapPending ~= 0 then
            env.fieldPending[fieldId] = d.mapPending
        end
    end
    if type(soil.packMapWaterPending) == "function" then
        env.positionalRows = soil:packMapWaterPending()
    end
    env.digest = self:compactDigest(env)
    return env
end

--- Commit a captured envelope. Mirrors Group K's synchronousSave exactly:
---   "COMPLETE"    - native AND compact both true; previous pair retained, current
---                   advances one generation, any PENDING_ONLY is superseded.
---   "PENDING_ONLY" - native false but compact true; one PENDING_ONLY bound to the
---                   base generation/revision/cursor is recorded, pair unchanged.
---   "FAILED"      - compact also failed; pair unchanged, no recovery payload.
function SaveLoadHandler:commitMoistureEnvelope(capture, nativeOk, compactOk)
    if capture == nil then return "FAILED" end
    local base = self._completePair.current
    if nativeOk == true and compactOk == true then
        self._completePair.previous = self._completePair.current
        self._completePair.current = {
            generation = (base.generation or 0) + 1,
            digest     = capture.digest,
            revision   = capture.moistureRevision,
            lastSettledMonotonicDay = capture.lastSettledMonotonicDay,
        }
        self._pendingOnly = nil
        return "COMPLETE"
    end
    if compactOk == true then
        -- SCS-039 v2.1 (Iris fix 7): a PENDING_ONLY recovery row binds to the
        -- RETAINED complete pair's identity (generation, revision, cursor), never
        -- the current RAM revision/cursor, so the selector does not reject it as
        -- BASE_MISMATCH when RAM moved on after the last successful save. The
        -- pending payload itself stays the captured one.
        self._pendingOnly = {
            payloadKind = "PENDING_ONLY",
            baseGeneration = base.generation or 0,
            baseRevision   = base.revision or capture.moistureRevision,
            baseLastSettledMonotonicDay = base.lastSettledMonotonicDay,
            aggregates = capture.aggregates,
            fieldPending = capture.fieldPending,
            positionalRows = capture.positionalRows,
            zoneOk = true,
            digest = "P:" .. tostring(self:compactDigest(capture)),
        }
        return "PENDING_ONLY"
    end
    return "FAILED"
end

--- Select the carrier from a candidate list gathered at load (own XML and the
--- StateLedger mirror). Mirrors the bar's Group D selection: group candidates by
--- generation and canonical digest, deduplicate identical mirrors, reject a
--- generation whose mirrors conflict, then take the highest valid COMPLETE
--- native pair, degrading to ZONE on a newer valid compact without a native
--- file. A PENDING_ONLY row is applied only when its complete-pair identity
--- (generation, revision, cursor) matches exactly.
---@return string mode  "TRUTH" | "ZONE" | "NONE"
---@return number|nil generation
---@return string|nil digest
---@return string|nil pendingDigest
---@return string|nil pendingStatus  "APPLIED" | "CONFLICT" | "BASE_MISMATCH" | "NONE"
---@return number|nil cursor
---@return number|nil revision
function SaveLoadHandler:selectMoistureCarrier(candidates)
    -- Phase 1: pick the complete generation.
    local byGeneration = {}
    local order = {}
    for _, c in ipairs(candidates or {}) do
        if c.payloadKind ~= "PENDING_ONLY" and c.compactOk and type(c.generation) == "number" then
            local g = byGeneration[c.generation]
            if g == nil then
                g = { digests = {}, rows = {} }
                byGeneration[c.generation] = g
                order[#order + 1] = c.generation
            end
            g.digests[c.digest] = true
            g.rows[#g.rows + 1] = c
        end
    end
    table.sort(order, function(a, b) return a > b end)

    local function selectPendingOnly(baseGeneration, baseRevision, baseCursor)
        local digests, rows = {}, {}
        for _, c in ipairs(candidates or {}) do
            if c.payloadKind == "PENDING_ONLY" and c.compactOk
               and c.baseGeneration == baseGeneration then
                digests[c.digest] = true
                rows[#rows + 1] = c
            end
        end
        local count = 0
        for _ in pairs(digests) do count = count + 1 end
        if count == 0 then return nil, "NONE" end
        if count > 1 then return nil, "CONFLICT" end
        local row = rows[1]
        if baseRevision ~= nil and row.baseRevision ~= baseRevision then
            return nil, "BASE_MISMATCH"
        end
        if baseCursor ~= nil and row.baseLastSettledMonotonicDay ~= baseCursor then
            return nil, "BASE_MISMATCH"
        end
        return row, "APPLIED"
    end

    for i = 1, #order do
        local generation = order[i]
        local g = byGeneration[generation]
        local digestCount = 0
        for _ in pairs(g.digests) do digestCount = digestCount + 1 end
        if digestCount == 1 then
            local row = g.rows[1]
            local cursor = row.lastSettledMonotonicDay
            local revision = row.revision
            if row.nativeOk then
                local pending, pendingStatus =
                    selectPendingOnly(generation, revision, cursor)
                return "TRUTH", generation, row.digest,
                    pending ~= nil and pending.digest or nil,
                    pendingStatus, cursor, revision
            end
            return "ZONE", generation, row.digest,
                nil, "NONE", cursor, revision
        end
    end

    -- No complete pair: a PENDING_ONLY row may provide explicit ZONE recovery.
    local bases = {}
    for _, c in ipairs(candidates or {}) do
        if c.payloadKind == "PENDING_ONLY" and c.compactOk and c.zoneOk
           and type(c.baseGeneration) == "number" then
            bases[c.baseGeneration] = true
        end
    end
    local baseOrder = {}
    for b in pairs(bases) do baseOrder[#baseOrder + 1] = b end
    table.sort(baseOrder, function(a, b) return a > b end)
    for i = 1, #baseOrder do
        local pending, pendingStatus = selectPendingOnly(baseOrder[i], nil, nil)
        if pending ~= nil and pending.zoneOk then
            return "ZONE", baseOrder[i], nil, pending.digest, pendingStatus,
                pending.baseLastSettledMonotonicDay, pending.baseRevision
        end
    end
    return "NONE", nil, nil, nil, "NONE", nil, nil
end

function SaveLoadHandler:delete()
    self.isInitialized = false
end