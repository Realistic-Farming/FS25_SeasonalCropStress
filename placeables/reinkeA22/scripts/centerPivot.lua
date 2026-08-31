-- ============================================================
-- centerPivot.lua  (FS25_ReinkeA22)
-- Reinke A22 center pivot placeable specialization.
--
-- IMPORTANT FS25 NOTE: Placeables expose their root scene node as
-- `self.rootNode`, NOT `self.nodeId`. Earlier versions referenced
-- `self.nodeId` which is nil at onLoad time, silently skipping all
-- node discovery. We use `self.rootNode` everywhere now.
--
-- IMPORTANT FS25 NOTE 2: Placeables don't tick by default  -  they have
-- to opt into the engine update loop via `Object:raiseActive()`. We call
-- it from onLoad, onPostLoad (defensive), and the top of every onUpdate
-- to stay alive. See $dataS/scripts/network/Object.lua line 78.
--
-- Hierarchy expected in the i3d:
--
--     CenterPivot
--       â""â"€â"€ pivotPoint            â† Y-rotated by this script
--             â""â"€â"€ Head
--                   â""â"€â"€ Center            (StructureCenter, section 1)
--                         â""â"€â"€ Middle      (StructureMiddle, section 2+)
--                               â""â"€â"€ End   (StructureEnd, last section)
--
-- Each section TG owns: wheels, lights, visuals, effects (children).
-- Section discovery walks Center â†’ Middle* â†’ End.
--
-- Subsystems:
--    - ¢ Arm rotation (sweep-mode aware, dt-correct, time-scale aware)
--    - ¢ Per-section Z-axis tilt â†’ boom articulates over rolling terrain.
--     Cascades through parent chain so each section's tilt builds on
--     the previous section's resolved position.
--    - ¢ Sprayer cone visibility toggle (interim  -  real GPU particles
--     would require effect-emitter shapes authored in Giants Editor).
--    - ¢ Pressure gauge needle eased toward pressureMultiplier.
--    - ¢ Throttled diagnostic logging (discovery, state flips, heartbeat).
--
-- Debug aids (XML):
--    - ¢ forceAlwaysActive="true" â†’ keeps self.isActive=true regardless of
--     SCS schedule. Use to test rotation/effects without waiting for
--     SCS schedule windows. (SCS's "Irrigate Now" button calls
--     applyOneTimeIrrigation which is a one-shot pulse  -  it does NOT
--     set system.isActive, so the pivot would never appear "on".)
-- ============================================================

ReinkeIrrigationPivot = {}
ReinkeIrrigationPivot.MOD_NAME = g_currentModName
ReinkeIrrigationPivot.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".reinkeIrrigationPivot"
ReinkeIrrigationPivot.INTERACTION_RADIUS         = 8        -- metres
ReinkeIrrigationPivot.TERRAIN_FOLLOW_INTERVAL_MS = 250      -- 4 Hz when active (adaptive when idle — see onUpdateTick)
ReinkeIrrigationPivot.STATUS_LOG_INTERVAL_MS     = 30000    -- 30s heartbeat while active
ReinkeIrrigationPivot.PRESSURE_GAUGE_MAX_DEG     = 270      -- needle sweeps 0..270Â°
ReinkeIrrigationPivot.WHEEL_HUB_ABOVE_GROUND     = 0.628    -- m, from Reinke i3d wheel rest pose
ReinkeIrrigationPivot.LIGHT_GLOW_INTENSITY       = 2        -- lightControl x-component authored in GE on LightBulbGlass
ReinkeIrrigationPivot.TERRAIN_MAX_SPAN_PITCH_DEG = 18       -- visual joint flex limit
ReinkeIrrigationPivot.TERRAIN_MAX_TOWER_ROLL_DEG = 12       -- visual axle/tower twist limit
ReinkeIrrigationPivot.TERRAIN_SMOOTH_FACTOR      = 0.35     -- lerp factor per tick (was 0.20 - bumped for faster wheel-ground convergence)
ReinkeIrrigationPivot.TERRAIN_MIN_APPLY_DEG      = 0.30     -- ignore corrections smaller than this (was 0.5 - smaller allows finer settling)
ReinkeIrrigationPivot.TERRAIN_MAX_RATE_DEG_TICK  = 1.50     -- max pitch change per tick (was 0.5 - 6/sec at 4 Hz for faster response)
ReinkeIrrigationPivot.TERRAIN_EMA_ALPHA          = 0.25     -- EMA weight on new sample (was 0.30 - slightly smoother at 4 Hz)
ReinkeIrrigationPivot.SPRAY_FEATHER_INTERVAL_MS  = 500      -- ms between each nozzle activation (0.5 s × N nozzles = total ramp time)

-- Speed system: index 2 = nominal (the speed set by rotationRevPerGameHour in XML).
-- 1X = 50%, 2X = 100%, 3X = 150%, 4X = 200% of nominal.
ReinkeIrrigationPivot.SPEED_MULTS         = { 0.5, 1.0, 1.5, 2.0 }
ReinkeIrrigationPivot.SPEED_LABELS        = { "1X", "2X", "3X", "4X" }
-- KnobSpeed 4-position offsets relative to the GE baked base rotation.
-- Each step is 90°: base+0, base+90, base+180, base+270.
-- With GE base at -45°: results are -45, 45, 135, 225°.
ReinkeIrrigationPivot.SPEED_KNOB_OFFSETS  = { 0, math.rad(90), math.rad(180), math.rad(270) }
-- ON/OFF knob offset: add this to the baked base for the ON position.
ReinkeIrrigationPivot.KNOB_ON_OFFSET      = math.rad(90)

function ReinkeIrrigationPivot.prerequisitesPresent(specializations)
    return true
end

-- ============================================================
-- SOUND HELPERS
-- ============================================================
local function sndPlay(s)
    if s ~= nil then g_soundManager:playSample(s) end
end
local function sndPlay1(s)
    if s ~= nil then g_soundManager:playSample(s, 1) end
end
local function sndStop(s)
    if s ~= nil then g_soundManager:stopSample(s) end
end
local function sndPlaying(s)
    return s ~= nil and g_soundManager:getIsSamplePlaying(s)
end

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- ============================================================
-- SCS DETECTION (cross-mod safe)
-- ============================================================
local function getSCSManager()
    if g_currentMission ~= nil and g_currentMission.cropStressManager ~= nil then
        return g_currentMission.cropStressManager
    end
    if g_cropStressManager ~= nil then return g_cropStressManager end
    return nil
end

local function getSCSIrrigationManager()
    local mgr = getSCSManager()
    if mgr == nil then return nil end
    local im = mgr.irrigationManager
    if im == nil then return nil end
    if im.isInitialized == false then return nil end
    return im
end

-- ============================================================
-- LOGGING
-- ============================================================
local LOG_PREFIX = "[ReinkeA22]"
local function rLog(msg)  if g_logManager then g_logManager:devInfo(LOG_PREFIX, msg) else print(LOG_PREFIX .. " " .. tostring(msg)) end end
local function rInfo(msg) if g_logManager then g_logManager:info(LOG_PREFIX .. " " .. tostring(msg)) else print(LOG_PREFIX .. " " .. tostring(msg)) end end

-- ============================================================
-- I3D NODE WALKERS
-- ============================================================
local function findNodeByName(rootNode, name)
    if rootNode == nil or rootNode == 0 then return nil end
    if getName(rootNode) == name then return rootNode end
    local n = getNumOfChildren(rootNode)
    for i = 0, n - 1 do
        local found = findNodeByName(getChildAt(rootNode, i), name)
        if found ~= nil then return found end
    end
    return nil
end

local function findAllByName(rootNode, name, acc)
    if rootNode == nil or rootNode == 0 then return acc end
    if getName(rootNode) == name then table.insert(acc, rootNode) end
    local n = getNumOfChildren(rootNode)
    for i = 0, n - 1 do
        findAllByName(getChildAt(rootNode, i), name, acc)
    end
    return acc
end

local function findDirectChild(rootNode, name)
    if rootNode == nil or rootNode == 0 then return nil end
    local n = getNumOfChildren(rootNode)
    for i = 0, n - 1 do
        local c = getChildAt(rootNode, i)
        if getName(c) == name then return c end
    end
    return nil
end

-- ============================================================
-- NODE PATH HELPER
-- Traverses the scene graph from `root` by a sequence of child
-- indices encoded as "A>B|C|D..." (both '>' and '|' are separators).
-- Returns the final node, or nil if any step fails.
-- Example: getNodeByIndexPath(root, "0|1|0|3|0")
--   -> getChildAt(root,0) -> getChildAt(.,1) -> ... etc.
-- Must be defined BEFORE discoverSections which calls it.
-- ============================================================
local function getNodeByIndexPath(root, path)
    local node = root
    for segment in string.gmatch(path, "[^>|]+") do
        if node == nil or node == 0 then return nil end
        local i = tonumber(segment)
        if i == nil then return nil end
        node = getChildAt(node, i)
    end
    return (node ~= nil and node ~= 0) and node or nil
end

-- Dynamic section discovery — reads the i3d chain at runtime, works for any tower count.
--
-- Tower 1 (Center):  StructureCenterROTATE1 (Shape) at 0>0|1|0
--   TowerTerrainComp at child[3], WheelLH/RH at child[0]/[1] of TowerTerrainComp.
--
-- Towers 2-N (Middle/End):  MiddleROTATEN (TG) reached via the chain below.
--   child[0] = StructureMiddle or StructureEnd (Shape)
--     child[0] = TowerTerrainComp → child[0]=WheelLH, child[1]=WheelRH
--
-- Chain advancement differs by variant:
--   3-tower:    MiddleROTATE2.child[1] = ArmatureEnd (1 child) → EndROTATE3 at child[2]
--   5/10-tower: MiddleROTATEN.child[1] = CenterN+1 TG (2 children) → MiddleROTATEN+1 at child[1]
--   End tower:  MiddleROTATEN has only 1 child → chain terminates.

local function discoverSections(rootNode)
    local sections = {}
    if rootNode == nil then return sections end

    -- Tower 1: fixed entry point
    local rot1 = getNodeByIndexPath(rootNode, "0>0|1|0")
    if rot1 == nil then
        rInfo("discoverSections: StructureCenterROTATE1 not found at 0>0|1|0")
        return sections
    end
    local tc1 = getChildAt(rot1, 3)
    table.insert(sections, {
        name       = "Tower1",
        rotateNode = rot1,
        wheelLH    = (tc1 ~= nil and tc1 ~= 0) and getChildAt(tc1, 0) or nil,
        wheelRH    = (tc1 ~= nil and tc1 ~= 0) and getChildAt(tc1, 1) or nil,
    })

    -- Walk the chain starting from Center2 (child[4] of Tower1 rotate)
    local center2 = getChildAt(rot1, 4)
    if center2 == nil or center2 == 0 then return sections end

    local currentRotate = getChildAt(center2, 1)   -- MiddleROTATE2

    while currentRotate ~= nil and currentRotate ~= 0 do
        local sm  = getChildAt(currentRotate, 0)   -- StructureMiddle or StructureEnd
        local tcN = (sm ~= nil and sm ~= 0) and getChildAt(sm, 0) or nil
        table.insert(sections, {
            name       = string.format("Tower%d", #sections + 1),
            rotateNode = currentRotate,
            wheelLH    = (tcN ~= nil and tcN ~= 0) and getChildAt(tcN, 0) or nil,
            wheelRH    = (tcN ~= nil and tcN ~= 0) and getChildAt(tcN, 1) or nil,
        })

        -- Advance chain
        local n  = getNumOfChildren(currentRotate)
        if n <= 1 then break end                   -- end tower, no further chain

        local c1 = getChildAt(currentRotate, 1)
        if c1 == nil or c1 == 0 then break end

        if getNumOfChildren(c1) > 1 then
            -- 5/10-tower: c1 is CenterN+1 container, next ROTATE at its child[1]
            currentRotate = getChildAt(c1, 1)
        elseif n > 2 then
            -- 3-tower: c1 is ArmatureEnd (1 child), EndROTATE3 at child[2]
            currentRotate = getChildAt(currentRotate, 2)
        else
            break
        end
    end

    return sections
end


function ReinkeIrrigationPivot.initSpecialization()
    local schemaSavegame = Placeable.xmlSchemaSavegame
    local key = "placeables.placeable(?)." .. ReinkeIrrigationPivot.MOD_NAME .. ".reinkeIrrigationPivot"
    schemaSavegame:register(XMLValueType.BOOL,  key .. "#isActive",       "Active state")
    schemaSavegame:register(XMLValueType.FLOAT, key .. "#armAngle",       "Arm angle (rad)")
    schemaSavegame:register(XMLValueType.BOOL,  key .. "#isSprayActive",  "Spray state")
    schemaSavegame:register(XMLValueType.BOOL,  key .. "#autoRotate",     "Auto-rotate state")
    schemaSavegame:register(XMLValueType.FLOAT, key .. "#sweepDirection", "Sweep direction (+1/-1)")
    schemaSavegame:register(XMLValueType.FLOAT, key .. "#autoMinAngleDeg","Sweep min angle")
    schemaSavegame:register(XMLValueType.FLOAT, key .. "#autoMaxAngleDeg","Sweep max angle")
    schemaSavegame:register(XMLValueType.BOOL,  key .. "#doorOpen",       "Control box door state")
    schemaSavegame:register(XMLValueType.FLOAT, key .. "#doorAngleCur",   "Door animation angle (rad)")
    schemaSavegame:register(XMLValueType.BOOL,  key .. "#masterPower",    "Running lights master power")
    schemaSavegame:register(XMLValueType.FLOAT, key .. "#targetAngle",    "Fixed-mode step target (rad)")
    schemaSavegame:register(XMLValueType.INT,   key .. "#speedIndex",     "Speed index 1-4 (1X/2X/3X/4X)")
    schemaSavegame:register(XMLValueType.BOOL,  key .. "#endGunActive",   "End gun on/off state")
end

function ReinkeIrrigationPivot.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "registerInteractionAction",  ReinkeIrrigationPivot.registerInteractionAction)
    -- [LOCAL TEST PATCH] disabled: removeInteractionAction is registered but never defined, so this nil crashed spec registration. Left for Antler to fix at source.
    -- SpecializationUtil.registerFunction(placeableType, "removeInteractionAction",    ReinkeIrrigationPivot.removeInteractionAction)
    SpecializationUtil.registerFunction(placeableType, "setInteractionHintsVisible", ReinkeIrrigationPivot.setInteractionHintsVisible)
    SpecializationUtil.registerFunction(placeableType, "onInteractPressed",         ReinkeIrrigationPivot.onInteractPressed)
    SpecializationUtil.registerFunction(placeableType, "updateArmRotation",         ReinkeIrrigationPivot.updateArmRotation)
    SpecializationUtil.registerFunction(placeableType, "toggleSprayActive",         ReinkeIrrigationPivot.toggleSprayActive)
    SpecializationUtil.registerFunction(placeableType, "onSprayPressed",            ReinkeIrrigationPivot.onSprayPressed)
    SpecializationUtil.registerFunction(placeableType, "onAnglePlusPressed",        ReinkeIrrigationPivot.onAnglePlusPressed)
    SpecializationUtil.registerFunction(placeableType, "onAngleMinusPressed",       ReinkeIrrigationPivot.onAngleMinusPressed)
    SpecializationUtil.registerFunction(placeableType, "onAutoMaxUpPressed",        ReinkeIrrigationPivot.onAutoMaxUpPressed)
    SpecializationUtil.registerFunction(placeableType, "onAutoMinUpPressed",        ReinkeIrrigationPivot.onAutoMinUpPressed)
    SpecializationUtil.registerFunction(placeableType, "stepTargetAngle",           ReinkeIrrigationPivot.stepTargetAngle)

    SpecializationUtil.registerFunction(placeableType, "updateDriveShaftAnimation", ReinkeIrrigationPivot.updateDriveShaftAnimation)
    SpecializationUtil.registerFunction(placeableType, "updateEndGunAnimation",     ReinkeIrrigationPivot.updateEndGunAnimation)
    SpecializationUtil.registerFunction(placeableType, "tryRegisterWithSCS",        ReinkeIrrigationPivot.tryRegisterWithSCS)
    SpecializationUtil.registerFunction(placeableType, "startSprayerParticles",     ReinkeIrrigationPivot.startSprayerParticles)
    SpecializationUtil.registerFunction(placeableType, "stopSprayerParticles",      ReinkeIrrigationPivot.stopSprayerParticles)
    SpecializationUtil.registerFunction(placeableType, "tickSprayFeather",          ReinkeIrrigationPivot.tickSprayFeather)
    SpecializationUtil.registerFunction(placeableType, "updateTerrainArticulation", ReinkeIrrigationPivot.updateTerrainArticulation)
    SpecializationUtil.registerFunction(placeableType, "updateWheelRotation",       ReinkeIrrigationPivot.updateWheelRotation)
    SpecializationUtil.registerFunction(placeableType, "updatePressureGauge",       ReinkeIrrigationPivot.updatePressureGauge)
    SpecializationUtil.registerFunction(placeableType, "logHeartbeat",              ReinkeIrrigationPivot.logHeartbeat)
    SpecializationUtil.registerFunction(placeableType, "onDoorPressed",             ReinkeIrrigationPivot.onDoorPressed)
    SpecializationUtil.registerFunction(placeableType, "updateControlPanel",        ReinkeIrrigationPivot.updateControlPanel)
    SpecializationUtil.registerFunction(placeableType, "updateLights",              ReinkeIrrigationPivot.updateLights)
    SpecializationUtil.registerFunction(placeableType, "toggleMasterPower",         ReinkeIrrigationPivot.toggleMasterPower)
    SpecializationUtil.registerFunction(placeableType, "onMasterPowerPressed",       ReinkeIrrigationPivot.onMasterPowerPressed)
    SpecializationUtil.registerFunction(placeableType, "onSweepMaxDnPressed",       ReinkeIrrigationPivot.onSweepMaxDnPressed)
    SpecializationUtil.registerFunction(placeableType, "onSweepMinDnPressed",       ReinkeIrrigationPivot.onSweepMinDnPressed)
    SpecializationUtil.registerFunction(placeableType, "updateButtonLight",         ReinkeIrrigationPivot.updateButtonLight)
    SpecializationUtil.registerFunction(placeableType, "toggleEndGun",             ReinkeIrrigationPivot.toggleEndGun)
    SpecializationUtil.registerFunction(placeableType, "onEndGunPressed",          ReinkeIrrigationPivot.onEndGunPressed)
    SpecializationUtil.registerFunction(placeableType, "cycleSpeed",               ReinkeIrrigationPivot.cycleSpeed)
    SpecializationUtil.registerFunction(placeableType, "onSpeedCyclePressed",      ReinkeIrrigationPivot.onSpeedCyclePressed)
    SpecializationUtil.registerFunction(placeableType, "syncLoopSounds",           ReinkeIrrigationPivot.syncLoopSounds)
end

function ReinkeIrrigationPivot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",              ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onPostLoad",          ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate",            ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onUpdateTick",        ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onDelete",            ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream",        ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream",       ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteUpdateStream", ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "onReadUpdateStream",  ReinkeIrrigationPivot)
    SpecializationUtil.registerEventListener(placeableType, "saveToXMLFile",       ReinkeIrrigationPivot)
end

function ReinkeIrrigationPivot.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("ReinkeIrrigationPivot")
    EffectManager.registerEffectXMLPaths(schema, basePath .. ".effects")
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#radius", "Pivot radius in metres", 115)
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#flowRatePerHour", "Flow rate per hour", 0.018)
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#operationalCostPerHour", "Cost per hour", 15)
    schema:register(XMLValueType.INT,    basePath .. ".irrigationConfig#defaultStartHour", "Default start hour", 6)
    schema:register(XMLValueType.INT,    basePath .. ".irrigationConfig#defaultEndHour", "Default end hour", 10)
    schema:register(XMLValueType.STRING, basePath .. ".irrigationConfig#defaultActiveDays", "Active days bitmap", "true,true,true,true,true,false,false")
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#rotationRevPerGameHour", "Rotations per game hour", 2.0)
    schema:register(XMLValueType.STRING, basePath .. ".irrigationConfig#sweepMode", "Sweep mode (full/bounded)", "full")
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#sweepMinAngleDeg", "Sweep min angle degrees", 0)
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#sweepMaxAngleDeg", "Sweep max angle degrees", 360)
    schema:register(XMLValueType.FLOAT,  basePath .. ".irrigationConfig#parkAngleDeg", "Park angle degrees", 0)
    schema:register(XMLValueType.BOOL,   basePath .. ".irrigationConfig#forceAlwaysActive", "Force always active (debug)", false)
    schema:register(XMLValueType.BOOL,   basePath .. ".irrigationConfig#enableSCS", "Enable SCS integration", false)
    schema:register(XMLValueType.STRING, basePath .. ".irrigationConfig#wheelRotAxis", "Wheel rotation axis (X/Z/NX)", "X")
    schema:register(XMLValueType.STRING, basePath .. ".irrigationConfig#angleUIMode", "UI angle mode (cycle/preset)", "cycle")
    schema:register(XMLValueType.STRING, basePath .. ".irrigationConfig#terrainTiltAxis", "Terrain tilt axis (Z/X/AUTO)", "Z")
    schema:register(XMLValueType.BOOL,   basePath .. ".irrigationConfig#terrainCounterRotate", "Apply A-frame counter-rotation", false)
    for _, name in ipairs({"motorLoop","rotationLoop","sprayLoop","pumpLoop","switchPress","sprayToggle","buttonClick","hydraulicOpen","hydraulicClose","endGunToggle","speedClick"}) do
        SoundManager.registerSampleXMLPaths(schema, basePath .. ".sounds", name)
    end
    schema:setXMLSpecializationType()
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function ReinkeIrrigationPivot.onLoad(self, savegame)
    -- NOTE: self.isPreviewMode is never true for this placeable type — FS25 calls
    -- onLoad fully even during placement preview (pivot is parked at Y≈-500 underground).
    -- Overlay visibility is handled via the Y < -100 check further below.

    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec == nil then
        spec = {}
        self[ReinkeIrrigationPivot.SPEC_TABLE_NAME] = spec
    end
    -- Defaults
    spec.irrigationManager       = nil
    spec.scsIntegrated           = false
    spec.enableSCS               = false   -- read from XML; false = standalone mode, no SCS coupling
    spec.radius                  = 115
    spec.flowRatePerHour         = 0.018
    spec.operationalCostPerHour  = 15
    spec.defaultStartHour        = 6
    spec.defaultEndHour          = 10
    spec.defaultActiveDays       = {true, true, true, true, true, false, false}
    spec.irrigationType          = "pivot"
    spec.isActive                = false
    spec.forceAlwaysActive       = false
    spec.playerInRange           = false
    spec.pollAccumMs             = 0
    spec.actionEventId           = nil
    -- Re-acquisition timer: reset on every onLoad so EDC reload (same Lua object,
    -- onLoad re-called) also fires the 3-second post-reload re-registration pass.
    spec.postReloadReacquireDone = false
    spec.postReloadReacquireMs   = 0
    -- GUI-close detection: track previous frame's GUI visibility so we can fire a
    -- re-registration pass on the first foot-mode frame after a menu closes.
    spec.guiWasVisible           = (g_gui ~= nil and g_gui:getIsGuiVisible()) or false

    spec.pivotPointNode          = nil
    spec.pivotBaseRotY           = 0
    spec.armAngle                = 0
    spec.rotationRevPerGameHour  = 2.0    -- bumped from 0.5 for testing visibility
    spec.sweepMode               = "full"
    spec.sweepMinAngleRad        = 0
    spec.sweepMaxAngleRad        = 2 * math.pi
    spec.parkAngleRad            = 0
    spec.sweepDirection          = 1

    spec.sections                = {}
    spec.effects                 = {}        -- EffectManager ParticleEffect list (WASHER_WATER)
    spec.sprayFeatherIndex       = 0         -- index of next effect to activate during feather-on
    spec.sprayFeatherAccumMs     = 0         -- accumulator for feather timer
    spec.sprayFeatherActive      = false     -- true while progressive start is in progress
    spec.pressureNeedleNode      = nil
    spec.pressureNeedleBase      = 0      -- base Y angle without flutter (rad)
    spec.pressureNeedleAngle     = 0      -- final applied Y angle (rad)
    spec.pressureFlutterOffset   = 0      -- current random Y offset (rad)
    spec.pressureFlutterAccum    = 0      -- time since last flutter (sec)
    spec.pressureFlutterInterval = 0.15   -- seconds until next flutter
    spec.placementY              = 0

    spec.terrainTiltAxis         = "Z"  -- "Z", "X", or "AUTO"  -  read from XML
    spec.isGhostPivot            = false  -- true when loaded at Y<-100 (dangling save entry)
    spec.lastLoggedActive        = false
    spec.terrainAccumMs          = 0
    spec.terrainDiagAccumMs      = 0   -- throttle for per-section terrain diagnostic log
    spec.terrainFirstDiag        = false
    spec.statusAccumMs           = 0
    spec.scsRetryAccumMs         = 0
    spec.scsRegisterAttempts     = 0
    spec.firstUpdateLogged       = false

    spec.dirtyFlag               = self:getNextDirtyFlag()

    -- Wheel spin axis (XML wheelRotAxis): "X" | "Z" | "NX" (negative X).
    -- Correct axis depends on how WheelLH/WheelRH are oriented in the i3d.
    spec.wheelRotAxis            = "NX"
    spec.wheelRotAccum           = 0   -- accumulated rotation (rad); prevents floating-point drift

    -- Spray state  -  completely independent from arm rotation.
    -- R key toggles autoRotate. G key toggles spray (isSprayActive).
    spec.isSprayActive           = false
    spec.lastSprayLogged         = false
    spec.sprayActionEventId      = nil
    spec.anglePlusActionEventId  = nil
    spec.angleMinusActionEventId = nil
    spec.autoMaxUpActionEventId  = nil
    spec.autoMinUpActionEventId  = nil

    -- Auto-rotate / fixed-angle system.
    --
    --   autoRotate = true  â†’ R is ON: arm sweeps continuously back-and-forth between
    --                         autoMinAngleDeg and autoMaxAngleDeg. Full-circle when
    --                         the range spans 360Â° (never reverses, just keeps going).
    --                         ] / [ adjust the upper / lower sweep bound by 10Â°.
    --
    --   autoRotate = false â†’ R is OFF: arm is stopped. ] / [ set a fixed target angle
    --                         (snapped to the nearest 10Â° grid); arm motors to it
    --                         then stops again. targetAngle=nil when no target set.
    spec.autoRotate              = false
    spec.autoMinAngleDeg         = 0
    spec.autoMaxAngleDeg         = 360
    spec.targetAngle             = nil   -- fixed-mode target (rad); nil = no target

    -- Animation node lists (filled during onLoad i3d walk)
    spec.driveShaftNodes         = {}   -- spin on local Z when isActive (arm rotating)
    spec.shaftSpinSpeed          = math.rad(720)   -- 720Â°/s when rotating

    -- End gun animation (squirtPart_treeLance + deflector)
    -- The gun barrel sweeps Y-axis Â±100Â°; the deflector bumper oscillates Z 0â†’-80Â°.
    -- Both run whenever isSprayActive is true.
    spec.endGunNode              = nil   -- squirtPart_treeLance  -  sweeps on local Y
    spec.endGunDeflectorNode     = nil   -- squirtPart_treeLance.001  -  deflects on local Z
    spec.endGunBurstNodes        = {}    -- "endGunBurst" effect TGs  -  flashed on burst trigger
    spec.endGunAngle             = 0     -- current gun Y rotation (rad)
    spec.endGunDir               = 1     -- +1 sweeping positive, -1 sweeping negative
    spec.endGunMinAngle          = math.rad(-100)
    spec.endGunMaxAngle          = math.rad( 100)
    spec.endGunSweepSpeed        = math.rad(40)   -- 40Â°/s â†’ ~5 s per half-sweep
    spec.deflectorAngle          = 0     -- current deflector Z rotation (rad)
    spec.deflectorDir            = -1   -- -1 moves toward -80Â°, +1 returns to 0Â°
    spec.deflectorMinAngle       = math.rad(-80)
    spec.deflectorMaxAngle       = 0
    spec.deflectorSpeed          = math.rad(240)  -- 240Â°/s â†’ ~0.33 s per half-cycle (2Ã— original)
    spec.burstActive             = false  -- true during the brief burst flash
    spec.burstAccumMs            = 0      -- how long the current burst has been visible
    spec.burstDurationMs         = 350    -- burst stays visible for 350 ms per hit
    spec.endGunBaseRY            = nil   -- baked Y rotation captured at load
    spec.deflectorBaseRZ         = nil   -- baked Z rotation captured at load
    spec.endGunEffectsNode       = nil   -- "effects" TG child of gun node (water only)
    spec.endGunVisible           = nil   -- tracks last setVisibility call (nil = not yet set)

    -- Control panel nodes (found by name in i3d — see spec defaults block above)
    spec.doorRotNode             = nil   -- ControlBoxDoorROT  -  rotated to open/close door
    spec.doorOpen                = false -- current door state
    spec.doorAngleCur            = 0     -- current door open angle (rad) for smooth animation
    spec.doorAngleTgt            = 0     -- target door open angle (rad)
    spec.doorActionEventId       = nil
    spec.doorShapeNode           = nil   -- ControlBoxDoor Shape  -  the node we actually animate
    spec.doorShapeBaseRX         = 0     -- i3d baked rotation of the Shape (captured at load)
    spec.doorShapeBaseRY         = 0
    spec.doorShapeBaseRZ         = 0

    -- Running lights:
    --   LightBulbLight = scene Point Light node  (toggled via setVisibility)
    --   LightBulbGlass = glass mesh with lightControl emissive shader param
    --                    (toggled via setShaderParameter — glass stays visible,
    --                     only the emissive glow turns on/off)
    -- LIGHT_GLOW_INTENSITY (class constant) is the authored lightControl x-value in GE.
    -- Change it there if you retune the intensity in GE.
    spec.masterPower              = false
    spec.lightNodes               = {}   -- Point Light nodes  (named "LightBulbLight")
    spec.lightGlowNodes           = {}   -- glass mesh nodes   (named "LightBulbGlass")
    spec.masterPowerActionEventId = nil
    spec.sweepMaxDnActionEventId  = nil
    spec.sweepMinDnActionEventId  = nil

    -- Speed system: index 2 = 2X (nominal/current XML speed).
    spec.speedIndex               = 2
    -- End gun: independent on/off toggle for the end gun animation + effects.
    spec.endGunActive             = false
    spec.endGunActionEventId      = nil
    spec.speedCycleActionEventId  = nil
    spec.samples                  = {}   -- sound samples loaded in onLoad (client only)

    -- Control panel knob and position-dial nodes (found by name in i3d).
    -- GE node names expected:
    --   KnobSystemPower  — master power switch
    --   KnobAutoManual   — mode selector (auto/manual)
    --   KnobWaterSupply  — main water supply / spray on-off
    --   KnobSpeed        — 4-position speed selector
    --   KnobEndGun       — end gun on/off
    --   PivotCurrentRot  — position dial showing live arm angle (local X = CW)
    --   LimitA           — lower limit dial (AUTO) / target (MANUAL)
    --   LimitB           — upper limit dial (AUTO) / target (MANUAL)
    spec.knobSystemPowerNode      = nil
    spec.knobAutoManualNode       = nil
    spec.knobWaterSupplyNode      = nil
    spec.knobSpeedNode            = nil
    spec.knobEndGunNode           = nil
    -- Button1: motion-indicator light (lightControl shader, same as LightBulbGlass).
    -- ON only when masterPower=true AND isActive=true (pivot is moving).
    spec.button1GlowNode          = nil
    spec.lastButtonLit            = false
    -- Dial nodes: PivotCurrentRot, LimitA, LimitB — animate on local X.
    spec.posDialCurrentNode       = nil
    spec.posDialCurrentBaseRX     = 0
    spec.posDialCurrentBaseRY     = 0
    spec.posDialCurrentBaseRZ     = 0
    spec.posDialMinNode           = nil
    spec.posDialMinBaseRX         = 0
    spec.posDialMinBaseRY         = 0
    spec.posDialMinBaseRZ         = 0
    spec.posDialMaxNode           = nil
    spec.posDialMaxBaseRX         = 0
    spec.posDialMaxBaseRY         = 0
    spec.posDialMaxBaseRZ         = 0

    -- Read XML config
    if self.xmlFile ~= nil then
        local base = "placeable.irrigationConfig"
        spec.radius                 = self.xmlFile:getFloat(base .. "#radius",                 spec.radius)
        spec.flowRatePerHour        = self.xmlFile:getFloat(base .. "#flowRatePerHour",        spec.flowRatePerHour)
        spec.operationalCostPerHour = self.xmlFile:getFloat(base .. "#operationalCostPerHour", spec.operationalCostPerHour)
        spec.defaultStartHour       = self.xmlFile:getInt(  base .. "#defaultStartHour",       spec.defaultStartHour)
        spec.defaultEndHour         = self.xmlFile:getInt(  base .. "#defaultEndHour",         spec.defaultEndHour)

        local daysStr = self.xmlFile:getString(base .. "#defaultActiveDays", nil)
        if daysStr ~= nil then
            local days = {}
            for v in string.gmatch(daysStr, "[^,]+") do
                local trimmed = v:match("^%s*(.-)%s*$") or v
                table.insert(days, trimmed == "true" or tonumber(trimmed) == 1)
            end
            if #days == 7 then spec.defaultActiveDays = days end
        end

        spec.rotationRevPerGameHour = self.xmlFile:getFloat(base .. "#rotationRevPerGameHour", spec.rotationRevPerGameHour)
        local mode = self.xmlFile:getString(base .. "#sweepMode", spec.sweepMode)
        if mode == "bounded" then spec.sweepMode = "bounded" else spec.sweepMode = "full" end

        local minDeg = self.xmlFile:getFloat(base .. "#sweepMinAngleDeg", 0)
        local maxDeg = self.xmlFile:getFloat(base .. "#sweepMaxAngleDeg", 360)
        spec.sweepMinAngleRad = math.rad(minDeg)
        spec.sweepMaxAngleRad = math.rad(maxDeg)
        if spec.sweepMaxAngleRad <= spec.sweepMinAngleRad then spec.sweepMode = "full" end
        spec.parkAngleRad = math.rad(self.xmlFile:getFloat(base .. "#parkAngleDeg", 0))
        spec.armAngle = spec.parkAngleRad

        spec.forceAlwaysActive = self.xmlFile:getBool(base .. "#forceAlwaysActive", false)
        if spec.forceAlwaysActive then
            rInfo(string.format("pivot %d: forceAlwaysActive=true (DEBUG  -  bypassing SCS schedule)", self.id or -1))
        end

        -- enableSCS: when false the pivot runs fully standalone  -  no SCS registration,
        -- no SCS dialog, standalone R-key toggle. Default false for all current variants.
        spec.enableSCS = self.xmlFile:getBool(base .. "#enableSCS", false)

        -- wheelRotAxis: which local axis WheelLH/RH spin on. "X" | "Z" | "NX".
        local rawWRA = self.xmlFile:getString(base .. "#wheelRotAxis", "X")
        if rawWRA == "Z" or rawWRA == "NX" then
            spec.wheelRotAxis = rawWRA
        else
            spec.wheelRotAxis = "X"
        end

        -- angleUIMode: how the park-angle UI works.
        --   "cycle"  (default)  -  ] / [ steps through 45Â° presets
        --   "preset"            -  same but cycles only cardinal + intercardinal names
        local rawAUI = self.xmlFile:getString(base .. "#angleUIMode", "cycle")
        spec.angleUIMode = (rawAUI == "preset") and "preset" or "cycle"

        -- terrainTiltAxis: which local Euler axis carries the boom pitch.
        --   "Z"    â†’ apply theta to local Z (correct when boom is along local X)
        --   "X"    â†’ apply -theta to local X (correct when boom is along local Z)
        --   "AUTO" â†’ detect axis from world boom direction each frame; self-signing
        local axisRaw = self.xmlFile:getString(base .. "#terrainTiltAxis", "Z")
        spec.terrainTiltAxis = string.upper(axisRaw or "Z")
        if spec.terrainTiltAxis ~= "X" and spec.terrainTiltAxis ~= "AUTO" then
            spec.terrainTiltAxis = "Z"
        end

        -- terrainCounterRotate: whether to apply A-frame counter-rotation after each
        -- section tilt. Only works correctly if the wheelsNode origin is at the section
        -- joint (NOT at the hub). Default false  -  diagnose wheelsNode identity first.
        spec.terrainCounterRotate = self.xmlFile:getBool(base .. "#terrainCounterRotate", false)
    end

    -- ===== ROOT NODE SETUP =====
    local root = self.rootNode  -- FS25 placeable: rootNode is set during i3dFileLoaded, before onLoad raises
    if root == nil or root == 0 then
        rInfo(string.format("pivot %d: FATAL  -  self.rootNode is nil/0 at onLoad. Specialization cannot run.",
            self.id or -1))
        return
    end

    -- ===== Locate pivotPoint and section chain =====
    spec.pivotPointNode = findNodeByName(root, "pivotPoint")
    if spec.pivotPointNode ~= nil then
        local _, ry, _ = getRotation(spec.pivotPointNode)
        spec.pivotBaseRotY = ry or 0
    spec.sections = discoverSections(self.rootNode)

        for _, s in ipairs(spec.sections) do
            s.baseRX, s.baseRY, s.baseRZ = getRotation(s.rotateNode)
            -- wheelNodes / wheelRefNode used by updateWheelRotation (spin animation)
            s.wheelNodes   = {}
            if s.wheelLH ~= nil then table.insert(s.wheelNodes, s.wheelLH) end
            if s.wheelRH ~= nil then table.insert(s.wheelNodes, s.wheelRH) end
            s.wheelRefNode = s.wheelLH

            -- Geometry used by updateTerrainArticulation (terrain slope matching)
            if s.wheelLH ~= nil and s.wheelRH ~= nil then
                local lhx, _, lhz = getWorldTranslation(s.wheelLH)
                local rhx, _, rhz = getWorldTranslation(s.wheelRH)
                local midX = (lhx + rhx) * 0.5
                local midZ = (lhz + rhz) * 0.5
                local rnx, _, rnz = getWorldTranslation(s.rotateNode)
                -- Horizontal distance from rotate node to wheel midpoint (arm span)
                s.armLength  = math.sqrt((midX - rnx)^2 + (midZ - rnz)^2)
                -- Lateral distance between wheel nodes (track width)
                s.trackWidth = math.sqrt((rhx - lhx)^2 + (rhz - lhz)^2)
            end
            -- EMA state for terrain smoothing (initialised to zero = no correction)
            s.thetaEMA   = 0
            s.lateralEMA = 0

            rInfo(string.format("pivot %d: section %s rotateNode=%d wLH=%d wRH=%d armLen=%.1fm trackW=%.1fm",
                self.id or -1, s.name, s.rotateNode,
                s.wheelLH or 0, s.wheelRH or 0,
                s.armLength or 0, s.trackWidth or 0))
        end

        local names = {}
        for _, s in ipairs(spec.sections) do table.insert(names, s.name) end
        rInfo(string.format("pivot %d: pivotPoint OK (baseRotY=%.1f°), %d sections (%s)",
            self.id or -1, math.deg(spec.pivotBaseRotY), #spec.sections, table.concat(names, " > ")))

        -- Spray effects loaded below from XML <effects> block via EffectManager

        -- End gun nodes â"€â"€ squirtPart_treeLance (Y-sweep) and its child deflector (.001).
        -- The deflector is the first child of the gun node whose name contains ".001".
        -- We also scan inside the gun node for any TG named "endGunBurst" so we can
        -- flash them briefly each time the deflector returns to 0Â° (water-pulse hit).
        local egNode = findNodeByName(spec.pivotPointNode, "squirtPart_treeLance")
        if egNode ~= nil then
            spec.endGunNode    = egNode
            spec.endGunBaseRY  = select(2, getRotation(egNode))   -- baked Y
            -- Deflector: primary = first child by index (confirmed in i3d at |0).
            -- Fallback: name-based search handles any future re-parenting.
            -- findNodeByName can fail on names containing "." (engine quirk).
            local defNode = getChildAt(egNode, 0)
            if defNode == nil or defNode == 0 then
                defNode = findNodeByName(egNode, "squirtPart_treeLance.001")
            end
            if defNode ~= nil and defNode ~= 0 then
                spec.endGunDeflectorNode = defNode
                spec.deflectorBaseRZ     = select(3, getRotation(defNode))  -- baked Z
                rInfo(string.format("pivot %d: end gun deflector found (id=%d baseRZ=%.2fÂ°)",
                    self.id or -1, defNode, math.deg(spec.deflectorBaseRZ)))
            else
                rInfo(string.format("pivot %d: WARNING  -  end gun deflector 'squirtPart_treeLance.001'"
                    .. " not found under gun node", self.id or -1))
            end
            -- Burst effect TGs  -  named "endGunBurst", one or more allowed
            findAllByName(egNode, "endGunBurst", spec.endGunBurstNodes)
            -- Effects TG  -  child of the gun node named "effects" (contains endGunStream
            -- and endGunBurst).  We toggle ONLY this node so the gun mesh stays visible.
            local numEgChildren = getNumOfChildren(egNode)
            for ci = 0, numEgChildren - 1 do
                local ch = getChildAt(egNode, ci)
                if ch ~= nil and ch ~= 0 and getName(ch) == "effects" then
                    spec.endGunEffectsNode = ch
                    break
                end
            end
        else
            rInfo(string.format("pivot %d: end gun node 'squirtPart_treeLance' not found"
                .. "  -  end gun animation disabled", self.id or -1))
        end

        -- Drive shaft nodes  -  spin on local Z when arm is rotating.
        -- First pass: exact name match against a broad list of common naming conventions.
        local shaftNames = {
            -- Confirmed names from Reinke A22 i3d (found via substring scan):
            "Shafts", "Shafts.001", "Shafts.002",
            -- Generic convention list (covers other i3d naming styles):
            "driveShaft", "DriveShaft", "driveshaft", "Driveshaft",
            "driveShaft_Rot", "DriveShaft_Rot", "driveShaftRot", "DriveShaftRot",
            "propShaft", "PropShaft", "propshaft",
            "shaft", "Shaft", "SHAFT",
            "motorShaft", "MotorShaft",
            "towerShaft", "TowerShaft",
            "driveAxle", "DriveAxle",
            "shaftDrive", "ShaftDrive",
        }
        for _, nm in ipairs(shaftNames) do
            findAllByName(spec.pivotPointNode, nm, spec.driveShaftNodes)
        end

        -- Second pass: if still empty, do a substring scan (case-insensitive) for any
        -- node whose name contains "shaft" or "drive". Logs matching names so you can
        -- add the exact name to the explicit list above for future builds.
        if #spec.driveShaftNodes == 0 then
            local function scanSubstring(root, acc)
                if root == nil or root == 0 then return end
                local lname = string.lower(getName(root) or "")
                if string.find(lname, "shaft", 1, true) or string.find(lname, "drivrot", 1, true) then
                    rInfo(string.format("  pivot %d: [shaft-scan] found candidate '%s' (id=%d)",
                        self.id or -1, getName(root), root))
                    table.insert(acc, root)
                end
                local n = getNumOfChildren(root)
                for i = 0, n - 1 do scanSubstring(getChildAt(root, i), acc) end
            end
            scanSubstring(spec.pivotPointNode, spec.driveShaftNodes)
            if #spec.driveShaftNodes > 0 then
                rInfo(string.format("pivot %d: shaft substring scan found %d candidate(s)  -  "
                    .. "add the exact name(s) shown above to shaftNames for future builds",
                    self.id or -1, #spec.driveShaftNodes))
            end
        end

        if #spec.driveShaftNodes == 0 then
            rInfo(string.format("pivot %d: WARNING  -  no shaft nodes found by name or substring scan."
                .. " Check your i3d node names. Search list: %s",
                self.id or -1, table.concat(shaftNames, " | ")))
        end

        -- Pressure gauge needle
        spec.pressureNeedleNode = findNodeByName(root, "PressureGaugeNeedleROT")

        -- Running lights — discovered by name; scales to 7/11-tower variants automatically.
        -- LightBulbLight: the Point Light scene node  → controlled via setVisibility.
        -- LightBulbGlass: the glass mesh with 'lightControl' emissive shader param
        --                 → controlled via setShaderParameter; mesh stays visible always.
        findAllByName(root, "LightBulbLight", spec.lightNodes)
        findAllByName(root, "LightBulbGlass", spec.lightGlowNodes)

        if #spec.lightNodes > 0 then
            rInfo(string.format("pivot %d: %d LightBulbLight + %d LightBulbGlass node(s) found",
                self.id or -1, #spec.lightNodes, #spec.lightGlowNodes))
        else
            rInfo(string.format("pivot %d: WARNING — no 'LightBulbLight' nodes found; check GE node names",
                self.id or -1))
        end

        -- Hide scene lights via visibility (masterPower starts false).
        for _, n in ipairs(spec.lightNodes) do setVisibility(n, false) end

        -- Zero the emissive on all glass meshes at load (masterPower starts false).
        -- The "on" value is LIGHT_GLOW_INTENSITY — no per-material-index read needed.
        -- setShaderParameter applies to all materials on the mesh; only the one whose
        -- shader defines 'lightControl' reacts, so multi-material meshes are safe.
        -- pcall: guards against third-party mods (e.g. TH PlaceableDesignKit) that hook
        -- setShaderParameter globally and crash on nodes they don't recognise.  A failed
        -- zero-reset is cosmetic; it must never kill onLoad.
        for _, n in ipairs(spec.lightGlowNodes) do
            pcall(setShaderParameter, n, "lightControl", 0, 0, 0, 0)
        end

        -- Button1 motion-indicator light.
        -- THDesignKit hooks multiple FS25 functions (getNumOfMaterials, setShaderParameter,
        -- etc.) and throws errors when called on any node named "Button1". Wrap the
        -- entire block in pcall so no hooked function can propagate an error into onLoad.
        local btn = findNodeByName(root, "Button1")
        if btn ~= nil then
            local ok = pcall(function()
                -- Try the first child (the mesh shape inside the TG parent).
                -- If Button1 has no children it IS the shape; fall back to it directly.
                local child = getChildAt(btn, 0)
                local shapeNode = (child ~= nil and child ~= 0) and child or btn
                spec.button1GlowNode = shapeNode
                setShaderParameter(shapeNode, "lightControl", 0, 0, 0, 0)
            end)
            if not ok then
                spec.button1GlowNode = nil
                rInfo(string.format("pivot %d: Button1 glow disabled (THDesignKit hook incompatibility)",
                    self.id or -1))
            end
        end

        -- â"€â"€ Control panel nodes â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
        -- Found by name  -  consistent across all three i3d variants.
        -- ControlBoxDoorROT: the rotation pivot for the door panel.
        --   Open = rotate 90Â° on its local Y axis (opens outward).
        -- ControlBoxDoorROT is the hinge TG  -  its rotation="180 ~0 180" sets up the
        -- hinge axis in world space. Calling setRotation on the TG itself collapses
        -- this (180Â°,0Â°,180Â°) Euler state and jumps the door.  Instead we leave the
        -- TG completely untouched and animate the SHAPE child inside it.
        spec.doorRotNode = findNodeByName(root, "ControlBoxDoorROT")
        if spec.doorRotNode ~= nil then
            -- Animate the panel Shape inside the hinge TG, not the TG itself.
            spec.doorShapeNode = findDirectChild(spec.doorRotNode, "ControlBoxDoor")
                              or findNodeByName(spec.doorRotNode, "ControlBoxDoor")
            if spec.doorShapeNode ~= nil then
                spec.doorShapeBaseRX, spec.doorShapeBaseRY, spec.doorShapeBaseRZ =
                    getRotation(spec.doorShapeNode)
            else
                rInfo(string.format("pivot %d: ControlBoxDoor Shape NOT found inside TG  -  door animation disabled",
                    self.id or -1))
            end
        else
            rInfo(string.format("pivot %d: ControlBoxDoorROT NOT found  -  door animation disabled", self.id or -1))
        end
        -- Control panel knobs — looked up by name so they work across all i3d variants.
        -- Base RX is captured here so updateControlPanel adds offsets to the GE baked angle
        -- rather than hard-coding absolute rotations. Knobs authored at -45° in GE will
        -- therefore have OFF = -45° and ON = -45°+90° = 45° automatically.
        spec.knobSystemPowerNode = findNodeByName(root, "KnobSystemPower")
        spec.knobSystemPowerBaseRX = spec.knobSystemPowerNode ~= nil
            and select(1, getRotation(spec.knobSystemPowerNode)) or 0

        spec.knobAutoManualNode  = findNodeByName(root, "KnobAutoManual")
        spec.knobAutoManualBaseRX = spec.knobAutoManualNode ~= nil
            and select(1, getRotation(spec.knobAutoManualNode)) or 0

        spec.knobWaterSupplyNode = findNodeByName(root, "KnobWaterSupply")
        spec.knobWaterSupplyBaseRX = spec.knobWaterSupplyNode ~= nil
            and select(1, getRotation(spec.knobWaterSupplyNode)) or 0

        spec.knobSpeedNode       = findNodeByName(root, "KnobSpeed")
        spec.knobSpeedBaseRX = spec.knobSpeedNode ~= nil
            and select(1, getRotation(spec.knobSpeedNode)) or 0

        spec.knobEndGunNode      = findNodeByName(root, "KnobEndGun")
        spec.knobEndGunBaseRX = spec.knobEndGunNode ~= nil
            and select(1, getRotation(spec.knobEndGunNode)) or 0

            -- Position indicator dials.
        -- PivotCurrentRot: live arm angle (always).
        -- LimitA: lower sweep limit in AUTO; target angle in MANUAL.
        -- LimitB: upper sweep limit in AUTO; target angle in MANUAL.
        -- All three animate on local X (+X = clockwise on the panel scale).
        -- Baked RY/RZ are captured here so we never clobber the GE-authored orientation.
        spec.posDialCurrentNode  = findNodeByName(root, "PivotCurrent")
        if spec.posDialCurrentNode ~= nil then
            local rx, ry, rz = getRotation(spec.posDialCurrentNode)
            spec.posDialCurrentBaseRX = rx
            spec.posDialCurrentBaseRY = ry
            spec.posDialCurrentBaseRZ = rz
        else
            rInfo("pivot: PivotCurrent node NOT found — position dial disabled")
        end

        spec.posDialMinNode = findNodeByName(root, "LimitA")
        if spec.posDialMinNode ~= nil then
            local rx, ry, rz = getRotation(spec.posDialMinNode)
            spec.posDialMinBaseRX = rx
            spec.posDialMinBaseRY = ry
            spec.posDialMinBaseRZ = rz
        else
            rInfo("pivot: LimitA node NOT found — min-limit dial disabled")
        end

        spec.posDialMaxNode = findNodeByName(root, "LimitB")
        if spec.posDialMaxNode ~= nil then
            local rx, ry, rz = getRotation(spec.posDialMaxNode)
            spec.posDialMaxBaseRX = rx
            spec.posDialMaxBaseRY = ry
            spec.posDialMaxBaseRZ = rz
        else
            rInfo("pivot: LimitB node NOT found — max-limit dial disabled")
        end

        -- Load spray effects from XML <effects> block (ParticleEffect / WASHER_WATER).
        -- self.components + self.i3dMappings are the correct roots for placeable specializations.
        if self.isClient then
            spec.effects = g_effectManager:loadEffect(
                self.xmlFile, "placeable.effects", self.components, self, self.i3dMappings)
            if spec.effects ~= nil and #spec.effects > 0 then
                -- Initialize particle system for WASHER_WATER type (required before start).
                g_effectManager:setEffectTypeInfo(spec.effects, FillType.WATER)
                rInfo(string.format("pivot %d: %d spray effects loaded (WASHER_WATER)", self.id or -1, #spec.effects))
            else
                spec.effects = {}
                rInfo(string.format("pivot %d: no spray effects loaded — add <effects> block to XML", self.id or -1))
            end
        end
    else
        rInfo(string.format("pivot %d: WARNING  -  `pivotPoint` not found in i3d. Arm rotation disabled.",
            self.id or -1))
    end

    -- ============================================================
    -- SOUND SAMPLES  (client only — loaded from XML <sounds> block)
    -- ============================================================
    if self.isClient then
        local sBase = "placeable.sounds"
        -- Loop sounds (loops=0: infinite, matching PlaceableRiceField pattern)
        spec.samples.motorLoop      = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "motorLoop",      self.baseDirectory, self.components,  0, AudioGroup.ENVIRONMENT, self.i3dMappings, self)
        spec.samples.rotationLoop   = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "rotationLoop",   self.baseDirectory, self.components,  0, AudioGroup.ENVIRONMENT, self.i3dMappings, self)
        spec.samples.sprayLoop      = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "sprayLoop",      self.baseDirectory, self.components,  0, AudioGroup.ENVIRONMENT, self.i3dMappings, self)
        spec.samples.pumpLoop       = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "pumpLoop",       self.baseDirectory, self.components,  0, AudioGroup.ENVIRONMENT, self.i3dMappings, self)
        -- One-shot sounds (loops=1: play once)
        spec.samples.switchPress    = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "switchPress",    self.baseDirectory, self.components,  1, AudioGroup.GUI,         self.i3dMappings, self)
        spec.samples.sprayToggle    = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "sprayToggle",    self.baseDirectory, self.components,  1, AudioGroup.GUI,         self.i3dMappings, self)
        spec.samples.buttonClick    = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "buttonClick",    self.baseDirectory, self.components,  1, AudioGroup.GUI,         self.i3dMappings, self)
        spec.samples.hydraulicOpen  = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "hydraulicOpen",  self.baseDirectory, self.components,  1, AudioGroup.ENVIRONMENT, self.i3dMappings, self)
        spec.samples.hydraulicClose = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "hydraulicClose", self.baseDirectory, self.components,  1, AudioGroup.ENVIRONMENT, self.i3dMappings, self)
        spec.samples.endGunToggle   = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "endGunToggle",   self.baseDirectory, self.components,  1, AudioGroup.GUI,         self.i3dMappings, self)
        spec.samples.speedClick     = g_soundManager:loadSampleFromXML(self.xmlFile, sBase, "speedClick",     self.baseDirectory, self.components,  1, AudioGroup.GUI,         self.i3dMappings, self)
        local loaded = 0
        for _, s in pairs(spec.samples) do if s ~= nil then loaded = loaded + 1 end end
        rInfo(string.format("pivot %d: %d/%d sound samples loaded", self.id or -1, loaded, 11))
    end

    -- Snapshot placement Y (terrain at pivot center).
    -- A Y value far below zero indicates a dangling save entry at world origin  -
    -- the pivot was placed in a previous session and the save entry was never
    -- removed. Flag it as a ghost so we skip terrain queries and heavy work.
    local _, py, _ = getWorldTranslation(root)
    spec.placementY = py or 0
    -- Overlay visibility: Y < -100 means the pivot is still underground in the
    -- placement preview (FS25 parks the preview instance at Y≈-500). Show the
    -- boundary overlays so the player can see them while positioning.
    -- Once the pivot is actually placed (Y on terrain, ≥ -100) hide them forever.
    local circleFenceNode = getNodeByIndexPath(root, "0>2|5")
    local squareFenceNode = getNodeByIndexPath(root, "0>2|6")
    if spec.placementY < -100 then
        spec.isGhostPivot = true
        if circleFenceNode ~= nil then setVisibility(circleFenceNode, true) end
        if squareFenceNode ~= nil then setVisibility(squareFenceNode, true) end
        rInfo(string.format(
            "pivot %d: placement preview detected (Y=%.0f)  -  overlays shown, heavy init skipped.",
            self.id or -1, spec.placementY))
    else
        if circleFenceNode ~= nil then setVisibility(circleFenceNode, false) end
        if squareFenceNode ~= nil then setVisibility(squareFenceNode, false) end
        rInfo(string.format("pivot %d: placement Y = %.2f", self.id or -1, spec.placementY))
    end

    -- Try SCS now; lazy retry in onUpdate handles late init
    self:tryRegisterWithSCS()

    -- â"€â"€ Proximity trigger (client only) â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    -- Replaces per-frame getWorldTranslation polling in onUpdate with a physics
    -- trigger that fires callbacks only when the player enters/exits the radius.

    -- â"€â"€ Savegame restore â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    -- Use raw native XML getters (getXMLBool / getXMLFloat) rather than the
    -- schema-validated xmlFile:getValue.  During EDC Reload the placeable
    -- savegame schema may be recreated before onLoad is called, meaning our
    -- custom paths are not yet re-registered.  The schema fallback path in
    -- XMLFile:getValueType uses an invalid Lua gsub replacement (%?) that
    -- would throw "invalid use of '%' in replacement string", killing onLoad
    -- before raiseActive() runs — which permanently freezes the pivot and
    -- prevents any controls from working.  Raw getters bypass getValueType
    -- entirely, matching the raw setters used in saveToXMLFile.
    if savegame ~= nil then
        local key = savegame.key .. "." .. ReinkeIrrigationPivot.MOD_NAME .. ".reinkeIrrigationPivot"
        local h   = savegame.xmlFile:getHandle()
        -- getXMLBool / getXMLFloat return nil when the attribute is absent.
        -- For bools we must NOT use "or default" (false or x → x, wrong).
        local function xmlBool(path, default)
            local v = getXMLBool(h, path)
            if v == nil then return default end
            return v
        end
        local function xmlFloat(path, default)
            return getXMLFloat(h, path) or default
        end
        local savedActive = getXMLBool(h, key .. "#isActive")
        if savedActive ~= nil then
            spec.isActive       = savedActive
            spec.armAngle       = xmlFloat(key .. "#armAngle",       spec.armAngle)
            spec.isSprayActive  = xmlBool( key .. "#isSprayActive",  false)
            spec.autoRotate     = xmlBool( key .. "#autoRotate",     false)
            spec.sweepDirection = xmlFloat(key .. "#sweepDirection", 1)
            local minDeg        = xmlFloat(key .. "#autoMinAngleDeg", 0)
            local maxDeg        = xmlFloat(key .. "#autoMaxAngleDeg", 360)
            spec.autoMinAngleDeg = minDeg
            spec.autoMaxAngleDeg = maxDeg
            spec.sweepMinAngleRad = math.rad(minDeg)
            spec.sweepMaxAngleRad = math.rad(maxDeg)
            spec.doorOpen       = xmlBool( key .. "#doorOpen",      false)
            spec.doorAngleCur   = xmlFloat(key .. "#doorAngleCur",  0)
            spec.doorAngleTgt   = spec.doorOpen and math.rad(-120) or 0
            spec.masterPower    = xmlBool( key .. "#masterPower",   false)
            -- targetAngle: only present when arm was mid-travel to a stepped target;
            -- getXMLFloat returns nil if the attribute was not written, which is correct.
            spec.targetAngle    = getXMLFloat(h, key .. "#targetAngle")
            local savedSpeed = getXMLInt(h, key .. "#speedIndex")
            if savedSpeed ~= nil and savedSpeed >= 1 and savedSpeed <= 4 then
                spec.speedIndex = savedSpeed
            end
            spec.endGunActive   = xmlBool( key .. "#endGunActive",  false)
            self:updateLights()
            rInfo(string.format("pivot %d: savegame restored: active=%s spray=%s angle=%.1f auto=%s"
                .. " door=%s sweep=(%.0f..%.0f) lights=%s",
                self.id or -1,
                tostring(spec.isActive), tostring(spec.isSprayActive),
                math.deg(spec.armAngle), tostring(spec.autoRotate),
                tostring(spec.doorOpen), minDeg, maxDeg, tostring(spec.masterPower)))
            -- Restore spray effect state (effects loaded above; start if spray was active)
            if spec.isSprayActive and self.isClient and spec.effects ~= nil and #spec.effects > 0 then
                g_effectManager:startEffects(spec.effects)
            end
        else
            rInfo(string.format("pivot %d: no savegame data found at key='%s'  -  using defaults",
                self.id or -1, key))
        end
    end

    -- Opt into the engine update loop. raiseActive is single-shot per call;
    -- we re-raise from onPostLoad (defensive) and from every onUpdate.
    self:raiseActive()
end

-- ============================================================
-- SAVEGAME
-- ============================================================
function ReinkeIrrigationPivot.saveToXMLFile(self, xmlFile, key, usedModNames)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec == nil then return end
    -- FS25 already passes the full specialisation path as `key`
    -- (e.g. "placeables.placeable(0).FS25_ReinkeA22.reinkeIrrigationPivot").
    -- Do NOT append the mod/spec name again or the written path will be doubled
    -- and the loader (which reconstructs the same single path from savegame.key)
    -- will never find the data → "no savegame data found" on every load.
    local k = key
    -- Use raw native XML setters (setXMLBool / setXMLFloat) rather than the
    -- schema-validated xmlFile:setValue.  During EDC Reload the placeable
    -- savegame schema is recreated before saveToXMLFile is called, so our
    -- custom paths are not yet re-registered.  The schema fallback path in
    -- XMLFile:getValueType uses an invalid Lua gsub replacement string (%?)
    -- that throws "invalid use of '%' in replacement string" in that window.
    -- Raw setters bypass getValueType entirely, fixing the EDC Reload crash.
    local h = xmlFile:getHandle()
    setXMLBool( h, k .. "#isActive",        spec.isActive  or false)
    setXMLFloat(h, k .. "#armAngle",        spec.armAngle  or 0)
    setXMLBool( h, k .. "#isSprayActive",   spec.isSprayActive  or false)
    setXMLBool( h, k .. "#autoRotate",      spec.autoRotate     or false)
    setXMLFloat(h, k .. "#sweepDirection",  spec.sweepDirection or 1)
    setXMLFloat(h, k .. "#autoMinAngleDeg", spec.autoMinAngleDeg or 0)
    setXMLFloat(h, k .. "#autoMaxAngleDeg", spec.autoMaxAngleDeg or 360)
    setXMLBool( h, k .. "#doorOpen",        spec.doorOpen  or false)
    setXMLFloat(h, k .. "#doorAngleCur",    spec.doorAngleCur   or 0)
    setXMLBool( h, k .. "#masterPower",     spec.masterPower    or false)
    if spec.targetAngle ~= nil then
        setXMLFloat(h, k .. "#targetAngle", spec.targetAngle)
    end
    setXMLInt( h, k .. "#speedIndex",   spec.speedIndex   or 2)
    setXMLBool(h, k .. "#endGunActive", spec.endGunActive or false)
    rInfo(string.format("pivot %d: saveToXMLFile at key='%s': active=%s spray=%s door=%s lights=%s",
        self.id or -1, k,
        tostring(spec.isActive), tostring(spec.isSprayActive), tostring(spec.doorOpen), tostring(spec.masterPower)))
end

-- ============================================================
-- NETWORK STREAM (multiplayer dirty-flag sync)
-- ============================================================
function ReinkeIrrigationPivot.onWriteUpdateStream(self, streamId, connection, dirtyMask)
    if connection:getIsServer() then return end
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if streamWriteBool(streamId, bitAND(dirtyMask, spec.dirtyFlag) ~= 0) then
        streamWriteBool(streamId,   spec.isActive)
        streamWriteFloat32(streamId, spec.armAngle)
        streamWriteBool(streamId,   spec.isSprayActive)
        streamWriteBool(streamId,   spec.autoRotate)
        streamWriteFloat32(streamId, spec.sweepDirection)
        streamWriteFloat32(streamId, spec.autoMinAngleDeg)
        streamWriteFloat32(streamId, spec.autoMaxAngleDeg)
        streamWriteBool(streamId,   spec.doorOpen)
        streamWriteFloat32(streamId, spec.doorAngleCur)
        streamWriteBool(streamId,   spec.masterPower)
        streamWriteBool(streamId,   spec.endGunActive or false)
        streamWriteInt32(streamId,  spec.speedIndex or 2)
    end
end

function ReinkeIrrigationPivot.onReadUpdateStream(self, streamId, timestamp, connection)
    if not connection:getIsServer() then return end
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if streamReadBool(streamId) then
        spec.isActive         = streamReadBool(streamId)
        spec.armAngle         = streamReadFloat32(streamId)
        spec.isSprayActive    = streamReadBool(streamId)
        spec.autoRotate       = streamReadBool(streamId)
        spec.sweepDirection   = streamReadFloat32(streamId)
        spec.autoMinAngleDeg  = streamReadFloat32(streamId)
        spec.autoMaxAngleDeg  = streamReadFloat32(streamId)
        spec.doorOpen         = streamReadBool(streamId)
        spec.doorAngleCur     = streamReadFloat32(streamId)
        spec.masterPower      = streamReadBool(streamId)
        spec.endGunActive     = streamReadBool(streamId)
        local si              = streamReadInt32(streamId)
        if si >= 1 and si <= 4 then spec.speedIndex = si end
        spec.doorAngleTgt     = spec.doorOpen and math.rad(-120) or 0
        self:updateLights()
        -- Spray effect state will reconcile on the next onUpdateTick spray-flip check
        rInfo(string.format("pivot %d: onReadUpdateStream sync: active=%s spray=%s angle=%.1f auto=%s"
            .. " sweep=(%.0f..%.0f) door=%s",
            self.id or -1,
            tostring(spec.isActive), tostring(spec.isSprayActive),
            math.deg(spec.armAngle), tostring(spec.autoRotate),
            spec.autoMinAngleDeg, spec.autoMaxAngleDeg,
            tostring(spec.doorOpen)))
    end
end

-- onPostLoad is raised after onLoad and the placeable is more fully wired
-- into the world. Re-raising here is defensive — covers the case where the
-- onLoad raiseActive was rejected for being too early in the load lifecycle.
function ReinkeIrrigationPivot.onPostLoad(self, savegame)
    if self.isPreviewMode then return end
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    -- Apply saved arm angle immediately so the arm is at the correct position
    -- before the first onUpdate fires (avoids a single-frame snap from 0).
    if spec.pivotPointNode ~= nil then
        local rx, _, rz = getRotation(spec.pivotPointNode)
        setRotation(spec.pivotPointNode, rx, spec.pivotBaseRotY - spec.armAngle, rz)
    end
    -- Apply saved door angle immediately.  updateControlPanel uses a dead-band
    -- (|diff| > 0.001) so it never fires when doorAngleCur already equals
    -- doorAngleTgt — the shape node stays at its baked (closed) pose even though
    -- spec.doorOpen = true.  Without this the player sees a closed door and presses
    -- F to "open" it, which toggles doorOpen false → loses tier-2/3 controls.
    if spec.doorShapeNode ~= nil then
        setRotation(spec.doorShapeNode, 0, spec.doorAngleCur or 0, 0)
    end
    self:raiseActive()
end

-- ============================================================
-- SCS REGISTRATION
-- ============================================================
function ReinkeIrrigationPivot.tryRegisterWithSCS(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.enableSCS then return false end   -- SCS integration disabled via XML
    if spec.scsIntegrated then return true end
    local im = getSCSIrrigationManager()
    if im == nil then
        spec.scsRegisterAttempts = spec.scsRegisterAttempts + 1
        return false
    end
    spec.irrigationManager = im
    -- SCS reads config directly off the placeable object, not the spec sub-table.
    -- Copy spec values onto self so registerIrrigationSystem() gets the correct
    -- Reinke-specific radius, flow rate, etc. instead of falling back to SCS defaults.
    self.irrigationType          = "pivot"
    self.radius                  = spec.radius
    self.flowRatePerHour         = spec.flowRatePerHour
    self.operationalCostPerHour  = spec.operationalCostPerHour
    self.defaultStartHour        = spec.defaultStartHour
    self.defaultEndHour          = spec.defaultEndHour
    self.defaultActiveDays       = spec.defaultActiveDays
    im:registerIrrigationSystem(self)
    spec.scsIntegrated = true
    rInfo(string.format(
        "pivot %d INTEGRATED with SCS  -  radius=%.0fm flow=%.4f sweep=%s revs/hr=%.2f forceActive=%s",
        self.id or -1, spec.radius, spec.flowRatePerHour, spec.sweepMode,
        spec.rotationRevPerGameHour, tostring(spec.forceAlwaysActive)
    ))
    -- Update the R-key hint text to show the SCS dialog label now that
    -- SCS integration is live. Action events are already registered and
    -- do NOT need to be removed/re-added.
    if spec.actionEventId ~= nil and g_inputBinding ~= nil then
        local label = (g_i18n ~= nil and g_i18n:getText("reinke_pivot_open_dialog"))
                   or "Open Irrigation Schedule"
        g_inputBinding:setActionEventText(spec.actionEventId, label)
    end
    return true
end

-- ============================================================
-- ROTATION
-- ============================================================
function ReinkeIrrigationPivot.updateArmRotation(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec.pivotPointNode == nil then return end

    -- Advance the angle only when active; always apply setRotation so the arm
    -- appears at the correct saved position even when stopped (isActive = false).
    if spec.isActive then
    local timeScale = 1
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        timeScale = g_currentMission.missionInfo.timeScale or 1
    end
    local gameDtSec = (dt * 0.001) * timeScale
    local speedMult = ReinkeIrrigationPivot.SPEED_MULTS[spec.speedIndex or 2]
    local maxStep   = gameDtSec * spec.rotationRevPerGameHour * speedMult * (2 * math.pi) / 3600.0
    if maxStep ~= 0 then

    if spec.autoRotate then
        -- â"€â"€ Auto-rotate mode â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
        -- Sweeps continuously between autoMinAngleDeg and autoMaxAngleDeg.
        -- When the range is 360Â° the arm just keeps going forward (no reversal).
        local rangeDeg = (spec.autoMaxAngleDeg or 360) - (spec.autoMinAngleDeg or 0)
        if rangeDeg >= 360 then
            -- Full circle  -  advance monotonically
            spec.armAngle = (spec.armAngle + maxStep) % (2 * math.pi)
        else
            local minRad = math.rad(spec.autoMinAngleDeg or 0)
            local maxRad = math.rad(spec.autoMaxAngleDeg or 360)

            -- â"€â"€ Smooth bound-change recovery â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
            -- When the user adjusts sweep limits the arm may now lie outside the
            -- new window.  Rather than clamping it instantly (a jarring jump),
            -- correct sweepDirection so the arm naturally drives back inside.
            -- The normal clamp below still fires once the arm REACHES the bound
            -- via motion  -  this only handles the "already outside" case.
            if spec.armAngle > maxRad and (spec.sweepDirection or 1) > 0 then
                -- Above upper bound and still heading up â†’ reverse toward max
                spec.sweepDirection = -1
            elseif spec.armAngle < minRad and (spec.sweepDirection or 1) < 0 then
                -- Below lower bound and still heading down â†’ reverse toward min
                spec.sweepDirection = 1
            end

            spec.armAngle = spec.armAngle + maxStep * (spec.sweepDirection or 1)
            -- Only snap-and-reverse when the arm is crossing a bound in the
            -- direction it is ALREADY travelling.  Without the direction guard
            -- an arm that starts BELOW minRad while heading up would snap to
            -- minRad every frame (arm <= minRad is true the whole way up).
            if spec.armAngle >= maxRad and (spec.sweepDirection or 1) > 0 then
                spec.armAngle       = maxRad
                spec.sweepDirection = -1
            elseif spec.armAngle <= minRad and (spec.sweepDirection or 1) < 0 then
                spec.armAngle       = minRad
                spec.sweepDirection = 1
            end
        end

    elseif spec.targetAngle ~= nil then
        -- â"€â"€ Fixed-angle mode â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
        -- Motor to targetAngle via shortest path, then stop.
        local diff = (spec.targetAngle - spec.armAngle) % (2 * math.pi)
        if diff > math.pi then diff = diff - 2 * math.pi end  -- normalise to (-Ï€, Ï€]

        local tol = math.rad(0.5)   -- within 0.5Â° = arrived
        if math.abs(diff) <= tol then
            spec.armAngle        = spec.targetAngle
            spec.targetAngle     = nil
            spec.isActive        = false   -- arm parks
            self:raiseDirtyFlags(spec.dirtyFlag)
            spec.lastArmTravelDir = 0      -- parked  -  no spinning
            rInfo(string.format("pivot %d: reached target %.0fÂ°  -  arm parked",
                self.id or -1, math.deg(spec.armAngle)))
        else
            local sign    = diff >= 0 and 1 or -1
            local step    = math.min(math.abs(diff), maxStep)
            spec.armAngle        = (spec.armAngle + sign * step) % (2 * math.pi)
            spec.lastArmTravelDir = sign   -- record direction for wheel/shaft animation
        end
    end
    end -- if maxStep ~= 0
    end -- if spec.isActive

    -- Always apply the current angle so a stopped arm appears at its saved position.
    -- Negate armAngle so that increasing armAngle = clockwise rotation viewed from above.
    local rx, _, rz = getRotation(spec.pivotPointNode)
    setRotation(spec.pivotPointNode, rx, spec.pivotBaseRotY - spec.armAngle, rz)
    -- Sync the physics proxy so kinematic collision shapes on the pivot arm
    -- follow the visual rotation. updateRigidBody on pivotPointNode covers the
    -- compound-root case. Independent kinematic child nodes (section collision shapes)
    -- each need their own call because they are not compound children of pivotPointNode.
    -- Guard: updateRigidBody is nil in some FS25 placeable environments.
    if updateRigidBody ~= nil then
        updateRigidBody(spec.pivotPointNode)
        if spec.sections ~= nil then
            for _, section in ipairs(spec.sections) do
                if section.rotateNode ~= nil then
                    updateRigidBody(section.rotateNode)
                end
            end
        end
    end
end

-- ============================================================
-- SPRAY EFFECTS  (EffectManager / ParticleEffect / WASHER_WATER)
-- Loaded from XML <effects> block in onLoad.
-- Controlled purely via g_effectManager:startEffects/stopEffects.
-- ============================================================

function ReinkeIrrigationPivot.startSprayerParticles(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not self.isClient then return end
    if spec.effects == nil or #spec.effects == 0 then return end
    -- Begin the progressive feather-on sequence — nozzles fire one at a time
    -- at SPRAY_FEATHER_INTERVAL_MS intervals until all are running.
    spec.sprayFeatherIndex   = 0
    spec.sprayFeatherAccumMs = ReinkeIrrigationPivot.SPRAY_FEATHER_INTERVAL_MS  -- fire nozzle 1 immediately
    spec.sprayFeatherActive  = true
    rInfo(string.format("pivot %d: spray FEATHER START — %d nozzles × %.0f ms = ~%.0f s total ramp",
        self.id or -1, #spec.effects,
        ReinkeIrrigationPivot.SPRAY_FEATHER_INTERVAL_MS,
        #spec.effects * ReinkeIrrigationPivot.SPRAY_FEATHER_INTERVAL_MS / 1000))
end

function ReinkeIrrigationPivot.stopSprayerParticles(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not self.isClient then return end
    -- Cancel any in-progress feather sequence immediately
    spec.sprayFeatherActive  = false
    spec.sprayFeatherIndex   = 0
    spec.sprayFeatherAccumMs = 0
    -- Stop all effects at once regardless of how far feathering progressed
    if spec.effects ~= nil and #spec.effects > 0 then
        g_effectManager:stopEffects(spec.effects)
    end
end

-- ============================================================
-- SPRAY FEATHER TICK
-- Called from onUpdate every client frame while sprayFeatherActive.
-- Activates one nozzle (effect) every SPRAY_FEATHER_INTERVAL_MS ms,
-- progressing from nozzle 1 at the pivot head outward to the end gun.
-- Using a while-loop allows catch-up after frame-rate spikes without
-- ever skipping a nozzle, while still honouring the configured interval.
-- ============================================================
function ReinkeIrrigationPivot.tickSprayFeather(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.sprayFeatherActive then return end
    if spec.effects == nil or #spec.effects == 0 then
        spec.sprayFeatherActive = false
        return
    end

    spec.sprayFeatherAccumMs = spec.sprayFeatherAccumMs + dt
    local interval = ReinkeIrrigationPivot.SPRAY_FEATHER_INTERVAL_MS

    -- Fire as many nozzles as the elapsed time covers (handles frame-rate spikes)
    while spec.sprayFeatherAccumMs >= interval
          and spec.sprayFeatherIndex < #spec.effects do
        spec.sprayFeatherAccumMs = spec.sprayFeatherAccumMs - interval
        spec.sprayFeatherIndex   = spec.sprayFeatherIndex + 1
        local eff = spec.effects[spec.sprayFeatherIndex]
        if eff ~= nil and eff.start ~= nil then
            eff:start()
        end
    end

    -- Sequence complete when all nozzles have been started
    if spec.sprayFeatherIndex >= #spec.effects then
        spec.sprayFeatherActive = false
        rInfo(string.format("pivot %d: spray FEATHER COMPLETE — all %d nozzles active",
            self.id or -1, #spec.effects))
    end
end

-- (spray effects sequenced per-nozzle via tickSprayFeather; stop via g_effectManager:stopEffects)

-- ============================================================
-- RUNNING LIGHTS
-- Lights track masterPower directly (no isActive dependency).
-- LightBulbLight: toggled via setVisibility.
-- LightBulbGlass: emissive toggled via setShaderParameter "lightControl".
--   ON  → restore GE-authored float4 baked at load.
--   OFF → zero all four components (glass mesh stays visible, glow extinguishes).
-- Scales automatically to 7/11-tower variants — no per-variant code needed.
-- ============================================================
function ReinkeIrrigationPivot.updateLights(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    local on = spec.masterPower == true

    -- Point Light nodes (LightBulbLight) — simple visibility toggle
    for _, n in ipairs(spec.lightNodes or {}) do
        if entityExists(n) then setVisibility(n, on) end
    end

    -- Glass mesh nodes (LightBulbGlass) — shader parameter toggle.
    -- LIGHT_GLOW_INTENSITY is the authored x-component of lightControl in GE.
    -- setShaderParameter on a multi-material mesh is safe: materials whose shader
    -- doesn't define 'lightControl' silently ignore the call.
    local glowOn = on and ReinkeIrrigationPivot.LIGHT_GLOW_INTENSITY or 0
    for _, n in ipairs(spec.lightGlowNodes or {}) do
        if entityExists(n) then
            -- pcall guards against third-party mods (e.g. TH PlaceableDesignKit) that
            -- hook setShaderParameter globally and may crash on unrecognised nodes.
            pcall(setShaderParameter, n, "lightControl", glowOn, 0, 0, 0)
        end
    end
    -- Also sync the motion-indicator button whenever power state changes.
    self:updateButtonLight()
end

-- ============================================================
-- BUTTON1 MOTION-INDICATOR LIGHT
-- Illuminates only when master power is ON and pivot is moving.
-- Uses the same lightControl shader parameter as LightBulbGlass.
-- Called on every isActive state-flip and on power toggle.
-- Button1 may be a TG parent: we write the param to both the node
-- and its first child so the actual Shape mesh is always reached.
-- ============================================================
function ReinkeIrrigationPivot.updateButtonLight(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec.button1GlowNode == nil then return end

    local lit = spec.masterPower == true and spec.isActive == true
    if lit == spec.lastButtonLit then return end   -- no change, skip setShaderParameter
    spec.lastButtonLit = lit

    local intensity = lit and ReinkeIrrigationPivot.LIGHT_GLOW_INTENSITY or 0
    if entityExists(spec.button1GlowNode) then
        -- button1GlowNode is resolved to a Shape at load time (see onLoad), so
        -- no child fallback needed here. pcall guards the TH PlaceableDesignKit hook.
        pcall(setShaderParameter, spec.button1GlowNode, "lightControl", intensity, 0, 0, 0)
    end
end

-- ============================================================
-- SOUND LOOP RECONCILIATION
-- Called from onUpdateTick every tick to keep loop sounds in sync
-- with the current isActive / isSprayActive states. Uses
-- getIsSamplePlaying so it is self-healing after reloads.
-- ============================================================
function ReinkeIrrigationPivot.syncLoopSounds(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not self.isClient or spec.samples == nil then return end
    local sm = g_soundManager

    -- Motor hum + tower rotation: run while arm is rotating
    if spec.isActive then
        if not sndPlaying(spec.samples.motorLoop)    then sndPlay(spec.samples.motorLoop) end
        if not sndPlaying(spec.samples.rotationLoop) then sndPlay(spec.samples.rotationLoop) end
    else
        if sndPlaying(spec.samples.motorLoop)    then sndStop(spec.samples.motorLoop) end
        if sndPlaying(spec.samples.rotationLoop) then sndStop(spec.samples.rotationLoop) end
    end

    -- Sprayer + pump: run while spray is on
    if spec.isSprayActive then
        if not sndPlaying(spec.samples.sprayLoop) then sndPlay(spec.samples.sprayLoop) end
        if not sndPlaying(spec.samples.pumpLoop)  then sndPlay(spec.samples.pumpLoop) end
    else
        if sndPlaying(spec.samples.sprayLoop) then sndStop(spec.samples.sprayLoop) end
        if sndPlaying(spec.samples.pumpLoop)  then sndStop(spec.samples.pumpLoop) end
    end
end

function ReinkeIrrigationPivot.toggleMasterPower(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    spec.masterPower = not spec.masterPower
    if self.isClient then sndPlay1(spec.samples.switchPress) end

    if not spec.masterPower then
        -- Kill all active operations when master power is cut
        spec.autoRotate  = false
        spec.isActive    = false
        spec.targetAngle = nil
        if spec.isSprayActive then
            spec.isSprayActive = false
            self:stopSprayerParticles()
        end
        rInfo(string.format("pivot %d: MASTER POWER OFF — arm stopped, spray off, lights off",
            self.id or -1))
    else
        rInfo(string.format("pivot %d: MASTER POWER ON — system ready", self.id or -1))
    end

    self:raiseDirtyFlags(spec.dirtyFlag)
    self:updateLights()
    -- Refresh the F1 hint tiers: tier-3 keys appear/disappear with power state
    self:setInteractionHintsVisible(true)
end

function ReinkeIrrigationPivot.onMasterPowerPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen then return end
    self:toggleMasterPower()
end

-- ============================================================
-- TERRAIN ARTICULATION
-- For each tower, reads wheel terrain heights and rotates the
-- ROTATE node (StructureCenterROTATE1 / MiddleROTATE2 / EndROTATE3)
-- on X (side-to-side roll) and Z (fore-aft pitch) to keep wheels
-- planted on the terrain surface at the target hub height.
--
-- Only the 3 ROTATE nodes are written. No children are searched.
-- No translations are applied. Pure Euler rotation.
--
-- Rotation conventions (confirmed from i3d):
--   +Z = boom tip rises, wheels move DOWN relative to pivot
--   -Z = boom tip falls, wheels move UP relative to pivot
--   +X = RH wheel DOWN, LH wheel UP
--   -X = RH wheel UP,   LH wheel DOWN
--
-- Throttled to 4 Hz by onUpdateTick.
-- ============================================================
function ReinkeIrrigationPivot.updateTerrainArticulation(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec.isGhostPivot or g_terrainNode == nil then return end
    if spec.sections == nil or #spec.sections == 0 then return end

    local emaAlpha = ReinkeIrrigationPivot.TERRAIN_EMA_ALPHA
    local maxPitch = math.rad(ReinkeIrrigationPivot.TERRAIN_MAX_SPAN_PITCH_DEG)
    local maxRoll  = math.rad(ReinkeIrrigationPivot.TERRAIN_MAX_TOWER_ROLL_DEG)
    local maxErr   = 0  -- track worst-case height error this pass for adaptive frequency

    for _, s in ipairs(spec.sections) do
        if s.wheelLH == nil or s.wheelRH == nil or s.rotateNode == nil then break end

        -- World position of each wheel hub — XZ for terrain sampling, Y for clearance
        local lhx, lhy, lhz = getWorldTranslation(s.wheelLH)
        local rhx, rhy, rhz = getWorldTranslation(s.wheelRH)

        -- Terrain heights at both wheel positions
        local tLH  = getTerrainHeightAtWorldPos(g_terrainNode, lhx, 0, lhz)
        local tRH  = getTerrainHeightAtWorldPos(g_terrainNode, rhx, 0, rhz)
        local tMid = (tLH + tRH) * 0.5
        local hub  = ReinkeIrrigationPivot.WHEEL_HUB_ABOVE_GROUND  -- 0.628 m

        -- ── Pitch (Z rotation) ────────────────────────────────────────────────
        -- Drive the average wheel hub to exactly (terrain + hub).
        -- pitchError > 0  →  wheels too high, need more downward pitch (negative Z)
        -- pitchError < 0  →  wheels too low,  need less pitch (positive Z)
        local armLen     = s.armLength or 37.0
        local midHubY    = (lhy + rhy) * 0.5
        local pitchError = (midHubY - tMid) - hub
        local targetPitch = s.thetaEMA - pitchError / armLen
        targetPitch = clamp(targetPitch, -maxPitch, maxPitch)

        -- ── Roll (X rotation) ─────────────────────────────────────────────────
        -- Drive each individual wheel hub to (its own terrain + hub).
        -- +X = RH wheel down / LH up.
        -- rollError > 0  →  LH hub too high relative to RH → need −X (LH down)
        -- rollError < 0  →  LH hub too low  relative to RH → need +X (LH up)
        local trackW     = s.trackWidth or 4.0
        local lhClear    = lhy - tLH
        local rhClear    = rhy - tRH
        local rollError  = lhClear - rhClear
        local targetRoll  = s.lateralEMA - rollError / trackW
        targetRoll = clamp(targetRoll, -maxRoll, maxRoll)

        -- ── EMA smoothing ─────────────────────────────────────────────────────
        s.thetaEMA   = s.thetaEMA   + emaAlpha * (targetPitch - s.thetaEMA)
        s.lateralEMA = s.lateralEMA + emaAlpha * (targetRoll  - s.lateralEMA)

        -- Track worst-case raw error across all sections for adaptive interval decision.
        local sectionErr = math.abs(pitchError) + math.abs(rollError * 0.5)
        if sectionErr > maxErr then maxErr = sectionErr end

        -- ── Apply span rotation ───────────────────────────────────────────────
        local wantRZ = s.baseRZ + s.thetaEMA
        local wantRX = s.baseRX + s.lateralEMA
        -- Apply every tick — no dead-band gate.
        -- A threshold here causes the EMA to accumulate past the needed correction
        -- while setRotation is blocked, then fire a large jump that overshoots,
        -- creating the 1m oscillation.
        setRotation(s.rotateNode, wantRX, s.baseRY, wantRZ)
        if updateRigidBody ~= nil then updateRigidBody(s.rotateNode) end

    end

    -- Expose the worst-case height error so the caller can adapt the poll interval.
    spec.terrainLastError = maxErr
end

-- ============================================================
-- PRESSURE GAUGE NEEDLE
-- Rotates PressureGaugeNeedleROT on the local Y axis.
-- Water ON  → needle eases to -90° (pointing straight up) with a
--             small random flutter to simulate live pressure.
-- Water OFF → needle eases back to 0° (resting position).
-- "Water ON" is defined as isSprayActive (the G-key spray toggle).
-- Future: hook into SCS pressureMultiplier for a real pressure curve.
-- ============================================================
function ReinkeIrrigationPivot.updatePressureGauge(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec.pressureNeedleNode == nil then return end

    local dtSec = (dt or 0) * 0.001

    -- Linear ramp: 90° over exactly 5 seconds in both directions
    local FULL_ANGLE = math.rad(-90)
    local RAMP_RATE  = math.abs(FULL_ANGLE) / 5.0   -- rad/s  (18°/s)

    -- ── Step the base angle linearly toward its target ──────────────────────
    local baseTarget = spec.isSprayActive and FULL_ANGLE or 0
    local diff = baseTarget - spec.pressureNeedleBase
    local step = RAMP_RATE * dtSec
    if math.abs(diff) <= step then
        spec.pressureNeedleBase = baseTarget
    else
        spec.pressureNeedleBase = spec.pressureNeedleBase + (diff > 0 and step or -step)
    end

    -- ── Flutter (only while spray is on) ────────────────────────────────────
    -- Scaled by travel progress (0→1) so the needle is steady at rest and
    -- fluttering fully only when it reaches operating pressure.
    if spec.isSprayActive then
        spec.pressureFlutterAccum = spec.pressureFlutterAccum + dtSec
        if spec.pressureFlutterAccum >= spec.pressureFlutterInterval then
            spec.pressureFlutterAccum    = 0
            spec.pressureFlutterInterval = 0.10 + math.random() * 0.15   -- 100–250 ms
            spec.pressureFlutterOffset   = (math.random() - 0.5) * math.rad(7)  -- ±3.5°
        end
    else
        spec.pressureFlutterAccum  = 0
        spec.pressureFlutterOffset = 0
    end

    local progress  = math.abs(spec.pressureNeedleBase / FULL_ANGLE)   -- 0..1
    local flutterY  = spec.pressureFlutterOffset * progress

    spec.pressureNeedleAngle = spec.pressureNeedleBase + flutterY
    setRotation(spec.pressureNeedleNode, 0, spec.pressureNeedleAngle, 0)
end

-- ============================================================
-- HEARTBEAT
-- ============================================================
function ReinkeIrrigationPivot.logHeartbeat(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.isActive then return end
    local pressurePct, fields = 0, 0
    if spec.scsIntegrated and spec.irrigationManager ~= nil then
        local sys = spec.irrigationManager.systems[self.id]
        if sys ~= nil then
            pressurePct = math.floor((sys.pressureMultiplier or 0) * 100)
            fields = #(sys.coveredFields or {})
        end
    end
    rInfo(string.format(
        "pivot %d HEARTBEAT  -  angle=%.1fÂ° pressure=%d%% fields=%d sweep=%s force=%s",
        self.id or -1, math.deg(spec.armAngle), pressurePct, fields, spec.sweepMode, tostring(spec.forceAlwaysActive)
    ))
end

-- ============================================================
-- WHEEL ROTATION
-- Spins WheelLH / WheelRH nodes proportional to their arc speed.
-- Arc speed = arm angular velocity Ã— distance from pivot center.
-- Wheel spin rate = arc speed / wheel radius (WHEEL_HUB_ABOVE_GROUND â‰ˆ 0.628 m).
--
-- Three test axes selectable via XML wheelRotAxis:
--   "X"   -  positive local X (try first; axle probably runs along section local X)
--   "Z"   -  positive local Z
--   "NX"  -  negative local X (if X gives reverse spin)
-- ============================================================
function ReinkeIrrigationPivot.updateWheelRotation(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.isActive then return end
    if spec.sections == nil or spec.pivotPointNode == nil then return end

    local timeScale = 1
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        timeScale = g_currentMission.missionInfo.timeScale or 1
    end
    local gameDtSec  = (dt * 0.001) * timeScale
    local speedMult  = ReinkeIrrigationPivot.SPEED_MULTS[spec.speedIndex or 2]
    -- Arm angle step this frame (same formula as updateArmRotation).
    -- Apply live sweepDirection whenever the arm is running in bounded auto-mode
    -- (range < 360Â°) so wheels reverse correctly when the arm bounces.
    -- For full-circle auto-mode the arm always advances CW so direction stays +1.
    -- For fixed-angle stepping, use self.lastArmTravelDir (set by updateArmRotation).
    local armDelta = gameDtSec * spec.rotationRevPerGameHour * speedMult * (2 * math.pi) / 3600.0
    if spec.autoRotate then
        local rangeDeg = (spec.autoMaxAngleDeg or 360) - (spec.autoMinAngleDeg or 0)
        if rangeDeg < 360 then
            armDelta = armDelta * (spec.sweepDirection or 1)
        end
    elseif spec.lastArmTravelDir ~= nil then
        -- Fixed-angle (manual step) mode: mirror direction from last step sign.
        armDelta = armDelta * spec.lastArmTravelDir
    end

    local WHEEL_RADIUS  = ReinkeIrrigationPivot.WHEEL_HUB_ABOVE_GROUND   -- ~0.628 m
    local rotAxis       = spec.wheelRotAxis or "X"
    local pivX, _, pivZ = getWorldTranslation(spec.pivotPointNode)

    for _, section in ipairs(spec.sections) do
        if section.wheelRefNode ~= nil and section.wheelNodes ~= nil then
            local wx, _, wz = getWorldTranslation(section.wheelRefNode)
            local distFromCenter = math.sqrt((wx - pivX)*(wx - pivX) + (wz - pivZ)*(wz - pivZ))

            -- Arc length â†’ wheel rotation delta
            local arcLen    = distFromCenter * math.abs(armDelta)
            local spinDelta = arcLen / WHEEL_RADIUS
            -- CW arm rotation (positive armDelta) = wheels spin opposite to old CCW convention.
            if armDelta >= 0 then spinDelta = -spinDelta end

            for _, wheelNode in ipairs(section.wheelNodes) do
                local rx, ry, rz = getRotation(wheelNode)
                if rotAxis == "X" then
                    setRotation(wheelNode, rx + spinDelta, ry, rz)
                elseif rotAxis == "Z" then
                    setRotation(wheelNode, rx, ry, rz + spinDelta)
                else  -- "NX"
                    setRotation(wheelNode, rx - spinDelta, ry, rz)
                end
            end
        end
    end
end



-- ============================================================
-- DRIVE SHAFT SPIN ANIMATION
-- Spins drive shaft nodes on local Z while the arm is rotating.
-- Drive shaft nodes are discovered at load by name (see onLoad).
-- Speed is set via self.shaftSpinSpeed (rad/s, default 720Â°/s).
-- ============================================================
function ReinkeIrrigationPivot.updateDriveShaftAnimation(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.isActive then return end
    if spec.driveShaftNodes == nil or #spec.driveShaftNodes == 0 then return end

    local timeScale = 1
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        timeScale = g_currentMission.missionInfo.timeScale or 1
    end
    local dtSec    = (dt * 0.001) * timeScale
    local speedMult = ReinkeIrrigationPivot.SPEED_MULTS[spec.speedIndex or 2]

    -- Mirror travel direction: bounded auto-mode uses sweepDirection; fixed-angle
    -- steps use lastArmTravelDir.  Full-circle auto-mode is always forward (+1).
    local travelDir = 1
    if spec.autoRotate then
        local rangeDeg = (spec.autoMaxAngleDeg or 360) - (spec.autoMinAngleDeg or 0)
        if rangeDeg < 360 then
            travelDir = spec.sweepDirection or 1
        end
    elseif spec.lastArmTravelDir ~= nil then
        travelDir = spec.lastArmTravelDir
    end

    -- Negate: positive travelDir is now CW arm rotation, so shafts spin opposite to old convention.
    local delta = -spec.shaftSpinSpeed * dtSec * travelDir * speedMult

    for _, node in ipairs(spec.driveShaftNodes) do
        local rx, ry, rz = getRotation(node)
        setRotation(node, rx, ry, rz + delta)
    end
end

-- ============================================================
-- END GUN ANIMATION
-- Drives the squirtPart_treeLance gun barrel (Y sweep Â±100Â°) and its
-- child deflector bumper (Z oscillation 0â†’-80Â°) while isSprayActive.
--
-- Gun barrel: sweeps back and forth across a Â±100Â° arc at endGunSweepSpeed
--   (default 40Â°/s).  Full cycle: ~10 s.  Mimics a Nelson-style rotary
--   gun sprinkler that slowly pans across the wetted area.
--
-- Deflector bumper: oscillates 0â†’-80Â° at deflectorSpeed (default 120Â°/s).
--   Full cycle: ~1.3 s.  Each time it returns to 0Â° (the "hit" position) a
--   burst effect fires briefly  -  this is the wide splash you see on real end
--   guns when the deflector plate intercepts the stream.
--
-- Both animations reset to base-rotation when isSprayActive turns off.
-- ============================================================
function ReinkeIrrigationPivot.updateEndGunAnimation(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if spec.endGunNode == nil then return end

    local timeScale = 1
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        timeScale = g_currentMission.missionInfo.timeScale or 1
    end
    local dtSec = (dt * 0.001) * timeScale

    -- End gun runs only when both main spray AND the end gun switch are ON.
    if not spec.isSprayActive or not spec.endGunActive then
        -- Either spray or end gun switched off: snap everything back to rest pose.
        if spec.endGunAngle ~= 0 or spec.deflectorAngle ~= 0 then
            local baseY = spec.endGunBaseRY or 0
            local baseZ = spec.deflectorBaseRZ or 0
            setRotation(spec.endGunNode, 0, baseY, 0)
            if spec.endGunDeflectorNode ~= nil then
                setRotation(spec.endGunDeflectorNode, 0, 0, baseZ)
            end
            spec.endGunAngle    = 0
            spec.deflectorAngle = 0
            spec.deflectorDir   = -1   -- restart toward -80Â° next activation
            spec.endGunDir      = 1
        end
        -- Hide burst nodes if they were left visible
        if spec.burstActive then
            spec.burstActive = false
            for _, bn in ipairs(spec.endGunBurstNodes) do
                if entityExists(bn) then setVisibility(bn, false) end
            end
        end
        -- Hide only the effects TG so water stops but the gun mesh stays visible.
        if spec.endGunVisible ~= false then
            if spec.endGunEffectsNode ~= nil then
                setVisibility(spec.endGunEffectsNode, false)
            end
            spec.endGunVisible = false
        end
        return
    end

    -- Gun turned on: restore effects visibility before animating.
    if spec.endGunVisible ~= true then
        if spec.endGunEffectsNode ~= nil then
            setVisibility(spec.endGunEffectsNode, true)
        end
        spec.endGunVisible = true
    end

    -- â"€â"€ Gun barrel sweep (Y axis) â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    spec.endGunAngle = spec.endGunAngle + spec.endGunDir * spec.endGunSweepSpeed * dtSec
    if spec.endGunAngle >= spec.endGunMaxAngle then
        spec.endGunAngle = spec.endGunMaxAngle
        spec.endGunDir   = -1
    elseif spec.endGunAngle <= spec.endGunMinAngle then
        spec.endGunAngle = spec.endGunMinAngle
        spec.endGunDir   = 1
    end
    local baseY = spec.endGunBaseRY or 0
    setRotation(spec.endGunNode, 0, baseY + spec.endGunAngle, 0)

    -- â"€â"€ Deflector bumper oscillation (Z axis) â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    if spec.endGunDeflectorNode ~= nil then
        local prevAngle = spec.deflectorAngle
        spec.deflectorAngle = spec.deflectorAngle
            + spec.deflectorDir * spec.deflectorSpeed * dtSec

        -- Clamp and reverse at each end
        if spec.deflectorAngle <= spec.deflectorMinAngle then
            spec.deflectorAngle = spec.deflectorMinAngle
            spec.deflectorDir   = 1    -- returning to 0Â° (positive direction)
        elseif spec.deflectorAngle >= spec.deflectorMaxAngle then
            spec.deflectorAngle = spec.deflectorMaxAngle
            spec.deflectorDir   = -1   -- heading toward -80Â° (negative direction)

            -- Crossed back through 0Â° (hit position) â†’ fire burst
            -- Only trigger if we weren't already bursting and we actually
            -- crossed 0 this frame (prevAngle was still negative).
            if prevAngle < 0 and not spec.burstActive then
                spec.burstActive  = true
                spec.burstAccumMs = 0
                for _, bn in ipairs(spec.endGunBurstNodes) do
                    if entityExists(bn) then setVisibility(bn, true) end
                end
            end
        end

        local baseZ = spec.deflectorBaseRZ or 0
        setRotation(spec.endGunDeflectorNode, 0, 0, baseZ + spec.deflectorAngle)
    end

    -- â"€â"€ Burst flash timer â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    if spec.burstActive then
        spec.burstAccumMs = spec.burstAccumMs + dt
        if spec.burstAccumMs >= spec.burstDurationMs then
            spec.burstActive = false
            for _, bn in ipairs(spec.endGunBurstNodes) do
                if entityExists(bn) then setVisibility(bn, false) end
            end
        end
    end
end

-- ============================================================
-- SPRAY TOGGLE
-- Toggles isSprayActive independently of arm rotation.
-- Starts/stops particle effects and refreshes shader visibility.
-- Called by G key handler and (if needed) by network sync.
-- ============================================================
function ReinkeIrrigationPivot.toggleSprayActive(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    spec.isSprayActive = not spec.isSprayActive
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: SPRAY %s (%d effects)",
        self.id or -1, spec.isSprayActive and "ON" or "OFF", #spec.effects))
    if spec.isSprayActive then
        self:startSprayerParticles()
    else
        self:stopSprayerParticles()
    end
    if self.isClient then sndPlay1(spec.samples.sprayToggle) end
    -- Sync tracker so onUpdateTick spray-flip doesn't fire a second time.
    spec.lastSprayLogged = spec.isSprayActive
end

-- ============================================================
-- ANGLE STEPPING (fixed-angle mode only)
-- Snaps the target to the nearest 10Â° grid point above/below the
-- current arm angle (or current target), then starts the arm.
-- direction: +1 for ] key (next 10Â° up), -1 for [ key (next 10Â° down).
-- ============================================================
function ReinkeIrrigationPivot.stepTargetAngle(self, direction)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    local STEP_DEG   = 10
    local baseDeg    = math.deg(spec.targetAngle or spec.armAngle) % 360

    local newDeg
    if direction > 0 then
        -- Next 10Â° multiple strictly above current position.
        -- E.g. at 15Â° â†’ 20Â°; at 20Â° â†’ 30Â°.
        newDeg = math.floor(baseDeg / STEP_DEG + 1e-6) * STEP_DEG + STEP_DEG
    else
        -- Next 10Â° multiple strictly below current position.
        -- E.g. at 15Â° â†’ 10Â°; at 20Â° â†’ 10Â°.
        newDeg = math.ceil(baseDeg / STEP_DEG - 1e-6) * STEP_DEG - STEP_DEG
    end
    newDeg = (newDeg % 360 + 360) % 360   -- wrap to [0, 360)

    spec.targetAngle = math.rad(newDeg)
    spec.isActive    = true   -- start the arm toward the target
    self:raiseDirtyFlags(spec.dirtyFlag)

    rInfo(string.format("pivot %d: fixed target â†’ %.0fÂ° (from %.0fÂ°, dir=%+d)",
        self.id or -1, newDeg, baseDeg, direction))
end

-- ============================================================
-- INPUT HANDLERS (spray + angle)
-- ============================================================
function ReinkeIrrigationPivot.onSprayPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen then return end
    if not spec.masterPower then return end
    self:toggleSprayActive()
end

-- ============================================================
-- DOOR TOGGLE
-- Toggles the control-box door open/closed via smooth animation.
-- The door rotates around ControlBoxDoorROT's local Y axis.
-- Open = -120Â° (Y), Closed = 0Â°.
-- ============================================================
function ReinkeIrrigationPivot.onDoorPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    rInfo(string.format("pivot %d: onDoorPressed FIRED playerInRange=%s doorOpen=%s",
        self.id or -1, tostring(spec.playerInRange), tostring(spec.doorOpen)))
    if not spec.playerInRange then return end
    spec.doorOpen = not spec.doorOpen
    if self.isClient then
        sndPlay1(spec.doorOpen and spec.samples.hydraulicOpen or spec.samples.hydraulicClose)
    end
    self:raiseDirtyFlags(spec.dirtyFlag)
    -- Open = -120Â° on local Y (confirmed in GE: open state is (0,-120,0)).
    -- Closed = 0Â°.  Animation uses absolute rotation so it is independent of
    -- the i3d baked pose  -  make sure the Shape is saved at (0,0,0) in GE.
    spec.doorAngleTgt = spec.doorOpen and math.rad(-120) or 0
    rInfo(string.format("pivot %d: door %s (tgt=%.1fÂ°)",
        self.id or -1, spec.doorOpen and "OPENING" or "CLOSING",
        math.deg(spec.doorAngleTgt)))
    -- Immediately refresh F1 hint visibility: show/hide control keys based on door state.
    -- Door key itself stays visible (player may want to close the box again).
    self:setInteractionHintsVisible(true)
end

-- ============================================================
-- CONTROL PANEL UPDATE
-- Smooth door animation + knob states every client frame.
-- ============================================================
function ReinkeIrrigationPivot.updateControlPanel(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    local dtSec = dt * 0.001   -- ms â†’ seconds

    -- Door: smooth sweep at 180Â°/s.
    -- Animate the ControlBoxDoor Shape inside the hinge TG  -  the TG itself is
    -- never touched so its (180Â°,0Â°,180Â°) hinge orientation stays intact.
    -- doorAngleCur=0 â†’ Shape at its i3d baked rotation = door closed (visually correct).
    -- doorAngleCur=target â†’ Shape rotated by target radians relative to baked = door open.
    if spec.doorShapeNode ~= nil then
        local diff = spec.doorAngleTgt - spec.doorAngleCur
        if math.abs(diff) > 0.001 then
            local step = math.rad(180) * dtSec   -- 180Â°/s max
            if math.abs(diff) <= step then
                spec.doorAngleCur = spec.doorAngleTgt
            else
                spec.doorAngleCur = spec.doorAngleCur + (diff > 0 and step or -step)
            end
            -- Absolute rotation  -  independent of i3d baked pose.
            -- Closed: (0,0,0).  Open: (0, -120Â°, 0).
            setRotation(spec.doorShapeNode, 0, spec.doorAngleCur, 0)
        end
    end

    -- All knobs use base+offset so GE-baked angles are preserved.
    -- With knobs authored at -45 deg: OFF = -45, ON = 45, speed stops -45/45/135/225.
    local ON = ReinkeIrrigationPivot.KNOB_ON_OFFSET  -- 90 deg

    -- KnobSystemPower: base = OFF, base+90 = ON
    if spec.knobSystemPowerNode ~= nil then
        local base = spec.knobSystemPowerBaseRX or 0
        local tgt  = base + (spec.masterPower and ON or 0)
        local _, ry, rz = getRotation(spec.knobSystemPowerNode)
        setRotation(spec.knobSystemPowerNode, tgt, ry, rz)
    end

    -- KnobAutoManual: base = AUTO, base+90 = MANUAL
    if spec.knobAutoManualNode ~= nil then
        local base = spec.knobAutoManualBaseRX or 0
        local tgt  = base + (spec.autoRotate and 0 or ON)
        local _, ry, rz = getRotation(spec.knobAutoManualNode)
        setRotation(spec.knobAutoManualNode, tgt, ry, rz)
    end

    -- KnobWaterSupply: base = OFF, base+90 = ON
    if spec.knobWaterSupplyNode ~= nil then
        local base = spec.knobWaterSupplyBaseRX or 0
        local tgt  = base + (spec.isSprayActive and ON or 0)
        local _, ry, rz = getRotation(spec.knobWaterSupplyNode)
        setRotation(spec.knobWaterSupplyNode, tgt, ry, rz)
    end

    -- KnobSpeed: base+0/90/180/270 = 1X/2X/3X/4X
    if spec.knobSpeedNode ~= nil then
        local base   = spec.knobSpeedBaseRX or 0
        local offset = ReinkeIrrigationPivot.SPEED_KNOB_OFFSETS[spec.speedIndex or 2]
        local tgt    = base + offset
        local _, ry, rz = getRotation(spec.knobSpeedNode)
        setRotation(spec.knobSpeedNode, tgt, ry, rz)
    end

    -- KnobEndGun: base = OFF, base+90 = ON
    if spec.knobEndGunNode ~= nil then
        local base = spec.knobEndGunBaseRX or 0
        local tgt  = base + (spec.endGunActive and ON or 0)
        local _, ry, rz = getRotation(spec.knobEndGunNode)
        setRotation(spec.knobEndGunNode, tgt, ry, rz)
    end

    -- Position indicator dials: rotate on local X (+X = clockwise on scale).
    -- Baked RY/RZ from GE are preserved so authored orientation isn't clobbered.

    -- PivotCurrentRot: always tracks live arm position.
    -- Uses base + armAngle so the GE-authored needle rest-angle is preserved,
    -- exactly like the knob pattern. armAngle is the compass bearing in radians.
    if spec.posDialCurrentNode ~= nil then
        setRotation(spec.posDialCurrentNode,
            (spec.posDialCurrentBaseRX or 0) + spec.armAngle,
            spec.posDialCurrentBaseRY or 0,
            spec.posDialCurrentBaseRZ or 0)
    end

    -- LimitA (min) / LimitB (max):
    --   AUTO mode  → LimitA = lower sweep bound, LimitB = upper sweep bound
    --   MANUAL mode → both point at the current target (or arm if no target set)
    local dialMinAngle, dialMaxAngle
    if spec.autoRotate then
        dialMinAngle = math.rad(spec.autoMinAngleDeg or 0)
        dialMaxAngle = math.rad(spec.autoMaxAngleDeg or 360)
    else
        local tgt = spec.targetAngle or spec.armAngle
        dialMinAngle = tgt
        dialMaxAngle = tgt
    end
    if spec.posDialMinNode ~= nil then
        setRotation(spec.posDialMinNode,
            (spec.posDialMinBaseRX or 0) + dialMinAngle,
            spec.posDialMinBaseRY or 0,
            spec.posDialMinBaseRZ or 0)
    end
    if spec.posDialMaxNode ~= nil then
        setRotation(spec.posDialMaxNode,
            (spec.posDialMaxBaseRX or 0) + dialMaxAngle,
            spec.posDialMaxBaseRY or 0,
            spec.posDialMaxBaseRZ or 0)
    end
end

-- ============================================================
-- SWEEP-BOUND HELPER
-- Clamps and enforces the min/max invariants.
-- Returns the validated (min, max) pair.
-- Invariants: 0 â‰¤ min â‰¤ 350, 10 â‰¤ max â‰¤ 360, min + 10 â‰¤ max.
-- ============================================================
local function clampSweepBounds(minDeg, maxDeg)
    -- Allow negative min so sweeps can cross the 0°/360° boundary.
    -- e.g. min=-170 + max=90 sweeps the 260° arc that passes through 0°.
    -- When min >= 0: preserve original 360 ceiling so full-circle (min=0,max=360) is reachable.
    -- When min < 0:  cap max at min+350 to prevent range >= 360 (which triggers full-circle mode).
    minDeg = math.max(-350, math.min(350, minDeg))
    local maxCeil = (minDeg >= 0) and 360 or (minDeg + 350)
    maxDeg = math.max(minDeg + 10, math.min(maxCeil, maxDeg))
    return minDeg, maxDeg
end

-- ============================================================
-- KP 6 — step arm +10° CW (manual mode only; no-op in AUTO)
-- ============================================================
function ReinkeIrrigationPivot.onAnglePlusPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen  then return end
    if not spec.masterPower then return end
    if spec.autoRotate then return end   -- dedicated keys handle AUTO bounds
    if self.isClient then sndPlay1(spec.samples.buttonClick) end
    self:stepTargetAngle(1)
end

-- ============================================================
-- KP 4 — step arm -10° CCW (manual mode only; no-op in AUTO)
-- ============================================================
function ReinkeIrrigationPivot.onAngleMinusPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen  then return end
    if not spec.masterPower then return end
    if spec.autoRotate then return end
    if self.isClient then sndPlay1(spec.samples.buttonClick) end
    self:stepTargetAngle(-1)
end

-- ============================================================
-- KP 9 — raise MAX sweep bound +10° (works in any mode)
-- ============================================================
function ReinkeIrrigationPivot.onAutoMaxUpPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen  then return end
    if not spec.masterPower then return end
    if self.isClient then sndPlay1(spec.samples.buttonClick) end
    local newMax = (spec.autoMaxAngleDeg or 360) + 10
    spec.autoMinAngleDeg, spec.autoMaxAngleDeg =
        clampSweepBounds(spec.autoMinAngleDeg or 0, newMax)
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: KP9 → MAX +10 → range %.0f°–%.0f°",
        self.id or -1, spec.autoMinAngleDeg, spec.autoMaxAngleDeg))
end

-- ============================================================
-- KP 3 — lower MAX sweep bound -10° (works in any mode)
-- ============================================================
function ReinkeIrrigationPivot.onSweepMaxDnPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen  then return end
    if not spec.masterPower then return end
    if self.isClient then sndPlay1(spec.samples.buttonClick) end
    local newMax = (spec.autoMaxAngleDeg or 360) - 10
    spec.autoMinAngleDeg, spec.autoMaxAngleDeg =
        clampSweepBounds(spec.autoMinAngleDeg or 0, newMax)
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: KP3 → MAX -10 → range %.0f°–%.0f°",
        self.id or -1, spec.autoMinAngleDeg, spec.autoMaxAngleDeg))
end

-- ============================================================
-- KP 7 — raise MIN sweep bound +10° (works in any mode)
-- ============================================================
function ReinkeIrrigationPivot.onAutoMinUpPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen  then return end
    if not spec.masterPower then return end
    if self.isClient then sndPlay1(spec.samples.buttonClick) end
    local newMin = (spec.autoMinAngleDeg or 0) + 10
    spec.autoMinAngleDeg, spec.autoMaxAngleDeg =
        clampSweepBounds(newMin, spec.autoMaxAngleDeg or 360)
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: KP7 → MIN +10 → range %.0f°–%.0f°",
        self.id or -1, spec.autoMinAngleDeg, spec.autoMaxAngleDeg))
end

-- ============================================================
-- KP 1 — lower MIN sweep bound -10° (works in any mode)
-- ============================================================
function ReinkeIrrigationPivot.onSweepMinDnPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen  then return end
    if not spec.masterPower then return end
    if self.isClient then sndPlay1(spec.samples.buttonClick) end
    local newMin = (spec.autoMinAngleDeg or 0) - 10
    spec.autoMinAngleDeg, spec.autoMaxAngleDeg =
        clampSweepBounds(newMin, spec.autoMaxAngleDeg or 360)
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: KP1 → MIN -10 → range %.0f°–%.0f°",
        self.id or -1, spec.autoMinAngleDeg, spec.autoMaxAngleDeg))
end

-- ============================================================
-- KP 0 — end gun on / off  (tier 3; requires power + door)
-- ============================================================
function ReinkeIrrigationPivot.toggleEndGun(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    spec.endGunActive = not spec.endGunActive
    if self.isClient then sndPlay1(spec.samples.endGunToggle) end
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: END GUN %s", self.id or -1, spec.endGunActive and "ON" or "OFF"))
end

function ReinkeIrrigationPivot.onEndGunPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen      then return end
    if not spec.masterPower   then return end
    self:toggleEndGun()
end

-- ============================================================
-- KP_enter — cycle speed  1X → 2X → 3X → 4X → 1X  (tier 3)
-- ============================================================
function ReinkeIrrigationPivot.cycleSpeed(self)
    local spec   = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    local mults  = ReinkeIrrigationPivot.SPEED_MULTS
    spec.speedIndex = (spec.speedIndex % #mults) + 1
    if self.isClient then sndPlay1(spec.samples.speedClick) end
    self:raiseDirtyFlags(spec.dirtyFlag)
    rInfo(string.format("pivot %d: SPEED → %s (%.1fx nominal)",
        self.id or -1,
        ReinkeIrrigationPivot.SPEED_LABELS[spec.speedIndex],
        mults[spec.speedIndex]))
end

function ReinkeIrrigationPivot.onSpeedCyclePressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen      then return end
    if not spec.masterPower   then return end
    self:cycleSpeed()
end

-- ============================================================
-- ON UPDATE (engine ticks this only after raiseActive)
-- ============================================================
function ReinkeIrrigationPivot.onUpdate(self, dt)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    -- Stop zombie re-activation: onDelete sets isDeleted=true.  Without this guard,
    -- the dead instance calls raiseActive() every frame and stays in the update queue
    -- indefinitely, running update code on stale / cleared state.
    if spec.isDeleted then return end
    -- Keep ourselves in the FS25 update loop — must come before xpcall so it fires
    -- even when the body throws.  A missed raiseActive permanently kills the loop.
    self:raiseActive()

    -- Indestructible update loop: wrap the entire body in xpcall so that any
    -- Lua error is caught and logged rather than propagating to the engine.
    -- Giants cancels the raiseActive scheduling when an unhandled error escapes
    -- a callback, permanently killing the update loop.  With this wrapper, that
    -- can never happen  -  the error is logged, and the next frame still runs.
    xpcall(function()

    -- Guard: onDelete clears pivotPointNode.  If onUpdate fires in the small
    -- window between onDelete and the next onLoad (e.g. during a reload), we
    -- skip all node-touching code but still called raiseActive above so the
    -- loop survives to pick up the re-loaded state.
    if spec.pivotPointNode == nil and (spec.sections == nil or #spec.sections == 0) then
        return
    end

    -- One-shot confirmation that onUpdate IS firing  -  invaluable when debugging
    if not spec.firstUpdateLogged then
        spec.firstUpdateLogged = true
        rInfo(string.format(
            "pivot %d: FIRST onUpdate fired (dt=%.1fms) isClient=%s isServer=%s "
            .. "pivotPointNode=%s sections=%d effects=%d",
            self.id or -1, dt,
            tostring(self.isClient), tostring(self.isServer),
            tostring(spec.pivotPointNode),
            spec.sections and #spec.sections or 0,
            spec.effects and #spec.effects or 0))
    end

    -- â"€â"€ Spray effects self-heal (not needed in visibility mode) â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€

    if self.isClient then
        self:updateArmRotation(dt)
        if spec.isActive then
            self:updateWheelRotation(dt)
            self:updateDriveShaftAnimation(dt)
        end
        self:updatePressureGauge(dt)
        if spec.isSprayActive then
            -- Sprayer visuals driven by EffectManager (g_effectManager:startEffects/stopEffects)
        end
        self:updateEndGunAnimation(dt)        -- handles spray-off reset too
        self:updateControlPanel(dt)
        if spec.sprayFeatherActive then
            self:tickSprayFeather(dt)
        end
    end

    -- Refresh hint text each frame while player is in range and events exist.
    -- The distance polling in onUpdateTick handles enter/leave; this block updates
    -- the dynamic label text (angle, spray, door state).
    if self.isClient and spec.playerInRange and g_inputBinding ~= nil
       and spec.actionEventId ~= nil and self.rootNode ~= nil then
        local label
        if not spec.doorOpen then
            label = string.format("Pivot @%.0f deg  [F] Open Box",
                math.deg(spec.armAngle) % 360)
        else
            local sprayStr = spec.isSprayActive and "SPRAY:ON" or "SPRAY:OFF"
            local modeStr
            if spec.autoRotate then
                modeStr = string.format("AUTO @%.0f (%.0f-%.0f deg)  R=Stop  ]=MaxDn ]=MaxUp [=MinDn [=MinUp",
                    math.deg(spec.armAngle) % 360,
                    ((spec.autoMinAngleDeg or 0) % 360 + 360) % 360,
                    ((spec.autoMaxAngleDeg or 360) % 360 + 360) % 360)
            elseif spec.isActive and spec.targetAngle ~= nil then
                modeStr = string.format("STEP %.0f>%.0f deg  R=FullRot  ]/[=Step10",
                    math.deg(spec.armAngle) % 360, math.deg(spec.targetAngle) % 360)
            else
                modeStr = string.format("STOP @%.0f deg  R=FullRot  ]/[=Step10",
                    math.deg(spec.armAngle) % 360)
            end
            label = string.format("[%s] [%s]  KP5=Spray  KP.:Close Panel", modeStr, sprayStr)
        end
        g_inputBinding:setActionEventText(spec.actionEventId, label)
    end

    -- One-shot post-reload re-acquisition (fires ~3 s after first onUpdate, then never again).
    -- FS25's reload finalizer (the step that prints "Successfully reloaded XML and I3D")
    -- clears registered action events AFTER our initial registration on range-enter.
    -- At the 3 s mark the finalizer is long done; registerInteractionAction will now
    -- get real non-nil handles and F1 will populate.
    -- Registrations target the "PLAYER" context via beginActionEventsModification inside
    -- registerInteractionAction, so they fire correctly in foot mode regardless of what
    -- context is active at the time this timer fires.
    if not spec.postReloadReacquireDone then
        spec.postReloadReacquireMs = (spec.postReloadReacquireMs or 0) + dt
        if spec.postReloadReacquireMs >= 3000 then
            spec.postReloadReacquireDone = true
            if self.isClient and spec.playerInRange and not spec.isDeleted then
                rInfo(string.format("pivot %d: post-reload re-acquisition firing", self.id or -1))
                self:registerInteractionAction()
                self:setInteractionHintsVisible(true)
            end
        end
    end

    end, function(err)  -- xpcall error handler
        -- Log the error with traceback so we can diagnose it.
        rInfo(string.format("pivot %d: [FATAL] onUpdate body error: %s",
            self.id or -1, tostring(err)))
    end)  -- end xpcall
end

-- ============================================================
-- ON UPDATE TICK (~30 Hz)
-- Throttled work that does NOT need per-frame (60 Hz) precision:
--    - ¢ SCS lazy retry / isActive computation
--    - ¢ Spray state-flip detection
--    - ¢ Terrain articulation (throttled to 2 Hz internally)
--    - ¢ Status heartbeat (30 s)
-- ============================================================
function ReinkeIrrigationPivot.onUpdateTick(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]

    -- Deleted instances must not run proximity detection or any other logic.
    -- onDelete sets isDeleted=true; FS25 may still fire onUpdateTick for 1-2 frames
    -- afterward — bail out immediately to avoid re-registering input events or
    -- touching cleared node tables.
    if spec.isDeleted then return end

    -- Wrap the ENTIRE tick body in xpcall — this includes proximity detection.
    -- Previously the polling block ran outside xpcall; any error from
    -- g_inputBinding:registerActionEvent or getWorldTranslation would escape
    -- unhandled and hard-crash the update tick.
    xpcall(function()

    -- Distance polling — runs even when the pivot is not fully initialised so
    -- the player can always enter range and trigger action-event registration.
    -- (Previously guarded by the pivotPointNode check below; that meant partial-
    -- init or ghost pivots never detected the player and controls stayed broken.)
    spec.pollAccumMs = spec.pollAccumMs + dt
    if spec.pollAccumMs >= ReinkeIrrigationPivot.TERRAIN_FOLLOW_INTERVAL_MS then
        spec.pollAccumMs = 0
        local r = ReinkeIrrigationPivot.INTERACTION_RADIUS
        local pollRangeSq = r * r
        local player = g_localPlayer
        local pNode = player ~= nil and (player.rootNode or player.playerId or player.nodeId) or nil
        if pNode ~= nil and self.rootNode ~= nil then
            local px, _, pz = getWorldTranslation(pNode)
            local sx, _, sz = getWorldTranslation(self.rootNode)
            local dxz2 = (px - sx) * (px - sx) + (pz - sz) * (pz - sz)
            spec.playerDistSq = dxz2
            local inRange = dxz2 <= pollRangeSq
            if inRange and not spec.playerInRange then
                spec.playerInRange = true
                self:registerInteractionAction()
                self:setInteractionHintsVisible(true)
            elseif not inRange and spec.playerInRange then
                spec.playerInRange = false
                self:setInteractionHintsVisible(false)
            end
        end
    end

    -- GUI-close detection: when a menu (e.g. PLACEABLES menu) closes, FS25 may
    -- remove placeable action events as part of returning to foot-mode context.
    -- The post-reload 3-second timer may have already fired while the menu was
    -- still open, leaving postReloadReacquireDone=true and no way to re-register.
    -- Detect the GUI→no-GUI transition and re-register + re-show on that frame.
    do
        local guiNow = g_gui ~= nil and g_gui:getIsGuiVisible()
        if spec.guiWasVisible and not guiNow then
            -- Menu just closed this tick
            if spec.playerInRange and not spec.isDeleted then
                rInfo(string.format("pivot %d: GUI closed while in range — re-registering action events",
                    self.id or -1))
                self:registerInteractionAction()
                self:setInteractionHintsVisible(true)
            end
        end
        spec.guiWasVisible = guiNow
    end

    -- The rest of the tick only runs when the pivot is fully initialised.
    if spec.pivotPointNode == nil and (spec.sections == nil or #spec.sections == 0) then
        return
    end

    -- No distance cull — terrain articulation must run regardless of player location
    -- (player may be in a vehicle far away while the pivot still needs to track ground).

    -- Lazy SCS retry (1 Hz)
    if spec.enableSCS and not spec.scsIntegrated then
        spec.scsRetryAccumMs = spec.scsRetryAccumMs + dt
        if spec.scsRetryAccumMs >= 1000 then
            spec.scsRetryAccumMs = 0
            self:tryRegisterWithSCS()
        end
    end

    -- Compute desired isActive
    local newActive
    if spec.forceAlwaysActive then
        newActive = true
    elseif spec.scsIntegrated then
        local sys = spec.irrigationManager and spec.irrigationManager.systems[self.id]
        newActive = sys ~= nil and sys.isActive == true
    else
        newActive = spec.isActive
    end
    spec.isActive = newActive

    -- [LOCAL PATCH] Under SCS, a real pivot sweeps while it irrigates. Follow SCS's
    -- activation: engage auto-rotate when SCS turns the system on, park it when off.
    -- Without this the boom stayed frozen even while SCS was irrigating, because the
    -- on-board auto/manual toggle (the only thing that set autoRotate) is replaced by
    -- the schedule-dialog on the interact key in SCS mode, so nothing ever set it.
    -- SCS now owns rotation as well as activation.
    if spec.scsIntegrated then
        if spec.isActive then
            spec.autoRotate  = true
            spec.targetAngle = nil
        else
            spec.autoRotate = false
        end
    end

    -- Rotation state-flip log
    if spec.isActive ~= spec.lastLoggedActive then
        if spec.isActive then
            if spec.autoRotate then
                rInfo(string.format("pivot %d â†’ AUTO ROTATING (sweep %.0fÂ° - %.0fÂ°)",
                    self.id or -1, spec.autoMinAngleDeg, spec.autoMaxAngleDeg))
            else
                rInfo(string.format("pivot %d â†’ MOVING TO %.0fÂ°",
                    self.id or -1, math.deg(spec.targetAngle or spec.armAngle)))
            end
        else
            rInfo(string.format("pivot %d â†’ STOPPED (parked at %.0fÂ°)", self.id or -1, math.deg(spec.armAngle)))
        end
        spec.lastLoggedActive = spec.isActive
        spec.statusAccumMs = 0
        self:updateLights()
        if self.isClient then self:updateButtonLight() end
    end

    -- Spray state-flip
    if spec.isSprayActive ~= spec.lastSprayLogged then
        spec.lastSprayLogged = spec.isSprayActive
        if spec.isSprayActive then
            self:startSprayerParticles()
        else
            self:stopSprayerParticles()
        end
    end

    -- Adaptive terrain articulation — visual only, skip on dedicated server.
    -- Frequency adapts to how much correction work is actually needed:
    --   Active (arm rotating)                    → 250 ms  (4 Hz, ground changes as arm sweeps)
    --   Inactive, last correction > 0.15 m       → 500 ms  (catching up to settled terrain)
    --   Inactive, last correction 0.02–0.15 m    → 2 000 ms (minor drift, low priority)
    --   Inactive, last correction < 0.02 m       → 8 000 ms (arm essentially flush with ground)
    -- spec.terrainLastError is set by updateTerrainArticulation after each pass.
    if self.isClient then
        local terrainInterval
        if spec.isActive then
            terrainInterval = 250
        else
            local err = spec.terrainLastError or 999
            if err > 0.15 then
                terrainInterval = 500
            elseif err > 0.02 then
                terrainInterval = 2000
            else
                terrainInterval = 8000
            end
        end
        spec.terrainAccumMs = (spec.terrainAccumMs or 0) + dt
        if spec.terrainAccumMs >= terrainInterval then
            spec.terrainAccumMs = 0
            self:updateTerrainArticulation()
        end
    end

    -- Status heartbeat (30 s)
    if spec.isActive then
        spec.statusAccumMs = spec.statusAccumMs + dt
        if spec.statusAccumMs >= ReinkeIrrigationPivot.STATUS_LOG_INTERVAL_MS then
            spec.statusAccumMs = 0
            self:logHeartbeat()
        end
    end

    -- Reconcile loop sounds with current state
    self:syncLoopSounds()

    end, function(err)  -- xpcall error handler for onUpdateTick
        rInfo(string.format("pivot %d: [FATAL] onUpdateTick body error: %s",
            self.id or -1, tostring(err)))
    end)  -- end xpcall

end

function ReinkeIrrigationPivot.onDelete(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    rInfo(string.format("pivot %d: onDelete fired isClient=%s playerInRange=%s actionEventId=%s",
        self.id or -1, tostring(self.isClient), tostring(spec.playerInRange),
        tostring(spec.actionEventId ~= nil)))
    if self.isClient then
        -- Tombstone this instance.  FS25 may continue calling onUpdateTick for one or
        -- more frames after onDelete returns; isDeleted prevents proximity detection from
        -- re-registering our events and stealing the InputAction slots from the new
        -- instance that EDC Reload is about to create.
        spec.isDeleted = true
        spec.playerInRange = false
        self:setInteractionHintsVisible(false)
        -- Remove all our events from the PLAYER context by target reference.
        -- Using beginActionEventsModification ensures iterateEvents searches the
        -- correct context even if onDelete fires while a menu has changed the
        -- active context away from "PLAYER".
        if g_inputBinding ~= nil then
            g_inputBinding:beginActionEventsModification("PLAYER")
            g_inputBinding:removeActionEventsByTarget(self)
            g_inputBinding:endActionEventsModification()
        end
        if spec.effects ~= nil and #spec.effects > 0 then
            g_effectManager:deleteEffects(spec.effects)
        end
        -- Stop and free all sound samples
        for _, s in pairs(spec.samples or {}) do
            g_soundManager:stopSample(s)
            g_soundManager:deleteSample(s)
        end
        spec.samples = {}
    end
    if spec.scsIntegrated and spec.irrigationManager ~= nil then
        spec.irrigationManager:deregisterIrrigationSystem(self.id)
    end
    -- Cancel any in-progress feather sequence before clearing the effect list
    spec.sprayFeatherActive  = false
    spec.sprayFeatherIndex   = 0
    spec.sprayFeatherAccumMs = 0
    -- Nil-out all node-reference tables so any stale onUpdate call that fires
    -- after delete sees empty lists rather than invalid entity IDs.
    spec.effects            = {}
    spec.sections           = {}
    spec.driveShaftNodes    = {}
    spec.endGunBurstNodes   = {}
    spec.lightNodes              = {}
    spec.lightGlowNodes          = {}
    spec.sweepMaxDnActionEventId = nil
    spec.sweepMinDnActionEventId = nil
    spec.endGunNode         = nil
    spec.endGunDeflectorNode= nil
    spec.pivotPointNode     = nil
    spec.pressureNeedleNode = nil
    spec.doorRotNode             = nil
    spec.doorShapeNode           = nil
    spec.knobSystemPowerNode     = nil
    spec.knobAutoManualNode      = nil
    spec.knobWaterSupplyNode     = nil
    spec.knobSpeedNode           = nil
    spec.knobEndGunNode          = nil
    spec.posDialCurrentNode      = nil
    spec.posDialMinNode          = nil
    spec.posDialMaxNode          = nil
    spec.endGunActionEventId     = nil
    spec.speedCycleActionEventId = nil
    spec.button1GlowNode         = nil
end

function ReinkeIrrigationPivot.onReadStream(self, streamId, connection)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    spec.isActive     = streamReadBool(streamId)
    spec.armAngle     = streamReadFloat32(streamId)
    spec.masterPower  = streamReadBool(streamId)
    spec.endGunActive = streamReadBool(streamId)
    local si = streamReadInt32(streamId)
    if si >= 1 and si <= 4 then spec.speedIndex = si end
    self:updateLights()
end

function ReinkeIrrigationPivot.onWriteStream(self, streamId, connection)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    streamWriteBool(streamId,   spec.isActive     or false)
    streamWriteFloat32(streamId, spec.armAngle    or 0)
    streamWriteBool(streamId,   spec.masterPower  or false)
    streamWriteBool(streamId,   spec.endGunActive or false)
    streamWriteInt32(streamId,  spec.speedIndex   or 2)
end

-- ============================================================
-- INPUT ACTION
-- ============================================================

-- Toggle hint text visibility.  Called when player enters/exits interaction range
-- and whenever the door state changes.
--
-- Door key   -  always visible while player is in range (how you open the box).
-- Control keys  -  only visible while in range AND the control box is open.
-- Passing show=false hides everything (player left range).
-- Toggle hint text visibility according to the 3-tier control hierarchy.
--
--   Tier 1 (in range only):            door key
--   Tier 2 (in range + door open):     master power key
--   Tier 3 (in range + door + power):  all operation keys
--
-- Passing show=false collapses all tiers (player left range).
function ReinkeIrrigationPivot.setInteractionHintsVisible(self, show)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if g_inputBinding == nil then return end

    -- Tier 1: door key — visible whenever player is in range
    if spec.doorActionEventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(spec.doorActionEventId, show)
        g_inputBinding:setActionEventActive(spec.doorActionEventId, show)
    end

    -- Tier 2: master power — visible when in range AND door is open
    local showPower = show and (spec.doorOpen == true)
    if spec.masterPowerActionEventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(spec.masterPowerActionEventId, showPower)
        g_inputBinding:setActionEventActive(spec.masterPowerActionEventId, showPower)
    end

    -- Tier 3: all operation keys — visible when in range AND door open AND power ON
    local showOps = showPower and (spec.masterPower == true)
    local opIds = {
        spec.actionEventId,
        spec.sprayActionEventId,
        spec.anglePlusActionEventId,
        spec.angleMinusActionEventId,
        spec.autoMaxUpActionEventId,
        spec.autoMinUpActionEventId,
        spec.sweepMaxDnActionEventId,
        spec.sweepMinDnActionEventId,
        spec.endGunActionEventId,
        spec.speedCycleActionEventId,
    }
    for _, evId in ipairs(opIds) do
        if evId ~= nil then
            g_inputBinding:setActionEventTextVisibility(evId, showOps)
            g_inputBinding:setActionEventActive(evId, showOps)
        end
    end
end

-- Register all interaction action events.  Called on first proximity entry and again
-- after any menu-close that may have cleared foot-mode events.  All registrations
-- target the "PLAYER" context so they fire and appear in F1 when the player is on foot.
-- Hint text starts HIDDEN; setInteractionHintsVisible(true) reveals it when in range.
function ReinkeIrrigationPivot.registerInteractionAction(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    -- Treat empty-string as nil  -  g_inputBinding sometimes returns "" on failure
    if spec.actionEventId == "" then spec.actionEventId = nil end
    if spec.sprayActionEventId == "" then spec.sprayActionEventId = nil end
    if spec.anglePlusActionEventId == "" then spec.anglePlusActionEventId = nil end
    if spec.angleMinusActionEventId == "" then spec.angleMinusActionEventId = nil end
    if spec.autoMaxUpActionEventId == "" then spec.autoMaxUpActionEventId = nil end
    if spec.autoMinUpActionEventId == "" then spec.autoMinUpActionEventId = nil end
    if spec.doorActionEventId == "" then spec.doorActionEventId = nil end
    if spec.masterPowerActionEventId == "" then spec.masterPowerActionEventId = nil end
    if spec.sweepMaxDnActionEventId   == "" then spec.sweepMaxDnActionEventId   = nil end
    if spec.sweepMinDnActionEventId   == "" then spec.sweepMinDnActionEventId   = nil end
    if spec.endGunActionEventId       == "" then spec.endGunActionEventId       = nil end
    if spec.speedCycleActionEventId   == "" then spec.speedCycleActionEventId   = nil end

    if g_inputBinding == nil then return end
    if InputAction == nil or InputAction.REINKE_PIVOT_INTERACT == nil then
        rInfo(string.format("pivot %d: REINKE_PIVOT_INTERACT action not found in InputAction table  -  "
            .. "check modDesc.xml <actions> block", self.id or -1))
        return
    end

    -- Target the foot-mode ("PLAYER") context explicitly so events land in the right
    -- bucket regardless of what context is active at call time (e.g. during a reload
    -- the active context may be ROOT or a menu context).
    g_inputBinding:beginActionEventsModification("PLAYER")

    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.REINKE_PIVOT_INTERACT, self, ReinkeIrrigationPivot.onInteractPressed,
        false, true, false, false
    )
    if actionEventId == "" then actionEventId = nil end
    if actionEventId ~= nil then
        if actionEventId ~= spec.actionEventId then
            rInfo(string.format("pivot %d: registerInteractionAction  -  actionEventId=%s rootNode=%s",
                self.id or -1, tostring(actionEventId), tostring(self.rootNode)))
        end
        spec.actionEventId = actionEventId
    end

    if actionEventId ~= nil then
        local label = "Start/Stop Full Rotation"
        if spec.enableSCS and spec.scsIntegrated then
            label = (g_i18n ~= nil and g_i18n:getText("reinke_pivot_open_dialog")) or label
        end
        g_inputBinding:setActionEventText(actionEventId, label)
        g_inputBinding:setActionEventActive(actionEventId, true)
        g_inputBinding:setActionEventTextVisibility(actionEventId, false)
    end

    local function tryReg(action, specField, cb, label)
        if action == nil then return end
        local _, evId = g_inputBinding:registerActionEvent(action, self, cb, false, true, false, false)
        if evId == "" then evId = nil end
        if evId ~= nil then
            spec[specField] = evId
            g_inputBinding:setActionEventText(evId, label)
            g_inputBinding:setActionEventActive(evId, true)
            g_inputBinding:setActionEventTextVisibility(evId, false)
        end
    end

    tryReg(InputAction.REINKE_PIVOT_SPRAY,      "sprayActionEventId",    ReinkeIrrigationPivot.onSprayPressed,      "Toggle Spray")
    tryReg(InputAction.REINKE_PIVOT_ANGLE_PLUS, "anglePlusActionEventId",ReinkeIrrigationPivot.onAnglePlusPressed,  "Step +10 deg")
    tryReg(InputAction.REINKE_PIVOT_ANGLE_MINUS,"angleMinusActionEventId",ReinkeIrrigationPivot.onAngleMinusPressed,"Step -10 deg")
    tryReg(InputAction.REINKE_PIVOT_AUTO_MAX_UP,"autoMaxUpActionEventId", ReinkeIrrigationPivot.onAutoMaxUpPressed,  "Raise Max Sweep Limit")
    tryReg(InputAction.REINKE_PIVOT_AUTO_MIN_UP,"autoMinUpActionEventId", ReinkeIrrigationPivot.onAutoMinUpPressed,  "Raise Min Sweep Limit")
    tryReg(InputAction.REINKE_DOOR_TOGGLE,      "doorActionEventId",      ReinkeIrrigationPivot.onDoorPressed,       "Open/Close Control Box")
    tryReg(InputAction.REINKE_MASTER_POWER,     "masterPowerActionEventId",ReinkeIrrigationPivot.onMasterPowerPressed,"Master Power On/Off")
    tryReg(InputAction.REINKE_PIVOT_SWEEP_MAX_DN,"sweepMaxDnActionEventId",ReinkeIrrigationPivot.onSweepMaxDnPressed,"Lower Max Sweep Bound")
    tryReg(InputAction.REINKE_PIVOT_SWEEP_MIN_DN,"sweepMinDnActionEventId",ReinkeIrrigationPivot.onSweepMinDnPressed,"Lower Min Sweep Bound")
    tryReg(InputAction.REINKE_END_GUN,          "endGunActionEventId",    ReinkeIrrigationPivot.onEndGunPressed,     "End Gun On/Off")
    tryReg(InputAction.REINKE_SPEED_CYCLE,      "speedCycleActionEventId",ReinkeIrrigationPivot.onSpeedCyclePressed,"Cycle Speed 1X/2X/3X/4X")

    g_inputBinding:endActionEventsModification()

    -- Log all IDs so a partial failure (some actions nil) is immediately visible.
    rInfo(string.format(
        "pivot %d: registerInteractionAction complete — interact=%s door=%s power=%s spray=%s angleP=%s angleM=%s",
        self.id or -1,
        tostring(spec.actionEventId ~= nil),
        tostring(spec.doorActionEventId ~= nil),
        tostring(spec.masterPowerActionEventId ~= nil),
        tostring(spec.sprayActionEventId ~= nil),
        tostring(spec.anglePlusActionEventId ~= nil),
        tostring(spec.angleMinusActionEventId ~= nil)))
end

function ReinkeIrrigationPivot.onInteractPressed(self)
    local spec = self[ReinkeIrrigationPivot.SPEC_TABLE_NAME]
    if not spec.playerInRange then return end
    if not spec.doorOpen then return end
    if not spec.masterPower then return end
    local scsMgr = getSCSManager()
    if spec.enableSCS and spec.scsIntegrated and scsMgr ~= nil and scsMgr.onOpenIrrigationDialog ~= nil then
        -- [LOCAL PATCH] Route through the cross-mod-visible manager instead of the
        -- bare CsDialogLoader global, which is invisible across FS25 mod environments
        -- (so the old `CsDialogLoader ~= nil` check was always false here and the
        -- dialog never opened). Reach it via g_currentMission.cropStressManager and
        -- pass our own system id so it opens THIS pivot's schedule.
        rInfo(string.format("pivot %d: opening SCS schedule dialog", self.id or -1))
        scsMgr:onOpenIrrigationDialog(self.id)
    elseif spec.forceAlwaysActive then
        rInfo(string.format(
            "pivot %d: [DEBUG] R pressed  -  forceAlwaysActive=true so pivot stays ON. "
            .. "Set forceAlwaysActive=\"false\" in XML to enable the R-key toggle.",
            self.id or -1))
    else
        -- R key behaviour (context-sensitive STOP-first design):
        --
        --    - ¢ Auto-rotating  â†’ R = STOP   (clear autoRotate + isActive)
        --    - ¢ Moving to target â†’ R = STOP  (clear isActive + targetAngle)
        --    - ¢ Stopped          â†’ R = START AUTO-ROTATE (sweeps minâ†"max)
        --
        -- This means R *always* stops motion when the arm is moving,
        -- and only enables auto-rotate when already at rest  -  no surprises.
        if spec.autoRotate then
            -- Was auto-rotating â†’ stop
            spec.autoRotate  = false
            spec.isActive    = false
            spec.targetAngle = nil
            rInfo(string.format("pivot %d: R key  -  AUTO ROTATE â†’ STOPPED at %.0fÂ°",
                self.id or -1, math.deg(spec.armAngle) % 360))
        elseif spec.isActive then
            -- Was moving to a fixed target â†’ stop
            spec.isActive    = false
            spec.targetAngle = nil
            rInfo(string.format("pivot %d: R key  -  FIXED MOVE â†’ STOPPED at %.0fÂ°",
                self.id or -1, math.deg(spec.armAngle) % 360))
        else
            -- Stopped â†’ start auto-rotate
            spec.autoRotate  = true
            spec.isActive    = true
            spec.targetAngle = nil
            if self.isClient then sndPlay1(spec.samples.hydraulicOpen) end
            rInfo(string.format("pivot %d: R key  -  STOPPED â†’ AUTO ROTATE (sweep %.0fÂ° - %.0fÂ°)",
                self.id or -1, spec.autoMinAngleDeg, spec.autoMaxAngleDeg))
        end
    end
    self:raiseDirtyFlags(spec.dirtyFlag)
    -- Action events remain registered for the entire lifetime of the pivot.
    -- They are only removed by removeInteractionAction() inside onDelete.
end

-- (proximity handled by distance polling in onUpdateTick)
