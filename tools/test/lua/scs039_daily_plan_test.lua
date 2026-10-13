-- scs039_daily_plan_test.lua
-- SCS-039 / GRID-1 (SDS 3.6): the daily-plan core. One open plan handles a
-- positive due day span, pinned to its target day, base provider revision,
-- carrier and field fingerprints; it advances at most DAILY_OPS_PER_FRAME per
-- frame and commits once, moving the cursor and advancing the readable
-- revision. Zero, backward, duplicate or non-finite spans do nothing; a broken
-- pin aborts the plan without moving the cursor.
--
-- Group J models the same contract. The runtime mapping of plan operations to
-- per-field redistribution work and the Time Guard subscribeTick registration
-- are the follow-on wiring slices.
--!load: src/SoilMoistureSystem.lua

local OPS = SoilMoistureSystem.DAILY_OPS_PER_FRAME

local function systemAt(day, revision)
  local s = SoilMoistureSystem.new({})
  s._lastSettledDay = day
  s.moistureRevision = revision
  return s
end

-- 1. PURE DUE MATH (zero, backward, duplicate, non-finite owe nothing).
do
  T.eq("due.threeWholeDays", SoilMoistureSystem.computeDueDays(5, 8), 3)
  T.eq("due.backward", SoilMoistureSystem.computeDueDays(8, 7), 0)
  T.eq("due.duplicate", SoilMoistureSystem.computeDueDays(8, 8), 0)
  T.eq("due.subDay", SoilMoistureSystem.computeDueDays(8, 8.5), 0)
  T.eq("due.missingCursor", SoilMoistureSystem.computeDueDays(nil, 8), 0)
  T.eq("due.missingDay", SoilMoistureSystem.computeDueDays(8, nil), 0)
  T.eq("due.nonFinite", SoilMoistureSystem.computeDueDays(8, math.huge), 0)
  T.eq("due.nan", SoilMoistureSystem.computeDueDays(8, math.huge * 0), 0)
end

-- 2. OPEN, BUDGETED ADVANCE AND ONE COMMIT (Group J J1-J11).
do
  local s = systemAt(5, 20)
  T.eq("plan.openPending", s:wakeDailyPlan(8, 900), "PENDING")
  T.eq("plan.cursorUnchangedWhileOpen", s._lastSettledDay, 5)
  T.eq("plan.pinnedDue", s._dailyPlan.due, 3)
  T.eq("plan.pinnedTarget", s._dailyPlan.targetDay, 8)
  T.eq("plan.pinnedRevision", s._dailyPlan.baseRevision, 20)
  local step1, st1 = s:advanceDailyPlan(8, OPS)
  T.eq("plan.firstFrameBudgeted", step1, OPS)
  T.eq("plan.firstFramePending", st1, "PENDING")
  local step2, st2 = s:advanceDailyPlan(8, OPS)
  T.eq("plan.secondFramePending", st2, "PENDING")
  local step3, st3 = s:advanceDailyPlan(8, OPS)
  T.eq("plan.finalFrameRemaining", step3, 100)
  T.eq("plan.finalFrameCommits", st3, "COMMITTED")
  T.eq("plan.cursorMovedToTarget", s._lastSettledDay, 8)
  T.eq("plan.revisionAdvancedOnce", s.moistureRevision, 21)
  T.eq("plan.cleared", s._dailyPlan, nil)
  T.eq("plan.duplicateWakeIdle", s:wakeDailyPlan(8), "IDLE")
end

-- 3. SEEDING: a first-ever wake seeds the current day with no invented history
--    and mints no revision (J18-J20).
do
  local s = SoilMoistureSystem.new({})
  T.eq("seed.firstWakeSeeds", s:wakeDailyPlan(12), "SEEDED")
  T.eq("seed.cursorIsCurrent", s._lastSettledDay, 12)
  T.eq("seed.noRevision", s.moistureRevision, 1)
  T.eq("seed.noPlan", s._dailyPlan, nil)
end

-- 4. ZERO BUDGET visibly pauses and never claims completion (J22-J23).
do
  local s = systemAt(5, 20)
  s:wakeDailyPlan(8, 900)
  T.eq("pause.zeroBudget", select(2, s:advanceDailyPlan(8, 0)), "PAUSED")
  T.eq("pause.cursorUnchanged", s._lastSettledDay, 5)
  T.eq("pause.planIntact", s._dailyPlan ~= nil, true)
  T.eq("pause.planNotAdvanced", s._dailyPlan.cursor, 0)
end

-- 5. PIN BREAKS ABORT THE PLAN WITHOUT MOVING THE CURSOR (J15-J17): an
--    authoritative replacement advances the revision, a provider transition
--    changes the carrier, and a geometry change alters the fingerprint.
do
  local s = systemAt(5, 20)
  s:wakeDailyPlan(8, 900)
  s.moistureRevision = 21
  T.eq("abort.replacement", select(2, s:advanceDailyPlan(8, OPS)), "ABORTED")
  T.eq("abort.planCleared", s._dailyPlan, nil)
  T.eq("abort.cursorHeld", s._lastSettledDay, 5)

  local s2 = systemAt(5, 20)
  s2:wakeDailyPlan(8, 900)
  s2.providerMode = "ZONE"
  T.eq("abort.carrierChange", select(2, s2:advanceDailyPlan(8, OPS)), "ABORTED")
  T.eq("abort.carrierCursorHeld", s2._lastSettledDay, 5)

  local s3 = systemAt(5, 20)
  s3:wakeDailyPlan(8, 900)
  s3.fieldData[1] = { fieldId = 1 }
  T.eq("abort.geometryChange", select(2, s3:advanceDailyPlan(8, OPS)), "ABORTED")
  T.eq("abort.geometryCursorHeld", s3._lastSettledDay, 5)
end

-- 6. INVALID WAKES and an absent day refuse before the provider.
do
  local s = systemAt(5, 20)
  T.eq("invalid.nan", s:wakeDailyPlan(math.huge * 0), "INVALID")
  T.eq("invalid.huge", s:wakeDailyPlan(math.huge), "INVALID")
  T.eq("idle.noPlanAdvance", select(2, s:advanceDailyPlan(8, OPS)), "IDLE")
end

-- 7. A duplicate wake while a plan is open resumes it without a second plan.
do
  local s = systemAt(5, 20)
  s:wakeDailyPlan(8, 900)
  s:wakeDailyPlan(8, 900)
  T.eq("resume.singlePlan", s._dailyPlan ~= nil, true)
  T.eq("resume.pinnedDue", s._dailyPlan.due, 3)
  T.eq("resume.cursorStillZero", s._dailyPlan.cursor, 0)
end

T.summary()
