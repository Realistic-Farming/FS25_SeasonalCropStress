-- =========================================================
-- FS25_SeasonalCropStress - SCS-042 One-Hop Runoff
-- =========================================================
-- Brief: SCS-042-runoff-BUILD-BRIEF.md v1.1 (Iris and Arissani, certified
-- 2026-09-04, owner-ratified field-boundary correction 2026-09-05). When packed
-- ground cannot take all of a controlled-irrigation request, the rejected portion
-- gets ONE immediate chance to land on the lowest neighbouring patch inside the
-- SAME cultivated field. If terrain truth is absent, stale, flat, a sink,
-- off-field, full or unreadable, the water stays at its source. Nothing
-- disappears and nothing travels twice.
--
-- WHAT THIS MODULE OWNS (brief section 2): neighbour selection and the numeric
-- amount accepted downhill. SCS-041 owns source and destination capacity
-- (SoilMoistureSystem:_acceptRunoffDestinationSpan, the only entry this module
-- calls back into); SCS-039 owns moisture and raw acceptance. This module writes
-- no SoilFertilizer state, keeps no persistent table, cursor, client state or
-- retry, adds no event, save payload, settings page, transport channel or
-- player string (sections 6 to 8).
--
-- THE ONLY CALLER is SCS-041's capacity ledger, through the manager handle:
--   CropStressManager.runoffSystem:acceptSurplusSpan(fieldId, sourceWorldX,
--       sourceWorldZ, providerGrainMetres, firstWindowId, windowCount,
--       candidateGainPerWindow) -> acceptedTotalGain
-- (SoilMoistureSystem:_absorptionApplyOne builds that call per compact span.)
--
-- THE TOPOLOGY READ (section 3) is discovery only, on the mission handle:
-- g_currentMission.soilFertilityManager.topography, never the per-mod
-- g_SoilFertilityManager global. SoilFertilizer's TopographyCache answers
-- grid() -> cellSize, axisX, axisZ, terrainSize (TopographyCache.lua:260-262) and
-- getCellInfo(x, z) -> { height, slope, sink, waterDist, stale } (:362-380), with
-- stale = true on its shaped default (:50-56), which this module never routes on.

RunoffSystem = {}
RunoffSystem.__index = RunoffSystem

-- Section 4: exactly four cardinal candidates, read in this order; equal height
-- keeps the order.
RunoffSystem.CARDINALS = {
    { name = "north", dx = 0,  dz = -1 },
    { name = "east",  dx = 1,  dz = 0 },
    { name = "south", dx = 0,  dz = 1 },
    { name = "west",  dx = -1, dz = 0 },
}

local function finiteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function finiteInteger(v)
    return finiteNumber(v) and math.floor(v) == v
end

local function positiveInteger(v)
    return finiteInteger(v) and v > 0
end

--- One local runoff object per manager, after the moisture owner exists; the
--- manager clears it at teardown (section 6).
function RunoffSystem.new(manager)
    local self = setmetatable({}, RunoffSystem)
    self.manager = manager
    -- Diagnostic counters only (csStatus reads nothing from them yet): offers,
    -- what was accepted, and why an offer stayed local. Never saved, never sent.
    self.stats = { offers = 0, routed = 0, accepted = 0, refused = {} }
    return self
end

function RunoffSystem:delete()
    self.manager = nil
end

--- The SF-77 topology, or nil. Guarded at every step: the manager, the object,
--- both methods (section 3).
function RunoffSystem.topology()
    local mission = g_currentMission
    local sfm = (type(mission) == "table") and mission.soilFertilityManager or nil
    local topo = (type(sfm) == "table") and sfm.topography or nil
    if type(topo) ~= "table" or type(topo.grid) ~= "function" or type(topo.getCellInfo) ~= "function" then
        return nil
    end
    return topo
end

--- One deterministic downhill neighbour of a source position (section 4), or
--- nil and the reason. Every provider call is pcall-guarded; a thrown cardinal
--- refuses the whole offer; only explicit-current cells with a finite height
--- strictly below the source's are candidates; the lowest wins, ties by order.
---@return table|nil route  { x, z, height, direction, topologyGrainMetres }
---@return string|nil reason
function RunoffSystem.resolveDownhill(topo, worldX, worldZ)
    if type(topo) ~= "table" or type(topo.grid) ~= "function" or type(topo.getCellInfo) ~= "function" then
        return nil, "NO_TOPOLOGY"
    end
    local gridOk, cellSize, axisX, axisZ, terrainSize = pcall(topo.grid, topo)
    if not gridOk or not finiteNumber(cellSize) or cellSize <= 0
       or not positiveInteger(axisX) or not positiveInteger(axisZ)
       or not finiteNumber(terrainSize) or terrainSize <= 0 then
        return nil, "NO_GRID"
    end
    local sourceOk, source = pcall(topo.getCellInfo, topo, worldX, worldZ)
    if not sourceOk or type(source) ~= "table" then return nil, "NO_SOURCE_CELL" end
    if source.stale ~= false then return nil, "SOURCE_STALE" end
    if not finiteNumber(source.height) then return nil, "SOURCE_HEIGHT" end
    if source.slope == "flat" then return nil, "SOURCE_FLAT" end
    if source.sink == true then return nil, "SOURCE_SINK" end

    local best = nil
    for _, d in ipairs(RunoffSystem.CARDINALS) do
        local x, z = worldX + d.dx * cellSize, worldZ + d.dz * cellSize
        local ok, c = pcall(topo.getCellInfo, topo, x, z)
        if not ok then return nil, "CARDINAL_THREW" end
        if type(c) == "table" and c.stale == false and finiteNumber(c.height)
           and c.height < source.height then
            if best == nil or c.height < best.height then
                best = { x = x, z = z, height = c.height, direction = d.name, topologyGrainMetres = cellSize }
            end
        end
    end
    if best == nil then return nil, "NO_LOWER_NEIGHBOUR" end
    return best
end

function RunoffSystem:_refuse(reason)
    if reason ~= nil then
        self.stats.refused[reason] = (self.stats.refused[reason] or 0) + 1
    end
    return 0
end

--- Section 2: the one entry. Server only. Revalidates every argument, routes
--- once, hands the ONE chosen destination and the retained SOURCE position to
--- SCS-041's private destination helper (section 5; the source position is the
--- field-eligibility anchor of the owner-ratified correction), and validates the
--- answer as finite and inside 0..candidateTotal. Every invalid input, missing
--- truth, refused route, thrown or over-accepting destination returns zero and
--- mutates nothing, so the caller keeps the whole candidate local.
---@return number acceptedTotalGain
function RunoffSystem:acceptSurplusSpan(fieldId, sourceWorldX, sourceWorldZ, providerGrainMetres,
                                        firstWindowId, windowCount, candidateGainPerWindow)
    if g_server == nil then return 0 end
    if not finiteNumber(fieldId) or not finiteNumber(sourceWorldX) or not finiteNumber(sourceWorldZ)
       or not finiteNumber(providerGrainMetres) or providerGrainMetres <= 0
       or not finiteInteger(firstWindowId)
       or not positiveInteger(windowCount)
       or not finiteNumber(candidateGainPerWindow) or candidateGainPerWindow <= 0 then
        return self:_refuse("INVALID_SPAN")
    end
    local candidateTotal = windowCount * candidateGainPerWindow
    if not finiteNumber(candidateTotal) or candidateTotal <= 0 then return self:_refuse("INVALID_SPAN") end

    local soil = (type(self.manager) == "table") and self.manager.soilSystem or nil
    if type(soil) ~= "table" or type(soil._acceptRunoffDestinationSpan) ~= "function" then
        return self:_refuse("NO_DESTINATION_OWNER")
    end

    self.stats.offers = self.stats.offers + 1
    local route, reason = RunoffSystem.resolveDownhill(RunoffSystem.topology(), sourceWorldX, sourceWorldZ)
    if route == nil then return self:_refuse(reason) end
    self.stats.routed = self.stats.routed + 1

    -- One hop, one destination, no runner-up: the helper decides the fence and
    -- the capacity, and never offers runoff again.
    local ok, accepted = pcall(soil._acceptRunoffDestinationSpan, soil, fieldId, route.x, route.z,
        providerGrainMetres, firstWindowId, windowCount, candidateGainPerWindow, sourceWorldX, sourceWorldZ)
    if not ok or not finiteNumber(accepted) or accepted < 0 or accepted > candidateTotal then
        return self:_refuse("DESTINATION_INVALID")
    end
    if accepted <= 0 then return self:_refuse("DESTINATION_REFUSED") end
    self.stats.accepted = self.stats.accepted + accepted
    return accepted
end
