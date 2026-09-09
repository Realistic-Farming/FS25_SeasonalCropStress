-- scs041_wiring_test.lua
-- SCS-041 §2/§3/§4: the live wiring. Mode-aware dispatch, the numeric CAPPED
-- path (hour resolve, neutral on nil hour), span-list CAPPED fan-out, and the
-- mission-config freeze. The injected leaf functions are spied so the routing is
-- proven without the full storage engine.
--!load: src/integrations/OptionScalingResolver.lua, src/ReleaseGate.lua, src/SoilMoistureSystem.lua

local function sys()
  local s = SoilMoistureSystem.new({})
  s._cellSize = 10
  s.valueMap = nil
  s.providerMode = "ZONE"
  s.fieldData[1] = { soilType = "clay" }
  return s
end

-- 1. UNCAPPED numeric -> raw door, never the ledger.
do
  local s = sys(); s.absorptionMode = "UNCAPPED"
  local rawCalls, spanCalls = 0, 0
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  s._applyAbsorptionSpan = function() spanCalls = spanCalls + 1; return {} end
  T.eq("uncapped.accepted", s:applyWaterAtCell(1, 5, 5, 0.02), true)
  T.eq("uncapped.rawDoor", rawCalls, 1)
  T.eq("uncapped.noLedger", spanCalls, 0)
end

-- 2. CAPPED numeric with a valid hour -> the ledger, one current-hour window,
--    soil factor from the field's soil type, provider resolved to ZONE.
do
  local s = sys(); s.absorptionMode = "CAPPED"; s.agronomyRestriction = 1.0
  local prev = g_currentMission
  g_currentMission = { environment = { currentHour = 5, currentMonotonicDay = 3 } }
  local captured
  s._applyAbsorptionSpan = function(_self, args) captured = args; return {} end
  T.eq("capped.accepted", s:applyWaterAtCell(1, 25, 35, 0.02), true)
  T.eq("capped.window", captured.windowEnd, 3 * 24 + 5)
  T.eq("capped.oneWindow", captured.windowCount, 1)
  T.near("capped.request", captured.requestPerWindow, 0.02, 1e-12)
  T.near("capped.soilFactorClay", captured.soilFactor, 0.72, 1e-12)
  T.eq("capped.providerZone", captured.providerMode, "ZONE")
  T.eq("capped.cellKey", captured.cellKey, "ZONE:10:2:3")
  T.eq("capped.hasRawWrite", type(captured.rawWrite), "function")
  T.eq("capped.hasCompactionReader", type(captured.compactionReader), "function")
  g_currentMission = prev
end

-- 3. CAPPED numeric with no resolvable hour -> neutral raw route, no ledger.
do
  local s = sys(); s.absorptionMode = "CAPPED"; s.agronomyRestriction = 1.0
  local prev = g_currentMission
  g_currentMission = { environment = { currentDay = 3 } }  -- no currentHour/monotonicDay
  local rawCalls, spanCalls = 0, 0
  s._applyRawWaterAtCell = function() rawCalls = rawCalls + 1; return true, true end
  s._applyAbsorptionSpan = function() spanCalls = spanCalls + 1; return {} end
  s:applyWaterAtCell(1, 25, 35, 0.02)
  T.eq("nilHour.rawDoor", rawCalls, 1)
  T.eq("nilHour.noLedger", spanCalls, 0)
  g_currentMission = prev
end

-- 4. CAPPED span list -> one ledger call per span, windowEnd derived per span.
do
  local s = sys(); s.absorptionMode = "CAPPED"; s.agronomyRestriction = 1.0
  local calls = {}
  s._applyAbsorptionSpan = function(_self, args) calls[#calls + 1] = args; return {} end
  local ok = s:applyWaterAtCell(1, 25, 35, {
    { firstWindowId = 100, windowCount = 3, requestedGainPerWindow = 0.01 },
    { firstWindowId = 110, windowCount = 1, requestedGainPerWindow = 0.02 },
  })
  T.eq("span.accepted", ok, true)
  T.eq("span.twoCalls", #calls, 2)
  T.eq("span.firstWindowEnd", calls[1].windowEnd, 102)  -- 100 + 3 - 1
  T.eq("span.firstCount", calls[1].windowCount, 3)
  T.eq("span.secondWindowEnd", calls[2].windowEnd, 110)
end

-- 5. mission-config freeze: the release row is locked and not opted in, so the
--    mission freezes UNCAPPED (real default: isSystemLive is false).
do
  local s = sys()
  local prev = g_currentMission; g_currentMission = {}
  local prevLive = ReleaseGate.isSystemLive
  ReleaseGate.isSystemLive = function() return false end
  s:_freezeAbsorptionConfig()
  T.eq("freeze.lockedIsUncapped", s.absorptionMode, "UNCAPPED")
  T.near("freeze.neutralRestriction", s.agronomyRestriction, 1.0, 1e-12)
  T.eq("freeze.frozenFlag", s._absorptionConfigFrozen, true)
  ReleaseGate.isSystemLive = prevLive
  g_currentMission = prev
end

-- 6. preFreezeWaterObserved forces UNCAPPED even with the row open.
do
  local s = sys()
  s._preFreezeWaterObserved = true
  local prev = g_currentMission; g_currentMission = {}
  local prevLive = ReleaseGate.isSystemLive
  ReleaseGate.isSystemLive = function() return true end
  s:_freezeAbsorptionConfig()
  T.eq("prefreeze.forcesUncapped", s.absorptionMode, "UNCAPPED")
  ReleaseGate.isSystemLive = prevLive
  g_currentMission = prev
end

-- 7. row open, no pre-freeze water, no SettingsHub -> CAPPED at neutral.
do
  local s = sys()
  local prev = g_currentMission; g_currentMission = {}
  local prevLive = ReleaseGate.isSystemLive
  ReleaseGate.isSystemLive = function() return true end
  s:_freezeAbsorptionConfig()
  T.eq("open.capped", s.absorptionMode, "CAPPED")
  T.near("open.neutral", s.agronomyRestriction, 1.0, 1e-12)
  ReleaseGate.isSystemLive = prevLive
  g_currentMission = prev
end
