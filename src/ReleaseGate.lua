-- =========================================================
-- FS25 Seasonal Crop Stress - Release Gate
-- =========================================================
-- The release gate: which systems are released (STABLE) vs experimental (LOCKED).
--
-- Orthogonal to difficulty. The gate is its own explicit opt-in (experimental
-- systems, on at your own risk), independent of difficulty, and the two locks
-- STACK.
--
-- The lock set and the rule that generates it come from Arissani's certification
-- (2026-08-03, ledger): LOCK the #89 rebuild and the moisture coupling when they
-- are built (both are gated or unbuilt today, so no live rows yet). F93 the
-- temperature fix ships STABLE, it is a fix and not a system, so it is not in the
-- registry. The two rows below are noted as unbuilt so the registry is honest.
-- =========================================================

-- Local log helper (the mod has no shared logger global).
local function csLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

ReleaseGate = ReleaseGate or {}

-- The certified experimental (LOCKED) set. Each entry: [systemId] = { name, status }.
-- `status` is a SHORT player-facing note on what is not working or implemented yet.
-- A system that is NOT in this table is released (the proven baseline).
ReleaseGate.EXPERIMENTAL = {
    cs_89_rebuild = {
        name = "Crop stress rebuild (#89)",
        status = "not built yet; locks when it lands",
    },
    moisture_coupling = {
        name = "Moisture coupling",
        status = "not built yet; locks when it lands",
    },
    -- SCS-039 / GRID-1. LOCKED at merge per the brief. Unlock gates on the
    -- standard in-game layer look: no FPS regression beside the six shipped
    -- soil layers. The system is inert on any install where the engine cannot
    -- carry the map, so a locked row here never costs the fallback anything.
    cs_grid_concordance = {
        name = "Moisture on the 2m grid",
        status = "new; awaiting the in-game layer look",
    },
}

-- Console command -> systemId, so command refusals route through the same registry.
ReleaseGate.COMMAND_TO_SYSTEM = {}

--- A system is released when it is NOT experimental, or the player has explicitly
--- opted into experimental systems. `optIn` is the settings.experimentalSystems boolean.
---@param systemId string
---@param optIn boolean|nil
---@return boolean
function ReleaseGate.isReleased(systemId, optIn)
    if not ReleaseGate.EXPERIMENTAL[systemId] then return true end
    return optIn == true
end

--- The LIVE opt-in: reads the player's current settings.experimentalSystems value
--- through the manager. Returns nil when the manager/settings are not available yet
--- (pre-init or the offline test bench); callers decide what nil means.
---@return boolean|nil
function ReleaseGate.liveOptIn()
    local cs = g_cropStressManager
    if cs and cs.settings and cs.settings.allowsExperimentalSystems then
        return cs.settings:allowsExperimentalSystems()
    end
    return nil
end

--- A system is LIVE right now: released, or the player has opted in.
--- FAIL-OPEN: when the live settings cannot be read (nil manager, nil settings, or
--- a settings object without the predicate - e.g. the offline test bench), the
--- system counts as live. The gate is an explicit opt-out of NEW systems; it must
--- never silently disable a path just because the opt-in flag is not readable at
--- that moment.
---@param systemId string
---@return boolean
function ReleaseGate.isSystemLive(systemId)
    local optIn = ReleaseGate.liveOptIn()
    if optIn == nil then return true end
    return ReleaseGate.isReleased(systemId, optIn)
end

--- Refusal message when a system is locked; nil when released.
---@param systemId string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.lockMessage(systemId, optIn)
    local entry = ReleaseGate.EXPERIMENTAL[systemId]
    if not entry or optIn == true then return nil end
    return string.format(
        "Locked: %s is not released yet. Enable Experimental Systems to use it at your own risk.",
        entry.name)
end

--- Console command gate. Mirrors the SF bypass-lock pattern but on the release axis.
---@param commandName string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.commandLockMessage(commandName, optIn)
    return ReleaseGate.lockMessage(ReleaseGate.COMMAND_TO_SYSTEM[commandName], optIn)
end

--- Player-friendly gate status, for the status/help surfaces and tests.
---@param optIn boolean|nil
---@return string
function ReleaseGate.status(optIn)
    local lines = { "=== Release gate ===" }
    lines[#lines + 1] = string.format("  Experimental systems: %s",
        optIn == true and "ON (at your own risk)" or "OFF (stable only)")
    local on = optIn == true
    if on then
        lines[#lines + 1] = "  All experimental systems: ON"
        for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
            lines[#lines + 1] = string.format("    [ON] %s", entry.name)
        end
    else
        lines[#lines + 1] = "  Not yet released:"
        for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
            lines[#lines + 1] = string.format("    [LOCKED] %s - %s", entry.name, entry.status)
        end
    end
    return table.concat(lines, "\n")
end

csLog("Release gate loaded")
