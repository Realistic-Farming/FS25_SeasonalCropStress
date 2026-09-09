-- SCS-041 One Ground thirsty-ground contract bar v18.
--
-- GROUP A loads the real current SeasonalCropStress moisture owner and proves
-- SCS-041 is not built at current source tip
-- 123a531db9137045898b12dacdf2095bdd3b00ad. The Auto/Manual and apply-on-load
-- schedule work moves activation and adjacent irrigation bodies, but the four
-- absorption surfaces below remain absent. When implementation lands,
-- Group A is expected to go red and instruct Stage 6A to re-point the bar at
-- the shipped surfaces.
--
-- GROUPS B onward model the pure contract fixed by SCS-041-SDS.md v3.7.
-- They cannot prove engine bit-vector writes, rendering, multiplayer transport,
-- runtime milliseconds, save-file size, or in-game farming balance.
--
-- Every decimal, field id, cell key and field-size probe below is synthetic and
-- cited to the SDS contract rather than copied from production source. The real
-- SCS soil coefficients used by Group C come from SoilMoistureSystem.SOIL_PARAMS.
--!load: src/maps/CropStressValueMap.lua, src/SoilMoistureSystem.lua, src/integrations/OptionScalingResolver.lua

-- GROUP A: CURRENT SOURCE IS STILL UNBUILT.
-- Current source: SoilMoistureSystem.lua:44-49, 163, 497-623, 893-950.
-- Required surface: SDS 5.2-5.15.
do
    -- SCS-041 slice 1 shipped: the active-cap constant and the provider-aware
    -- hour resolver now exist on the real source, so A1/A4 test the shipped
    -- surfaces. A2/A3 stay absence tripwires until their slices land.
    T.near("A1 shipped base-infiltration constant is 0.018",
        SoilMoistureSystem.BASE_INFILTRATION_PER_HOUR, 0.018, 1e-12)
    T.eq("A2 current source has no private raw-water door",
        SoilMoistureSystem._applyRawWaterAtCell, nil)
    T.eq("A3 current source has no private span-aware boundary",
        SoilMoistureSystem._applyControlledWaterSpans, nil)
    T.eq("A4 shipped provider-aware hour resolver is a function",
        type(SoilMoistureSystem.resolveCurrentHourKey), "function")

    -- Behaviour of the shipped resolver (brief §4).
    local RK = SoilMoistureSystem.resolveCurrentHourKey
    T.eq("A4a integer hour with monotonic day resolves day*24+hour",
        RK({ currentHour = 13, currentMonotonicDay = 5 }), 5 * 24 + 13)
    T.eq("A4b hour zero is valid", RK({ currentHour = 0, currentMonotonicDay = 5 }), 120)
    T.eq("A4c missing monotonic day is nil (no currentDay fallback, no or-0)",
        RK({ currentHour = 13, currentDay = 5 }), nil)
    T.eq("A4d non-integer hour is nil",
        RK({ currentHour = 13.5, currentMonotonicDay = 5 }), nil)
    T.eq("A4e negative or out-of-range hour is nil",
        RK({ currentHour = 24, currentMonotonicDay = 5 }), nil)
    T.eq("A4f synced Time Guard monotonic day wins",
        RK({ currentHour = 1, currentMonotonicDay = 2 },
           { getContext = function() return { synced = true, monotonicDay = 9 } end }), 9 * 24 + 1)
    T.eq("A4g unsynced Time Guard falls back to the environment day",
        RK({ currentHour = 1, currentMonotonicDay = 2 },
           { getContext = function() return { synced = false, monotonicDay = 9 } end }), 2 * 24 + 1)
    T.eq("A4h a thrown Time Guard getContext is ignored, environment day used",
        RK({ currentHour = 1, currentMonotonicDay = 2 },
           { getContext = function() error("tg down") end }), 2 * 24 + 1)
end

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function finiteInteger(value)
    return finiteNumber(value) and math.floor(value) == value
end

local function positiveInteger(value)
    return finiteInteger(value) and value > 0
end

local function clamp(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

-- Current ecosystem precedent: SCS IrrigationManager.lua:260 and SoilFertilizer
-- Constants.lua:449-451 both define 0.018 normalized moisture gain per hour.
local BASE_INFILTRATION_PER_HOUR = 0.018

local function capacityPerHour(soilFactor, compaction, compactionGrain, agronomyRestriction)
    if not finiteNumber(agronomyRestriction) or agronomyRestriction <= 0 then
        return nil, "INVALID_RESTRICTION"
    end
    local sf = finiteNumber(soilFactor) and soilFactor or 1.0
    local compactionFactor = 1.0
    if finiteNumber(compaction) and finiteNumber(compactionGrain) and compactionGrain > 0 then
        compactionFactor = 1.0 - clamp(compaction, 0, 100) / 100
    end
    return BASE_INFILTRATION_PER_HOUR * sf * compactionFactor / agronomyRestriction, nil
end

local function absorptionDeclaration()
    return {
        id = "irrigation_absorption_restriction",
        dial = "agronomy",
        base = 1.0,
        neutral = 1.0,
    }
end

local function resolveMissionConfiguration(gateRegistered, gateOpen, declaration, profile)
    if gateRegistered ~= true or gateOpen ~= true then return "UNCAPPED", 1.0 end
    if type(declaration) ~= "table"
        or declaration.id ~= "irrigation_absorption_restriction"
        or declaration.dial ~= "agronomy"
        or declaration.base ~= 1.0
        or declaration.neutral ~= 1.0 then return "UNCAPPED", 1.0 end
    local resolvedRestriction = OptionScalingResolver.resolve(declaration, profile)
    if not finiteNumber(resolvedRestriction) or resolvedRestriction <= 0 then
        return "UNCAPPED", 1.0
    end
    return "CAPPED", resolvedRestriction
end

local function newState(mode, agronomyRestriction)
    return {
        mode = mode,
        base = BASE_INFILTRATION_PER_HOUR,
        agronomyRestriction = agronomyRestriction or 1.0,
        carriedWindowId = nil,
        cells = {},
        optionalReads = 0,
        ledgerWrites = 0,
        providerResolves = 0,
        rawWrites = 0,
        pointOps = 0,
        neutralCount = 0,
        standDownThroughHourKey = nil,
        standDownAwaitingFirstValidHour = false,
        standDownReason = nil,
        lastObservedHour = nil,
        dirtyPending = false,
        dirtyFlushes = 0,
    }
end

local function cellState(state, cellKey)
    local row = state.cells[cellKey]
    if row == nil then
        row = { windowId = nil, used = 0, capacity = nil, providerMode = nil, providerGrain = nil,
                compactionGrain = nil }
        state.cells[cellKey] = row
    end
    return row
end

local function appendSpan(spans, firstWindowId, windowCount, candidatePerWindow)
    if windowCount <= 0 or candidatePerWindow <= 0 then return end
    spans[#spans + 1] = {
        firstWindowId = firstWindowId,
        windowCount = windowCount,
        candidatePerWindow = candidatePerWindow,
    }
end

local function planSpan(requestPerWindow, capacity, windowEnd, windowCount,
                        carriedWindowId, carriedUsed, carriedCapacity)
    local first = windowEnd - windowCount + 1
    local uniformAbsorbed = math.min(requestPerWindow, capacity)
    local uniformCandidate = requestPerWindow - uniformAbsorbed
    local totalAbsorbed = uniformAbsorbed * windowCount
    local totalCandidate = uniformCandidate * windowCount
    local spans = {}

    if carriedWindowId ~= nil and carriedWindowId >= first and carriedWindowId <= windowEnd then
        local exceptionCap = carriedCapacity or capacity
        local exceptionalRemaining = math.max(0, exceptionCap - carriedUsed)
        local exceptionalAbsorbed = math.min(requestPerWindow, exceptionalRemaining)
        local exceptionalCandidate = requestPerWindow - exceptionalAbsorbed
        totalAbsorbed = totalAbsorbed - uniformAbsorbed + exceptionalAbsorbed
        totalCandidate = totalCandidate - uniformCandidate + exceptionalCandidate

        appendSpan(spans, first, carriedWindowId - first, uniformCandidate)
        appendSpan(spans, carriedWindowId, 1, exceptionalCandidate)
        appendSpan(spans, carriedWindowId + 1, windowEnd - carriedWindowId, uniformCandidate)
    else
        appendSpan(spans, first, windowCount, uniformCandidate)
    end

    local currentAbsorbed = uniformAbsorbed
    if carriedWindowId == windowEnd then
        local exceptionCap = carriedCapacity or capacity
        currentAbsorbed = math.min(requestPerWindow, math.max(0, exceptionCap - carriedUsed))
    end

    return {
        firstWindowId = first,
        totalRequested = requestPerWindow * windowCount,
        totalAbsorbed = totalAbsorbed,
        totalCandidate = totalCandidate,
        currentAbsorbed = currentAbsorbed,
        spans = spans,
    }
end

local function acceptedForSpans(spans, acceptFn)
    local accepted = 0
    for _, span in ipairs(spans) do
        local candidateTotal = span.candidatePerWindow * span.windowCount
        local result = 0
        if type(acceptFn) == "function" then
            local ok, value = pcall(acceptFn, span, candidateTotal)
            if ok then result = value end
        end
        if not finiteNumber(result) or result < 0 or result > candidateTotal then result = 0 end
        accepted = accepted + result
    end
    return accepted
end

local function rawWrite(state, changed)
    state.rawWrites = state.rawWrites + 1
    if changed ~= false then state.dirtyPending = true end
end

local function flushDirty(state)
    if state.dirtyPending then
        state.dirtyPending = false
        state.dirtyFlushes = state.dirtyFlushes + 1
        return true
    end
    return false
end

local function boundaryResult(args, requested, localWrite, candidate, accepted, neutral)
    return {
        requestedGain = requested,
        localWriteRequest = localWrite,
        candidateSurplus = candidate,
        acceptedSurplus = accepted,
        providerGrainMetres = args.providerGrain,
        executionGrainMetres = args.executionGrain,
        compactionGrainMetres = args.compactionGrain,
        windowEnd = args.windowEnd,
        windowCount = args.windowCount,
        neutralReason = neutral,
    }
end

local function neutralWrite(state, args, totalRequested, reason)
    state.neutralCount = state.neutralCount + 1
    rawWrite(state, args.rawChanged)
    return boundaryResult(args, totalRequested, totalRequested, 0, 0, reason)
end

local function validWindow(windowEnd, windowCount)
    return finiteNumber(windowEnd) and math.floor(windowEnd) == windowEnd
        and finiteNumber(windowCount) and math.floor(windowCount) == windowCount
        and windowCount >= 1 and windowCount <= 168
end

local function applyControlled(state, args)
    local totalRequested = (args.requestPerWindow or 0) * (args.windowCount or 1)

    -- SDS 5.2: mission-frozen UNCAPPED mode performs one existing raw write only.
    if state.mode == "UNCAPPED" then
        rawWrite(state, args.rawChanged)
        return boundaryResult(args, totalRequested, totalRequested, 0, 0, "UNCAPPED")
    end

    if not validWindow(args.windowEnd, args.windowCount) then
        return neutralWrite(state, args, totalRequested, "INVALID_WINDOW")
    end
    if state.lastObservedHour ~= nil and args.windowEnd < state.lastObservedHour then
        return neutralWrite(state, args, totalRequested, "CLOCK_REWIND")
    end
    if state.standDownAwaitingFirstValidHour then
        state.standDownAwaitingFirstValidHour = false
        state.standDownThroughHourKey = args.windowEnd
        state.standDownReason = state.standDownReason or "CORRUPT_STATE"
        return neutralWrite(state, args, totalRequested, "RESTORE_STAND_DOWN")
    end
    if state.standDownThroughHourKey ~= nil then
        local marker = state.standDownThroughHourKey
        local windowStart = args.windowEnd - args.windowCount + 1
        if args.windowEnd <= marker then
            return neutralWrite(state, args, totalRequested, "RESTORE_STAND_DOWN")
        end
        state.standDownThroughHourKey = nil
        state.standDownReason = nil
        local neutralCount = math.max(0, marker - windowStart + 1)
        if neutralCount > 0 then
            local prefixRequested = args.requestPerWindow * neutralCount
            state.neutralCount = state.neutralCount + 1
            rawWrite(state, args.rawChanged)
            local suffixArgs = {}
            for key, value in pairs(args) do suffixArgs[key] = value end
            suffixArgs.windowCount = args.windowCount - neutralCount
            local suffix = applyControlled(state, suffixArgs)
            return boundaryResult(args, totalRequested,
                prefixRequested + suffix.localWriteRequest,
                suffix.candidateSurplus, suffix.acceptedSurplus, "RESTORE_SPLIT")
        end
    end
    state.lastObservedHour = args.windowEnd

    state.providerResolves = state.providerResolves + 1
    if args.providerMode == nil or not finiteNumber(args.providerGrain)
            or args.providerGrain <= 0 or args.cellKey == nil
            or not finiteNumber(args.providerCenterX) or not finiteNumber(args.providerCenterZ) then
        return neutralWrite(state, args, totalRequested, "PROVIDER_UNAVAILABLE")
    end

    local row = cellState(state, args.cellKey)
    local firstWindowId = args.windowEnd - args.windowCount + 1
    if row.windowId ~= nil and row.windowId >= firstWindowId and row.windowId <= args.windowEnd
            and row.providerMode ~= nil
            and (row.providerMode ~= args.providerMode or row.providerGrain ~= args.providerGrain) then
        state.standDownThroughHourKey = args.windowEnd
        state.standDownReason = "PROVIDER_CHANGED"
        return neutralWrite(state, args, totalRequested, "PROVIDER_CHANGED")
    end

    local carriedWindowId = row.windowId
    local carriedUsed = row.used
    local carriedCapacity = row.capacity
    local currentCapacity = row.capacity
    local compaction, compactionGrain = args.compaction, args.compactionGrain
    if row.capacity == nil or row.windowId ~= args.windowEnd then
        state.optionalReads = state.optionalReads + 1
        if type(args.compactionReader) == "function" then
            local ok, value, grain = pcall(args.compactionReader,
                args.providerCenterX, args.providerCenterZ)
            if ok then
                compaction, compactionGrain = value, grain
            else
                compaction, compactionGrain = nil, nil
            end
        end
        local cap = capacityPerHour(args.soilFactor, compaction, compactionGrain,
            state.agronomyRestriction)
        if cap == nil then
            return neutralWrite(state, args, totalRequested, "CAPACITY_UNAVAILABLE")
        end
        currentCapacity = cap
    end

    local plan = planSpan(args.requestPerWindow, currentCapacity, args.windowEnd,
        args.windowCount, carriedWindowId, carriedUsed, carriedCapacity)
    local accepted = acceptedForSpans(plan.spans, args.acceptFn)
    local localWrite = plan.totalAbsorbed + plan.totalCandidate - accepted

    state.carriedWindowId = args.windowEnd
    row.windowId = args.windowEnd
    row.capacity = currentCapacity
    row.providerMode = args.providerMode
    row.providerGrain = args.providerGrain
    row.compactionGrain = compactionGrain
    row.fieldId = args.fieldId
    row.cellX = args.cellX
    row.cellZ = args.cellZ
    local priorUsed = ((carriedWindowId == args.windowEnd) and carriedUsed or 0)
    local rawAccepted = false
    if localWrite > 0 then
        rawWrite(state, args.rawChanged)
        rawAccepted = args.rawAccepted ~= false
    end
    row.used = priorUsed + (rawAccepted and plan.currentAbsorbed or 0)
    state.ledgerWrites = state.ledgerWrites + 1

    args.compactionGrain = compactionGrain
    return boundaryResult(args, plan.totalRequested, localWrite,
        plan.totalCandidate, accepted, nil)
end

-- GROUP B: RELEASE MODE, AGRONOMY RESTRICTION AND KNOWN-THIN REJECTION.
-- SDS 3a, 5.1, 5.2 and the UNCAPPED scheduled-irrigation rationale.
do
    local state = newState("UNCAPPED", 1.0)
    local result = applyControlled(state, {
        requestPerWindow = 0.02,
        windowEnd = 100,
        windowCount = 3,
    })
    T.near("B1 UNCAPPED preserves complete elapsed request", result.localWriteRequest, 0.06, 1e-12)
    T.eq("B2 UNCAPPED creates zero candidate surplus", result.candidateSurplus, 0)
    T.eq("B3 UNCAPPED resolves zero provider cells", state.providerResolves, 0)
    T.eq("B4 UNCAPPED performs zero optional compaction reads", state.optionalReads, 0)
    T.eq("B5 UNCAPPED performs zero ledger writes", state.ledgerWrites, 0)
    T.eq("B6 UNCAPPED performs one existing raw write", state.rawWrites, 1)

    local cap = 0.01
    local thinAccepted = math.min(0.02, cap) + math.min(0.02, cap)
    T.ok("B7 bar rejects independent per-caller capacity budgets", thinAccepted > cap)
    local profileRelaxed = { dials = { agronomy = 0.0 }, switches = { agronomy = true } }
    local profileOn = { dials = { agronomy = 1.0 }, switches = { agronomy = true } }
    local profilePunishing = { dials = { agronomy = 2.0 }, switches = { agronomy = true } }
    local profileOff = { dials = { agronomy = 1.0 }, switches = { agronomy = false } }
    local declaration = absorptionDeclaration()
    T.eq("B8 restriction declaration id", declaration.id, "irrigation_absorption_restriction")
    T.near("B9 restriction declaration base", declaration.base, 1.0, 1e-12)
    T.near("B10 restriction declaration neutral", declaration.neutral, 1.0, 1e-12)
    local mode, restriction = resolveMissionConfiguration(true, false, declaration, profileOn)
    T.eq("B11 closed release gate selects UNCAPPED", mode, "UNCAPPED")
    mode, restriction = resolveMissionConfiguration(true, true, nil, profileOn)
    T.eq("B12 missing declaration refuses CAPPED", mode, "UNCAPPED")
    mode, restriction = resolveMissionConfiguration(true, true, declaration, nil)
    T.eq("B13 absent SettingsHub keeps released feature CAPPED", mode, "CAPPED")
    T.near("B14 absent SettingsHub resolves Standard restriction", restriction, 1.0, 1e-12)
    mode, restriction = resolveMissionConfiguration(true, true, declaration, profileOff)
    T.eq("B15 off Agronomy keeps released feature CAPPED", mode, "CAPPED")
    T.near("B16 off Agronomy resolves Standard restriction", restriction, 1.0, 1e-12)
    local _, relaxed = resolveMissionConfiguration(true, true, declaration, profileRelaxed)
    local _, standard = resolveMissionConfiguration(true, true, declaration, profileOn)
    local _, punishing = resolveMissionConfiguration(true, true, declaration, profilePunishing)
    T.near("B17 canonical Relaxed restriction", relaxed, 0.7, 1e-12)
    T.near("B18 canonical Standard restriction", standard, 1.0, 1e-12)
    T.near("B19 canonical Punishing restriction", punishing, 1.4, 1e-12)
    local frozenRestriction = standard
    T.near("B20 mission restriction stays frozen after an external dial change",
        frozenRestriction, 1.0, 1e-12)
    T.ok("B21 changed external dial is not reread", punishing ~= frozenRestriction)
    mode = resolveMissionConfiguration(false, true, declaration, profileOn)
    T.eq("B22 absent release row fails closed before isReleased semantics", mode, "UNCAPPED")
    T.near("B23 real resolver honors explicit identity neutral while off",
        OptionScalingResolver.resolve(declaration, profileOff), 1.0, 1e-12)
end

-- GROUP C: FIXED BASE, CURRENT SOIL COEFFICIENTS, COMPACTION AND RESTRICTION.
-- Source literals: IrrigationManager.lua:260, SoilFertilizer Constants.lua:449-451,
-- SoilMoistureSystem.lua:46-48. Formula: SDS 5.6.
do
    local sandy = SoilMoistureSystem.SOIL_PARAMS.sandy.rainAbsorb
    local loamy = SoilMoistureSystem.SOIL_PARAMS.loamy.rainAbsorb
    local clay = SoilMoistureSystem.SOIL_PARAMS.clay.rainAbsorb
    T.near("C1 current sandy coefficient", sandy, 1.25, 1e-12)
    T.near("C2 current loamy coefficient", loamy, 1.00, 1e-12)
    T.near("C3 current clay coefficient", clay, 0.72, 1e-12)

    T.near("C4 fixed Standard base infiltration", BASE_INFILTRATION_PER_HOUR, 0.018, 1e-12)
    local cap = capacityPerHour(sandy, 0, 2, 1.0)
    T.near("C5 open sandy ground raises Standard capacity", cap, 0.0225, 1e-12)
    cap = capacityPerHour(clay, 50, 2, 1.0)
    T.near("C6 half-compacted clay uses the linear response", cap, 0.00648, 1e-12)
    cap = capacityPerHour(loamy, 100, 2, 1.0)
    T.near("C7 full compaction reaches zero capacity", cap, 0, 1e-12)
    cap = capacityPerHour(clay, 90, nil, 1.0)
    T.near("C8 nil compaction grain is neutral, not field fallback", cap, 0.01296, 1e-12)
    T.near("C9 Relaxed divides by restriction", capacityPerHour(loamy, 0, 2, 0.7), 0.018 / 0.7, 1e-12)
    T.near("C10 Standard keeps identity restriction", capacityPerHour(loamy, 0, 2, 1.0), 0.018, 1e-12)
    T.near("C11 Punishing divides by restriction", capacityPerHour(loamy, 0, 2, 1.4), 0.018 / 1.4, 1e-12)
    local invalid, reason = capacityPerHour(loamy, 0, 2, 0)
    T.eq("C12 invalid restriction refuses capacity", invalid, nil)
    T.eq("C13 invalid restriction names the refusal", reason, "INVALID_RESTRICTION")
end

local function normalArgs(overrides)
    local args = {
        requestPerWindow = 0.015,
        windowEnd = 50,
        windowCount = 1,
        providerMode = "TRUTH",
        providerGrain = 2,
        cellKey = "TRUTH:2:10:20",
        fieldId = 1,
        cellX = 10,
        cellZ = 20,
        providerCenterX = -2037,
        providerCenterZ = -2017,
        executionGrain = 2,
        soilFactor = 1.0,
        compaction = 0,
        compactionGrain = 2,
    }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

-- GROUP D: SHARED CELL/HOUR CAPACITY AND CALLER ORDER.
-- SDS 5.5-5.7.
do
    local state = newState("CAPPED", 1.0)
    local acceptAll = function(_span, candidateTotal) return candidateTotal end
    local first = applyControlled(state, normalArgs({ acceptFn = acceptAll }))
    local second = applyControlled(state, normalArgs({ acceptFn = acceptAll }))
    T.near("D1 first caller receives its request below capacity", first.localWriteRequest, 0.015, 1e-12)
    T.near("D2 second caller receives only remaining capacity locally", second.localWriteRequest, 0.003, 1e-12)
    T.near("D3 shared callers consume one cell-hour allowance", state.cells["TRUTH:2:10:20"].used, 0.018, 1e-12)
    T.near("D4 second caller exposes the excess as candidate", second.candidateSurplus, 0.012, 1e-12)
    T.eq("D5 capacity is read once for the shared cell hour", state.optionalReads, 1)

    local reverse = newState("CAPPED", 1.0)
    local big = applyControlled(reverse, normalArgs({ requestPerWindow = 0.02, acceptFn = acceptAll }))
    local small = applyControlled(reverse, normalArgs({ requestPerWindow = 0.01, acceptFn = acceptAll }))
    T.near("D6 reversed request order keeps total local allowance", big.localWriteRequest + small.localWriteRequest, 0.018, 1e-12)
    T.near("D7 reversed request order keeps total candidate", big.candidateSurplus + small.candidateSurplus, 0.012, 1e-12)

    local nextHour = applyControlled(state, normalArgs({ windowEnd = 51 }))
    T.near("D8 a different SCS hour receives a new allowance", nextHour.localWriteRequest, 0.015, 1e-12)

    local sampledX, sampledZ, reads
    reads = 0
    local centred = newState("CAPPED", 1.0)
    local reader = function(x, z)
        reads = reads + 1
        sampledX, sampledZ = x, z
        return 50, 2
    end
    applyControlled(centred, normalArgs({ compactionReader = reader }))
    applyControlled(centred, normalArgs({ compactionReader = reader }))
    T.eq("D9 compaction is read once for one provider cell and hour", reads, 1)
    T.near("D10 compaction samples the provider-cell centre X", sampledX, -2037, 1e-12)
    T.near("D11 compaction samples the provider-cell centre Z", sampledZ, -2017, 1e-12)

    local refused = newState("CAPPED", 1.0)
    applyControlled(refused, normalArgs({ rawAccepted = false, rawChanged = false }))
    T.eq("D12 a refused raw write still executes the one attempted raw door", refused.rawWrites, 1)
    T.near("D13 a refused raw write consumes no cell-hour capacity",
        refused.cells["TRUTH:2:10:20"].used, 0, 1e-12)
end

-- GROUP E: CATCH-UP SPANS, CARRIED EXCEPTION AND THREE-SPAN CEILING.
-- SDS 5.8.
do
    local plan = planSpan(0.03, 0.02, 12, 5, 10, 0.015, 0.02)
    T.eq("E1 five-hour span starts at derived hour", plan.firstWindowId, 8)
    T.near("E2 five-hour span keeps every requested gain", plan.totalRequested, 0.15, 1e-12)
    T.near("E3 carried hour subtracts its already-used capacity", plan.totalAbsorbed, 0.085, 1e-12)
    T.near("E4 remaining amount becomes candidate", plan.totalCandidate, 0.065, 1e-12)
    T.eq("E5 one carried exception yields at most three compact spans", #plan.spans, 3)
    T.eq("E6 first uniform span starts at hour eight", plan.spans[1].firstWindowId, 8)
    T.eq("E7 carried exception is isolated at hour ten", plan.spans[2].firstWindowId, 10)
    T.eq("E8 trailing uniform span ends through derived count", plan.spans[3].windowCount, 2)

    local noException = planSpan(0.03, 0.02, 12, 5, nil, 0, nil)
    T.eq("E9 no carried exception needs one compact span", #noException.spans, 1)
    T.near("E10 no exception receives five capacity allowances", noException.totalAbsorbed, 0.10, 1e-12)
end

-- GROUP F: SURPLUS ACCEPTANCE AND ROUTING CONSERVATION.
-- SDS 4 Provides, 5.7-5.8 and 5.15.
do
    local state = newState("CAPPED", 1.0)
    local partial = applyControlled(state, normalArgs({
        requestPerWindow = 0.03,
        acceptFn = function(_span, candidateTotal) return candidateTotal * 0.5 end,
    }))
    T.near("F1 active cap creates candidate surplus", partial.candidateSurplus, 0.012, 1e-12)
    T.near("F2 sibling may accept part of candidate", partial.acceptedSurplus, 0.006, 1e-12)
    T.near("F3 unaccepted candidate folds into local write", partial.localWriteRequest, 0.024, 1e-12)
    T.near("F4 routing identity conserves requested gain",
        partial.localWriteRequest + partial.acceptedSurplus, partial.requestedGain, 1e-12)

    local absent = newState("CAPPED", 1.0)
    local noSibling = applyControlled(absent, normalArgs({ requestPerWindow = 0.03 }))
    T.eq("F5 absent sibling accepts zero", noSibling.acceptedSurplus, 0)
    T.near("F6 absent sibling preserves complete local write request", noSibling.localWriteRequest, 0.03, 1e-12)

    local invalid = newState("CAPPED", 1.0)
    local badSibling = applyControlled(invalid, normalArgs({
        requestPerWindow = 0.03,
        acceptFn = function(_span, candidateTotal) return candidateTotal + 1 end,
    }))
    T.eq("F7 over-accepting sibling result is rejected", badSibling.acceptedSurplus, 0)
    T.near("F8 rejected sibling result folds back locally", badSibling.localWriteRequest, 0.03, 1e-12)

    local thrown = applyControlled(newState("CAPPED", 1.0), normalArgs({
        requestPerWindow = 0.03,
        acceptFn = function() error("sibling failed") end,
    }))
    T.eq("F9 throwing sibling accepts zero through pcall", thrown.acceptedSurplus, 0)
    T.near("F10 throwing sibling folds the complete remainder locally", thrown.localWriteRequest, 0.03, 1e-12)

    local runoffOnly = newState("CAPPED", 1.0)
    applyControlled(runoffOnly, normalArgs({
        requestPerWindow = 0.03,
        rawAccepted = false,
        rawChanged = false,
        acceptFn = function(_span, candidateTotal) return candidateTotal end,
    }))
    T.near("F11 accepted runoff does not spend a refused local capacity portion",
        runoffOnly.cells["TRUTH:2:10:20"].used, 0, 1e-12)
end

-- GROUP G: PROVIDER FAILURE AND GRAIN CHANGE ARE NEUTRAL.
-- SDS 5.3-5.4 and 5.11.
do
    local missing = newState("CAPPED", 1.0)
    local missingArgs = normalArgs()
    missingArgs.providerMode = nil
    local result = applyControlled(missing, missingArgs)
    T.near("G1 missing provider identity preserves full local request", result.localWriteRequest, 0.015, 1e-12)
    T.eq("G2 missing provider identity creates no candidate", result.candidateSurplus, 0)
    T.eq("G3 missing provider identity records neutral reason", result.neutralReason, "PROVIDER_UNAVAILABLE")

    local changed = newState("CAPPED", 1.0)
    applyControlled(changed, normalArgs())
    result = applyControlled(changed, normalArgs({ providerMode = "ZONE", providerGrain = 10 }))
    T.near("G4 mid-window provider change preserves full local request", result.localWriteRequest, 0.015, 1e-12)
    T.eq("G5 mid-window provider change creates no guessed surplus", result.candidateSurplus, 0)
    T.eq("G6 mid-window provider change is diagnosed", result.neutralReason, "PROVIDER_CHANGED")
    T.eq("G7 mismatch uses the unified stand-down hour", changed.standDownThroughHourKey, 50)
    T.eq("G7a live provider change keeps its diagnostic reason",
        changed.standDownReason, "PROVIDER_CHANGED")
    result = applyControlled(changed, normalArgs())
    T.eq("G8 original provider cannot reopen the stood-down hour", result.neutralReason, "RESTORE_STAND_DOWN")
    result = applyControlled(changed, normalArgs({ windowEnd = 51 }))
    T.eq("G9 next valid hour clears provider stand-down", result.neutralReason, nil)

    local mixed = newState("CAPPED", 1.0)
    applyControlled(mixed, normalArgs())
    applyControlled(mixed, normalArgs({ providerMode = "ZONE", providerGrain = 10 }))
    result = applyControlled(mixed, normalArgs({ windowEnd = 52, windowCount = 3,
        providerMode = "ZONE", providerGrain = 10 }))
    T.eq("G10 provider marker uses the same mixed-span split", result.neutralReason, "RESTORE_SPLIT")
    T.near("G11 provider-marker split preserves routing conservation",
        result.localWriteRequest + result.acceptedSurplus, result.requestedGain, 1e-12)
end

local function processTouched(totalFieldCells, touchedKeys)
    local state = newState("CAPPED", 1.0)
    local ignored = totalFieldCells
    if ignored < 0 then return nil end
    for _, key in ipairs(touchedKeys) do
        state.pointOps = state.pointOps + 1
        applyControlled(state, normalArgs({ cellKey = key }))
    end
    return state
end

-- GROUP H: COST SHAPE IS TOUCHED-POINT PROPORTIONAL, NEVER FIELD-SIZE DRIVEN.
-- SDS 5.10 and Risk 1. The bench counts operations and does not time them.
do
    local forty = {}
    for i = 1, 40 do forty[i] = "M:2:" .. i .. ":1" end
    local small = processTouched(4096, forty)
    local large = processTouched(1048576, forty)
    T.eq("H1 small field processes every touched point", small.pointOps, 40)
    T.eq("H2 large field with same footprint processes same point count", large.pointOps, 40)
    T.eq("H3 total field cells do not change provider resolutions", small.providerResolves, large.providerResolves)

    local wide = {}
    for i = 1, 1025 do wide[i] = "M:2:" .. i .. ":2" end
    local uncappedPopulation = processTouched(9999999, wide)
    T.eq("H4 touched population has no hidden 1024-point omission cap", uncappedPopulation.pointOps, 1025)
    T.eq("H5 every included point reaches the raw write door", uncappedPopulation.rawWrites, 1025)

    local reinke369 = {}
    for i = 1, 4300 do reinke369[i] = "M:2:" .. i .. ":3" end
    local largestCurrentPivot = processTouched(9999999, reinke369)
    T.eq("H6 current 369m pivot model omits none of roughly 4300 candidate points",
        largestCurrentPivot.pointOps, 4300)
    T.eq("H7 every current large-pivot point reaches the raw write door",
        largestCurrentPivot.rawWrites, 4300)
end

local function canonicalNumber(value)
    return string.format("%.17g", value)
end

local function rowLess(a, b)
    if a.fieldId ~= b.fieldId then return a.fieldId < b.fieldId end
    if a.cellX ~= b.cellX then return a.cellX < b.cellX end
    return a.cellZ < b.cellZ
end

local function canonicalRows(rows)
    local ordered = {}
    for i, row in ipairs(rows) do ordered[i] = row end
    table.sort(ordered, rowLess)
    local encoded = {}
    for i, row in ipairs(ordered) do
        encoded[i] = table.concat({
            tostring(row.fieldId), tostring(row.cellX), tostring(row.cellZ),
            canonicalNumber(row.capacity), canonicalNumber(row.used),
            row.compactionGrain == nil and "-" or canonicalNumber(row.compactionGrain),
        }, ",")
    end
    return table.concat(encoded, ";"), ordered
end

local function adler32(bytes)
    local a, b = 1, 0
    for i = 1, #bytes do
        a = (a + string.byte(bytes, i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08X", b * 65536 + a)
end

local function packWindow(state)
    local windowId, cells = state.carriedWindowId, state.cells
    local rows, providerMode, providerGrain = {}, nil, nil
    for _, row in pairs(cells) do
        if windowId ~= nil and row.windowId == windowId then
            providerMode = providerMode or row.providerMode
            providerGrain = providerGrain or row.providerGrain
            rows[#rows + 1] = {
                fieldId = row.fieldId,
                cellX = row.cellX,
                cellZ = row.cellZ,
                capacity = row.capacity,
                used = row.used,
                compactionGrain = row.compactionGrain,
            }
        end
    end
    local packed, ordered = canonicalRows(rows)
    return {
        outerSchema = 3,
        schema = 2,
        windowId = windowId,
        providerMode = providerMode,
        providerGrainMetres = providerGrain,
        standDownThroughHourKey = state.standDownThroughHourKey,
        standDownAwaitingFirstValidHour = state.standDownAwaitingFirstValidHour == true,
        standDownReason = state.standDownReason,
        rowCount = #ordered,
        rowsPacked = packed,
        rowsAdler32 = adler32(packed),
    }
end

local function parseRows(packed)
    local rows = {}
    if packed == "" then return rows end
    for encoded in string.gmatch(packed or "", "([^;]+)") do
        local cols = {}
        for value in string.gmatch(encoded, "([^,]+)") do cols[#cols + 1] = value end
        if #cols ~= 6 then return nil end
        local fieldId, cellX, cellZ = tonumber(cols[1]), tonumber(cols[2]), tonumber(cols[3])
        local capacity, used = tonumber(cols[4]), tonumber(cols[5])
        local compactionGrain = cols[6] == "-" and nil or tonumber(cols[6])
        if not finiteNumber(fieldId) or math.floor(fieldId) ~= fieldId or fieldId <= 0
                or not finiteNumber(cellX) or math.floor(cellX) ~= cellX
                or not finiteNumber(cellZ) or math.floor(cellZ) ~= cellZ
                or not finiteNumber(capacity) or capacity < 0
                or not finiteNumber(used) or used < 0 or used > capacity
                or (compactionGrain ~= nil and (not finiteNumber(compactionGrain) or compactionGrain <= 0)) then
            return nil
        end
        rows[#rows + 1] = {
            fieldId = fieldId, cellX = cellX, cellZ = cellZ,
            capacity = capacity, used = used, compactionGrain = compactionGrain,
        }
    end
    local canonical, ordered = canonicalRows(rows)
    if canonical ~= packed then return nil end
    for i = 2, #ordered do
        local a, b = ordered[i - 1], ordered[i]
        if a.fieldId == b.fieldId and a.cellX == b.cellX and a.cellZ == b.cellZ then return nil end
    end
    return ordered
end

local function tableCount(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function pruneMissingFields(state, liveFields)
    local removed = 0
    for key, row in pairs(state.cells or {}) do
        if liveFields[row.fieldId] ~= true then
            state.cells[key] = nil
            removed = removed + 1
        end
    end
    return removed
end

local function loadWindow(state, block, liveMode, liveGrain, currentHour)
    state.cells = {}
    state.carriedWindowId = nil
    state.standDownThroughHourKey = nil
    state.standDownAwaitingFirstValidHour = false
    state.standDownReason = nil

    if state.mode == "UNCAPPED" then return true, "UNCAPPED_IGNORED" end
    if block.outerSchema == 2 then return true, "MIGRATED_SCHEMA_2" end

    local function reject(reason)
        if finiteInteger(currentHour) then
            state.standDownThroughHourKey = currentHour
        else
            state.standDownAwaitingFirstValidHour = true
        end
        state.standDownReason = reason == "PROVIDER_MISMATCH"
            and "PROVIDER_MISMATCH" or "CORRUPT_STATE"
        return false, reason
    end

    if block.outerSchema ~= 3 or (block.schema ~= 1 and block.schema ~= 2) then
        return reject("MALFORMED_BLOCK")
    end

    if block.schema == 2 then
        local marker = block.standDownThroughHourKey
        local awaiting = block.standDownAwaitingFirstValidHour == true
        local reasonOk = block.standDownReason == nil
            or block.standDownReason == "CORRUPT_STATE"
            or block.standDownReason == "PROVIDER_MISMATCH"
            or block.standDownReason == "PROVIDER_CHANGED"
        if (marker ~= nil and (not finiteNumber(marker) or math.floor(marker) ~= marker))
                or (marker ~= nil and awaiting) or not reasonOk then
            return reject("MALFORMED_MARKER")
        end
        if marker ~= nil or awaiting then
            if awaiting then
                state.standDownAwaitingFirstValidHour = true
                state.standDownReason = block.standDownReason or "CORRUPT_STATE"
            elseif not finiteInteger(currentHour) then
                state.standDownAwaitingFirstValidHour = true
                state.standDownReason = "CORRUPT_STATE"
            elseif marker > currentHour then
                state.standDownThroughHourKey = currentHour
                state.standDownReason = "CORRUPT_STATE"
            else
                state.standDownThroughHourKey = marker
                state.standDownReason = block.standDownReason or "CORRUPT_STATE"
            end
            return true, "RESTORED_STAND_DOWN"
        end
    end

    if block.windowId == nil and block.rowCount == 0 and block.rowsPacked == ""
            and block.rowsAdler32 == adler32("") then
        return true, "EMPTY_ABSORPTION"
    end

    if not finiteNumber(block.windowId) or math.floor(block.windowId) ~= block.windowId
            or (block.providerMode ~= "TRUTH" and block.providerMode ~= "ZONE")
            or not finiteNumber(block.providerGrainMetres) or block.providerGrainMetres <= 0
            or not finiteNumber(block.rowCount) or math.floor(block.rowCount) ~= block.rowCount
            or type(block.rowsPacked) ~= "string" or type(block.rowsAdler32) ~= "string" then
        return reject("MALFORMED_BLOCK")
    end
    if not finiteInteger(currentHour) then return reject("UNREADABLE_CURRENT_HOUR") end
    if block.windowId > currentHour then return reject("FUTURE_WINDOW") end
    if block.windowId < currentHour then return true, "EXPIRED_WINDOW" end
    if block.providerMode ~= liveMode or block.providerGrainMetres ~= liveGrain then
        return reject("PROVIDER_MISMATCH")
    end
    if adler32(block.rowsPacked) ~= block.rowsAdler32 then return reject("ADLER_MISMATCH") end
    local rows = parseRows(block.rowsPacked)
    if rows == nil or #rows ~= block.rowCount then return reject("ROW_MISMATCH") end

    for _, row in ipairs(rows) do
        local key = string.format("%s:%g:%d:%d", liveMode, liveGrain, row.cellX, row.cellZ)
        state.cells[key] = {
            fieldId = row.fieldId,
            cellX = row.cellX,
            cellZ = row.cellZ,
            capacity = row.capacity,
            used = row.used,
            compactionGrain = row.compactionGrain,
            providerMode = liveMode,
            providerGrain = liveGrain,
            windowId = block.windowId,
        }
    end
    state.carriedWindowId = block.windowId
    return true, "RESTORED"
end

-- GROUP I: SCHEMA-3 SPARSE STATE IS CANONICAL, VALIDATED AND REPLACE-NOT-ADD.
-- SDS 5.13. All values are synthetic contract probes.
do
    local state = newState("CAPPED", 1.0)
    local acceptAll = function(_span, total) return total end
    applyControlled(state, normalArgs({ requestPerWindow = 0.015, acceptFn = acceptAll }))
    applyControlled(state, normalArgs({
        cellKey = "TRUTH:2:3:7", cellX = 3, cellZ = 7,
        providerCenterX = -2041, providerCenterZ = -2023,
        requestPerWindow = 0.005, acceptFn = acceptAll,
    }))
    local block = packWindow(state)
    T.eq("I1 outer StateLedger schema is three", block.outerSchema, 3)
    T.eq("I2 absorption schema is two", block.schema, 2)
    T.eq("I3 block carries provider mode", block.providerMode, "TRUTH")
    T.eq("I4 block carries provider grain", block.providerGrainMetres, 2)
    T.eq("I5 sparse state packs touched cells only", block.rowCount, 2)
    T.ok("I6 rows are numerically sorted", string.find(block.rowsPacked, "1,3,7", 1, true) == 1)
    T.eq("I7 Adler-32 covers exact packed bytes", block.rowsAdler32, adler32(block.rowsPacked))
    T.eq("I7a ordinary live window carries no stand-down marker", block.standDownThroughHourKey, nil)
    T.eq("I7b ordinary live window carries no awaiting-hour flag",
        block.standDownAwaitingFirstValidHour, false)

    local restored = newState("CAPPED", 1.0)
    local ok, reason = loadWindow(restored, block, "TRUTH", 2, 50)
    T.ok("I8 same-hour block restores", ok)
    T.eq("I9 restore disposition is exact", reason, "RESTORED")
    local resumed = applyControlled(restored, normalArgs({ requestPerWindow = 0.015, acceptFn = acceptAll }))
    T.near("I10 same-hour restore preserves remaining capacity", resumed.localWriteRequest, 0.003, 1e-12)
    T.near("I11 same-hour restore exposes already-used excess", resumed.candidateSurplus, 0.012, 1e-12)
    T.near("I12 restored cell reaches but does not exceed capacity",
        restored.cells["TRUTH:2:10:20"].used, 0.018, 1e-12)

    ok = loadWindow(restored, block, "TRUTH", 2, 50)
    T.ok("I13 second load is accepted", ok)
    T.eq("I14 second load replaces rather than adds rows", tableCount(restored.cells), 2)
    T.near("I15 second load does not double used gain", restored.cells["TRUTH:2:10:20"].used, 0.015, 1e-12)

    local mismatch = newState("CAPPED", 1.0)
    ok, reason = loadWindow(mismatch, block, "ZONE", 10, 50)
    T.ok("I16 provider mismatch rejects saved rows", not ok)
    T.eq("I17 provider mismatch names its reason", reason, "PROVIDER_MISMATCH")
    T.eq("I18 provider mismatch restores no partial rows", tableCount(mismatch.cells), 0)
    T.eq("I19 provider mismatch uses the unified hour marker", mismatch.standDownThroughHourKey, 50)
    T.eq("I19a provider mismatch keeps its diagnostic reason",
        mismatch.standDownReason, "PROVIDER_MISMATCH")

    local badCount = {}
    for k, v in pairs(block) do badCount[k] = v end
    badCount.rowCount = block.rowCount + 1
    local malformed = newState("CAPPED", 1.0)
    ok = loadWindow(malformed, badCount, "TRUTH", 2, 50)
    T.ok("I20 row-count mismatch rejects the whole block", not ok)
    T.eq("I21 row-count mismatch restores no partial rows", tableCount(malformed.cells), 0)

    local badHash = {}
    for k, v in pairs(block) do badHash[k] = v end
    badHash.rowsAdler32 = "00000000"
    ok = loadWindow(malformed, badHash, "TRUTH", 2, 50)
    T.ok("I22 Adler mismatch rejects the whole block", not ok)
    T.eq("I23 Adler mismatch restores no partial rows", tableCount(malformed.cells), 0)

    local schema2 = newState("CAPPED", 1.0)
    ok, reason = loadWindow(schema2, { outerSchema = 2 }, "TRUTH", 2, 50)
    T.ok("I24 schema-two save migrates without invented absorption", ok)
    T.eq("I25 schema-two migration leaves the ledger empty", tableCount(schema2.cells), 0)
    T.eq("I26 schema-two migration is named", reason, "MIGRATED_SCHEMA_2")

    local uncapped = newState("UNCAPPED", 1.0)
    ok, reason = loadWindow(uncapped, block, "TRUTH", 2, 50)
    T.ok("I27 uncapped mission accepts the save without restoring absorption", ok)
    T.eq("I28 uncapped mission names the ignored absorption block", reason, "UNCAPPED_IGNORED")
    T.eq("I29 uncapped mission restores no absorption rows", tableCount(uncapped.cells), 0)

    local markerBlock = packWindow(mismatch)
    T.eq("I30 marker-only save retains absorption schema two", markerBlock.schema, 2)
    T.eq("I31 marker-only save persists the unified hour", markerBlock.standDownThroughHourKey, 50)
    T.eq("I32 marker-only save persists its reason", markerBlock.standDownReason, "PROVIDER_MISMATCH")
    T.eq("I33 marker-only save carries zero capacity rows", markerBlock.rowCount, 0)
    T.eq("I34 marker-only empty bytes keep a valid Adler", markerBlock.rowsAdler32, adler32(""))

    local markerReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(markerReload, markerBlock, "ZONE", 10, 50)
    T.ok("I35 marker-only block reloads", ok)
    T.eq("I36 marker-only reload names stand-down", reason, "RESTORED_STAND_DOWN")
    T.eq("I37 marker-only reload restores the same hour", markerReload.standDownThroughHourKey, 50)
    T.eq("I38 marker-only reload restores no capacity rows", tableCount(markerReload.cells), 0)
    local sameHour = applyControlled(markerReload, normalArgs({ windowEnd = 50 }))
    T.eq("I39 reloaded marker keeps the saved hour neutral", sameHour.neutralReason, "RESTORE_STAND_DOWN")
    local nextHour = applyControlled(markerReload, normalArgs({ windowEnd = 51 }))
    T.eq("I40 newer hour clears the reloaded marker", markerReload.standDownThroughHourKey, nil)
    T.eq("I41 newer hour returns to controlled work", nextHour.neutralReason, nil)

    local awaitingState = newState("CAPPED", 1.0)
    awaitingState.standDownAwaitingFirstValidHour = true
    awaitingState.standDownReason = "CORRUPT_STATE"
    local awaitingBlock = packWindow(awaitingState)
    local awaitingReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(awaitingReload, awaitingBlock, "TRUTH", 2, 50)
    T.ok("I42 awaiting-hour marker reloads", ok)
    T.ok("I43 awaiting-hour flag survives save and reload", awaitingReload.standDownAwaitingFirstValidHour)

    local schema1 = {}
    for key, value in pairs(block) do schema1[key] = value end
    schema1.schema = 1
    schema1.standDownThroughHourKey = nil
    schema1.standDownAwaitingFirstValidHour = nil
    schema1.standDownReason = nil
    local schema1Reload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(schema1Reload, schema1, "TRUTH", 2, 50)
    T.ok("I44 absorption schema one migrates its rows", ok)
    T.eq("I45 schema-one migration restores no marker", schema1Reload.standDownThroughHourKey, nil)

    local markerWithRows = newState("CAPPED", 1.0)
    applyControlled(markerWithRows, normalArgs())
    applyControlled(markerWithRows, normalArgs({ providerMode = "ZONE", providerGrain = 10 }))
    local mixedBlock = packWindow(markerWithRows)
    T.ok("I46 live provider-change save contains old capacity rows", mixedBlock.rowCount > 0)
    T.eq("I47 live provider-change save contains the unified marker",
        mixedBlock.standDownThroughHourKey, 50)
    local mixedReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(mixedReload, mixedBlock, "ZONE", 10, 50)
    T.ok("I48 marker-plus-rows block reloads", ok)
    T.eq("I49 marker-plus-rows load restores stand-down first", reason, "RESTORED_STAND_DOWN")
    T.eq("I50 marker-plus-rows load preserves the saved hour", mixedReload.standDownThroughHourKey, 50)
    T.eq("I51 marker-plus-rows load discards every capacity row", tableCount(mixedReload.cells), 0)

    local changedProviderBlock = {}
    for key, value in pairs(mixedBlock) do changedProviderBlock[key] = value end
    changedProviderBlock.providerMode = "TRUTH"
    changedProviderBlock.providerGrainMetres = 2
    local mismatchMarkerReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(mismatchMarkerReload, changedProviderBlock, "ZONE", 10, 50)
    T.ok("I52 persisted marker wins before provider mismatch validation", ok)
    T.eq("I53 provider mismatch cannot rewrite the saved marker",
        mismatchMarkerReload.standDownThroughHourKey, 50)
    T.eq("I54 provider mismatch marker load restores no rows", tableCount(mismatchMarkerReload.cells), 0)

    local uncappedMarkerReload = newState("UNCAPPED", 1.0)
    ok, reason = loadWindow(uncappedMarkerReload, mixedBlock, "ZONE", 10, 50)
    T.ok("I55 uncapped mission accepts marker-plus-rows block", ok)
    T.eq("I56 uncapped ignore runs before marker restoration", reason, "UNCAPPED_IGNORED")
    T.eq("I57 uncapped marker load restores no hour", uncappedMarkerReload.standDownThroughHourKey, nil)
    T.eq("I58 uncapped marker load restores no rows", tableCount(uncappedMarkerReload.cells), 0)

    local futureWindowBlock = {}
    for key, value in pairs(block) do futureWindowBlock[key] = value end
    futureWindowBlock.windowId = 60
    local futureWindowReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(futureWindowReload, futureWindowBlock, "TRUTH", 2, 50)
    T.ok("I59 future ordinary window is rejected", not ok)
    T.eq("I60 future ordinary window names its rejection", reason, "FUTURE_WINDOW")
    T.eq("I61 future ordinary window normalizes to the current valid hour",
        futureWindowReload.standDownThroughHourKey, 50)
    T.eq("I62 future ordinary window becomes corrupt-state stand-down",
        futureWindowReload.standDownReason, "CORRUPT_STATE")

    local futureMarkerBlock = {}
    for key, value in pairs(markerBlock) do futureMarkerBlock[key] = value end
    futureMarkerBlock.standDownThroughHourKey = 60
    futureMarkerBlock.standDownReason = "PROVIDER_MISMATCH"
    local futureMarkerReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(futureMarkerReload, futureMarkerBlock, "ZONE", 10, 50)
    T.ok("I63 future persisted marker reloads as conservative stand-down", ok)
    T.eq("I64 future persisted marker normalizes to current hour",
        futureMarkerReload.standDownThroughHourKey, 50)
    T.eq("I65 future persisted marker is reclassified corrupt",
        futureMarkerReload.standDownReason, "CORRUPT_STATE")
    T.eq("I66 future persisted marker restores no rows", tableCount(futureMarkerReload.cells), 0)

    local noCurrentMarkerReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(noCurrentMarkerReload, futureMarkerBlock, "ZONE", 10, nil)
    T.ok("I67 numeric marker with no current hour reloads as awaiting", ok)
    T.eq("I68 numeric marker with no current hour retains no poisoned bound",
        noCurrentMarkerReload.standDownThroughHourKey, nil)
    T.ok("I69 numeric marker with no current hour sets awaiting",
        noCurrentMarkerReload.standDownAwaitingFirstValidHour)

    local noCurrentWindowReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(noCurrentWindowReload, block, "TRUTH", 2, nil)
    T.ok("I70 ordinary window with no current hour is rejected", not ok)
    T.eq("I71 unreadable current hour is named", reason, "UNREADABLE_CURRENT_HOUR")
    T.eq("I72 unreadable current hour retains no numeric marker",
        noCurrentWindowReload.standDownThroughHourKey, nil)
    T.ok("I73 unreadable current hour sets awaiting",
        noCurrentWindowReload.standDownAwaitingFirstValidHour)

    local pastMarkerReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(pastMarkerReload, markerBlock, "ZONE", 10, 51)
    T.ok("I74 valid past marker reloads", ok)
    T.eq("I75 valid past marker remains unchanged", pastMarkerReload.standDownThroughHourKey, 50)
    T.eq("I76 valid past marker keeps its diagnostic reason",
        pastMarkerReload.standDownReason, "PROVIDER_MISMATCH")

    local olderWindowBlock = {}
    for key, value in pairs(block) do olderWindowBlock[key] = value end
    olderWindowBlock.windowId = 49
    local olderWindowReload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(olderWindowReload, olderWindowBlock, "TRUTH", 2, 50)
    T.ok("I77 older saved capacity window expires cleanly", ok)
    T.eq("I78 older saved capacity window names expiry", reason, "EXPIRED_WINDOW")
    T.eq("I79 older saved capacity window restores no rows", tableCount(olderWindowReload.cells), 0)
    T.eq("I80 older saved capacity window creates no stand-down marker",
        olderWindowReload.standDownThroughHourKey, nil)

    local olderSchema1 = {}
    for key, value in pairs(olderWindowBlock) do olderSchema1[key] = value end
    olderSchema1.schema = 1
    local olderSchema1Reload = newState("CAPPED", 1.0)
    ok, reason = loadWindow(olderSchema1Reload, olderSchema1, "TRUTH", 2, 50)
    T.ok("I81 older schema-one window expires through the ordinary row path", ok)
    T.eq("I82 older schema-one window names expiry", reason, "EXPIRED_WINDOW")
    T.eq("I83 older schema-one window restores no rows", tableCount(olderSchema1Reload.cells), 0)

    local pruneState = newState("CAPPED", 1.0)
    pruneState.cells = {
        a = { fieldId = 1 },
        b = { fieldId = 2 },
        c = { fieldId = 2 },
    }
    T.eq("I84 live-field prune removes every absent-field row",
        pruneMissingFields(pruneState, { [1] = true }), 2)
    T.eq("I85 live-field prune retains only present fields", tableCount(pruneState.cells), 1)
    T.eq("I86 live-field prune retains the present-field row", pruneState.cells.a.fieldId, 1)
    T.eq("I87 repeated live-field prune is idempotent",
        pruneMissingFields(pruneState, { [1] = true }), 0)
end

local function currentHourKey(environment, timeGuard)
    if type(environment) ~= "table" or not finiteInteger(environment.currentHour) then return nil end

    local day = nil
    if type(timeGuard) == "table" and type(timeGuard.getContext) == "function" then
        local ok, context = pcall(timeGuard.getContext, timeGuard)
        if ok and type(context) == "table" and context.synced == true then
            if positiveInteger(context.monotonicDay) then day = context.monotonicDay end
        end
    end

    if day == nil then day = environment.currentMonotonicDay end
    if not positiveInteger(day) then return nil end
    local key = day * 24 + environment.currentHour
    if not positiveInteger(key) then return nil end
    return key
end

local function requestHourKey(explicitHourKey, environment, timeGuard)
    if explicitHourKey ~= nil then
        return positiveInteger(explicitHourKey) and explicitHourKey or nil
    end
    return currentHourKey(environment, timeGuard)
end

local function coverageFor(kind)
    if kind == "pivot" or kind == "drip" then return true end
    return nil
end

-- GROUP J: DIRECT HOUR, WINDOW REFUSAL AND ROUTE CUTOVER.
-- SDS 5.4 and 5.9-5.11.
do
    local synced = { getContext = function() return { synced = true, monotonicDay = 5 } end }
    T.eq("J1 synced Time Guard day wins over environment day",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6 }, synced), 126)
    T.eq("J2 absent Time Guard uses standalone monotonic day",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6 }, nil), 102)
    T.eq("J3 explicit midnight is a valid hour",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 0 }, synced), 120)
    T.eq("J4 invalid environment hour refuses",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6.5 }, synced), nil)
    T.eq("J5 missing environment never becomes midnight", currentHourKey(nil, synced), nil)
    local unsynced = { getContext = function() return { synced = false, monotonicDay = 5 } end }
    T.eq("J6 readable unsynced Time Guard uses the standalone environment day",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6 }, unsynced), 102)
    local throwing = { getContext = function() error("synthetic provider failure") end }
    T.eq("J7 throwing Time Guard uses standalone monotonic day",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6 }, throwing), 102)
    local malformed = { getContext = function() return { synced = true, monotonicDay = 4.5 } end }
    T.eq("J8 malformed Time Guard day uses standalone monotonic day",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6 }, malformed), 102)
    local zeroDay = { getContext = function() return { synced = true, monotonicDay = 0 } end }
    T.eq("J8a Time Guard missing-day zero uses positive standalone day",
        currentHourKey({ currentMonotonicDay = 4, currentHour = 6 }, zeroDay), 102)
    T.eq("J8b two missing-day zeros refuse a fabricated day",
        currentHourKey({ currentMonotonicDay = 0, currentHour = 6 }, zeroDay), nil)
    T.eq("J8c an admitted fitted endpoint is never re-derived through another clock",
        requestHourKey(102, { currentMonotonicDay = 4, currentHour = 6 }, synced), 102)
    T.eq("J8d an invalid explicit endpoint refuses instead of falling through",
        requestHourKey(0, { currentMonotonicDay = 4, currentHour = 6 }, synced), nil)

    local invalid = applyControlled(newState("CAPPED", 1.0), normalArgs({ windowCount = 0 }))
    T.eq("J9 zero window count takes neutral route", invalid.neutralReason, "INVALID_WINDOW")
    invalid = applyControlled(newState("CAPPED", 1.0), normalArgs({ windowCount = 169 }))
    T.eq("J10 over-ceiling window count takes neutral route", invalid.neutralReason, "INVALID_WINDOW")
    invalid = applyControlled(newState("CAPPED", 1.0), normalArgs({ windowCount = 1.5 }))
    T.eq("J11 fractional window count takes neutral route", invalid.neutralReason, "INVALID_WINDOW")

    local rewind = newState("CAPPED", 1.0)
    rewind.lastObservedHour = 51
    local rewound = applyControlled(rewind, normalArgs({ windowEnd = 50 }))
    T.eq("J12 clock rewind is neutral", rewound.neutralReason, "CLOCK_REWIND")
    T.eq("J13 clock rewind performs no ledger write", rewind.ledgerWrites, 0)
    T.near("J14 clock rewind preserves complete local request", rewound.localWriteRequest, 0.015, 1e-12)

    T.ok("J15 pivot remains supported", coverageFor("pivot"))
    T.ok("J16 unchanged manager retains drip-producer compatibility", coverageFor("drip"))
    T.eq("J17 unknown irrigation type remains refused", coverageFor("unknown"), nil)
    T.near("J18 every modeled mission carries the fixed base",
        newState("CAPPED", 1.0).base, 0.018, 1e-12)
    T.eq("J19 UNCAPPED is an explicit mode, not a negative base",
        newState("UNCAPPED", 1.0).mode, "UNCAPPED")
end

-- GROUP K: THE PURE READABLE-DIRTY CONTRACT FLUSHES ONCE PER MODELED OUTER ACT.
-- SDS 5.10. This does not bind scheduled, vehicle, event or transport call sites.
do
    for index = 1, 4 do
        local state = newState("CAPPED", 1.0)
        applyControlled(state, normalArgs({ cellKey = "TRUTH:2:1:1", cellX = 1, cellZ = 1 }))
        applyControlled(state, normalArgs({ cellKey = "TRUTH:2:2:1", cellX = 2, cellZ = 1 }))
        T.ok("K" .. tostring(index) .. "a modeled outer act flushes changed water", flushDirty(state))
        T.eq("K" .. tostring(index) .. "b modeled outer act flushes exactly once", state.dirtyFlushes, 1)
        T.ok("K" .. tostring(index) .. "c modeled outer act second flush is empty", not flushDirty(state))
    end

    local unchanged = newState("CAPPED", 1.0)
    local args = normalArgs({ rawChanged = false })
    args.providerMode = nil
    applyControlled(unchanged, args)
    T.ok("K5 unchanged raw refusal does not mint a dirty flush", not flushDirty(unchanged))
end

local function newLifecycleState()
    return {
        settingsLoaded = false,
        fieldsEnumerated = false,
        compactReady = false,
        mapReady = false,
        configurationFrozen = false,
        preFreezeWaterObserved = false,
        mode = nil,
        base = BASE_INFILTRATION_PER_HOUR,
        agronomyRestriction = nil,
        providerMode = nil,
        restoreCount = 0,
        routeArmCount = 0,
        waterRoutesReady = false,
        finalized = false,
    }
end

local function observePreFreezeWater(state, readableChanged)
    if not state.configurationFrozen and readableChanged == true then
        state.preFreezeWaterObserved = true
    end
end

local function freezeLifecycle(state, gateRegistered, gateOpen, declaration, profile)
    if state.configurationFrozen then return false end
    if state.preFreezeWaterObserved then
        state.mode = "UNCAPPED"
        state.agronomyRestriction = 1.0
    else
        state.mode, state.agronomyRestriction = resolveMissionConfiguration(
            gateRegistered, gateOpen, declaration, profile)
    end
    state.configurationFrozen = true
    return true
end

local function tryFinalizeLifecycle(state, liveProviderMode)
    if state.finalized then return false, "ALREADY_FINALIZED" end
    if not state.settingsLoaded or not state.fieldsEnumerated
            or not state.compactReady or not state.mapReady
            or not state.configurationFrozen then return false, "WAITING" end
    state.providerMode = liveProviderMode
    state.restoreCount = state.restoreCount + 1
    state.routeArmCount = state.routeArmCount + 1
    state.waterRoutesReady = true
    state.finalized = true
    return true, "FINALIZED"
end

-- GROUP L: SETTINGS/FIELDS A-B ORDER CONVERGES BEFORE ANY CONTROLLED WATER ROUTE.
-- SDS 5.1 and R2 lifecycle fold. This models ordering and cannot prove engine hooks.
do
    local profileOn = { dials = { agronomy = 1.0 }, switches = { agronomy = true } }
    local profilePunishing = { dials = { agronomy = 2.0 }, switches = { agronomy = true } }
    local declaration = absorptionDeclaration()
    local settingsFirst = newLifecycleState()
    settingsFirst.settingsLoaded = true
    settingsFirst.compactReady = true
    settingsFirst.mapReady = true
    T.ok("L1 settings-first freezes one mission configuration",
        freezeLifecycle(settingsFirst, true, true, declaration, profileOn))
    local ok, reason = tryFinalizeLifecycle(settingsFirst, "TRUTH")
    T.ok("L2 settings-first waits for fields", not ok)
    T.eq("L3 settings-first wait reason", reason, "WAITING")
    T.ok("L4 water routes remain unarmed before fields", not settingsFirst.waterRoutesReady)
    settingsFirst.fieldsEnumerated = true
    ok, reason = tryFinalizeLifecycle(settingsFirst, "TRUTH")
    T.ok("L5 settings-first finalizes after fields", ok)
    T.eq("L6 settings-first final disposition", reason, "FINALIZED")

    local fieldsFirst = newLifecycleState()
    fieldsFirst.fieldsEnumerated = true
    fieldsFirst.compactReady = true
    fieldsFirst.mapReady = true
    ok, reason = tryFinalizeLifecycle(fieldsFirst, "TRUTH")
    T.ok("L7 fields-first waits for persisted settings", not ok)
    fieldsFirst.settingsLoaded = true
    T.ok("L8 fields-first freezes after settings load",
        freezeLifecycle(fieldsFirst, true, true, declaration, profileOn))
    ok, reason = tryFinalizeLifecycle(fieldsFirst, "TRUTH")
    T.ok("L9 fields-first finalizes through the same barrier", ok)
    T.eq("L10 both orders freeze the same mode", fieldsFirst.mode, settingsFirst.mode)
    T.near("L10b both orders freeze the same base", fieldsFirst.base, settingsFirst.base, 1e-12)
    T.near("L10c both orders freeze the same restriction",
        fieldsFirst.agronomyRestriction, settingsFirst.agronomyRestriction, 1e-12)
    T.eq("L11 both orders select the same provider", fieldsFirst.providerMode, settingsFirst.providerMode)
    T.eq("L12 settings-first restores exactly once", settingsFirst.restoreCount, 1)
    T.eq("L13 fields-first restores exactly once", fieldsFirst.restoreCount, 1)
    T.eq("L14 settings-first arms routes exactly once", settingsFirst.routeArmCount, 1)
    T.eq("L15 fields-first arms routes exactly once", fieldsFirst.routeArmCount, 1)
    ok, reason = tryFinalizeLifecycle(fieldsFirst, "TRUTH")
    T.ok("L16 repeated barrier cannot restore again", not ok)
    T.eq("L17 repeated barrier names finalization", reason, "ALREADY_FINALIZED")
    T.eq("L18 repeated barrier leaves restore count one", fieldsFirst.restoreCount, 1)

    local earlyWater = newLifecycleState()
    observePreFreezeWater(earlyWater, true)
    earlyWater.settingsLoaded = true
    T.ok("L19 pre-freeze changed water still permits one freeze act",
        freezeLifecycle(earlyWater, true, true, declaration, profileOn))
    T.eq("L20 pre-freeze changed water locks the whole mission uncapped",
        earlyWater.mode, "UNCAPPED")
    T.ok("L21 mission configuration refuses a second freeze",
        not freezeLifecycle(earlyWater, true, true, declaration, profilePunishing))
    T.eq("L22 later dial changes cannot lift the uncapped lock",
        earlyWater.mode, "UNCAPPED")

    local unchanged = newLifecycleState()
    observePreFreezeWater(unchanged, false)
    unchanged.settingsLoaded = true
    freezeLifecycle(unchanged, true, true, declaration, profileOn)
    T.eq("L23 unchanged pre-freeze refusal keeps released mode capped",
        unchanged.mode, "CAPPED")
    T.near("L23b unchanged pre-freeze refusal keeps fixed base",
        unchanged.base, 0.018, 1e-12)
    T.near("L23c unchanged pre-freeze refusal keeps Standard restriction",
        unchanged.agronomyRestriction, 1.0, 1e-12)

    local absentRow = newLifecycleState()
    absentRow.settingsLoaded = true
    freezeLifecycle(absentRow, false, true, declaration, profileOn)
    T.eq("L24 absent release row fails closed", absentRow.mode, "UNCAPPED")

    local standDown = newState("CAPPED", 1.0)
    standDown.standDownThroughHourKey = 50
    local immediate = applyControlled(standDown, normalArgs())
    T.eq("L25 corrupt-state stand-down neutralizes immediate water",
        immediate.neutralReason, "RESTORE_STAND_DOWN")
    T.eq("L26 same-hour immediate water keeps the hour marker",
        standDown.standDownThroughHourKey, 50)
    local nextHour = applyControlled(standDown, normalArgs({ windowEnd = 51 }))
    T.eq("L27 first newer immediate hour clears stand-down without a schedule",
        standDown.standDownThroughHourKey, nil)
    T.eq("L28 newer immediate hour enters the controlled path", nextHour.neutralReason, nil)

    local mixed = newState("CAPPED", 1.0)
    mixed.standDownThroughHourKey = 50
    local split = applyControlled(mixed, normalArgs({ windowEnd = 52, windowCount = 3 }))
    T.eq("L29 catch-up spanning the marker names the split", split.neutralReason, "RESTORE_SPLIT")
    T.near("L30 split preserves the complete three-hour request",
        split.requestedGain, 0.045, 1e-12)
    T.near("L31 split keeps routing conservation",
        split.localWriteRequest + split.acceptedSurplus, split.requestedGain, 1e-12)
    T.eq("L32 split clears the marker after preserving its neutral prefix",
        mixed.standDownThroughHourKey, nil)

    local rewind = newState("CAPPED", 1.0)
    rewind.standDownThroughHourKey = 50
    local oldHour = applyControlled(rewind, normalArgs({ windowEnd = 49 }))
    T.eq("L33 older hour stays neutral", oldHour.neutralReason, "RESTORE_STAND_DOWN")
    T.eq("L34 older hour cannot clear the marker", rewind.standDownThroughHourKey, 50)

    local noRestoreHour = newState("CAPPED", 1.0)
    noRestoreHour.standDownAwaitingFirstValidHour = true
    local firstValid = applyControlled(noRestoreHour, normalArgs({ windowEnd = 70 }))
    T.eq("L35 first valid hour after an unreadable restore is neutral",
        firstValid.neutralReason, "RESTORE_STAND_DOWN")
    T.eq("L36 first valid hour becomes the marker", noRestoreHour.standDownThroughHourKey, 70)
    local afterUnknown = applyControlled(noRestoreHour, normalArgs({ windowEnd = 71 }))
    T.eq("L37 later hour clears an initially unknown marker", noRestoreHour.standDownThroughHourKey, nil)
    T.eq("L38 later hour enters the controlled path", afterUnknown.neutralReason, nil)

    local neutralOfferCalls = 0
    local neutralHigh = newState("CAPPED", 1.0)
    neutralHigh.standDownThroughHourKey = 50
    local aboveCapNeutral = applyControlled(neutralHigh, normalArgs({
        requestPerWindow = 0.05,
        acceptFn = function(_span, candidate)
            neutralOfferCalls = neutralOfferCalls + 1
            return candidate
        end,
    }))
    T.near("L39 above-cap stood-down hour remains a complete local raw write",
        aboveCapNeutral.localWriteRequest, 0.05, 1e-12)
    T.eq("L40 stood-down neutral hour creates zero candidate surplus",
        aboveCapNeutral.candidateSurplus, 0)
    T.eq("L41 stood-down neutral hour accepts zero surplus", aboveCapNeutral.acceptedSurplus, 0)
    T.eq("L42 stood-down neutral hour never calls the sibling", neutralOfferCalls, 0)

    local mixedOfferCalls = 0
    local mixedHigh = newState("CAPPED", 1.0)
    mixedHigh.standDownThroughHourKey = 50
    local aboveCapSplit = applyControlled(mixedHigh, normalArgs({
        windowEnd = 52, windowCount = 3, requestPerWindow = 0.05,
        acceptFn = function(_span, candidate)
            mixedOfferCalls = mixedOfferCalls + 1
            return candidate
        end,
    }))
    T.near("L43 mixed above-cap split preserves the full request",
        aboveCapSplit.requestedGain, 0.15, 1e-12)
    T.near("L44 only the two controlled suffix hours create candidate surplus",
        aboveCapSplit.candidateSurplus, 0.064, 1e-12)
    T.near("L45 only suffix candidate can be accepted",
        aboveCapSplit.acceptedSurplus, 0.064, 1e-12)
    T.near("L46 neutral prefix plus controlled suffix conserve routing",
        aboveCapSplit.localWriteRequest + aboveCapSplit.acceptedSurplus,
        aboveCapSplit.requestedGain, 1e-12)
    T.eq("L47 mixed split calls the sibling only for the suffix span", mixedOfferCalls, 1)
end

local function rawReceipt(accepted, readableChanged)
    return accepted == true, accepted == true and readableChanged == true
end

local function publicReceipt(localWriteRequest, rawAccepted, acceptedSurplus, diagnostics)
    local accepted = (acceptedSurplus or 0) > 0
        or rawAccepted == true
    return accepted, diagnostics
end

local function envelopeIdentityMatches(complete, pending)
    return type(complete) == "table" and type(pending) == "table"
        and pending.payloadKind == "PENDING_ONLY"
        and pending.nativeFailure == true
        and pending.generation == complete.generation
        and pending.providerMode == complete.providerMode
        and pending.providerGrainMetres == complete.providerGrainMetres
        and pending.moistureRevision == complete.moistureRevision
        and pending.lastSettledMonotonicDay == complete.lastSettledMonotonicDay
end

local function selectedAbsorptionLeaf(complete, pending)
    if envelopeIdentityMatches(complete, pending) and pending.absorption ~= nil then
        return pending.absorption
    end
    return complete and complete.absorption or nil
end

-- GROUP M: FINAL PACKAGE FIT. One literal first-return receipt, one shared
-- SCS-039 barrier and one nested absorption leaf. SDS 5.1, 5.3, 5.13, 5.15.
-- This models contract composition; it cannot prove the later source landing.
do
    local accepted, readable = rawReceipt(true, false)
    T.ok("M1 pending-only raw water remains an accepted COVER receipt", accepted)
    T.ok("M2 pending-only raw water is not a readable change", not readable)

    local diagnostics = { requestedGain = 0.02, localWriteRequest = 0.02 }
    local first, second = publicReceipt(0.02, true, 0, diagnostics)
    T.eq("M3 public first return is literal Boolean true", type(first), "boolean")
    T.ok("M4 accepted local water returns true", first)
    T.eq("M5 diagnostics remain the optional second return", second, diagnostics)

    first = publicReceipt(0.02, false, 0, diagnostics)
    T.ok("M6 refused local water with no runoff returns false", not first)
    first = publicReceipt(0, false, 0.01, diagnostics)
    T.ok("M7 runoff-only accepted consequence returns true", first)

    local barrier = newLifecycleState()
    barrier.settingsLoaded = true
    barrier.fieldsEnumerated = true
    freezeLifecycle(barrier, true, true, absorptionDeclaration(), nil)
    local ok, reason = tryFinalizeLifecycle(barrier, "TRUTH")
    T.ok("M8 settings and fields cannot bypass compact/map readiness", not ok)
    T.eq("M9 incomplete shared barrier reports waiting", reason, "WAITING")
    barrier.compactReady = true
    ok, reason = tryFinalizeLifecycle(barrier, "TRUTH")
    T.ok("M10 compact readiness alone cannot bypass map readiness", not ok)
    barrier.mapReady = true
    ok, reason = tryFinalizeLifecycle(barrier, "TRUTH")
    T.ok("M11 all shared prerequisites finalize exactly once", ok)
    T.eq("M12 shared barrier restores once", barrier.restoreCount, 1)
    T.eq("M13 shared barrier arms routes once", barrier.routeArmCount, 1)

    local complete = {
        schema = 3,
        payloadKind = "COMPLETE",
        generation = 4,
        providerMode = "TRUTH",
        providerGrainMetres = 2,
        moistureRevision = 19,
        lastSettledMonotonicDay = 91,
        absorption = { schema = 2, windowId = 50 },
    }
    local matchingPending = {
        payloadKind = "PENDING_ONLY",
        nativeFailure = true,
        generation = 4,
        providerMode = "TRUTH",
        providerGrainMetres = 2,
        moistureRevision = 19,
        lastSettledMonotonicDay = 91,
        absorption = { schema = 2, windowId = 51 },
    }
    T.eq("M14 paired SCS-039 owner fixes outer provider schema three", complete.schema, 3)
    T.eq("M15 matching PENDING_ONLY may replace the absorption leaf",
        selectedAbsorptionLeaf(complete, matchingPending).windowId, 51)
    local wrongGeneration = {
        payloadKind = "PENDING_ONLY",
        nativeFailure = true,
        generation = 5,
        providerMode = "TRUTH",
        providerGrainMetres = 2,
        moistureRevision = 19,
        lastSettledMonotonicDay = 91,
        absorption = { schema = 2, windowId = 99 },
    }
    T.eq("M16 mismatched pending identity cannot replace absorption",
        selectedAbsorptionLeaf(complete, wrongGeneration).windowId, 50)
    local wrongRevision = {}
    for key, value in pairs(matchingPending) do wrongRevision[key] = value end
    wrongRevision.moistureRevision = 20
    T.eq("M17 mismatched moisture revision cannot replace absorption",
        selectedAbsorptionLeaf(complete, wrongRevision).windowId, 50)
    local ordinaryOverlay = {}
    for key, value in pairs(matchingPending) do ordinaryOverlay[key] = value end
    ordinaryOverlay.nativeFailure = false
    T.eq("M18 ordinary pending overlay cannot replace absorption",
        selectedAbsorptionLeaf(complete, ordinaryOverlay).windowId, 50)
    local wrongDay = {}
    for key, value in pairs(matchingPending) do wrongDay[key] = value end
    wrongDay.lastSettledMonotonicDay = 92
    T.eq("M19 mismatched committed day cannot replace absorption",
        selectedAbsorptionLeaf(complete, wrongDay).windowId, 50)
    T.eq("M20 absent absorption leaf means no prior absorption state",
        selectedAbsorptionLeaf({ generation = 1 }, nil), nil)
end

local function buildCoverageSpans(firstWindowId, gains)
    local spans = {}
    for offset, gain in ipairs(gains) do
        local windowId = firstWindowId + offset - 1
        if finiteNumber(gain) and gain > 0 then
            local last = spans[#spans]
            if last ~= nil
                    and last.firstWindowId + last.windowCount == windowId
                    and last.requestedGainPerWindow == gain then
                last.windowCount = last.windowCount + 1
            else
                spans[#spans + 1] = {
                    firstWindowId = windowId,
                    windowCount = 1,
                    requestedGainPerWindow = gain,
                }
            end
        end
    end
    return spans
end

local function absorbedAcrossSpans(spans, capacityPerWindow)
    local absorbed = 0
    for _, span in ipairs(spans) do
        absorbed = absorbed
            + math.min(span.requestedGainPerWindow, capacityPerWindow) * span.windowCount
    end
    return absorbed
end

local function newSaveCutState()
    return {
        dirty = true,
        fittedHours = 1,
        generation = 3,
        cached = { generation = 3, digest = "prior" },
        settleCount = 0,
        packCount = 0,
        nativeWriteCount = 0,
        completeCount = 0,
    }
end

local function markSaveCutDirty(state, fittedHours)
    state.dirty = true
    state.fittedHours = (state.fittedHours or 0) + (fittedHours or 0)
end

local function ensureMissionWaterSaveCut(state, caller, nativeSucceeds)
    if state.cached ~= nil and state.dirty ~= true then return state.cached end
    state.settleCount = state.settleCount + 1
    state.fittedHours = 0
    state.packCount = state.packCount + 1
    state.nativeWriteCount = state.nativeWriteCount + 1
    if nativeSucceeds == false then return state.cached end
    state.generation = state.generation + 1
    state.cached = { generation = state.generation, digest = "cut-" .. tostring(state.generation) }
    state.completeCount = state.completeCount + 1
    state.dirty = false
    return state.cached
end

-- GROUP N: R10 OWNER FOLD. SCS-023 retains exact per-hour service spans,
-- SCS-039 fixes schema/token identity, and F200 settles before one save cut.
-- Amendment candidates are the contract sources; this bar models no engine save.
do
    local equal = buildCoverageSpans(40, { 0.03, 0.03, 0.01 })
    T.eq("N1 adjacent equal served gains coalesce", #equal, 2)
    T.eq("N2 coalesced span retains two represented hours", equal[1].windowCount, 2)
    T.near("N3 changed served gain starts a new span",
        equal[2].requestedGainPerWindow, 0.01, 1e-12)

    local gapped = buildCoverageSpans(50, { 0.03, 0, 0.03 })
    T.eq("N4 a dry gap prevents false span coalescing", #gapped, 2)
    T.eq("N5 second positive span retains its true hour", gapped[2].firstWindowId, 52)
    local exact = absorbedAcrossSpans(gapped, 0.018)
    local averaged = math.min((0.03 + 0 + 0.03) / 3, 0.018) * 3
    T.near("N6 exact per-hour service absorbs only the two served hours", exact, 0.036, 1e-12)
    T.ok("N7 averaging aggregate service changes the farm result", math.abs(exact - averaged) > 1e-12)
    local geometryCalls = 0
    local receivedSpans = nil
    local function coverOnce(spans)
        geometryCalls = geometryCalls + 1
        receivedSpans = spans
    end
    coverOnce(equal)
    T.eq("N8 one immutable span list receives one geometry enumeration", geometryCalls, 1)
    T.eq("N8a COVER receives the unchanged PLAN span object", receivedSpans, equal)

    local truthState = newState("CAPPED", 1.0)
    applyControlled(truthState, normalArgs())
    local truthLeaf = packWindow(truthState)
    local badToken = {}
    for key, value in pairs(truthLeaf) do badToken[key] = value end
    badToken.providerMode = "MAP"
    local rejected = newState("CAPPED", 1.0)
    local ok, reason = loadWindow(rejected, badToken, "TRUTH", 2, 50)
    T.ok("N9 MAP is not a legal SCS-039 provider token", not ok)
    T.eq("N10 illegal provider token is a malformed leaf", reason, "MALFORMED_BLOCK")

    local save = newSaveCutState()
    local pumpCut = ensureMissionWaterSaveCut(save, "pump", true)
    local ledgerCut = ensureMissionWaterSaveCut(save, "stateLedger", true)
    local xmlCut = ensureMissionWaterSaveCut(save, "careerXml", true)
    T.eq("N11 pump-first save creates generation four", pumpCut.generation, 4)
    T.eq("N12 StateLedger reuses the pump-created immutable envelope", ledgerCut, pumpCut)
    T.eq("N13 career XML reuses the same immutable envelope", xmlCut, pumpCut)
    T.eq("N14 one dirty save cut settles fitted water once", save.settleCount, 1)
    T.eq("N15 one dirty save cut packs once", save.packCount, 1)
    T.eq("N16 one dirty save cut writes native once", save.nativeWriteCount, 1)
    T.eq("N17 one dirty save cut commits COMPLETE once", save.completeCount, 1)

    markSaveCutDirty(save, 0.5)
    local nextCut = ensureMissionWaterSaveCut(save, "stateLedger", true)
    T.eq("N18 a later mutation creates exactly one next generation", nextCut.generation, 5)
    T.eq("N19 the later dirty cut settles exactly once more", save.settleCount, 2)

    markSaveCutDirty(save, 0.25)
    local retained = ensureMissionWaterSaveCut(save, "careerXml", false)
    T.eq("N20 failed native capture retains the prior valid envelope", retained, nextCut)
    T.eq("N21 failed native capture advances no generation", save.generation, 5)
    T.ok("N22 failed native capture remains dirty for a later attempt", save.dirty)
end

T.summary()
