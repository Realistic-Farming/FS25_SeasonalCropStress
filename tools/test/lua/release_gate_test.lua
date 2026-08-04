-- release_gate_test.lua - the release gate (STABLE vs experimental-LOCKED).
--
-- The gate is orthogonal to difficulty and mirrors the bypass lock, but on the
-- release axis. Arissani's certification (2026-08-03): the #89 rebuild and the
-- moisture coupling LOCK when built (both unbuilt today, so the rows are noted
-- as such). F93 the temperature fix ships STABLE, it is a fix and not a system,
-- so it is NOT in the registry.
--!load: src/ReleaseGate.lua, src/settings/CropStressSettings.lua

-- Sanity: the two future rows exist and carry the not-built note.
T.ok("cs_89_rebuild registered", ReleaseGate.EXPERIMENTAL.cs_89_rebuild ~= nil)
T.ok("moisture_coupling registered", ReleaseGate.EXPERIMENTAL.moisture_coupling ~= nil)
T.ok("rebuild row notes not built", string.find(ReleaseGate.EXPERIMENTAL.cs_89_rebuild.status, "not built", 1, true) ~= nil)
T.ok("coupling row notes not built", string.find(ReleaseGate.EXPERIMENTAL.moisture_coupling.status, "not built", 1, true) ~= nil)

-- F93 is a fix, not a system: it is NOT in the registry (ships stable).
T.ok("F93 not in the experimental registry", ReleaseGate.EXPERIMENTAL.f93_temperature == nil)

-- isReleased: a non-experimental system is always released regardless of opt-in.
T.ok("stable system released with no opt-in", ReleaseGate.isReleased("yieldCap", nil) == true)
T.ok("stable system released with opt-in off", ReleaseGate.isReleased("yieldCap", false) == true)

-- isReleased: the future rows are LOCKED until the explicit opt-in.
T.ok("rebuild LOCKED by default", ReleaseGate.isReleased("cs_89_rebuild", nil) == false)
T.ok("rebuild LOCKED with opt-in off", ReleaseGate.isReleased("cs_89_rebuild", false) == false)
T.ok("rebuild released when opt-in on", ReleaseGate.isReleased("cs_89_rebuild", true) == true)
T.ok("coupling LOCKED by default", ReleaseGate.isReleased("moisture_coupling", nil) == false)
T.ok("coupling released when opt-in on", ReleaseGate.isReleased("moisture_coupling", true) == true)

-- lockMessage: nil when released, a refusal string when locked.
T.eq("no lock message for a stable system", ReleaseGate.lockMessage("yieldCap", nil), nil)
T.eq("no lock message when opted in", ReleaseGate.lockMessage("cs_89_rebuild", true), nil)
local msg = ReleaseGate.lockMessage("cs_89_rebuild", false)
T.ok("lock message when locked", msg ~= nil)
T.ok("message names the not-released state", string.find(msg, "not released", 1, true) ~= nil)

-- status: player-friendly, short, one line per system.
local st = ReleaseGate.status(false)
T.ok("status says OFF when not opted in", string.find(st, "OFF", 1, true) ~= nil)
T.ok("status lists LOCKED systems", string.find(st, "LOCKED", 1, true) ~= nil)
local stOn = ReleaseGate.status(true)
T.ok("status says ON when opted in", string.find(stOn, "ON", 1, true) ~= nil)

-- The settings predicate: default false, orthogonal to difficulty.
local s = CropStressSettings.new()
T.ok("experimentalSystems defaults off", s:allowsExperimentalSystems() == false)
s.experimentalSystems = true
T.ok("experimentalSystems reads on", s:allowsExperimentalSystems() == true)
s:resetToDefaults()
T.ok("reset returns the opt-in to off", s:allowsExperimentalSystems() == false)

-- Fail-open: no manager means the gate cannot be read, so a system counts as live.
T.ok("isSystemLive fails open with no manager", ReleaseGate.isSystemLive("cs_89_rebuild"))
