-- RSF-F244-moisture_generation_cleanup_spec_test.lua
--
-- RSF-F244 (SCS-039 section 3.7 cleanup, F250 item 2). Three defects, one bench:
--   1. the probe opened csMoistureMap.grle at field-ready, before the restore
--      barrier had read any envelope, so a stale legacy picture could survive as
--      current truth on the barrier's no-candidate branch;
--   2. every save left the previous generation's g<N> image on disk for good,
--      because a mod cannot delete savegame files (mods.lua:708-733);
--   3. the StateLedger bridge called a refused registration registered.
--
-- WHAT IS REAL AND WHAT IS A STUB. CropStressValueMap, SoilMoistureSystem,
-- SaveLoadHandler, CropStressManager and the StateLedger bridge are the shipping
-- code. The engine is stubbed at its API: createBitVectorMap, loadBitVectorMapNew,
-- loadBitVectorMapFromFile, getBitVectorMapSize, saveBitVectorMapToFile, fileExists,
-- DensityMapModifier.new and DensityMapFilter.new, each recording what it was
-- asked. The existing benches replace the value map with a fake, so before this
-- file the loader, the probe and the slot write had never run under test.
--
-- EVERY CASE RUNS INSIDE group(), so a Lua error fails a named row and the cases
-- after it still report, instead of the suite discarding the whole file.
--
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/SaveLoadHandler.lua, src/CropStressManager.lua, src/integrations/CropStressStateLedgerBridge.lua

local ROOT = "careerSavegame.cropStress"
local HOUR = 50
local LEGACY = "csMoistureMap.grle"
local S1, S2, S3 = "csMoistureMap.s1.grle", "csMoistureMap.s2.grle", "csMoistureMap.s3.grle"

g_currentMission = {
  time = 1000,
  environment = { currentHour = 2, currentMonotonicDay = 2, currentDay = 2, daysPerPeriod = 1 },
  missionInfo = { savegameDirectory = "sg" },
}

local function group(tag, fn)
  local ok, err = pcall(fn)
  T.eq(tag .. "x the case ran to its end without a Lua error", ok and "clean" or tostring(err), "clean")
end

-- ── The engine stub ─────────────────────────────────────────────────────────

--- Any method on an engine object is a no-op returning numbers, so painting and
--- reading through a real map do not need a model of the density map.
local function engineObject(fields)
  return setmetatable(fields, { __index = function() return function() return 0, 0, 0 end end })
end

local eng
--- opts.files: path -> { width = N, loads = true | false | 1 | "throw" }
--- An attempted load that fails still moves the stored width when the file names
--- one, which is how a partial engine load leaves the map not determinable.
local function resetEngine(opts)
  opts = opts or {}
  eng = {
    files = opts.files or {},
    existsCalls = {}, loadCalls = {}, newCalls = {}, saveCalls = {},
    modifiers = 0, filters = 0, width = nil,
    saveAnswer = true, dropWrites = false, newThrowsAfter = nil,
  }
  g_terrainNode = 1
  getTerrainSize = function() return opts.terrain or 4096 end     -- computed 2048
  createBitVectorMap = function() return 77 end
  loadBitVectorMapNew = function(_bvm, w)
    eng.newCalls[#eng.newCalls + 1] = w
    if eng.newThrowsAfter ~= nil and #eng.newCalls > eng.newThrowsAfter then error("engine new refused") end
    eng.width = w
  end
  loadBitVectorMapFromFile = function(_bvm, path)
    eng.loadCalls[#eng.loadCalls + 1] = path
    local f = eng.files[path]
    if f == nil then return false end
    if f.width ~= nil then eng.width = f.width end
    if f.loads == "throw" then error("engine load refused") end
    if f.loads == nil then return true end
    return f.loads
  end
  getBitVectorMapSize = function() return eng.width, eng.width end
  saveBitVectorMapToFile = function(_bvm, path)
    eng.saveCalls[#eng.saveCalls + 1] = path
    if eng.saveAnswer == true and not eng.dropWrites then eng.files[path] = { width = eng.width } end
    return eng.saveAnswer
  end
  fileExists = function(path)
    eng.existsCalls[#eng.existsCalls + 1] = path
    return eng.files[path] ~= nil
  end
  DensityMapModifier = { new = function()
    eng.modifiers = eng.modifiers + 1
    return engineObject({ id = eng.modifiers, builtAt = eng.width })
  end }
  DensityMapFilter = { new = function()
    eng.filters = eng.filters + 1
    return engineObject({ id = eng.filters, builtAt = eng.width })
  end }
  DensityCoordType = DensityCoordType or { POINT_POINT_POINT = 0 }
  delete = function() end
  g_cropStressManager = nil                                          -- release gate fails open: live
end

local function clearCalls()
  eng.existsCalls, eng.loadCalls, eng.saveCalls = {}, {}, {}
end

local function liveMap(opts)
  resetEngine(opts)
  local m = CropStressValueMap.new()
  assert(m:initialize() == true, "the stub engine must stand a map up")
  clearCalls()
  return m
end

-- ── Soil and manager harness (the shape scs039_save_view_restore_test uses) ─

local function seedAbsorption(soil)
  soil.absorptionMode = "CAPPED"
  soil.agronomyRestriction = 1.0
  soil:_applyAbsorptionSpan({
    requestPerWindow = 0.015, windowEnd = HOUR, windowCount = 1,
    soilFactor = 1.0, fieldId = 1,
    providerMode = "TRUTH", providerGrain = 2,
    cellKey = "TRUTH:2:10:20",
    providerCenterX = -2101, providerCenterZ = -2087,
    cellX = 10, cellZ = 20,
    rawWrite = function() return true end,
    compactionReader = function() return nil end,
  })
end

local function bareManager(soil)
  local m = setmetatable({}, CropStressManager)
  m.isInitialized = true
  m.soilSystem = soil
  m.stressModifier = { fieldStress = {}, getStress = function(self, fid) return self.fieldStress[fid] or 0 end }
  m.irrigationManager = { systems = {}, settled = {},
    settleFittedSystem = function(self, sys) sys.activeGameHoursSinceSettle = 0 end }
  m.sprayerIntegration = { calls = 0, initialize = function(self) self.calls = self.calls + 1 end }
  m.irrigatorSectorIntegration = { calls = 0, initialize = function(self) self.calls = self.calls + 1 end }
  m.saveLoad = SaveLoadHandler.new(m)
  m.saveLoad:initialize()
  return m
end

local function allReady(m)
  local r = m:_restoreState()
  r.compactReady, r.fieldsReady, r.mapReady, r.settingsLoaded, r.absorptionFrozen = true, true, true, true, true
end

--- A soil carrying a REAL value map on the stub engine. `gateOff` leaves the map
--- release-gated off, exactly as an ordinary save runs.
local function realSoil(gateOff)
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.50, soilType = "loamy" }
  soil.fieldData[2] = { fieldId = 2, moisture = 0.50, soilType = "sandy" }
  soil.absorptionMode = "CAPPED"
  soil.agronomyRestriction = 1.0
  if gateOff then
    g_cropStressManager = { settings = { allowsExperimentalSystems = function() return false end } }
  end
  soil:initValueMap("sg")
  g_cropStressManager = nil
  return soil
end

--- A soil in TRUTH on a fake map with a native-save spy, used only to WRITE a
--- generation-era save for the load cases.
local function writerSoil()
  local soil = SoilMoistureSystem.new({})
  soil.fieldData[1] = { fieldId = 1, moisture = 0.62, soilType = "loamy", mapPending = 0.002 }
  soil.fieldData[2] = { fieldId = 2, moisture = 0.40, soilType = "sandy", mapPending = 0 }
  soil.moistureRevision = 7
  soil._lastSettledDay = 20
  soil.providerMode = "TRUTH"
  soil.valueMap = { available = true, resolution = 2048, loadedFromSave = false,
    getGrainMetres = function() return 2 end, delete = function(self) self.available = false end }
  -- The receipt AND the file on the stub disk, so the cut's on-disk check passes.
  soil.saveNativeMap = function(_self, dir, filename)
    eng.files[dir .. "/" .. filename] = { width = 2048 }
    return true
  end
  seedAbsorption(soil)
  return soil
end

--- A two-generation own-XML save whose BOTH complete envelopes fail their digest.
local function generationEraXmlAllInvalid()
  resetEngine({})
  local soil = writerSoil()
  local m = bareManager(soil)
  local handle = {}
  m.saveLoad:saveToXMLFile(handle)
  m:markMissionWaterDirty()
  soil.moistureRevision = 8
  handle = {}
  m.saveLoad:saveToXMLFile(handle)
  assert(handle[ROOT .. ".moisture.complete(0)#generation"] == 2, "the writer must produce generation 2")
  handle[ROOT .. ".moisture.complete(0)#aggregates"] = "1=0.99;2=0.40"
  handle[ROOT .. ".moisture.complete(1)#aggregates"] = "1=0.98;2=0.40"
  return handle
end

local function legacyXml(saveGeneration)
  return {
    [ROOT .. ".fields.field(0)#id"] = 1, [ROOT .. ".fields.field(0)#moisture"] = 0.33,
    [ROOT .. ".fields.field(0)#soilType"] = "clay",
    [ROOT .. "#moistureRevision"] = 12, [ROOT .. "#lastSettledDay"] = 4,
    [ROOT .. "#saveGeneration"] = saveGeneration,
  }
end

local function count(list, value)
  local n = 0
  for _, v in ipairs(list) do if v == value then n = n + 1 end end
  return n
end

-- ════════════════════════════════════════════════════════════════════════════
-- P. THE PROBE OPENS NO FILE
-- ════════════════════════════════════════════════════════════════════════════

group("P", function()
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 1024 } } })
  local m = CropStressValueMap.new()
  T.eq("P1 the map stands up", m:initialize("sg"), true)
  T.eq("P2 INITIALIZE OPENS NO FILE, with a legacy image on disk and a directory passed in", #eng.loadCalls, 0)
  T.eq("P3 and does not even look for one", #eng.existsCalls, 0)
  T.eq("P4 it is not marked as loaded from a save", m.loadedFromSave, false)
  T.eq("P5 it is fresh at the computed resolution", eng.newCalls[1], 2048)
  T.eq("P6 created once", #eng.newCalls, 1)
  T.eq("P7 its tools were built at that width", m.toolWidth, 2048)
  T.eq("P8 against a map of that width", m.modifier.builtAt, 2048)

  local soil = realSoil(false)
  T.eq("P9 through the soil system too: the map is live", soil:mapActive(), true)
  T.eq("P10 and nothing was opened", #eng.loadCalls, 0)

  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 1024 } } })
  local gated = realSoil(true)
  T.eq("P11 GATE OFF: no map at all", gated.valueMap, nil)
  T.eq("P12 and no engine call was made", #eng.newCalls + #eng.loadCalls + #eng.existsCalls, 0)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- N. THE ONE LOADER: the door, the receipt, the width, the tools
-- ════════════════════════════════════════════════════════════════════════════

group("N1", function()
  local m = liveMap({ files = { ["sg/../" .. S1] = { width = 2048 } } })
  local ok, attempted = m:loadNativeFile("sg", "../" .. S1, nil)
  T.eq("N1 a traversal name is refused", ok, false)
  T.eq("N2 before any engine load", attempted, false)
  T.eq("N3 and before even checking the disk", #eng.existsCalls + #eng.loadCalls, 0)
  ok, attempted = m:loadNativeFile("sg", "csMoistureMap.g0.grle", nil)
  T.eq("N4 g0 is refused at the door", ok == false and attempted == false, true)
  ok, attempted = m:loadNativeFile(nil, S1, nil)
  T.eq("N5 a nil directory attempts nothing", ok == false and attempted == false, true)
  T.eq("N6 and touches nothing", #eng.existsCalls + #eng.loadCalls, 0)
end)

group("N7", function()
  local m = liveMap({})
  local ok, attempted = m:loadNativeFile("sg", S2, 2048)
  T.eq("N7 a missing file is refused", ok, false)
  T.eq("N8 without an engine load", attempted == false and #eng.loadCalls == 0, true)
  T.eq("N9 after one disk check of exactly that path", eng.existsCalls[1], "sg/" .. S2)
end)

group("N10", function()
  local m = liveMap({ files = {
    ["sg/" .. S1] = { loads = false },
    ["sg/" .. S2] = { loads = 1 },
    ["sg/" .. S3] = { loads = "throw" },
  } })
  local ok, attempted = m:loadNativeFile("sg", S1, nil)
  T.eq("N10 an engine false is a refusal", ok, false)
  T.eq("N11 after an attempted load", attempted, true)
  ok, attempted = m:loadNativeFile("sg", S2, nil)
  T.eq("N12 a truthy non-true engine result is a refusal too", ok == false and attempted == true, true)
  ok, attempted = m:loadNativeFile("sg", S3, nil)
  T.eq("N13 so is an engine throw", ok == false and attempted == true, true)
  T.eq("N14 none of them marks the map loaded", m.loadedFromSave, false)
end)

group("N15", function()
  local m = liveMap({ files = { ["sg/" .. S1] = { width = 1024 } } })
  local ok, attempted = m:loadNativeFile("sg", S1, 2048)
  T.eq("N15 a width the envelope does not expect is refused", ok, false)
  T.eq("N16 after the load was attempted", attempted, true)
  T.eq("N17 and the map is not marked loaded", m.loadedFromSave, false)
end)

group("N18", function()
  local m = liveMap({ files = { ["sg/csMoistureMap.g7.grle"] = { width = 2048 } } })
  local before = m.modifier
  local ok, attempted = m:loadNativeFile("sg", "csMoistureMap.g7.grle", 2048)
  T.eq("N18 a PR188-era g<N> image still loads", ok, true)
  T.eq("N19 as an attempted load", attempted, true)
  T.eq("N20 from exactly the name it was given", eng.loadCalls[1], "sg/csMoistureMap.g7.grle")
  T.eq("N21 it is marked loaded", m.loadedFromSave, true)
  T.eq("N22 the width did not move, so the tools were not rebuilt", m.modifier, before)
end)

group("N23", function()
  local m = liveMap({ files = { ["sg/" .. S2] = { width = 1024 } } })
  local ok = m:loadNativeFile("sg", S2, nil)
  T.eq("N23 a slot image at another width loads", ok, true)
  T.eq("N24 the map adopts the file's width", m.resolution, 1024)
  T.eq("N25 THE MODIFIER WAS REBUILT against the loaded width", m.modifier.builtAt, 1024)
  T.eq("N26 and so was the filter", m.filter.builtAt, 1024)
  T.eq("N27 and the recorded tool width follows", m.toolWidth, 1024)
  T.eq("N28 one rebuild, not more", eng.modifiers, 2)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- L. THE LEGACY IMPORT: absence does nothing, a failed attempt resets
-- ════════════════════════════════════════════════════════════════════════════

group("L1", function()
  local m = liveMap({})
  local tools = m.modifier
  T.eq("L1 no legacy file: nothing imported", m:importLegacyFile("sg"), false)
  T.eq("L2 no engine load", #eng.loadCalls, 0)
  T.eq("L3 NO RESET for an absence", #eng.newCalls, 1)
  T.eq("L4 and the tools are untouched", m.modifier, tools)
  T.eq("L5 a nil directory imports nothing either", m:importLegacyFile(nil), false)
end)

group("L6", function()
  local m = liveMap({ files = { ["sg/" .. LEGACY] = { loads = false } } })
  T.eq("L6 an attempted legacy load that fails imports nothing", m:importLegacyFile("sg"), false)
  T.eq("L7 THE MAP IS RESET FRESH", #eng.newCalls, 2)
  T.eq("L8 at the computed resolution", eng.newCalls[2], 2048)
  T.eq("L9 AND THE TOOLS ARE REBUILT EVEN THOUGH THE WIDTH DID NOT CHANGE", eng.modifiers, 2)
  T.eq("L10 the map is not marked loaded", m.loadedFromSave, false)
end)

group("L11", function()
  -- A partial load that moved the width before failing.
  local m = liveMap({ files = { ["sg/" .. LEGACY] = { width = 1024, loads = "throw" } } })
  m:importLegacyFile("sg")
  T.eq("L11 the reset puts the map back at the computed resolution", m.resolution, 2048)
  T.eq("L12 the tools are built against that width", m.modifier.builtAt, 2048)
  T.eq("L13 and recorded at it", m.toolWidth, 2048)
end)

group("L14", function()
  local m = liveMap({ files = { ["sg/" .. LEGACY] = { width = 1024 } } })
  T.eq("L14 a good legacy image imports", m:importLegacyFile("sg"), true)
  T.eq("L15 marked loaded, so the seed pass will not flatten it", m.loadedFromSave, true)
  T.eq("L16 at the file's own width, with no expected width imposed", m.resolution, 1024)
  T.eq("L17 its tools rebuilt at that width", m.modifier.builtAt, 1024)
  T.eq("L18 and no reset on a success", #eng.newCalls, 1)
end)

group("L19", function()
  -- Even the reset fails: the map is released and the soil system declines it.
  resetEngine({ files = { ["sg/" .. LEGACY] = { loads = false } } })
  local soil = realSoil(false)
  eng.newThrowsAfter = 1
  T.eq("L19 nothing imported", soil:importLegacyNativeMap("sg"), false)
  T.eq("L20 the unusable map is declined for the mission", soil.valueMap, nil)
  T.eq("L21 and the zone store carries it", soil.providerMode, "ZONE")
end)

-- ════════════════════════════════════════════════════════════════════════════
-- G. THE SOIL SYSTEM SEAMS
-- ════════════════════════════════════════════════════════════════════════════

group("G1", function()
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local gated = realSoil(true)
  clearCalls()
  T.eq("G1 GATE OFF: the legacy import is a no-op", gated:importLegacyNativeMap("sg"), false)
  T.eq("G2 that touches no engine call", #eng.existsCalls + #eng.loadCalls, 0)

  local soil = realSoil(false)
  clearCalls()
  T.eq("G3 a nil save directory is a no-op", soil:importLegacyNativeMap(nil), false)
  T.eq("G4 that touches nothing", #eng.existsCalls + #eng.loadCalls, 0)
  soil.providerMode = "UNAVAILABLE_PENDING_RELOAD"
  T.eq("G5 so is a provider that failed closed", soil:importLegacyNativeMap("sg"), false)
end)

group("G6", function()
  resetEngine({ files = { ["sg/" .. S3] = { width = 2048 } } })
  local soil = realSoil(false)
  clearCalls()
  local env = { filename = S3, generation = 9, mapWidth = 2048 }
  T.eq("G6 adoption succeeds", soil:adoptNativeGeneration("sg", env), true)
  T.eq("G7 BY THE RECORDED FILE NAME, not a name rebuilt from generation 9", eng.loadCalls[1], "sg/" .. S3)
  clearCalls()
  T.eq("G8 an unsafe recorded name is refused", soil:adoptNativeGeneration("sg",
    { filename = "../" .. S3, generation = 9, mapWidth = 2048 }), false)
  T.eq("G9 without touching the disk", #eng.existsCalls + #eng.loadCalls, 0)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- B. THE BARRIER'S LEGACY BRANCH
-- ════════════════════════════════════════════════════════════════════════════

group("B1", function()
  -- Pre-generation save, legacy image on disk, through the manager's own barrier.
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  clearCalls()
  g_currentMission.missionInfo.xmlFile = legacyXml(0)
  allReady(m)
  m:_restoreState().compactReady = false
  m:loadFromXMLFile()
  g_currentMission.missionInfo.xmlFile = nil
  local r = m:_restoreState().result
  T.eq("B1 the manager supplied ctx.legacyProbe and it imported", r.legacyImported, true)
  T.eq("B2 exactly the legacy file, once", count(eng.loadCalls, "sg/" .. LEGACY), 1)
  T.eq("B3 no decline", r.declined, nil)
  T.eq("B4 the map is carried as the saved picture", soil.valueMap.loadedFromSave, true)
  T.eq("B5 and the provider is TRUTH", soil.providerMode, "TRUTH")
  T.eq("B6 the barrier completed", m:isMissionWaterReady(), true)
end)

group("B7", function()
  -- Pre-generation save, no legacy image: a fresh map for the seed pass.
  resetEngine({})
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(legacyXml(0))
  local probes = 0
  local r = m.saveLoad:restoreMissionWater({
    legacyProbe = function() probes = probes + 1; return soil:importLegacyNativeMap("sg") end,
    currentHour = HOUR,
  })
  T.eq("B7 the legacy probe was offered the load", probes, 1)
  T.eq("B8 and found nothing", r.legacyImported, false)
  T.eq("B9 no decline", r.declined, nil)
  T.eq("B10 the map stays live and fresh", soil:mapActive() and soil.valueMap.loadedFromSave == false, true)
end)

group("B11", function()
  -- GENERATION-ERA, every envelope unusable, legacy image on disk: declined.
  local handle = generationEraXmlAllInvalid()
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(handle)
  T.eq("B11 the candidates are all rejected", m.saveLoad:selectMoistureCarrier(m.saveLoad:collectMoistureCandidates()), "NONE")
  local probes = 0
  clearCalls()
  local r = m.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil:adoptNativeGeneration("sg", env) end,
    legacyProbe = function() probes = probes + 1; return soil:importLegacyNativeMap("sg") end,
    currentHour = HOUR,
  })
  T.eq("B12 THE LEGACY PROBE IS NEVER CALLED on a generation-era save", probes, 0)
  T.eq("B13 and the legacy image is never opened", count(eng.loadCalls, "sg/" .. LEGACY), 0)
  T.eq("B14 the load declines instead", type(r.declined), "string")
  T.eq("B15 THE MAP IS RELEASED TO ZONE before any seed pass", soil.valueMap, nil)
  T.eq("B16 the provider is ZONE", soil.providerMode, "ZONE")
end)

group("B17", function()
  -- saveGeneration on the XML mirror ONLY, while the LEDGER mirror (first in stage
  -- order, so the one the branch's own snapshot reads) carries neither mark.
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(legacyXml(2))
  m.saveLoad:applyStateTable({ fields = {} })
  local probes = 0
  local r = m.saveLoad:restoreMissionWater({
    legacyProbe = function() probes = probes + 1; return soil:importLegacyNativeMap("sg") end,
    currentHour = HOUR,
  })
  T.eq("B17 the branch's snapshot is the ledger one", r.source, "LEDGER")
  T.eq("B18 BOTH SURFACES ARE WALKED: no legacy import", probes, 0)
  T.eq("B19 and the load declines", type(r.declined), "string")
end)

group("B20", function()
  -- The reverse: saveGeneration on the ledger mirror, a pre-generation XML mirror.
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(legacyXml(0))
  m.saveLoad:applyStateTable({ fields = {}, saveGeneration = 3 })
  local probes = 0
  local r = m.saveLoad:restoreMissionWater({
    legacyProbe = function() probes = probes + 1 return true end, currentHour = HOUR })
  T.eq("B20 a ledger saveGeneration above 0 is generation-era", probes, 0)
  T.eq("B21 and declines", type(r.declined), "string")
end)

group("B22", function()
  -- Unusable COMPLETE envelopes on the second surface only; the first carries nothing.
  local handle = generationEraXmlAllInvalid()
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(handle)
  m.saveLoad:applyStateTable({ fields = {} })
  T.eq("B22 an invalid COMPLETE row on either mirror marks the load generation-era",
    m.saveLoad:isGenerationEraLoad(m.saveLoad:collectMoistureCandidates()), true)
  T.eq("B23 the staged saveGeneration alone marks it, with no candidate rows passed",
    m.saveLoad:isGenerationEraLoad({}), true)
  T.eq("B23b no rows and nothing staged is pre-generation",
    bareManager(realSoil(false)).saveLoad:isGenerationEraLoad({}), false)
  T.eq("B24 a PENDING_ONLY row alone is not a generation mark",
    bareManager(realSoil(false)).saveLoad:isGenerationEraLoad({ { payloadKind = "PENDING_ONLY" } }), false)
end)

group("B32", function()
  -- The COMPLETE rows ALONE. Every other generation-era fixture also carries the
  -- flat saveGeneration key, which would mark the load by itself; here that key is
  -- gone, so only the rejected COMPLETE envelopes can say the save moved on.
  local handle = generationEraXmlAllInvalid()
  handle[ROOT .. "#saveGeneration"] = nil
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(handle)
  T.eq("B32 the staged snapshot carries no generation mark", m.saveLoad._staged.XML.saveGeneration, nil)
  local probes = 0
  local r = m.saveLoad:restoreMissionWater({
    legacyProbe = function() probes = probes + 1; return soil:importLegacyNativeMap("sg") end, currentHour = HOUR })
  T.eq("B33 REJECTED COMPLETE ENVELOPES ALONE MAKE IT GENERATION-ERA: no legacy import", probes, 0)
  T.eq("B34 and the load declines", type(r.declined), "string")
end)

group("B25", function()
  -- GATE OFF: an ordinary save. Nothing to import, nothing to decline.
  local handle = generationEraXmlAllInvalid()
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(true)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(handle)
  clearCalls()
  local r = m.saveLoad:restoreMissionWater({
    legacyProbe = function() return soil:importLegacyNativeMap("sg") end, currentHour = HOUR })
  T.eq("B25 a generation-era load with the gate off sets no decline", r.declined, nil)
  T.eq("B26 and opens nothing", #eng.loadCalls + #eng.existsCalls, 0)

  local soil2 = realSoil(true)
  local m2 = bareManager(soil2)
  m2.saveLoad:loadFromXMLFile(legacyXml(0))
  clearCalls()
  local r2 = m2.saveLoad:restoreMissionWater({
    legacyProbe = function() return soil2:importLegacyNativeMap("sg") end, currentHour = HOUR })
  T.eq("B27 a pre-generation load with the gate off imports nothing", r2.legacyImported, false)
  T.eq("B28 and opens nothing", #eng.loadCalls + #eng.existsCalls, 0)
end)

group("B29", function()
  -- No legacyProbe in ctx (a caller that does not supply one): absence, not an error.
  resetEngine({ files = { ["sg/" .. LEGACY] = { width = 2048 } } })
  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(legacyXml(0))
  clearCalls()
  local r = m.saveLoad:restoreMissionWater({ currentHour = HOUR })
  T.eq("B29 a missing legacy callback is treated as absence", r.legacyImported, nil)
  T.eq("B30 nothing was opened", #eng.loadCalls, 0)
  T.eq("B31 and the map stays live", soil:mapActive(), true)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- W. ONE NAME, END TO END, AND THE THREE-SLOT ROTATION
-- ════════════════════════════════════════════════════════════════════════════

local function cutAgain(m, soil, revision)
  m:markMissionWaterDirty()
  soil.moistureRevision = revision
  return m:ensureMissionWaterSaveCut("PUMP")
end

group("W1", function()
  resetEngine({})
  local soil = realSoil(false)
  soil.moistureRevision = 7
  seedAbsorption(soil)
  local m = bareManager(soil)
  clearCalls()
  local v = m:ensureMissionWaterSaveCut("PUMP")
  T.eq("W1 the first cut commits", m._waterSaveCut.lastOutcome, "COMPLETE")
  T.eq("W2 THE ENGINE WROTE EXACTLY THE FIRST SLOT", eng.saveCalls[1], "sg/" .. S1)
  T.eq("W3 the disk check is on that same path", eng.existsCalls[#eng.existsCalls], "sg/" .. S1)
  T.eq("W4 and the envelope records that same string", v.complete[1].filename, S1)
  T.eq("W5 one write", #eng.saveCalls, 1)

  local function nameOf(record)
    return record ~= nil and record.envelope ~= nil and record.envelope.filename or nil
  end
  local written = { S1 }
  local cleanRule = true
  for rev = 8, 11 do
    local cur = nameOf(m.saveLoad._completePair.current)
    local prev = nameOf(m.saveLoad._completePair.previous)
    cutAgain(m, soil, rev)
    local name = m.saveLoad._completePair.current.envelope.filename
    written[#written + 1] = name
    if name == cur or name == prev then cleanRule = false end
  end
  T.eq("W6 THE SLOTS ROTATE s1 s2 s3 s1 s2", table.concat(written, " "),
    table.concat({ S1, S2, S3, S1, S2 }, " "))
  T.eq("W7 no cut ever wrote the selected current or previous file", cleanRule, true)
  local onlySlots = true
  for _, path in ipairs(eng.saveCalls) do
    if not CropStressValueMap.isSlotFileName((path:gsub("^sg/", ""))) then onlySlots = false end
  end
  T.eq("W8 every engine write went to a slot name", onlySlots, true)
  T.eq("W9 five saves put three moisture files on disk, no more",
    (eng.files["sg/" .. S1] and 1 or 0) + (eng.files["sg/" .. S2] and 1 or 0) + (eng.files["sg/" .. S3] and 1 or 0), 3)
  local extra = 0
  for path in pairs(eng.files) do if not CropStressValueMap.isSlotFileName((path:gsub("^sg/", ""))) then extra = extra + 1 end end
  T.eq("W10 and nothing else", extra, 0)
end)

group("W11", function()
  -- INTERRUPTION: the engine reports a write that never reaches disk.
  resetEngine({})
  local soil = realSoil(false)
  soil.moistureRevision = 7
  seedAbsorption(soil)
  local m = bareManager(soil)
  m:ensureMissionWaterSaveCut("PUMP")                    -- generation 1 in s1
  cutAgain(m, soil, 8)                                   -- generation 2 in s2
  clearCalls()
  eng.dropWrites = true
  cutAgain(m, soil, 9)
  T.eq("W11 the lost write does not commit", m._waterSaveCut.lastOutcome, "PENDING_ONLY")
  T.eq("W12 the interrupted write went to the candidate slot only", eng.saveCalls[1], "sg/" .. S3)
  T.eq("W13 the current file is intact", eng.files["sg/" .. S2] ~= nil, true)
  T.eq("W14 the previous file is intact", eng.files["sg/" .. S1] ~= nil, true)
  T.eq("W15 no generation advanced", m.saveLoad._completePair.current.generation, 2)
  eng.dropWrites = false
  clearCalls()
  m:ensureMissionWaterSaveCut("CAREER_XML")
  T.eq("W16 THE RETRY REUSES THE SAME SLOT", eng.saveCalls[1], "sg/" .. S3)
  T.eq("W17 and commits", m.saveLoad._completePair.current.generation, 3)
end)

group("W18", function()
  -- A nil save directory: the cut calls no native writer at all.
  resetEngine({})
  local soil = realSoil(false)
  soil.moistureRevision = 7
  seedAbsorption(soil)
  local m = bareManager(soil)
  local writerCalls = 0
  local realSave = soil.saveNativeMap
  soil.saveNativeMap = function(self, ...) writerCalls = writerCalls + 1; return realSave(self, ...) end
  g_currentMission.missionInfo.savegameDirectory = nil
  clearCalls()
  m:ensureMissionWaterSaveCut("PUMP")
  g_currentMission.missionInfo.savegameDirectory = "sg"
  T.eq("W18 no native writer is called with a nil directory", writerCalls, 0)
  T.eq("W19 nothing reached the engine", #eng.saveCalls, 0)
  T.eq("W20 and the provider did not fail closed over it", soil.providerMode, "TRUTH")
end)

group("W21", function()
  -- After a restore the bank is what the winning mirror names.
  resetEngine({})
  local writer = realSoil(false)
  writer.moistureRevision = 7
  seedAbsorption(writer)
  local mw = bareManager(writer)
  local handle = {}
  mw.saveLoad:saveToXMLFile(handle)                      -- s1
  mw:markMissionWaterDirty()
  writer.moistureRevision = 8
  handle = {}
  mw.saveLoad:saveToXMLFile(handle)                      -- s2, previous s1

  local soil = realSoil(false)
  local m = bareManager(soil)
  m.saveLoad:loadFromXMLFile(handle)
  clearCalls()
  local r = m.saveLoad:restoreMissionWater({
    nativeProbe = function(env) return soil:adoptNativeGeneration("sg", env) end, currentHour = HOUR })
  T.eq("W21 the restore adopts generation 2", r.generation, 2)
  T.eq("W22 from its recorded slot", eng.loadCalls[1], "sg/" .. S2)
  clearCalls()
  cutAgain(m, soil, 9)
  T.eq("W23 THE NEXT CUT WRITES THE ONE SLOT THE RESTORED PAIR DOES NOT NAME", eng.saveCalls[1], "sg/" .. S3)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- R. THE STATELEDGER REGISTRATION RESULT
-- ════════════════════════════════════════════════════════════════════════════

local function registerWith(fn)
  g_stateLedger = nil
  g_currentMission.stateLedger = fn ~= nil and { registerModule = fn } or nil
  CropStressStateLedgerBridge.register({})
  g_currentMission.stateLedger = nil
end

group("R", function()
  registerWith(function() return true end)
  T.eq("R1 an exact true registers", CropStressStateLedgerBridge.active, true)
  registerWith(function() return false end)
  T.eq("R2 A REFUSAL (false) IS NOT REGISTERED", CropStressStateLedgerBridge.active, false)
  registerWith(function() return nil end)
  T.eq("R3 nor is a nil return", CropStressStateLedgerBridge.active, false)
  registerWith(function() return 1 end)
  T.eq("R4 nor a truthy non-true return", CropStressStateLedgerBridge.active, false)
  registerWith(function() error("ledger threw") end)
  T.eq("R5 nor a throw", CropStressStateLedgerBridge.active, false)
  registerWith(nil)
  T.eq("R6 no ledger, no registration", CropStressStateLedgerBridge.active, false)

  -- A late registrant: StateLedger delivers synchronously inside registerModule.
  registerWith(function(_self, _name, hooks)
    hooks.deserialize({ state = { marker = 1 } })
    return true
  end)
  T.eq("R7 a synchronous late delivery still registers", CropStressStateLedgerBridge.active, true)
  T.eq("R8 and its data is staged", CropStressStateLedgerBridge.delivered, true)
  T.eq("R9 so the ledger is a source for this load", CropStressStateLedgerBridge.hasLedgerState() == true, true)
end)

T.summary()
