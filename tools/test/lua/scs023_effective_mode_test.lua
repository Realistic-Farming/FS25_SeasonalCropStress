-- scs023_effective_mode_test.lua
-- SCS-023 / GRID-1 (SDS 4): effective finite-water mode. The session-only latch
-- fills finite sources exactly once on the server at an active-to-inactive
-- edge and never on repeated false or false-to-true. One authoritative
-- settings owner routes panel, sync-event and SettingsHub writes through apply,
-- validate, subsystem re-apply and the mode edge.
--!load: src/IrrigationManager.lua, src/CropStressManager.lua

-- 1. FILL-ONCE EDGE on the irrigation manager.
do
  local mgrSettings = { finiteWater = true }
  local mgr = IrrigationManager.new({ settings = mgrSettings })
  mgr.waterSources = { [1] = { id = 1, finite = true, capacity = 48, waterRemaining = 10, hasWater = true } }

  T.eq('edge.firstSeeds', mgr:handleFiniteWaterModeEdge(), "seeded")
  T.eq('edge.seedDoesNotFill', mgr.waterSources[1].waterRemaining, 10)

  g_server = {}
  mgrSettings.finiteWater = false
  T.eq('edge.activeToInactiveFills', mgr:handleFiniteWaterModeEdge(), "filled")
  T.eq('edge.filledToCapacity', mgr.waterSources[1].waterRemaining, 48)
  T.ok('edge.derivedWet', mgr.waterSources[1].hasWater == true)

  T.eq('edge.repeatedFalseNoFill', mgr:handleFiniteWaterModeEdge(), "unchanged")
  T.eq('edge.stillFull', mgr.waterSources[1].waterRemaining, 48)

  mgrSettings.finiteWater = true
  T.eq('edge.falseToTrueNoFill', mgr:handleFiniteWaterModeEdge(), "unchanged")
  T.eq('edge.fullRemainsFull', mgr.waterSources[1].waterRemaining, 48)
  g_server = nil
end

-- 2. AUTHORITATIVE SETTINGS OWNER applies, validates, re-applies and edges.
do
  local edgeCalls = 0
  local applyCalls = 0
  local validateCalls = 0
  local mgr = setmetatable({}, { __index = CropStressManager })
  mgr.settings = {
    finiteWater = false,
    foo = 1,
    validateSettings = function() validateCalls = validateCalls + 1 end,
  }
  mgr.applySettings = function() applyCalls = applyCalls + 1 end
  mgr.irrigationManager = {
    handleFiniteWaterModeEdge = function() edgeCalls = edgeCalls + 1 return "unchanged" end,
  }

  T.eq('owner.finiteWaterApplied', mgr:applyAuthoritativeSettingChange("finiteWater", true, "panel"), true)
  T.eq('owner.settingValue', mgr.settings.finiteWater, true)
  T.eq('owner.applied', applyCalls, 1)
  T.eq('owner.validated', validateCalls, 1)
  T.eq('owner.edgeRefreshed', edgeCalls, 1)

  T.eq('owner.unknownRejected', mgr:applyAuthoritativeSettingChange("noSuchKey", true, "hub"), false)
  T.eq('owner.unknownNotSet', mgr.settings.noSuchKey, nil)
end

T.summary()
