-- scs039_netsync_gate_test.lua
-- SCS-039 / GRID-1 (SDS 3.8): the NetworkSync aggregate mirror is active only
-- when registerModule returns EXACTLY true, and its read callback updates
-- legacy aggregates only while the SCS fine map is not the current authority.
--!load: src/SoilMoistureSystem.lua, src/integrations/CropStressNetworkSyncBridge.lua

local function soilWithField(providerMode, withMap)
  local s = SoilMoistureSystem.new({})
  s.fieldData[1] = { fieldId = 1, moisture = 0.5, soilType = "loamy" }
  s.providerMode = providerMode
  if withMap then s.valueMap = { available = true } end
  return s
end

local function applyRead(soil)
  local mgr = { soilSystem = soil, stressModifier = { fieldStress = {} } }
  g_currentMission.cropStressManager = mgr   -- the bridge resolves the manager globally
  local arr = CropStressNetworkSyncBridge.serializeFields(
    { [1] = { moisture = 0.9 } }, { [1] = 0.25 })
  CropStressNetworkSyncBridge._onReadState(arr)
  g_currentMission.cropStressManager = nil
  return mgr
end

-- 1. REGISTRATION REQUIRES EXACT TRUE (Group M M1-M4).
do
  local function registerReturning(ret)
    g_currentMission.networkSync = {
      registerModule = function()
        if type(ret) == "table" and ret.throw then error("refused") end
        return ret
      end,
    }
    CropStressNetworkSyncBridge.register({})
    local active = CropStressNetworkSyncBridge.active
    g_currentMission.networkSync = nil
    return active
  end
  T.eq("netsync.exactTrueActivates", registerReturning(true), true)
  T.eq("netsync.falseIsNeutralAbsence", registerReturning(false), false)
  T.eq("netsync.nilIsNeutralAbsence", registerReturning(nil), false)
  T.eq("netsync.thrownIsNeutralAbsence", registerReturning({ throw = true }), false)

  g_currentMission.networkSync = nil
  CropStressNetworkSyncBridge.register({})
  T.eq("netsync.absentIsNeutralAbsence", CropStressNetworkSyncBridge.active, false)
end

-- 2. THE READ MIRROR STANDS DOWN WHILE THE SCS FINE MAP IS CURRENT.
do
  local current = soilWithField("TRUTH", true)
  T.eq("barrier.currentIsTrue", current:isMoistureMapCurrent(), true)
  applyRead(current)
  T.near("barrier.currentKeepsScalar", current.fieldData[1].moisture, 0.5, 1e-12)

  local notCurrent = soilWithField("ZONE", false)
  T.eq("barrier.notCurrentIsFalse", notCurrent:isMoistureMapCurrent(), false)
  applyRead(notCurrent)
  T.near("barrier.mirrorUpdatesScalar", notCurrent.fieldData[1].moisture, 0.9, 1e-12)
end

T.summary()
