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
        current  = { generation = 0, digest = nil, revision = 1, lastSettledMonotonicDay = nil, envelope = nil },
        previous = nil,
    }
    self._pendingOnly = nil
    -- SCS-039 SDS 3.7 / SCS-041 SDS 5.13: the provider envelope is OUTER schema 3.
    -- The optional absorption leaf nested inside keeps its own schema 2. A legacy
    -- scalar save (no .moisture block) is the pre-envelope schema-2 carrier and
    -- migrates through the barrier with no absorption allowance.
    self._saveEnvelopeSchema = 3
    -- SCS-039 SDS 3.8: the two load surfaces STAGE their snapshot here instead of
    -- publishing water state on arrival. The one restore barrier reads both
    -- stages, selects one coherent view and applies it once fields exist.
    self._staged = {}
    return self
end

local ENVELOPE_SCHEMA = 3
local STAGE_ORDER = { "LEDGER", "XML" }

-- ============================================================
-- SCS-039 SDS 3.5/3.7: envelope encoders shared by own XML and the ledger table.
-- Every recognized envelope field round-trips through these, so the two mirrors
-- carry byte-equal logical payloads and the load-time digest check can rebuild
-- the canonical digest from either surface.
-- ============================================================

local function encodeFieldMap(map)
    local keys = {}
    for fieldId, value in pairs(map or {}) do
        if type(fieldId) == "number" and type(value) == "number" then keys[#keys + 1] = fieldId end
    end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
        parts[#parts + 1] = string.format("%d=%.17g", keys[i], map[keys[i]])
    end
    return table.concat(parts, ";")
end

local function decodeFieldMap(packed)
    local out = {}
    if type(packed) ~= "string" or packed == "" then return out end
    for part in string.gmatch(packed, "[^;]+") do
        local k, v = part:match("^(%-?%d+)=(.+)$")
        local fieldId, value = tonumber(k), tonumber(v)
        if fieldId ~= nil and value ~= nil then out[fieldId] = value end
    end
    return out
end

--- Positional rows use the exact grammar of SoilMoistureSystem:packMapWaterPendingString
--- (R|field|pixelKey|amount ; U|field|x|z|width|amount) so the envelope mirror
--- and the legacy #mapWaterPending key decode identically.
function SaveLoadHandler.packPositionalRows(rows)
    local parts = {}
    for i = 1, #(rows or {}) do
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

function SaveLoadHandler.unpackPositionalRows(packed)
    local rows = {}
    if type(packed) ~= "string" or packed == "" then return rows end
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
    return rows
end

local ABSORPTION_KEYS = {
    "schema", "windowId", "providerMode", "providerGrainMetres",
    "standDownThroughHourKey", "standDownAwaitingFirstValidHour", "standDownReason",
    "rowCount", "rowsPacked", "rowsAdler32",
}

local function copyAbsorptionLeaf(leaf)
    if type(leaf) ~= "table" then return nil end
    local out = {}
    for _, k in ipairs(ABSORPTION_KEYS) do out[k] = leaf[k] end
    return out
end

local function copyRows(rows)
    local out = {}
    for i = 1, #(rows or {}) do
        local r, c = rows[i], {}
        for k, v in pairs(r) do c[k] = v end
        out[i] = c
    end
    return out
end

local function copyMap(map)
    local out = {}
    for k, v in pairs(map or {}) do out[k] = v end
    return out
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

    -- SCS-039 SDS 3.7 / SCS-041 SDS 5.13: career XML asks the manager for the ONE
    -- immutable save view BEFORE reading any water state. The cut settles fitted
    -- groups, refreshes aggregates, packs both pending stores and the absorption
    -- leaf, writes the generation-qualified native image and commits; the pump
    -- save and StateLedger reuse the same cached view in this save act. The
    -- per-field scalar rows written below stay as the DEGRADE layer.
    local view = self:_missionWaterSaveView("CAREER_XML")

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

        -- SCS-039 SDS 3.7: the retained generation and the FULL logical view
        -- (current and previous COMPLETE envelopes, any PENDING_ONLY row, the
        -- absorption leaf with its digest) are the standalone safety copy. The
        -- legacy scalar keys above stay so an older reader still degrades.
        setInt(root .. "#saveGeneration", self._completePair.current.generation or 0)
        self:writeMoistureViewXML(setInt, setFloat, setBool, setString, root .. ".moisture", view)
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
            -- SCS-046: persist a fitted pivot's rain-key latch and dial so a
            -- reload restores the fitted state before any activity resumes.
            if system.rainKeyFitted == true then
                setBool(  key .. "#rkFitted",  true)
                setFloat( key .. "#rkTripMm",  system.rainKeyTripMm or 2.5)
                setFloat( key .. "#rkAccMm",   system.rainKeyAccumulatedMm or 0)
                setFloat( key .. "#rkDryMin",  system.rainKeyDryElapsedMinutes or 0)
                setBool(  key .. "#rkTripped", system.rainKeyTripped or false)
                setInt(   key .. "#rkRev",     system.rainKeyStateRevision or 0)
                setString(key .. "#rkInput",   system.rainKeyInputState or "UNAVAILABLE")
            end
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

    -- SCS-039 SDS 3.8: own XML is parsed into the SAME table shape the ledger
    -- delivers (buildStateTable's), then STAGED. Field water, revision, cursor,
    -- pending stores and the envelope candidates are applied only by the one
    -- restore barrier; HUD, schedules and the NPC row apply on arrival as before.
    local snap = { fields = {}, irrigation = {}, source = "XML" }

    local i = 0
    while true do
        local key     = string.format("%s.fields.field(%d)", root, i)
        local fieldId = getInt(key .. "#id", nil)
        if fieldId == nil then break end
        snap.fields[fieldId] = {
            moisture   = getFloat(key .. "#moisture", 0.50),
            stress     = getFloat(key .. "#stress",   0.0),
            soilType   = getString(key .. "#soilType", nil),
            cells      = getString(key .. "#cells", nil),
            mapPending = getFloat(key .. "#mapPending", nil),
        }
        i = i + 1
    end
    snap.fieldCount = i

    snap.moistureRevision = getInt(root .. "#moistureRevision", nil)
    snap.lastSettledDay   = getInt(root .. "#lastSettledDay", nil)
    snap.saveGeneration   = getInt(root .. "#saveGeneration", nil)
    local pendingPacked = getString(root .. "#mapWaterPending", nil)
    if pendingPacked ~= nil then
        snap.mapWaterPending = SaveLoadHandler.unpackPositionalRows(pendingPacked)
    end
    snap.moistureEnvelope = self:readMoistureViewXML(getInt, getFloat, getBool, getString, root .. ".moisture")

    snap.hud = {
        visible       = getBool(root .. ".hud#visible",       false),
        firstRunShown = getBool(root .. ".hud#firstRunShown", false),
    }

    i = 0
    while true do
        local key   = string.format("%s.irrigation.system(%d)", root, i)
        local sysId = getInt(key .. "#id", nil)
        if sysId == nil then break end
        local entry = {
            startHour  = getInt(key .. "#startHour", nil),
            endHour    = getInt(key .. "#endHour",   nil),
            isActive   = getBool(key .. "#isActive", false),
            manualMode = getBool(key .. "#manualMode", false) == true,
        }
        local daysStr = getString(key .. "#activeDays", nil)
        if daysStr ~= nil then
            local days = {}
            for v in string.gmatch(daysStr, "[^,]+") do days[#days + 1] = tonumber(v) end
            entry.activeDays = days
        end
        if getBool(key .. "#rkFitted", false) then
            entry.rkFitted  = true
            entry.rkTripMm  = getFloat(key .. "#rkTripMm", nil)
            entry.rkAccMm   = getFloat(key .. "#rkAccMm", 0)
            entry.rkDryMin  = getFloat(key .. "#rkDryMin", 0)
            entry.rkTripped = getBool(key .. "#rkTripped", false)
            entry.rkRev     = getInt(key .. "#rkRev", 0)
            entry.rkInput   = getString(key .. "#rkInput", "UNAVAILABLE")
        end
        snap.irrigation[sysId] = entry
        i = i + 1
    end

    local rel = getInt(root .. ".npc#relationship", 0)
    if rel > 0 then snap.npcRelationship = rel end

    self:stageSnapshot(snap, "XML")
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

    -- SCS-041 SDS 5.13: StateLedger calls the cut before buildStateTable, so the
    -- ledger mirror carries the identical logical view the career XML writes.
    local view = self:_missionWaterSaveView("STATELEDGER")

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

        -- SCS-039 SDS 3.7: the full logical view (both COMPLETE envelopes, the
        -- PENDING_ONLY row, the absorption leaf) rides the ledger as the
        -- optional mirror of the own-XML safety copy.
        out.saveGeneration = self._completePair.current.generation or 0
        out.moistureEnvelope = self:viewToTable(view)
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
            local entry = {
                startHour  = system.schedule.startHour,
                endHour    = system.schedule.endHour,
                isActive   = system.isActive or false,
                manualMode = system.manualMode == true,
                activeDays = days,
            }
            -- SCS-046: carry a fitted pivot's rain-key latch and dial.
            if system.rainKeyFitted == true then
                entry.rkFitted  = true
                entry.rkTripMm  = system.rainKeyTripMm or 2.5
                entry.rkAccMm   = system.rainKeyAccumulatedMm or 0
                entry.rkDryMin  = system.rainKeyDryElapsedMinutes or 0
                entry.rkTripped = system.rainKeyTripped or false
                entry.rkRev     = system.rainKeyStateRevision or 0
                entry.rkInput   = system.rainKeyInputState or "UNAVAILABLE"
            end
            out.irrigation[sysId] = entry
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
    self:stageSnapshot(data, "LEDGER")
    return true
end

--- SCS-039 SDS 3.8: one staging step for both load surfaces. Non-water state
--- (HUD, schedules, the NPC row) applies on arrival exactly as before. Field
--- water, revision, cursor, both pending stores and the envelope candidates are
--- retained on the stage until the one restore barrier selects and applies
--- them, so neither surface publishes a live water state early or twice.
function SaveLoadHandler:stageSnapshot(data, source)
    if type(data) ~= "table" then return false end
    source = source or "XML"
    self._staged = self._staged or {}
    self._staged[source] = data

    -- HUD state
    local hud = self.manager.hudOverlay
    if hud ~= nil and type(data.hud) == "table" then
        hud.isVisible     = data.hud.visible or false
        hud.firstRunShown = data.hud.firstRunShown or false
    end

    -- Irrigation schedules
    local irrMgr = self.manager.irrigationManager
    if irrMgr ~= nil and type(data.irrigation) == "table" then
        local restored, seen = 0, 0
        for sysId, s in pairs(data.irrigation) do
            seen = seen + 1
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
                -- SCS-046: restore a fitted pivot's rain-key latch and dial
                -- before any activity resumes.
                if s.rkFitted == true then
                    system.rainKeyFitted = true
                    system.rainKeyTripMm = s.rkTripMm or system.rainKeyTripMm or 2.5
                    system.rainKeyAccumulatedMm = s.rkAccMm or 0
                    system.rainKeyDryElapsedMinutes = s.rkDryMin or 0
                    system.rainKeyTripped = s.rkTripped or false
                    system.rainKeyStateRevision = s.rkRev or 0
                    system.rainKeyInputState = s.rkInput or "UNAVAILABLE"
                    system._lastRainKeyPausePublished = nil
                end
                restored = restored + 1
            end
        end
        csLog(string.format("SaveLoadHandler: restored schedules for %d/%d irrigation systems (%s)",
            restored, seen, source))
    end

    -- NPC relationship (applied via applyLoadedState, which holds it until
    -- NPCFavor finishes its own init).
    local npcInt = self.manager.npcIntegration
    if npcInt ~= nil and data.npcRelationship ~= nil and data.npcRelationship > 0 then
        npcInt:applyLoadedState(data.npcRelationship)
    end

    local fieldCount = 0
    for _ in pairs(data.fields or {}) do fieldCount = fieldCount + 1 end
    csLog(string.format("SaveLoadHandler: staged %s snapshot (%d field rows, %s envelope)",
        source, fieldCount, type(data.moistureEnvelope) == "table" and "with" or "no"))
    return true
end

--- True once at least one load surface has staged a snapshot.
function SaveLoadHandler:hasStagedSnapshot()
    for _, source in ipairs(STAGE_ORDER) do
        if self._staged ~= nil and self._staged[source] ~= nil then return true end
    end
    return false
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
    -- SCS-041 §8: bind the nested absorption leaf into the digest when the
    -- COMPLETE envelope carries one. Only the fields that survive save and
    -- reload appear, so identical leaves dedupe across mirrors and any drift
    -- (window, provider token, stand-down marker, row bytes) changes the digest
    -- exactly like the positional payload does. An absent leaf contributes
    -- nothing, so a pre-absorption envelope digests byte-identically.
    local absorption = env.absorption
    if type(absorption) == "table" then
        local marker = tostring(absorption.standDownThroughHourKey or "")
        local awaiting = absorption.standDownAwaitingFirstValidHour == true and "1" or "0"
        local reason = tostring(absorption.standDownReason or "")
        local window = tostring(absorption.windowId or "")
        parts[#parts + 1] = string.format("ab=w%s/m%s/g%s/mk%s/a%s/r%s/c%d/h%s",
            window, tostring(absorption.providerMode or ""),
            tostring(absorption.providerGrainMetres or ""), marker, awaiting, reason,
            absorption.rowCount or 0, tostring(absorption.rowsAdler32 or ""))
    end
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
    -- SCS-041 §8: nest the absorption leaf in the COMPLETE envelope when the
    -- mission is CAPPED and the ledger actually carries state worth persisting
    -- (a window, capacity rows, or a stand-down marker). SCS-039 owns the
    -- envelope; this adds only the optional leaf. An absent or state-less leaf
    -- stays nil so a pre-absorption save digests byte-identically, and the leaf
    -- itself carries its provider token and grain for the load-time validation.
    env.absorption = nil
    if soil.absorptionMode == "CAPPED" and type(soil.packAbsorptionWindow) == "function" then
        local leaf = soil:packAbsorptionWindow()
        if type(leaf) == "table"
           and (leaf.windowId ~= nil or (leaf.rowCount or 0) > 0
                or leaf.standDownThroughHourKey ~= nil
                or leaf.standDownAwaitingFirstValidHour == true) then
            env.absorption = leaf
        end
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
        local generation = (base.generation or 0) + 1
        -- SCS-039 SDS 3.7: the committed COMPLETE record retains its FULL
        -- envelope at the committed generation (the capture digests at the base
        -- generation; the stored copy re-digests at its own generation and names
        -- its generation-qualified native image) so the save surfaces can write
        -- the current and previous envelopes and a reload can validate them.
        local stored = {
            schema = capture.schema, payloadKind = "COMPLETE",
            generation = generation,
            filename = capture.filename, mapWidth = capture.mapWidth, grain = capture.grain,
            moistureRevision = capture.moistureRevision,
            lastSettledMonotonicDay = capture.lastSettledMonotonicDay,
            aggregates = capture.aggregates, fieldPending = capture.fieldPending,
            positionalRows = capture.positionalRows, absorption = capture.absorption,
        }
        stored.digest = self:compactDigest(stored)
        self._completePair.previous = self._completePair.current
        self._completePair.current = {
            generation = generation,
            digest     = capture.digest,
            revision   = capture.moistureRevision,
            lastSettledMonotonicDay = capture.lastSettledMonotonicDay,
            envelope   = stored,
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
        local pending = {
            payloadKind = "PENDING_ONLY",
            baseGeneration = base.generation or 0,
            baseRevision   = base.revision or capture.moistureRevision,
            baseLastSettledMonotonicDay = base.lastSettledMonotonicDay,
            aggregates = capture.aggregates,
            fieldPending = capture.fieldPending,
            positionalRows = capture.positionalRows,
            absorption = capture.absorption,
            zoneOk = true,
        }
        pending.digest = self:pendingDigest(pending)
        self._pendingOnly = pending
        return "PENDING_ONLY"
    end
    return "FAILED"
end

--- Canonical digest of a PENDING_ONLY row over its OWN fields (base identity,
--- payload, leaf), so a reload can rebuild and check it from either mirror.
function SaveLoadHandler:pendingDigest(pending)
    if type(pending) ~= "table" then return nil end
    return "P:" .. tostring(self:compactDigest({
        schema = self._saveEnvelopeSchema or ENVELOPE_SCHEMA,
        payloadKind = "PENDING_ONLY",
        generation = pending.baseGeneration,
        moistureRevision = pending.baseRevision,
        lastSettledMonotonicDay = pending.baseLastSettledMonotonicDay,
        aggregates = pending.aggregates,
        fieldPending = pending.fieldPending,
        positionalRows = pending.positionalRows,
        absorption = pending.absorption,
    }))
end

--- Decide which absorption leaf a load restores, mirroring the bar's Group M
--- replace-not-add rule (M14-M20): a PENDING_ONLY recovery row may REPLACE the
--- COMPLETE envelope's leaf only when it is bound to the same retained identity
--- (baseGeneration, baseRevision, base cursor match the capture's generation,
--- moistureRevision and lastSettledMonotonicDay). Any other pending row, or no
--- pending row, leaves the COMPLETE leaf in charge. An envelope that carried no
--- leaf means no prior absorption state, and nil comes back. The leaf's own
--- provider token and grain are validated separately by the absorption loader
--- (SCS-041 loadAbsorptionWindow), so they are not re-checked here.
---@return table|nil leaf
function SaveLoadHandler:selectedAbsorptionLeaf(complete, pending)
    if type(complete) == "table" and type(pending) == "table"
       and pending.payloadKind == "PENDING_ONLY"
       and type(pending.absorption) == "table"
       and pending.baseGeneration == complete.generation
       and pending.baseRevision == complete.moistureRevision
       and pending.baseLastSettledMonotonicDay == complete.lastSettledMonotonicDay then
        return pending.absorption
    end
    return type(complete) == "table" and complete.absorption or nil
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

-- ============================================================
-- SCS-039 SDS 3.7 / SCS-041 SDS 5.13: THE FILE LAYER.
--
-- performMissionWaterSaveCut is the mechanical cut the manager's
-- ensureMissionWaterSaveCut drives: capture at the current revision, write the
-- native image to its chosen slot file through the REAL saveNativeMap receipt,
-- commit, and hand back the logical view (current + previous COMPLETE, any
-- PENDING_ONLY row). The view encoders below carry that view to own XML and to
-- the StateLedger table; the candidate collector rebuilds and validates it from
-- either mirror; restoreMissionWater is what the one barrier calls to select and
-- apply a coherent generation, its pending overlay and its absorption leaf.
-- ============================================================

--- Resolve the save view for a save-surface caller. The manager owns the cached
--- immutable view; a bench that drives this handler over a bare manager table
--- performs the cut directly (no cache, same mechanics).
function SaveLoadHandler:_missionWaterSaveView(reason)
    local mgr = self.manager
    if mgr ~= nil and type(mgr.ensureMissionWaterSaveCut) == "function" then
        local view = mgr:ensureMissionWaterSaveCut(reason)
        if view ~= nil then return view end
    end
    local view = self:performMissionWaterSaveCut(reason)
    return view
end

--- RSF-F244: the native file a retained record's envelope names, or nil (a ZONE
--- generation or a record with no envelope names no file).
local function retainedFileName(record)
    if type(record) ~= "table" or type(record.envelope) ~= "table" then return nil end
    return record.envelope.filename
end

--- The mechanical cut. Returns the logical view and the commit outcome
--- ("COMPLETE" | "PENDING_ONLY" | "FAILED"). Only COMPLETE advances the
--- generation; anything else retains the prior pairs byte-current.
function SaveLoadHandler:performMissionWaterSaveCut(reason)
    local soil = self.manager ~= nil and self.manager.soilSystem or nil
    local capture = self:captureMoistureEnvelope()
    if capture == nil or soil == nil then
        csLog("SaveLoadHandler: save cut found no soil system to capture (" .. tostring(reason) .. ")")
        return self:buildMoistureView(), "FAILED"
    end

    local nativeOk, filename = false, nil
    if soil.providerMode == "UNAVAILABLE_PENDING_RELOAD" then
        -- SDS 3.3/3.7: a provider that failed closed writes no native image this
        -- mission; the compact write records PENDING_ONLY against the retained pair.
        nativeOk = false
    elseif type(soil.mapActive) == "function" and soil:mapActive() then
        -- RSF-F244: THREE ROTATING SLOTS, ONE NAME END TO END. The slot is chosen
        -- here, once, before the native write: the lowest one named by neither
        -- the selected current nor the selected previous retained record. That
        -- exact string is capture.filename, the argument written down through
        -- saveNativeMap and saveToSavegame, and the path checked on disk below.
        -- Nothing derives a name from the generation any more.
        if CropStressValueMap ~= nil and CropStressValueMap.chooseSlotFileName ~= nil then
            filename = CropStressValueMap.chooseSlotFileName(
                retainedFileName(self._completePair.current),
                retainedFileName(self._completePair.previous))
        end
        local sgDir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
            and g_currentMission.missionInfo.savegameDirectory or nil
        if sgDir ~= nil and filename ~= nil and type(soil.saveNativeMap) == "function" then
            -- The engine receipt must be literal true: a non-throwing false is a
            -- failure even when the outer pcall survived (saveToSavegame enforces
            -- that; saveNativeMap routes a refusal through the fail-closed path).
            nativeOk = soil:saveNativeMap(sgDir, filename) == true
            if nativeOk and fileExists ~= nil and filename ~= nil
               and fileExists(sgDir .. "/" .. filename) ~= true then
                csLog("SaveLoadHandler: native image reported saved but is not on disk; treating the write as failed")
                nativeOk = false
            end
        end
    else
        -- ZONE mission: there is no native leg. The compact envelope IS the whole
        -- generation (filename nil) and a reload degrades it to its own zone and
        -- pending state; the selector never pairs it with any native file.
        nativeOk = true
    end
    capture.filename = nativeOk and filename or nil

    local outcome = self:commitMoistureEnvelope(capture, nativeOk, true)
    if outcome == "COMPLETE" then
        csLog(string.format("SaveLoadHandler: save cut (%s) committed generation %d%s",
            tostring(reason), self._completePair.current.generation or 0,
            filename ~= nil and (" [" .. filename .. "]") or " [compact only]"))
    else
        csLog(string.format("SaveLoadHandler: save cut (%s) did not complete: %s; generation stays %d",
            tostring(reason), tostring(outcome), self._completePair.current.generation or 0))
    end
    return self:buildMoistureView(), outcome
end

--- The logical view the save surfaces persist: the current and previous
--- COMPLETE envelopes (when committed this session or restored on load) and
--- the one PENDING_ONLY recovery row. Immutable by construction: every table
--- referenced here was frozen at its capture.
function SaveLoadHandler:buildMoistureView()
    local view = { schema = self._saveEnvelopeSchema or ENVELOPE_SCHEMA, complete = {} }
    local cur, prev = self._completePair.current, self._completePair.previous
    if cur ~= nil and type(cur.envelope) == "table" then view.complete[#view.complete + 1] = cur.envelope end
    if prev ~= nil and type(prev.envelope) == "table" then view.complete[#view.complete + 1] = prev.envelope end
    view.pendingOnly = self._pendingOnly
    view.generation = cur ~= nil and (cur.generation or 0) or 0
    return view
end

local function envelopeToTable(env)
    return {
        schema = env.schema, payloadKind = "COMPLETE", generation = env.generation,
        filename = env.filename, mapWidth = env.mapWidth, grain = env.grain,
        moistureRevision = env.moistureRevision,
        lastSettledMonotonicDay = env.lastSettledMonotonicDay,
        digest = env.digest,
        aggregates = copyMap(env.aggregates), fieldPending = copyMap(env.fieldPending),
        positionalRows = copyRows(env.positionalRows),
        absorption = copyAbsorptionLeaf(env.absorption),
    }
end

local function pendingToTable(p)
    return {
        payloadKind = "PENDING_ONLY",
        baseGeneration = p.baseGeneration, baseRevision = p.baseRevision,
        baseLastSettledMonotonicDay = p.baseLastSettledMonotonicDay,
        zoneOk = p.zoneOk == true, digest = p.digest,
        aggregates = copyMap(p.aggregates), fieldPending = copyMap(p.fieldPending),
        positionalRows = copyRows(p.positionalRows),
        absorption = copyAbsorptionLeaf(p.absorption),
    }
end

--- Plain-table form of the view for the StateLedger mirror (deep copy, so the
--- ledger's serializer can never reach into the frozen envelopes).
function SaveLoadHandler:viewToTable(view)
    if type(view) ~= "table" then return nil end
    local out = { schema = view.schema or ENVELOPE_SCHEMA, complete = {} }
    for i, env in ipairs(view.complete or {}) do out.complete[i] = envelopeToTable(env) end
    if type(view.pendingOnly) == "table" then out.pendingOnly = pendingToTable(view.pendingOnly) end
    return out
end

local function writeAbsorptionXML(setInt, setFloat, setBool, setString, key, leaf)
    if type(leaf) ~= "table" then return end
    setInt(key .. "#schema", leaf.schema or 2)
    if leaf.windowId ~= nil then setInt(key .. "#windowId", leaf.windowId) end
    if leaf.providerMode ~= nil then setString(key .. "#providerMode", leaf.providerMode) end
    if leaf.providerGrainMetres ~= nil then
        setString(key .. "#providerGrainMetres", string.format("%.17g", leaf.providerGrainMetres))
    end
    if leaf.standDownThroughHourKey ~= nil then
        setInt(key .. "#standDownThroughHourKey", leaf.standDownThroughHourKey)
    end
    setBool(key .. "#standDownAwaitingFirstValidHour", leaf.standDownAwaitingFirstValidHour == true)
    if leaf.standDownReason ~= nil then setString(key .. "#standDownReason", leaf.standDownReason) end
    setInt(key .. "#rowCount", leaf.rowCount or 0)
    setString(key .. "#rowsPacked", leaf.rowsPacked or "")
    setString(key .. "#rowsAdler32", leaf.rowsAdler32 or "")
end

local function readAbsorptionXML(getInt, getFloat, getBool, getString, key)
    local schema = getInt(key .. "#schema", nil)
    if schema == nil then return nil end
    local leaf = {
        schema = schema,
        windowId = getInt(key .. "#windowId", nil),
        providerMode = getString(key .. "#providerMode", nil),
        providerGrainMetres = tonumber(getString(key .. "#providerGrainMetres", nil)),
        standDownThroughHourKey = getInt(key .. "#standDownThroughHourKey", nil),
        standDownAwaitingFirstValidHour = getBool(key .. "#standDownAwaitingFirstValidHour", false) == true,
        standDownReason = getString(key .. "#standDownReason", nil),
        rowCount = getInt(key .. "#rowCount", 0),
        rowsPacked = getString(key .. "#rowsPacked", nil) or "",
        rowsAdler32 = getString(key .. "#rowsAdler32", nil) or "",
    }
    return leaf
end

local function writeEnvelopeXML(setInt, setFloat, setBool, setString, key, env)
    setInt(key .. "#schema", env.schema or ENVELOPE_SCHEMA)
    setString(key .. "#payloadKind", "COMPLETE")
    setInt(key .. "#generation", env.generation or 0)
    if env.filename ~= nil then setString(key .. "#filename", env.filename) end
    if env.mapWidth ~= nil then setInt(key .. "#mapWidth", env.mapWidth) end
    if env.grain ~= nil then setString(key .. "#grain", string.format("%.17g", env.grain)) end
    setInt(key .. "#moistureRevision", env.moistureRevision or 1)
    if env.lastSettledMonotonicDay ~= nil then
        setInt(key .. "#lastSettledMonotonicDay", env.lastSettledMonotonicDay)
    end
    setString(key .. "#digest", env.digest or "")
    setString(key .. "#aggregates", encodeFieldMap(env.aggregates))
    setString(key .. "#fieldPending", encodeFieldMap(env.fieldPending))
    setString(key .. "#positionalRows", SaveLoadHandler.packPositionalRows(env.positionalRows))
    writeAbsorptionXML(setInt, setFloat, setBool, setString, key .. ".absorption", env.absorption)
end

local function readEnvelopeXML(getInt, getFloat, getBool, getString, key)
    local schema = getInt(key .. "#schema", nil)
    if schema == nil then return nil end
    return {
        schema = schema,
        payloadKind = getString(key .. "#payloadKind", nil),
        generation = getInt(key .. "#generation", nil),
        filename = getString(key .. "#filename", nil),
        mapWidth = getInt(key .. "#mapWidth", nil),
        grain = tonumber(getString(key .. "#grain", nil)),
        moistureRevision = getInt(key .. "#moistureRevision", nil),
        lastSettledMonotonicDay = getInt(key .. "#lastSettledMonotonicDay", nil),
        digest = getString(key .. "#digest", nil),
        aggregates = decodeFieldMap(getString(key .. "#aggregates", nil)),
        fieldPending = decodeFieldMap(getString(key .. "#fieldPending", nil)),
        positionalRows = SaveLoadHandler.unpackPositionalRows(getString(key .. "#positionalRows", nil)),
        absorption = readAbsorptionXML(getInt, getFloat, getBool, getString, key .. ".absorption"),
    }
end

--- Write the full logical view under <cropStress><moisture>. Unrelated career
--- fields are untouched; a view with nothing committed writes only its schema.
function SaveLoadHandler:writeMoistureViewXML(setInt, setFloat, setBool, setString, key, view)
    if type(view) ~= "table" then return end
    setInt(key .. "#schema", view.schema or ENVELOPE_SCHEMA)
    for i, env in ipairs(view.complete or {}) do
        writeEnvelopeXML(setInt, setFloat, setBool, setString,
            string.format("%s.complete(%d)", key, i - 1), env)
    end
    local p = view.pendingOnly
    if type(p) == "table" then
        local pk = key .. ".pendingOnly"
        setString(pk .. "#payloadKind", "PENDING_ONLY")
        setInt(pk .. "#baseGeneration", p.baseGeneration or 0)
        setInt(pk .. "#baseRevision", p.baseRevision or 1)
        if p.baseLastSettledMonotonicDay ~= nil then
            setInt(pk .. "#baseLastSettledMonotonicDay", p.baseLastSettledMonotonicDay)
        end
        setBool(pk .. "#zoneOk", p.zoneOk == true)
        setString(pk .. "#digest", p.digest or "")
        setString(pk .. "#aggregates", encodeFieldMap(p.aggregates))
        setString(pk .. "#fieldPending", encodeFieldMap(p.fieldPending))
        setString(pk .. "#positionalRows", SaveLoadHandler.packPositionalRows(p.positionalRows))
        writeAbsorptionXML(setInt, setFloat, setBool, setString, pk .. ".absorption", p.absorption)
    end
end

--- Read the view back into the same table shape the ledger delivers. nil when
--- the save predates the envelope (legacy scalar schema 2).
function SaveLoadHandler:readMoistureViewXML(getInt, getFloat, getBool, getString, key)
    local schema = getInt(key .. "#schema", nil)
    if schema == nil then return nil end
    local out = { schema = schema, complete = {} }
    local i = 0
    while true do
        local env = readEnvelopeXML(getInt, getFloat, getBool, getString,
            string.format("%s.complete(%d)", key, i))
        if env == nil then break end
        out.complete[#out.complete + 1] = env
        i = i + 1
    end
    local pk = key .. ".pendingOnly"
    if getString(pk .. "#payloadKind", nil) == "PENDING_ONLY" then
        out.pendingOnly = {
            payloadKind = "PENDING_ONLY",
            baseGeneration = getInt(pk .. "#baseGeneration", nil),
            baseRevision = getInt(pk .. "#baseRevision", nil),
            baseLastSettledMonotonicDay = getInt(pk .. "#baseLastSettledMonotonicDay", nil),
            zoneOk = getBool(pk .. "#zoneOk", false) == true,
            digest = getString(pk .. "#digest", nil),
            aggregates = decodeFieldMap(getString(pk .. "#aggregates", nil)),
            fieldPending = decodeFieldMap(getString(pk .. "#fieldPending", nil)),
            positionalRows = SaveLoadHandler.unpackPositionalRows(getString(pk .. "#positionalRows", nil)),
            absorption = readAbsorptionXML(getInt, getFloat, getBool, getString, pk .. ".absorption"),
        }
    end
    return out
end

--- A COMPLETE candidate is valid only when its payload parses whole and its
--- canonical digest rebuilds byte-for-byte. Returns ok, reason.
function SaveLoadHandler:validateCompleteEnvelope(env)
    if type(env) ~= "table" then return false, "NOT_TABLE" end
    if env.schema ~= ENVELOPE_SCHEMA then return false, "SCHEMA" end
    if env.payloadKind ~= "COMPLETE" then return false, "KIND" end
    if type(env.generation) ~= "number" or type(env.moistureRevision) ~= "number" then
        return false, "IDENTITY"
    end
    if type(env.aggregates) ~= "table" or type(env.fieldPending) ~= "table"
       or type(env.positionalRows) ~= "table" then
        return false, "PAYLOAD"
    end
    if type(env.digest) ~= "string" or self:compactDigest(env) ~= env.digest then
        return false, "DIGEST"
    end
    return true
end

function SaveLoadHandler:validatePendingRow(p)
    if type(p) ~= "table" then return false, "NOT_TABLE" end
    if p.payloadKind ~= "PENDING_ONLY" then return false, "KIND" end
    if type(p.baseGeneration) ~= "number" or type(p.baseRevision) ~= "number" then
        return false, "IDENTITY"
    end
    if type(p.aggregates) ~= "table" or type(p.fieldPending) ~= "table"
       or type(p.positionalRows) ~= "table" then
        return false, "PAYLOAD"
    end
    if type(p.digest) ~= "string" or self:pendingDigest(p) ~= p.digest then
        return false, "DIGEST"
    end
    return true
end

--- RSF-F244: has this save moved to generation storage? True when either mirror
--- staged any COMPLETE candidate, valid or not, or either staged snapshot carries
--- saveGeneration above 0. Built from both surfaces, never from the selector's
--- mode (it groups only valid rows, so all-invalid envelopes read as NONE) nor
--- from the legacy branch's single snapshot (the first staged surface only).
---
--- It does not look at slot files, on purpose. A save cut writes its slot image
--- before either mirror commits it, so a pre-generation save interrupted after
--- its first slot write leaves the same disk picture as a generation-era save
--- that lost both moisture records. Only the first may keep its legacy image, and
--- nothing on disk separates them, so the lost-both-records save is a named
--- residual, not a detected case.
---@param candidates table  every row collectMoistureCandidates returned
---@return boolean
function SaveLoadHandler:isGenerationEraLoad(candidates)
    for _, c in ipairs(candidates or {}) do
        if c.payloadKind == "COMPLETE" then return true end
    end
    for _, source in ipairs(STAGE_ORDER) do
        local snap = self._staged ~= nil and self._staged[source] or nil
        if type(snap) == "table" and type(snap.saveGeneration) == "number" and snap.saveGeneration > 0 then
            return true
        end
    end
    return false
end

--- Collect candidate rows from every staged surface with their FULL payloads
--- attached (the selector's returned identifiers alone are never restored
--- material). Native availability is left false here: the barrier probes the
--- one file the selection would use.
function SaveLoadHandler:collectMoistureCandidates()
    local candidates = {}
    for _, source in ipairs(STAGE_ORDER) do
        local snap = self._staged ~= nil and self._staged[source] or nil
        local me = type(snap) == "table" and snap.moistureEnvelope or nil
        if type(me) == "table" then
            for _, env in ipairs(me.complete or {}) do
                local ok, why = self:validateCompleteEnvelope(env)
                candidates[#candidates + 1] = {
                    payloadKind = "COMPLETE", generation = env.generation, digest = env.digest,
                    compactOk = ok == true, nativeOk = false,
                    revision = env.moistureRevision,
                    lastSettledMonotonicDay = env.lastSettledMonotonicDay,
                    payload = env, source = source, reason = why,
                }
                if ok ~= true then
                    csLog(string.format("SaveLoadHandler: %s COMPLETE candidate at generation %s rejected (%s)",
                        source, tostring(env.generation), tostring(why)))
                end
            end
            local p = me.pendingOnly
            if type(p) == "table" then
                local ok, why = self:validatePendingRow(p)
                candidates[#candidates + 1] = {
                    payloadKind = "PENDING_ONLY", baseGeneration = p.baseGeneration,
                    baseRevision = p.baseRevision,
                    baseLastSettledMonotonicDay = p.baseLastSettledMonotonicDay,
                    digest = p.digest, compactOk = ok == true, zoneOk = p.zoneOk == true,
                    payload = p, source = source, reason = why,
                }
                if ok ~= true then
                    csLog(string.format("SaveLoadHandler: %s PENDING_ONLY candidate (base %s) rejected (%s)",
                        source, tostring(p.baseGeneration), tostring(why)))
                end
            end
        end
    end
    return candidates
end

local function clamp01(v) return math.max(0.0, math.min(1.0, v or 0)) end

--- THE RESTORE APPLY. Called exactly once by the manager's barrier after
--- compact data, fields, the provider decision, settings and the absorption
--- freeze are all ready. Selects one coherent SCS-039 view from the staged
--- candidates, probes the ONE native image that selection would use
--- (ctx.nativeProbe(envelope) -> true only when the file opens with the right
--- shape), applies the selected envelope plus any identity-matching
--- PENDING_ONLY overlay together, then hands the permitted absorption leaf to
--- the absorption loader with the enclosing provider identity, current hour and
--- field membership. Legacy scalar saves (no envelope) migrate through the same
--- path with no absorption allowance.
---@param ctx table|nil { nativeProbe=fn(env)->bool, legacyProbe=fn()->bool, liveMode, liveGrain, currentHour }
---@return table result
function SaveLoadHandler:restoreMissionWater(ctx)
    ctx = ctx or {}
    local soil = self.manager ~= nil and self.manager.soilSystem or nil
    local stressModifier = self.manager ~= nil and self.manager.stressModifier or nil
    local result = {
        mode = "NONE", generation = nil, digest = nil, pendingStatus = "NONE",
        source = nil, provider = nil, absorption = nil,
        fieldsApplied = 0, fieldsIgnored = 0, declined = nil,
    }
    if soil == nil or type(soil.fieldData) ~= "table" then return result end

    local candidates = self:collectMoistureCandidates()
    local mode, generation, digest, pendingDigest, pendingStatus =
        self:selectMoistureCarrier(candidates)

    -- Probe native availability for the generation the selection lands on, and
    -- only that one (SDS 3.7: a newer compact never pairs with an older file).
    local selectedRow = nil
    if mode ~= "NONE" and digest ~= nil then
        for _, c in ipairs(candidates) do
            if c.payloadKind == "COMPLETE" and c.compactOk
               and c.generation == generation and c.digest == digest then
                selectedRow = c
                break
            end
        end
        if selectedRow ~= nil then
            local ok = false
            if type(ctx.nativeProbe) == "function" and selectedRow.payload.filename ~= nil then
                ok = ctx.nativeProbe(selectedRow.payload) == true
            end
            if ok then
                for _, c in ipairs(candidates) do
                    if c.payloadKind == "COMPLETE" and c.generation == generation
                       and c.digest == digest then
                        c.nativeOk = true
                    end
                end
            end
            mode, generation, digest, pendingDigest, pendingStatus =
                self:selectMoistureCarrier(candidates)
        end
    end

    local pendingRow = nil
    if pendingStatus == "APPLIED" and pendingDigest ~= nil then
        for _, c in ipairs(candidates) do
            if c.payloadKind == "PENDING_ONLY" and c.compactOk and c.digest == pendingDigest then
                pendingRow = c
                break
            end
        end
    end

    -- The field rows come from the surface that supplied the winning candidate
    -- (identical mirrors dedupe; a lone surface wins by default in stage order).
    local source = (selectedRow ~= nil and selectedRow.source)
        or (pendingRow ~= nil and pendingRow.source) or nil
    if source == nil then
        for _, s in ipairs(STAGE_ORDER) do
            if self._staged ~= nil and self._staged[s] ~= nil then source = s; break end
        end
    end
    local snap = (source ~= nil and self._staged ~= nil) and self._staged[source] or {}
    result.source = source

    -- 1. Compact fallback rows load first (cells as migration evidence, scalar,
    --    stress, soil type, field-wide carry). Rows absent from the current map
    --    population are ignored and logged, never attached to another field.
    for fieldId, f in pairs(snap.fields or {}) do
        local d = soil.fieldData[fieldId]
        if d ~= nil then
            d.moisture = clamp01(f.moisture ~= nil and f.moisture or 0.50)
            if stressModifier ~= nil and stressModifier.fieldStress ~= nil then
                stressModifier.fieldStress[fieldId] = clamp01(f.stress or 0.0)
            end
            if f.soilType ~= nil and SoilMoistureSystem ~= nil and SoilMoistureSystem.SOIL_PARAMS ~= nil
               and SoilMoistureSystem.SOIL_PARAMS[f.soilType] ~= nil then
                d.soilType = f.soilType
            end
            if f.cells ~= nil and type(soil.unpackCells) == "function" then
                soil:unpackCells(fieldId, f.cells)
            end
            if f.mapPending ~= nil then d.mapPending = f.mapPending end
            result.fieldsApplied = result.fieldsApplied + 1
        else
            result.fieldsIgnored = result.fieldsIgnored + 1
            csLog(string.format("SaveLoadHandler: saved field %s is not in the current map population; row ignored",
                tostring(fieldId)))
        end
    end

    -- 2. The selected envelope's aggregate, revision and cursor install after
    --    cell unpack; a matching PENDING_ONLY row replaces ONLY the pending stores.
    local env = selectedRow ~= nil and selectedRow.payload or nil
    local pending = pendingRow ~= nil and pendingRow.payload or nil
    if env ~= nil then
        for fieldId, agg in pairs(env.aggregates or {}) do
            local d = soil.fieldData[fieldId]
            if d ~= nil then d.moisture = clamp01(agg) end
        end
        soil.moistureRevision = env.moistureRevision
        soil._lastSettledDay = env.lastSettledMonotonicDay
        local pendSrc = pending or env
        for fieldId, d in pairs(soil.fieldData) do
            d.mapPending = (pendSrc.fieldPending or {})[fieldId] or 0
        end
        if type(soil.unpackMapWaterPending) == "function" then
            soil:unpackMapWaterPending(pendSrc.positionalRows or {})
        end
        self._completePair.current = {
            generation = env.generation, digest = env.digest,
            revision = env.moistureRevision,
            lastSettledMonotonicDay = env.lastSettledMonotonicDay,
            envelope = env,
        }
        local previous = nil
        for _, c in ipairs(candidates) do
            if c.payloadKind == "COMPLETE" and c.compactOk and c.source == source
               and type(c.generation) == "number" and c.generation < env.generation
               and (previous == nil or c.generation > previous.generation) then
                previous = c
            end
        end
        self._completePair.previous = previous ~= nil and {
            generation = previous.generation, digest = previous.digest,
            revision = previous.revision,
            lastSettledMonotonicDay = previous.lastSettledMonotonicDay,
            envelope = previous.payload,
        } or nil
        self._pendingOnly = pending
        if mode == "ZONE" and env.filename ~= nil then
            result.declined = string.format("native image %s for generation %d unusable",
                tostring(env.filename), env.generation)
        end
    elseif mode == "ZONE" and pending ~= nil then
        -- Explicit zone recovery: the PENDING_ONLY row supplies only its own
        -- zone state, pending stores and copied base cursor.
        for fieldId, agg in pairs(pending.aggregates or {}) do
            local d = soil.fieldData[fieldId]
            if d ~= nil then d.moisture = clamp01(agg) end
        end
        soil.moistureRevision = pending.baseRevision
        soil._lastSettledDay = pending.baseLastSettledMonotonicDay
        for fieldId, d in pairs(soil.fieldData) do
            d.mapPending = (pending.fieldPending or {})[fieldId] or 0
        end
        if type(soil.unpackMapWaterPending) == "function" then
            soil:unpackMapWaterPending(pending.positionalRows or {})
        end
        self._completePair.current = {
            generation = pending.baseGeneration, digest = nil,
            revision = pending.baseRevision,
            lastSettledMonotonicDay = pending.baseLastSettledMonotonicDay,
            envelope = nil,
        }
        self._completePair.previous = nil
        self._pendingOnly = pending
        result.declined = "no usable COMPLETE native pair; PENDING_ONLY zone recovery"
    else
        -- Legacy scalar schema 2 (or a fresh game): migrate the flat keys with
        -- no absorption allowance.
        --
        -- RSF-F244: the legacy csMoistureMap.grle is imported HERE, never by the
        -- probe, and only on a pre-generation load, where it stays generation 0.
        -- A generation-era load whose envelopes are all unusable declines the
        -- live map to ZONE instead: that legacy picture predates every generation
        -- save, and a fresh fine map would invent detail. With the map not live
        -- (release gate off) there is nothing to import or decline.
        if self:isGenerationEraLoad(candidates) then
            if type(soil.mapActive) == "function" and soil:mapActive() then
                result.declined = "generation-era save with no usable moisture envelope; legacy image not imported"
            end
        elseif type(ctx.legacyProbe) == "function" then
            result.legacyImported = ctx.legacyProbe() == true
        end
        if snap.moistureRevision ~= nil then
            soil.moistureRevision = snap.moistureRevision
            self._completePair.current.revision = snap.moistureRevision
        end
        if snap.lastSettledDay ~= nil then
            soil._lastSettledDay = snap.lastSettledDay
            self._completePair.current.lastSettledMonotonicDay = snap.lastSettledDay
        end
        if snap.saveGeneration ~= nil then
            self._completePair.current.generation = snap.saveGeneration
        end
        if type(snap.mapWaterPending) == "table" and type(soil.unpackMapWaterPending) == "function" then
            soil:unpackMapWaterPending(snap.mapWaterPending)
        end
    end

    -- 3. A selection that names a native image it could not use, or that has no
    --    complete native pair at all, leaves the zone store authoritative: the
    --    live map is declined rather than paired with another generation's file.
    if result.declined ~= nil and type(soil.declineNativeCarrier) == "function" then
        soil:declineNativeCarrier(result.declined)
    end

    -- 4. The absorption leaf, admitted only against the enclosing provider
    --    identity (mode + grain), the current valid hour and live membership.
    local leaf = self:selectedAbsorptionLeaf(env, pending)
    if type(leaf) == "table" then
        leaf = copyAbsorptionLeaf(leaf)
        leaf.outerSchema = ENVELOPE_SCHEMA
    end
    local liveMode = ctx.liveMode or soil.providerMode
    local liveGrain = ctx.liveGrain
    if liveGrain == nil then
        if liveMode == "TRUTH" and soil.valueMap ~= nil
           and type(soil.valueMap.getGrainMetres) == "function" then
            liveGrain = soil.valueMap:getGrainMetres()
        elseif type(soil.getCellSize) == "function" then
            liveGrain = soil:getCellSize()
        end
    end
    local currentHour = ctx.currentHour
    if currentHour == nil and SoilMoistureSystem ~= nil
       and type(SoilMoistureSystem.resolveCurrentHourKey) == "function" then
        local environment = g_currentMission ~= nil and g_currentMission.environment or nil
        local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
        currentHour = SoilMoistureSystem.resolveCurrentHourKey(environment, tg)
    end
    if type(soil.loadAbsorptionWindow) == "function" then
        local _, disposition = soil:loadAbsorptionWindow(leaf, liveMode, liveGrain, currentHour)
        result.absorption = disposition
        if type(soil.pruneAbsorptionMissingFields) == "function" then
            local live = {}
            for fieldId in pairs(soil.fieldData) do live[fieldId] = true end
            result.absorptionPruned = soil:pruneAbsorptionMissingFields(live)
        end
    end

    result.mode = mode
    result.generation = generation
    result.digest = digest
    result.pendingStatus = pendingStatus
    result.provider = soil.providerMode
    csLog(string.format(
        "SaveLoadHandler: mission water restored (%s, generation %s, pending %s, source %s, provider %s, absorption %s, %d fields, %d ignored)",
        tostring(mode), tostring(generation), tostring(pendingStatus), tostring(source),
        tostring(soil.providerMode), tostring(result.absorption),
        result.fieldsApplied, result.fieldsIgnored))
    return result
end

function SaveLoadHandler:delete()
    self.isInitialized = false
end