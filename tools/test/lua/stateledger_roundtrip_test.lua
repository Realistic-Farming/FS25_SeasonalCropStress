-- stateledger_roundtrip_test.lua - StateLedger table serializer round-trip (#bedrock).
-- Proves SaveLoadHandler:buildStateTable() <-> applyStateTable() is lossless for the
-- persisted crop-stress state (per-field moisture/stress/soilType, HUD flags,
-- irrigation schedules), so the ledger save path equals the careerSavegame.xml path.
--!load: src/SaveLoadHandler.lua

-- Minimal soil-type table the apply path validates against.
SoilMoistureSystem = SoilMoistureSystem or { SOIL_PARAMS = { loamy = {}, clay = {}, sandy = {}, silty = {} } }

-- Build a SaveLoadHandler over a mock manager with just the subsystems the table
-- serializer touches.
local function newHandler(fields, stress, systems, hud)
  local mgr = {
    soilSystem     = { fieldData = fields or {} },
    stressModifier = {
      fieldStress = stress or {},
      getStress   = function(self, fid) return self.fieldStress[fid] or 0.0 end,
    },
    irrigationManager = {
      systems        = systems or {},
      activateSystem = function(self, id)
        if self.systems[id] then self.systems[id].isActive = true end
      end,
    },
    hudOverlay    = hud or { isVisible = false, firstRunShown = false },
    npcIntegration = nil,
  }
  local sl = SaveLoadHandler.new(mgr)
  sl.isInitialized = true
  return sl, mgr
end

-- Full round-trip: fields, HUD, and an irrigation schedule survive the table pass.
do
  local srcSystems = {
    [42] = {
      schedule = { startHour = 6, endHour = 10, activeDays = { true, true, true, true, true, false, false } },
      isActive = true,
    },
  }
  local src = newHandler(
    { [1] = { moisture = 0.42, soilType = "clay" }, [7] = { moisture = 0.63, soilType = "loamy" } },
    { [1] = 0.10, [7] = 0.55 },
    srcSystems,
    { isVisible = true, firstRunShown = true }
  )

  local snap = src:buildStateTable()

  -- Fresh destination: empty field data + a matching irrigation system to restore into
  -- (schedules apply onto existing systems, mirroring the XML load).
  local dstSystems = {
    [42] = {
      schedule = { startHour = 0, endHour = 0, activeDays = { false, false, false, false, false, false, false } },
      isActive = false,
    },
  }
  local dst, dstMgr = newHandler(
    { [1] = { moisture = 0.0, soilType = "sandy" }, [7] = { moisture = 0.0, soilType = "sandy" } },
    {},
    dstSystems,
    { isVisible = false, firstRunShown = false }
  )
  local ok = dst:applyStateTable(snap)
  T.ok("roundtrip: applyStateTable returned true", ok == true)

  local fd = dstMgr.soilSystem.fieldData
  T.near("roundtrip: field 1 moisture", fd[1].moisture, 0.42)
  T.near("roundtrip: field 7 moisture", fd[7].moisture, 0.63)
  T.eq("roundtrip: field 1 soilType", fd[1].soilType, "clay")
  T.eq("roundtrip: field 7 soilType", fd[7].soilType, "loamy")

  T.near("roundtrip: field 1 stress", dstMgr.stressModifier.fieldStress[1], 0.10)
  T.near("roundtrip: field 7 stress", dstMgr.stressModifier.fieldStress[7], 0.55)

  T.eq("roundtrip: hud visible", dstMgr.hudOverlay.isVisible, true)
  T.eq("roundtrip: hud firstRunShown", dstMgr.hudOverlay.firstRunShown, true)

  local sys = dstMgr.irrigationManager.systems[42]
  T.eq("roundtrip: irrigation startHour", sys.schedule.startHour, 6)
  T.eq("roundtrip: irrigation endHour", sys.schedule.endHour, 10)
  T.eq("roundtrip: irrigation day[1] true", sys.schedule.activeDays[1], true)
  T.eq("roundtrip: irrigation day[6] false", sys.schedule.activeDays[6], false)
  T.eq("roundtrip: irrigation reactivated", sys.isActive, true)
end

-- Clamping: out-of-range moisture/stress pulled into 0..1 on apply.
do
  local dst, dstMgr = newHandler({ [2] = { moisture = 0.0, soilType = "loamy" } }, {})
  dst:applyStateTable({ fields = { [2] = { moisture = 1.9, stress = -0.5, soilType = "loamy" } } })
  T.near("clamp: moisture capped at 1", dstMgr.soilSystem.fieldData[2].moisture, 1.0)
  T.near("clamp: stress floored at 0", dstMgr.stressModifier.fieldStress[2], 0.0)
end

-- An unknown soilType is rejected (keeps the local value), matching the XML guard.
do
  local dst, dstMgr = newHandler({ [3] = { moisture = 0.5, soilType = "loamy" } }, {})
  dst:applyStateTable({ fields = { [3] = { moisture = 0.5, soilType = "notarealtype" } } })
  T.eq("guard: unknown soilType rejected", dstMgr.soilSystem.fieldData[3].soilType, "loamy")
end

-- Fields absent locally are skipped (never fabricated), matching the XML guard.
do
  local dst, dstMgr = newHandler({}, {})
  dst:applyStateTable({ fields = { [9] = { moisture = 0.7, soilType = "loamy" } } })
  T.ok("guard: unknown field not created", dstMgr.soilSystem.fieldData[9] == nil)
end

-- nil / non-table input degrades to false (never crashes).
do
  local dst = newHandler({}, {})
  T.eq("guard: nil input = false", dst:applyStateTable(nil), false)
end
