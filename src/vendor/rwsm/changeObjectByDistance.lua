-- Vendored from FS25_RealisticWaterSoilManagement (Sherman / original HoFFi)
-- for SeasonalCropStress BUILD 21:13 Phase 1. Unmodified except where marked
-- 'SCS vendor note'. Moisture stays on the SCS door: this file does not write
-- soil moisture, and RWSM53WaterControl is deliberately not shipped.
--[[ RWSM53ChangeObjectByDistance 

Author: 		HoFFi (modding-welt.com)

Description: 	script to animate an object according to distance between to nodes

Version: 		1.0.0.1

Changelog: 		2019-03-27 - initial release
				2019-03-29 - added simple text hud with current length of pipe

--------------------------------------------------------------------------------------------------

XML:
	<RWSM53ChangeObjectByDistance>
		<roll CheckNode="1>4|0|0|1|2|1" CheckNodeRef="0>20|2|1|0" objectToChange="0>0"/>
	</RWSM53ChangeObjectByDistance>
	
Explaination:
	CheckNode = TG or object in one part of mod
	CheckNodeRef = TG or object in another part of mod
	objectToChange = object which gets scaled/rotated according to distance

]]


RWSM53ChangeObjectByDistance = {};

RWSM53ChangeObjectByDistance.modDir = g_currentModDirectory;
RWSM53ChangeObjectByDistance.currentModName = g_currentModName;

function RWSM53ChangeObjectByDistance.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("ChangeObjectByDistance")
    -- These values are i3dMapping IDs (for example "hoseStart"), not raw node indices.
    -- Registering them as strings avoids the FS25 "No components given" NODE_INDEX warning.
    schema:register(XMLValueType.STRING, "vehicle.RWSM53ChangeObjectByDistance.roll#CheckNode", "Hose start i3dMapping")
    schema:register(XMLValueType.STRING, "vehicle.RWSM53ChangeObjectByDistance.roll#CheckNodeRef", "Hose end i3dMapping")
    schema:register(XMLValueType.STRING, "vehicle.RWSM53ChangeObjectByDistance.roll#objectToChange", "Visible hose drum i3dMapping")
    schema:register(XMLValueType.FLOAT, "vehicle.RWSM53ChangeObjectByDistance.roll#maxHoseLenght", "Maximum hose length", 220)
    schema:register(XMLValueType.INT, "vehicle.RWSM53ChangeObjectByDistance.roll#hoseObjectCount", "Visible hose layers", 13)
    schema:register(XMLValueType.FLOAT, "vehicle.RWSM53ChangeObjectByDistance.roll#speedScale", "Drum rotation factor", 1)
    schema:setXMLSpecializationType()
end

local function cobdGetValue(xmlFile, path, defaultValue)
    if xmlFile ~= nil and xmlFile.getValue ~= nil then
        local value = xmlFile:getValue(path, defaultValue)
        return value
    end

    if getXMLString ~= nil then
        local value = getXMLString(xmlFile, path)
        if value ~= nil then
            return value
        end
    end

    return defaultValue
end

local function cobdNormalizePath(path)
    if path == nil then
        return ""
    end
    return string.lower(string.gsub(path, "\\", "/"))
end

-- Returns the Euromacchine pump only when it is the actual attacher vehicle
-- of the Rainstar. This is deliberately read-only and does not alter any joint.
local function cobdGetConnectedPump(vehicle)
    if vehicle == nil then
        return nil
    end

    -- 1.38.26: hose-only connection has no physical attacher vehicle. Use the
    -- lightweight back-reference first so normal 100 ms pump-state updates do
    -- not scan the complete vehicle list.
    local virtualPump = vehicle.rwsmVirtualPump
    if virtualPump ~= nil and virtualPump.RPC ~= nil
        and virtualPump.RPC.virtualHoseConnected == true
        and virtualPump.RPC.virtualRainstar == vehicle then
        return virtualPump
    end
    if RWSMPumpConnectionState ~= nil
        and RWSMPumpConnectionState.findVirtualPumpForRainstar ~= nil then
        local ok, found = pcall(RWSMPumpConnectionState.findVirtualPumpForRainstar, vehicle)
        if ok and found ~= nil then return found end
    end

    local pump = nil
    if vehicle.getAttacherVehicle ~= nil then
        local ok, value = pcall(vehicle.getAttacherVehicle, vehicle)
        if ok then
            pump = value
        end
    end

    if pump == nil and vehicle.spec_attachable ~= nil then
        pump = vehicle.spec_attachable.attacherVehicle
    end

    if pump == nil then
        return nil
    end

    local configFileName = cobdNormalizePath(pump.configFileName)
    local isRWSMPump = pump.RPC ~= nil
        or pump.RIS ~= nil
        or string.find(configFileName, "aggregat.xml", 1, true) ~= nil

    if isRWSMPump then
        return pump
    end

    return nil
end

local function cobdIsPumpRunning(pump)
    if pump == nil then
        return false
    end

    if pump.getIsTurnedOn ~= nil then
        local ok, value = pcall(pump.getIsTurnedOn, pump)
        if ok then
            return value == true
        end
    end

    if pump.spec_turnOnVehicle ~= nil and pump.spec_turnOnVehicle.isTurnedOn == true then
        return true
    end

    -- A running diesel engine alone must not start the irrigation effect.
    -- Only the actual pump on/off state may enable water output.
    return false
end

local function cobdUpdatePumpState(vehicle)
    local spec = vehicle ~= nil and vehicle.COBD or nil
    if spec == nil then
        return
    end

    local pump = cobdGetConnectedPump(vehicle)
    local connected = pump ~= nil
    local running = connected and cobdIsPumpRunning(pump)

    spec.connectedPump = pump
    spec.isPumpConnected = connected
    spec.isPumpRunning = running

    local configuredPressure = 8.5
    local configuredRadius = 33
    local configuredFlow = 34
    local configuredStripWidth = 66
    local configuredApplication = 17

    if pump ~= nil and pump.RIS ~= nil then
        configuredPressure = tonumber(pump.RIS.pressure) or configuredPressure
        configuredRadius = tonumber(pump.RIS.radius) or configuredRadius
        configuredFlow = tonumber(pump.RIS.flow) or configuredFlow
        configuredStripWidth = tonumber(pump.RIS.stripWidth) or (configuredRadius * 2)
        configuredApplication = tonumber(pump.RIS.applicationDepth) or configuredApplication
    end

    spec.sprayRadius = configuredRadius
    spec.workingWidth = configuredStripWidth
    spec.configuredPressure = configuredPressure
    spec.configuredWaterFlow = configuredFlow
    spec.applicationDepth = configuredApplication
    spec.pumpPressure = running and configuredPressure or 0
    spec.waterFlow = running and configuredFlow or 0

    if spec.roll ~= nil and spec.roll.workingWidth2 ~= nil then
        local _, widthY, widthZ = getTranslation(spec.roll.workingWidth2)
        setTranslation(
            spec.roll.workingWidth2,
            configuredStripWidth,
            widthY,
            widthZ
        )
    end

    local stateKey = string.format(
        "%s:%s:%.1f:%.0f",
        tostring(connected),
        tostring(running),
        configuredPressure,
        configuredRadius
    )
    if spec.lastPumpStateKey ~= stateKey then
        spec.lastPumpStateKey = stateKey
        print(string.format(
            "[RWSM v0.63] Pump status: connected=%s running=%s pressure=%.1f bar radius=%.0f m flow=%.1f m3/h",
            tostring(connected),
            tostring(running),
            spec.pumpPressure or 0,
            spec.sprayRadius or 33,
            spec.waterFlow or 0
        ))
    end
end

local function cobdResolveNode(vehicle, path, defaultValue)
    -- The Rainstar XML stores i3dMapping IDs such as "hoseStart" and
    -- "Trommel_vis". Resolve those mapping strings explicitly.
    local mapping = cobdGetValue(vehicle.xmlFile, path, defaultValue)
    if mapping == nil or mapping == "" then
        return nil
    end

    local node = I3DUtil.indexToObject(vehicle.components, mapping, vehicle.i3dMappings)
    if node == nil or node == 0 then
        return nil
    end
    return node
end


-- RWSM 1.38.4: terrain-following hose with native GIANTS fallback between reel and sprinkler cart.
-- The hose does not drive irrigation, physics, reel speed or savegame state; those remain
-- controlled by the existing Rainstar specializations. The reference mesh comes from the
-- provided IrriFrance implementation, but no other functions from that mod are used.
-- SCS vendor note (BUILD 21:13): the kit lives under vehicles/irrigatorPlay/
-- so the whole thing stays swap-art replaceable in one folder. Retargeted here
-- rather than duplicating the 11.6 MB shapes blob at the mod root.
local RWSM_GROUND_HOSE_I3D = "vehicles/irrigatorPlay/i3d/rwsmGroundHoseTemplate.i3d"
local RWSM_GROUND_HOSE_SEGMENT_LENGTH = 0.05
local RWSM_GROUND_HOSE_TEMPLATE_LENGTH = 0.5
local RWSM_GROUND_HOSE_CLEARANCE = 0.09
local RWSM_GROUND_HOSE_UPDATE_MS = 100
local RWSM_GROUND_HOSE_ENDPOINT_BLEND = 6.0

local function cobdFindNodeByName(node, wantedName)
    if node == nil or node == 0 then
        return nil
    end
    if getName ~= nil and getName(node) == wantedName then
        return node
    end
    local count = getNumOfChildren ~= nil and getNumOfChildren(node) or 0
    for i = 0, count - 1 do
        local found = cobdFindNodeByName(getChildAt(node, i), wantedName)
        if found ~= nil then
            return found
        end
    end
    return nil
end

local function cobdGroundHeight(x, z)
    local terrainNode = g_currentMission ~= nil and g_currentMission.terrainRootNode or g_terrainNode
    if terrainNode == nil or getTerrainHeightAtWorldPos == nil then
        return 0
    end
    return getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
end

local function cobdSmoothStep(t)
    t = math.max(0, math.min(1, t or 0))
    return t * t * (3 - 2 * t)
end

local function cobdGroundHosePointY(distance, totalDistance, endpointY, terrainY, fromStart)
    local groundY = terrainY + RWSM_GROUND_HOSE_CLEARANCE
    local blendLength = math.min(RWSM_GROUND_HOSE_ENDPOINT_BLEND, math.max(0.01, totalDistance * 0.5))
    local edgeDistance = fromStart and distance or (totalDistance - distance)
    if edgeDistance < blendLength then
        local t = cobdSmoothStep(edgeDistance / blendLength)
        local safeEndpointY = math.max(endpointY or groundY, groundY)
        return safeEndpointY * (1 - t) + groundY * t
    end
    return groundY
end

local function cobdSetNativeLongHoseVisible(vehicle, visible)
    if vehicle == nil or not vehicle.isClient then return end
    local cs = vehicle.spec_connectionHoses
    local entry = cs ~= nil and cs.localHoseNodes ~= nil and cs.localHoseNodes[1] or nil
    local hose = entry ~= nil and entry.hose or nil
    local node = hose ~= nil and (hose.visibilityNode or hose.hoseNode) or nil
    if node ~= nil and node ~= 0 then
        setVisibility(node, visible == true)
    end
end

local function cobdHideGroundHose(spec)
    if spec == nil or spec.groundHoseSegments == nil then
        return
    end
    for _, seg in ipairs(spec.groundHoseSegments) do
        if seg ~= nil and seg ~= 0 then
            setVisibility(seg, false)
        end
    end
end

local function cobdLoadGroundHoseTemplate(vehicle)
    local spec = vehicle ~= nil and vehicle.COBD or nil
    if spec == nil or not vehicle.isClient or loadI3DFile == nil then
        return
    end

    local filename = Utils.getFilename(RWSM_GROUND_HOSE_I3D, RWSM53ChangeObjectByDistance.modDir)
    local rootNode, sharedRequestId, failedReason
    if g_i3DManager ~= nil and g_i3DManager.loadSharedI3DFile ~= nil then
        rootNode, sharedRequestId, failedReason = g_i3DManager:loadSharedI3DFile(filename, false, false, false)
    else
        rootNode, failedReason = loadI3DFile(filename, false, false, false)
    end
    if rootNode == nil or rootNode == 0 then
        print(string.format("[RWSM v1.38.6] Warning: ground hose template could not be loaded (%s)", tostring(failedReason)))
        if sharedRequestId ~= nil and g_i3DManager ~= nil then
            g_i3DManager:releaseSharedI3DFile(sharedRequestId)
        end
        return
    end

    local template = cobdFindNodeByName(rootNode, "rwsmGroundHoseTemplate")
    if template == nil then
        delete(rootNode)
        print("[RWSM v1.38.6] Warning: ground hose template node missing")
        return
    end

    if getParent(rootNode) == nil or getParent(rootNode) == 0 then
        link(getRootNode(), rootNode)
    end
    setVisibility(rootNode, true)
    setVisibility(template, false)
    spec.groundHoseTemplateRoot = rootNode
    spec.groundHoseSharedRequestId = sharedRequestId
    spec.groundHoseTemplate = template
    spec.groundHoseSegments = {}
    spec.groundHoseTimer = RWSM_GROUND_HOSE_UPDATE_MS
    spec.groundHoseCustomVisible = false
end

local function cobdUpdateGroundHose(vehicle, dt, startX, startY, startZ, endX, endY, endZ)
    local spec = vehicle ~= nil and vehicle.COBD or nil
    if spec == nil or not vehicle.isClient then return end
    if spec.groundHoseTemplate == nil then
        spec.groundHoseCustomVisible = false
        cobdSetNativeLongHoseVisible(vehicle, true)
        return
    end

    spec.groundHoseTimer = (spec.groundHoseTimer or 0) + (tonumber(dt) or 0)
    if spec.groundHoseTimer < RWSM_GROUND_HOSE_UPDATE_MS then
        return
    end
    spec.groundHoseTimer = spec.groundHoseTimer - RWSM_GROUND_HOSE_UPDATE_MS

    -- Performance: the complete terrain path is only rebuilt when one of the
    -- two hose endpoints has actually moved.  While parked there are no
    -- terrain queries and no segment transforms.
    if spec.groundHoseLastStartX ~= nil then
        local sdx = startX - spec.groundHoseLastStartX
        local sdy = startY - spec.groundHoseLastStartY
        local sdz = startZ - spec.groundHoseLastStartZ
        local edx = endX - spec.groundHoseLastEndX
        local edy = endY - spec.groundHoseLastEndY
        local edz = endZ - spec.groundHoseLastEndZ
        local movedSq = sdx * sdx + sdy * sdy + sdz * sdz + edx * edx + edy * edy + edz * edz
        if movedSq < 0.000225 then -- about 1.5 cm combined endpoint movement
            return
        end
    end

    spec.groundHoseLastStartX, spec.groundHoseLastStartY, spec.groundHoseLastStartZ = startX, startY, startZ
    spec.groundHoseLastEndX, spec.groundHoseLastEndY, spec.groundHoseLastEndZ = endX, endY, endZ

    local dx = endX - startX
    local dz = endZ - startZ
    local totalDistance = math.sqrt(dx * dx + dz * dz)
    if totalDistance < 0.15 then
        cobdHideGroundHose(spec)
        spec.groundHoseCustomVisible = false
        cobdSetNativeLongHoseVisible(vehicle, true)
        return
    end

    -- RWSM 1.38.30: 5 cm visual hose segments over the complete distance for softer hose bending.
    -- The reference mesh remains 0.5 m long and is scaled to each 0.10 m
    -- terrain-following section; irrigation/reel physics remain untouched.
    local requiredSegments = math.min(
        math.ceil(totalDistance / RWSM_GROUND_HOSE_SEGMENT_LENGTH),
        math.ceil((spec.roll.maxHoseLenght or 220) / RWSM_GROUND_HOSE_SEGMENT_LENGTH) + 2
    )

    while #spec.groundHoseSegments < requiredSegments do
        local seg = clone(spec.groundHoseTemplate, false, false, false)
        if seg == nil or seg == 0 then
            break
        end
        link(getRootNode(), seg)
        setVisibility(seg, false)
        table.insert(spec.groundHoseSegments, seg)
    end

    local usableSegments = math.min(requiredSegments, #spec.groundHoseSegments)
    if usableSegments <= 0 then
        spec.groundHoseCustomVisible = false
        cobdSetNativeLongHoseVisible(vehicle, true)
        return
    end

    -- Reuse point buffers so the moving hose does not create hundreds of Lua
    -- tables every update.  Every terrain position is sampled exactly once.
    local px = spec.groundHosePointX or {}
    local py = spec.groundHosePointY or {}
    local pz = spec.groundHosePointZ or {}
    spec.groundHosePointX = px
    spec.groundHosePointY = py
    spec.groundHosePointZ = pz

    for pointIndex = 0, usableSegments do
        local distance = math.min(pointIndex * RWSM_GROUND_HOSE_SEGMENT_LENGTH, totalDistance)
        local t = distance / totalDistance
        local x = startX + dx * t
        local z = startZ + dz * t
        local terrainY = cobdGroundHeight(x, z)

        local y
        if distance <= totalDistance * 0.5 then
            y = cobdGroundHosePointY(distance, totalDistance, startY, terrainY, true)
        else
            y = cobdGroundHosePointY(distance, totalDistance, endY, terrainY, false)
        end

        local idx = pointIndex + 1
        px[idx] = x
        py[idx] = y
        pz[idx] = z
    end

    -- The final point must always be the exact hose endpoint in X/Z.  Its Y is
    -- blended down to the terrain by cobdGroundHosePointY, preventing the last
    -- metres from becoming a rigid floating rod.
    local visibleSegments = 0
    for i = 1, usableSegments do
        local x1, y1, z1 = px[i], py[i], pz[i]
        local x2, y2, z2 = px[i + 1], py[i + 1], pz[i + 1]
        local seg = spec.groundHoseSegments[i]

        local dirX = x2 - x1
        local dirY = y2 - y1
        local dirZ = z2 - z1
        local length = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)

        if length > 0.001 then
            -- Slight overlap hides the tiny joints between rigid template
            -- pieces and makes the 10 cm chain read as one continuously
            -- bending hose on uneven terrain.
            local visualLength = length + 0.035
            setDirection(seg, dirX / length, dirY / length, dirZ / length, 0, 1, 0)
            setScale(seg, 1, 1, visualLength / RWSM_GROUND_HOSE_TEMPLATE_LENGTH)
            setTranslation(seg, x1, y1, z1)
            setVisibility(seg, true)
            visibleSegments = visibleSegments + 1
        else
            setVisibility(seg, false)
        end
    end

    for i = usableSegments + 1, #spec.groundHoseSegments do
        setVisibility(spec.groundHoseSegments[i], false)
    end

    spec.groundHoseCustomVisible = visibleSegments > 0
    cobdSetNativeLongHoseVisible(vehicle, not spec.groundHoseCustomVisible)
end

function RWSM53ChangeObjectByDistance.prerequisitesPresent(specializations)
    return true; 
end;

function RWSM53ChangeObjectByDistance.registerEventListeners(vehicleType)
	for _, spec in pairs({"onLoad", "onDelete", "onUpdate", "onUpdateEnd", "onReadStream", "onWriteStream"}) do
		SpecializationUtil.registerEventListener(vehicleType, spec, RWSM53ChangeObjectByDistance)
	end
end

function RWSM53ChangeObjectByDistance:onUpdateEnd(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if self.COBD ~= nil and self.isClient then
        cobdSetNativeLongHoseVisible(self, self.COBD.groundHoseCustomVisible ~= true)
    end
end

function RWSM53ChangeObjectByDistance.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getIsFoldAllowed", RWSM53ChangeObjectByDistance.getIsFoldAllowed)
end

-- Prevents the transport lock from pulling an extended sprinkler cart instantly back to the reel.
-- The cart must be within 3 m of the reel before transport mode can be selected.
function RWSM53ChangeObjectByDistance:getIsFoldAllowed(superFunc, direction, onAiTurnOn)
    local allowed, warning = superFunc(self, direction, onAiTurnOn)
    if not allowed then
        return allowed, warning
    end

    local spec = self.COBD
    if spec ~= nil and not spec.disabled and direction ~= nil and direction > 0 and (spec.distance or 0) > 3 then
        return false, g_i18n:getText("warning_RAINSTAR_HOSE_EXTENDED")
    end

    return true, nil
end

function RWSM53ChangeObjectByDistance:onLoad(savegame)
	self.COBD = {};
	self.COBD.roll = {};
	self.COBD.roll.CheckNode = cobdResolveNode(self, "vehicle.RWSM53ChangeObjectByDistance.roll#CheckNode");
	self.COBD.roll.CheckNodeRef = cobdResolveNode(self, "vehicle.RWSM53ChangeObjectByDistance.roll#CheckNodeRef");
	self.COBD.roll.objectToChange = cobdResolveNode(self, "vehicle.RWSM53ChangeObjectByDistance.roll#objectToChange");
	self.COBD.roll.workingWidth1 = I3DUtil.indexToObject(self.components, "workAreaStart", self.i3dMappings);
	self.COBD.roll.workingWidth2 = I3DUtil.indexToObject(self.components, "workAreaWidth", self.i3dMappings);
	self.COBD.roll.maxHoseLenght = tonumber(cobdGetValue(self.xmlFile, "vehicle.RWSM53ChangeObjectByDistance.roll#maxHoseLenght", 220)) or 220;
	self.COBD.roll.hoseObjectCount = tonumber(cobdGetValue(self.xmlFile, "vehicle.RWSM53ChangeObjectByDistance.roll#hoseObjectCount", 13)) or 13;
	self.COBD.roll.speedScale = tonumber(cobdGetValue(self.xmlFile, "vehicle.RWSM53ChangeObjectByDistance.roll#speedScale", 1)) or 1;
	self.COBD.distance = 0;
	self.COBD.sprayRadius = 33;
	self.COBD.workingWidth = 66;
	self.COBD.configuredPressure = 8.5;
	self.COBD.configuredWaterFlow = 34;
	self.COBD.waterFlow = 0;
	self.COBD.applicationDepth = 17;
	self.COBD.textsize = 0.014
	self.COBD.connectedPump = nil
	self.COBD.isPumpConnected = false
	self.COBD.isPumpRunning = false
	self.COBD.pumpPressure = 0
	self.COBD.lastPumpStateKey = nil
	self.COBD.lastDrumDistance = nil
	self.COBD.drumRotationOffset = nil
	if g_currentMission ~= nil and g_currentMission.hud ~= nil and g_currentMission.hud.speedMeter ~= nil and g_currentMission.hud.speedMeter.cruiseControlTextSize ~= nil then
		self.COBD.textsize = g_currentMission.hud.speedMeter.cruiseControlTextSize * 1.5
	end
	
	self.COBD.roll1 = I3DUtil.indexToObject(self.components, "Schlauch1_vis", self.i3dMappings);
	self.COBD.roll2 = I3DUtil.indexToObject(self.components, "Schlauch2_vis", self.i3dMappings);
	self.COBD.roll3 = I3DUtil.indexToObject(self.components, "Schlauch3_vis", self.i3dMappings);
	self.COBD.roll4 = I3DUtil.indexToObject(self.components, "Schlauch4_vis", self.i3dMappings);
	self.COBD.roll5 = I3DUtil.indexToObject(self.components, "Schlauch5_vis", self.i3dMappings);
	self.COBD.roll6 = I3DUtil.indexToObject(self.components, "Schlauch6_vis", self.i3dMappings);
	self.COBD.roll7 = I3DUtil.indexToObject(self.components, "Schlauch7_vis", self.i3dMappings);
	self.COBD.roll8 = I3DUtil.indexToObject(self.components, "Schlauch8_vis", self.i3dMappings);
	self.COBD.roll9 = I3DUtil.indexToObject(self.components, "Schlauch9_vis", self.i3dMappings);
	self.COBD.roll10 = I3DUtil.indexToObject(self.components, "Schlauch10_vis", self.i3dMappings);
	self.COBD.roll11 = I3DUtil.indexToObject(self.components, "Schlauch11_vis", self.i3dMappings);
	self.COBD.roll12 = I3DUtil.indexToObject(self.components, "Schlauch12_vis", self.i3dMappings);
	self.COBD.roll13 = I3DUtil.indexToObject(self.components, "Schlauch13_vis", self.i3dMappings);
	self.COBD.Halter = I3DUtil.indexToObject(self.components, "Strebe2_vis", self.i3dMappings);
	
	
	self.COBD.HudPressure1 = I3DUtil.indexToObject(self.components, "HudPressure1", self.i3dMappings);
	self.COBD.HudPressure2 = I3DUtil.indexToObject(self.components, "HudPressure2", self.i3dMappings);
	self.COBD.HudLength1 = I3DUtil.indexToObject(self.components, "HudLength1", self.i3dMappings);
	self.COBD.HudLength2 = I3DUtil.indexToObject(self.components, "HudLength2", self.i3dMappings);
	
	self.COBD.scaleAmount13 = 1;
	self.COBD.scaleAmount12 = 1;
	self.COBD.scaleAmount11 = 1;
	self.COBD.scaleAmount10 = 1;
	self.COBD.scaleAmount9 = 1;
	self.COBD.scaleAmount8 = 1;
	self.COBD.scaleAmount7 = 1;
	self.COBD.scaleAmount6 = 1;
	self.COBD.scaleAmount5 = 1;
	self.COBD.scaleAmount4 = 1;
	self.COBD.scaleAmount3 = 1;
	self.COBD.scaleAmount2 = 1;
	self.COBD.scaleAmount1 = 1;
	self.COBD.transAmount1 = 0;
	self.COBD.pumpStateTimer = 100;
	self.COBD.visualLayerTimer = 100;
	self.COBD.lastVisualLayerDistance = nil;
	self.COBD.groundHoseSegments = {};
	self.COBD.groundHoseTemplate = nil;
	self.COBD.groundHoseTemplateRoot = nil;
	self.COBD.groundHoseSharedRequestId = nil;
	self.COBD.groundHoseTimer = RWSM_GROUND_HOSE_UPDATE_MS;
	self.COBD.groundHoseLastStartX = nil;
	self.COBD.groundHoseLastEndX = nil;
	self.COBD.groundHoseCustomVisible = false;

	self.COBD.disabled = self.COBD.roll.CheckNode == nil
		or self.COBD.roll.CheckNodeRef == nil
		or self.COBD.roll.objectToChange == nil
		or self.COBD.roll.workingWidth1 == nil
		or self.COBD.roll.workingWidth2 == nil

	if self.COBD.disabled then
		print(string.format(
            "[RWSM v0.54] Warning: drum nodes unresolved start=%s end=%s drum=%s widthStart=%s widthEnd=%s",
            tostring(self.COBD.roll.CheckNode ~= nil),
            tostring(self.COBD.roll.CheckNodeRef ~= nil),
            tostring(self.COBD.roll.objectToChange ~= nil),
            tostring(self.COBD.roll.workingWidth1 ~= nil),
            tostring(self.COBD.roll.workingWidth2 ~= nil)
        ))
	else
		cobdLoadGroundHoseTemplate(self)
		local rx, ry, rz = getRotation(self.COBD.roll.objectToChange)
		self.COBD.baseDrumRotX = rx or 0
		self.COBD.baseDrumRotY = ry or 0
		self.COBD.baseDrumRotZ = rz or 0
		print("[RWSM v0.54] Dynamic drum and hose-layer animation active; manual pull-out rotation restored")
	end
end;


function RWSM53ChangeObjectByDistance:onUpdate(dt)
	if self.COBD == nil or self.COBD.disabled then
		return
	end

	local sx, sy, sz = getWorldTranslation(self.COBD.roll.CheckNode)
	local ex, ey, ez = getWorldTranslation(self.COBD.roll.CheckNodeRef)
	local dx = sx - ex
	local dz = sz - ez
	self.COBD.distance = math.sqrt(dx * dx + dz * dz)

	-- Visual only: the long hose follows terrain independently of irrigation and reel logic.
	cobdUpdateGroundHose(self, dt, sx, sy, sz, ex, ey, ez)
	
	-- Pump/connection state and configured working width only need a 10 Hz
	-- refresh. The former per-frame connection scan and node translation were
	-- among the most expensive Rainstar update paths.
	self.COBD.pumpStateTimer = (self.COBD.pumpStateTimer or 0) + (tonumber(dt) or 0)
	if self.COBD.pumpStateTimer >= 100 then
		self.COBD.pumpStateTimer = self.COBD.pumpStateTimer - 100
		cobdUpdatePumpState(self)
	end
	
	-- Accumulated visual drum rotation.
	-- Hose distance and drum rotation must use opposite signs:
	-- pulling the cart out unwinds the drum, while decreasing distance winds it in.
	-- This also preserves the already correct automatic-reel direction.
	if self.COBD.lastDrumDistance == nil then
		self.COBD.drumRotationOffset =
			-self.COBD.distance * self.COBD.roll.speedScale
	else
		local distanceDelta =
			self.COBD.distance - self.COBD.lastDrumDistance

		self.COBD.drumRotationOffset =
			(self.COBD.drumRotationOffset or 0)
			- distanceDelta * self.COBD.roll.speedScale
	end

	self.COBD.lastDrumDistance =
		self.COBD.distance

	setRotation(
		self.COBD.roll.objectToChange,
		self.COBD.baseDrumRotX or 0,
		self.COBD.baseDrumRotY or 0,
		(self.COBD.baseDrumRotZ or 0)
			+ (self.COBD.drumRotationOffset or 0)
	);
	
	-- Updating all 13 hose-layer transforms every render frame is unnecessary.
	-- The drum itself remains smooth above; layer scale and HUD values refresh at
	-- 10 Hz, or immediately after a larger hose-length change.
	self.COBD.visualLayerTimer = (self.COBD.visualLayerTimer or 0) + (tonumber(dt) or 0)
	local lastVisualDistance = tonumber(self.COBD.lastVisualLayerDistance)
	local visualDistanceDelta = lastVisualDistance == nil
		and math.huge or math.abs(self.COBD.distance - lastVisualDistance)
	if self.COBD.visualLayerTimer < 100 and visualDistanceDelta < 0.25 then
		return
	end
	self.COBD.visualLayerTimer = 0
	self.COBD.lastVisualLayerDistance = self.COBD.distance
	
	--get length steps of each roll
	local roll1MaxLenght = self.COBD.roll.maxHoseLenght / 36
	
	
	
	if self.COBD.distance < roll1MaxLenght then
		self.COBD.scaleAmount1 = 1 - ((self.COBD.distance / roll1MaxLenght) / 8)
	elseif self.COBD.distance >= roll1MaxLenght*1 and self.COBD.distance < roll1MaxLenght*2 then
		self.COBD.scaleAmount2 = 1 - (((self.COBD.distance - (roll1MaxLenght * 1)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*2 and self.COBD.distance < roll1MaxLenght*3 then
		self.COBD.scaleAmount3 = 1 - (((self.COBD.distance - (roll1MaxLenght * 2)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*3 and self.COBD.distance < roll1MaxLenght*4 then
		self.COBD.scaleAmount4 = 1 - (((self.COBD.distance - (roll1MaxLenght * 3)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount3 = 0.875
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*4 and self.COBD.distance < roll1MaxLenght*5 then
		self.COBD.scaleAmount5 = 1 - (((self.COBD.distance - (roll1MaxLenght * 4)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount4 = 0.875
		self.COBD.scaleAmount3 = 0.875
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*5 and self.COBD.distance < roll1MaxLenght*6 then
		self.COBD.scaleAmount6 = 1 - (((self.COBD.distance - (roll1MaxLenght * 5)) / roll1MaxLenght) / 4)
		self.COBD.scaleAmount5 = 0.875
		self.COBD.scaleAmount4 = 0.875
		self.COBD.scaleAmount3 = 0.875
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*6 and self.COBD.distance < roll1MaxLenght*7 then
		self.COBD.scaleAmount5 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 6)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount4 = 0.875
		self.COBD.scaleAmount3 = 0.875
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*7 and self.COBD.distance < roll1MaxLenght*8 then
		self.COBD.scaleAmount4 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 7)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount3 = 0.875
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*8 and self.COBD.distance < roll1MaxLenght*9 then
		self.COBD.scaleAmount3 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 8)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount2 = 0.875
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*9 and self.COBD.distance < roll1MaxLenght*10 then
		self.COBD.scaleAmount2 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 9)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount1 = 0.875
	elseif self.COBD.distance >= roll1MaxLenght*10 and self.COBD.distance < roll1MaxLenght*11 then
		self.COBD.scaleAmount1 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 10)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*11 and self.COBD.distance < roll1MaxLenght*12 then
		self.COBD.scaleAmount7 = 1 - (((self.COBD.distance - (roll1MaxLenght * 11)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*12 and self.COBD.distance < roll1MaxLenght*13 then
		self.COBD.scaleAmount8 = 1 - (((self.COBD.distance - (roll1MaxLenght * 12)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*13 and self.COBD.distance < roll1MaxLenght*14 then
		self.COBD.scaleAmount9 = 1 - (((self.COBD.distance - (roll1MaxLenght * 13)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*14 and self.COBD.distance < roll1MaxLenght*15 then
		self.COBD.scaleAmount10 = 1 - (((self.COBD.distance - (roll1MaxLenght * 14)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*15 and self.COBD.distance < roll1MaxLenght*16 then
		self.COBD.scaleAmount11 = 1 - (((self.COBD.distance - (roll1MaxLenght * 15)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount10 = 0.875
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*16 and self.COBD.distance < roll1MaxLenght*17 then
		self.COBD.scaleAmount12 = 1 - (((self.COBD.distance - (roll1MaxLenght * 16)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount11 = 0.875
		self.COBD.scaleAmount10 = 0.875
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*17 and self.COBD.distance < roll1MaxLenght*18 then
		self.COBD.scaleAmount13 = 1 - (((self.COBD.distance - (roll1MaxLenght * 17)) / roll1MaxLenght) / 4)
		self.COBD.scaleAmount12 = 0.875
		self.COBD.scaleAmount11 = 0.875
		self.COBD.scaleAmount10 = 0.875
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*18 and self.COBD.distance < roll1MaxLenght*19 then
		self.COBD.scaleAmount12 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 18)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount11 = 0.875
		self.COBD.scaleAmount10 = 0.875
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*19 and self.COBD.distance < roll1MaxLenght*20 then
		self.COBD.scaleAmount11 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 19)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount10 = 0.875
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*20 and self.COBD.distance < roll1MaxLenght*21 then
		self.COBD.scaleAmount10 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 20)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount9 = 0.875
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*21 and self.COBD.distance < roll1MaxLenght*22 then
		self.COBD.scaleAmount9 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 21)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount8 = 0.875
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*22 and self.COBD.distance < roll1MaxLenght*23 then
		self.COBD.scaleAmount8 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 22)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount7 = 0.875
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*23 and self.COBD.distance < roll1MaxLenght*24 then
		self.COBD.scaleAmount7 = 0.875 - (((self.COBD.distance - (roll1MaxLenght * 23)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
		self.COBD.scaleAmount1 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*24 and self.COBD.distance < roll1MaxLenght*25 then
		self.COBD.scaleAmount1 = 0.75 - (((self.COBD.distance - (roll1MaxLenght * 24)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount2 = 0.75
	elseif self.COBD.distance >= roll1MaxLenght*25 and self.COBD.distance < roll1MaxLenght*26 then
		self.COBD.scaleAmount2 = 0.75 - (((self.COBD.distance - (roll1MaxLenght * 25)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount3 = 0.75
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*26 and self.COBD.distance < roll1MaxLenght*27 then
		self.COBD.scaleAmount3 = 0.75 - (((self.COBD.distance - (roll1MaxLenght * 26)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount4 = 0.75
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*27 and self.COBD.distance < roll1MaxLenght*28 then
		self.COBD.scaleAmount4 = 0.75 - (((self.COBD.distance - (roll1MaxLenght * 27)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount5 = 0.75
		self.COBD.scaleAmount3 = 0.625
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*28 and self.COBD.distance < roll1MaxLenght*29 then
		self.COBD.scaleAmount5 = 0.75 - (((self.COBD.distance - (roll1MaxLenght * 28)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.75
		self.COBD.scaleAmount4 = 0.625
		self.COBD.scaleAmount3 = 0.625
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*29  and self.COBD.distance < roll1MaxLenght*30 then
		self.COBD.scaleAmount6 = 0.75 - (((self.COBD.distance - (roll1MaxLenght * 29)) / roll1MaxLenght) / 4)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount5 = 0.625
		self.COBD.scaleAmount4 = 0.625
		self.COBD.scaleAmount3 = 0.625
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*30  and self.COBD.distance < roll1MaxLenght*31 then
		self.COBD.scaleAmount5 = 0.625 - (((self.COBD.distance - (roll1MaxLenght * 30)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.5
		self.COBD.scaleAmount4 = 0.625
		self.COBD.scaleAmount3 = 0.625
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*31  and self.COBD.distance < roll1MaxLenght*32 then
		self.COBD.scaleAmount4 = 0.625 - (((self.COBD.distance - (roll1MaxLenght * 31)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.5
		self.COBD.scaleAmount5 = 0.5
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount3 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*32  and self.COBD.distance < roll1MaxLenght*33 then
		self.COBD.scaleAmount3 = 0.625 - (((self.COBD.distance - (roll1MaxLenght * 32)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.5
		self.COBD.scaleAmount5 = 0.5
		self.COBD.scaleAmount4 = 0.5
		self.COBD.scaleAmount2 = 0.625
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*33  and self.COBD.distance < roll1MaxLenght*34 then
		self.COBD.scaleAmount2 = 0.625 - (((self.COBD.distance - (roll1MaxLenght * 33)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.5
		self.COBD.scaleAmount5 = 0.5
		self.COBD.scaleAmount4 = 0.5
		self.COBD.scaleAmount3 = 0.5
		self.COBD.scaleAmount1 = 0.625
	elseif self.COBD.distance >= roll1MaxLenght*34  and self.COBD.distance < roll1MaxLenght*35 then
		self.COBD.scaleAmount1 = 0.625 - (((self.COBD.distance - (roll1MaxLenght * 34)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.75
		self.COBD.scaleAmount6 = 0.5
		self.COBD.scaleAmount5 = 0.5
		self.COBD.scaleAmount4 = 0.5
		self.COBD.scaleAmount3 = 0.5
		self.COBD.scaleAmount2 = 0.5
	elseif self.COBD.distance >= roll1MaxLenght*35  and self.COBD.distance < roll1MaxLenght*36 then
		self.COBD.scaleAmount6 = 0.625 - (((self.COBD.distance - (roll1MaxLenght * 35)) / roll1MaxLenght) / 8)
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.625
		self.COBD.scaleAmount5 = 0.5
		self.COBD.scaleAmount4 = 0.5
		self.COBD.scaleAmount3 = 0.5
		self.COBD.scaleAmount2 = 0.5
		self.COBD.scaleAmount1 = 0.5
	else
		self.COBD.scaleAmount13 = 0.75
		self.COBD.scaleAmount12 = 0.75
		self.COBD.scaleAmount11 = 0.75
		self.COBD.scaleAmount10 = 0.75
		self.COBD.scaleAmount9 = 0.75
		self.COBD.scaleAmount8 = 0.75
		self.COBD.scaleAmount7 = 0.625
		self.COBD.scaleAmount6 = 0.5
		self.COBD.scaleAmount5 = 0.5
		self.COBD.scaleAmount4 = 0.5
		self.COBD.scaleAmount3 = 0.5
		self.COBD.scaleAmount2 = 0.5
		self.COBD.scaleAmount1 = 0.5
	end
	
	
	if self.COBD.distance < roll1MaxLenght*6 then
		self.COBD.transAmount1 = -0.497 + (((self.COBD.distance - (roll1MaxLenght * 6)) / roll1MaxLenght) / -10)
	elseif self.COBD.distance >= roll1MaxLenght*6  and  self.COBD.distance < roll1MaxLenght*18 then
		self.COBD.transAmount1 = 0.503 - ((((self.COBD.distance - (roll1MaxLenght * 6)) - (roll1MaxLenght * 12)) / roll1MaxLenght) / -12)
	elseif self.COBD.distance >= roll1MaxLenght*18  and  self.COBD.distance < roll1MaxLenght*30 then
		self.COBD.transAmount1 = 0.503 + ((((self.COBD.distance - (roll1MaxLenght * 6)) - (roll1MaxLenght * 12)) / roll1MaxLenght) / -12)
	elseif self.COBD.distance >= roll1MaxLenght*30	and  self.COBD.distance < roll1MaxLenght*42 then
		self.COBD.transAmount1 = -0.997 - ((((self.COBD.distance - (roll1MaxLenght * 6)) - (roll1MaxLenght * 12)) / roll1MaxLenght) / -12)
	else
		self.COBD.transAmount1 = -0.497
	end
	
	
	-- 1.38.24: the old LS19 layer logic never reached a visually empty drum.
	-- Multiply all 13 hose rows by the REAL remaining hose ratio so the drum is
	-- practically bare at 220 m and fills back up smoothly during retraction.
	local maxHose = math.max(1, tonumber(self.COBD.roll.maxHoseLenght) or 220)
	local remainingRatio = math.max(0, math.min(1, (maxHose - self.COBD.distance) / maxHose))
	local remainingVisualFactor = 0.015 + 0.985 * math.sqrt(remainingRatio)
	setScale(self.COBD.roll1, self.COBD.scaleAmount1 * remainingVisualFactor, self.COBD.scaleAmount1 * remainingVisualFactor, 1);
	setScale(self.COBD.roll2, self.COBD.scaleAmount2 * remainingVisualFactor, self.COBD.scaleAmount2 * remainingVisualFactor, 1);
	setScale(self.COBD.roll3, self.COBD.scaleAmount3 * remainingVisualFactor, self.COBD.scaleAmount3 * remainingVisualFactor, 1);
	setScale(self.COBD.roll4, self.COBD.scaleAmount4 * remainingVisualFactor, self.COBD.scaleAmount4 * remainingVisualFactor, 1);
	setScale(self.COBD.roll5, self.COBD.scaleAmount5 * remainingVisualFactor, self.COBD.scaleAmount5 * remainingVisualFactor, 1);
	setScale(self.COBD.roll6, self.COBD.scaleAmount6 * remainingVisualFactor, self.COBD.scaleAmount6 * remainingVisualFactor, 1);
	setScale(self.COBD.roll7, self.COBD.scaleAmount7 * remainingVisualFactor, self.COBD.scaleAmount7 * remainingVisualFactor, 1);
	setScale(self.COBD.roll8, self.COBD.scaleAmount8 * remainingVisualFactor, self.COBD.scaleAmount8 * remainingVisualFactor, 1);
	setScale(self.COBD.roll9, self.COBD.scaleAmount9 * remainingVisualFactor, self.COBD.scaleAmount9 * remainingVisualFactor, 1);
	setScale(self.COBD.roll10, self.COBD.scaleAmount10 * remainingVisualFactor, self.COBD.scaleAmount10 * remainingVisualFactor, 1);
	setScale(self.COBD.roll11, self.COBD.scaleAmount11 * remainingVisualFactor, self.COBD.scaleAmount11 * remainingVisualFactor, 1);
	setScale(self.COBD.roll12, self.COBD.scaleAmount12 * remainingVisualFactor, self.COBD.scaleAmount12 * remainingVisualFactor, 1);
	setScale(self.COBD.roll13, self.COBD.scaleAmount13 * remainingVisualFactor, self.COBD.scaleAmount13 * remainingVisualFactor, 1);
	
	setTranslation(self.COBD.Halter, -0.674, 0.413, self.COBD.transAmount1);
	
	-- Pressure is only available when the Euromacchine pump is actually
	-- connected to input joint 3 and its motor/turn-on state is active.
	self.COBD.disctanceToSplit = MathUtil.round(self.COBD.pumpPressure or 0, 1)
	self.COBD.text1 = math.floor(self.COBD.disctanceToSplit)
	self.COBD.text2 = MathUtil.round((self.COBD.disctanceToSplit - self.COBD.text1) * 10, 0)
	-- Legacy physical number display disabled: LS19 numberShader is incompatible with LS25.
	
	-- set distance for dash hud
	self.COBD.disctanceToSplit2 = MathUtil.round(self.COBD.workingWidth,1)
	if self.COBD.disctanceToSplit2 > 50 and self.COBD.disctanceToSplit2 < 60 then
		self.COBD.text3 = 5
		self.COBD.text4 = MathUtil.round(self.COBD.disctanceToSplit2 - 50,0)
	elseif self.COBD.disctanceToSplit2 >= 60 and self.COBD.disctanceToSplit2 < 70 then
		self.COBD.text3 = 6
		self.COBD.text4 = MathUtil.round(self.COBD.disctanceToSplit2 - 60,0)
	elseif self.COBD.disctanceToSplit2 >= 70 and self.COBD.disctanceToSplit2 < 80 then
		self.COBD.text3 = 7
		self.COBD.text4 = MathUtil.round(self.COBD.disctanceToSplit2 - 70,0)
	else
		self.COBD.text3 = 8
		self.COBD.text4 = MathUtil.round(self.COBD.disctanceToSplit2 - 80,0)
	end
	-- Legacy physical number display disabled; values are shown in the normal HUD.
	
end;

function RWSM53ChangeObjectByDistance:onDelete()
	if self.COBD ~= nil and self.COBD.groundHoseSegments ~= nil then
		for _, seg in ipairs(self.COBD.groundHoseSegments) do
			if seg ~= nil and seg ~= 0 then
				delete(seg)
			end
		end
	end
	if self.COBD ~= nil and self.COBD.groundHoseTemplateRoot ~= nil and self.COBD.groundHoseTemplateRoot ~= 0 then
		delete(self.COBD.groundHoseTemplateRoot)
		self.COBD.groundHoseTemplateRoot = nil
	end
	if self.COBD ~= nil and self.COBD.groundHoseSharedRequestId ~= nil and g_i3DManager ~= nil then
		g_i3DManager:releaseSharedI3DFile(self.COBD.groundHoseSharedRequestId)
		self.COBD.groundHoseSharedRequestId = nil
	end
end;

function RWSM53ChangeObjectByDistance:onReadStream(streamId, connection)
end;

function RWSM53ChangeObjectByDistance:onWriteStream(streamId, connection)
end;

function RWSM53ChangeObjectByDistance:onDraw(isActiveForInput, isSelected)
    -- Central operating information is displayed only on the selected pump.
end
