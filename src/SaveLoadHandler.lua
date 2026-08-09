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
--               activeDays="1,1,1,1,1,0,0"/>
--       ...
--     </irrigation>
--     <npc relationship="35"/>
--   </cropStress>
-- ============================================================

SaveLoadHandler = {}
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
    local soilSystemForMap = self.manager ~= nil and self.manager.soilSystem or nil
    if soilSystemForMap ~= nil and soilSystemForMap.valueMap ~= nil
       and soilSystemForMap.valueMap.available then
        local sgDir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
            and g_currentMission.missionInfo.savegameDirectory or nil
        if sgDir ~= nil then
            soilSystemForMap.valueMap:saveToSavegame(sgDir)
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
            i = i + 1
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
            end
            i = i + 1
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
            -- SCS-018 3.8: packed cell leaf rides the ledger table (nil when no cells).
            if soilSystem.packCells ~= nil then
                entry.cells = soilSystem:packCells(fieldId)
            end
            out.fields[fieldId] = entry
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
                -- SCS-018 3.8: install cells from the ledger-packed leaf.
                if f.cells ~= nil and soilSystem.unpackCells ~= nil then
                    soilSystem:unpackCells(fieldId, f.cells)
                end
                n = n + 1
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

function SaveLoadHandler:delete()
    self.isInitialized = false
end