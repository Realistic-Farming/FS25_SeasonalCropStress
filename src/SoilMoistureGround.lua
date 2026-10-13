-- ============================================================
-- SoilMoistureGround.lua
-- RSF-F247: the parcel-wide written-pixel probe, the unwritten-only parcel
-- fill, the field ground check that decides once per field per mission what
-- the fine map may do for a field, and the member anchor for the two
-- display-centre irrigation calls.
--
-- Loaded by main.lua right after SoilMoistureSystem.lua; it only adds methods
-- to SoilMoistureSystem. The per-load restore record, the geometry retry doors
-- and the aggregate state helpers live in SoilMoistureSystem.lua.
--
-- Server memory only: nothing here is saved or sent. F247 never publishes a
-- field number; the host number stays RSF-F245's first-polygon refresh.
-- ============================================================

local function groundLog(msg)
    if g_logManager ~= nil then
        g_logManager:devInfo("[CropStress]", msg)
    else
        print("[CropStress] " .. tostring(msg))
    end
end

-- ------------------------------------------------------------
-- Parcel wrappers (item 2)
-- ------------------------------------------------------------

--- Probe every polygon of the complete collection. Any PROVIDER_REFUSAL is a
--- refusal; else any PRESENT is PRESENT; else any UNPROVEN is UNPROVEN; else NONE.
--- No collection is INVALID_FIELD_GEOMETRY. First-polygon reads are never used.
---@return string outcome
function SoilMoistureSystem:_parcelHasWrittenPixels(fieldId)
    local polys = self:_getFieldPolygons(fieldId)
    if polys == nil or #polys == 0 then return "INVALID_FIELD_GEOMETRY" end
    local present, unproven = false, false
    for i = 1, #polys do
        local p = polys[i]
        local outcome = self.valueMap:hasWrittenPixels(p.vx, p.vz, p.n)
        if outcome == "PROVIDER_REFUSAL" then
            return "PROVIDER_REFUSAL"
        elseif outcome == "PRESENT" then
            present = true
        elseif outcome ~= "NONE" then
            -- UNPROVEN, or a polygon the value map calls malformed: nothing proved.
            unproven = true
        end
    end
    if present then return "PRESENT" end
    if unproven then return "UNPROVEN" end
    return "NONE"
end

local function finitePolygon(p)
    if type(p) ~= "table" or type(p.vx) ~= "table" or type(p.vz) ~= "table"
       or type(p.n) ~= "number" or p.n < 3 then
        return false
    end
    for i = 1, p.n do
        local x, z = p.vx[i], p.vz[i]
        if type(x) ~= "number" or type(z) ~= "number" or x ~= x or z ~= z
           or math.abs(x) == math.huge or math.abs(z) == math.huge then
            return false
        end
    end
    return true
end

--- Fill only unwritten pixels over the complete collection, in two phases.
--- Preflight writes nothing: a missing map, modifier or filter answers NOOP; a
--- disabled polygon capability, a malformed polygon or a failed bind answers
--- PROVIDER_REFUSAL. Execution stops at the first NOOP or PROVIDER_REFUSAL:
--- before any OK that answer stands (write-free); after an OK it is PARTIAL.
--- All OK or EMPTY_OUTLINE with at least one OK is OK; all EMPTY_OUTLINE is NOOP.
---@return string outcome  "OK" | "NOOP" | "PARTIAL" | "PROVIDER_REFUSAL"
function SoilMoistureSystem:_fillParcelUnwritten(fieldId, value)
    local vm = self.valueMap
    if vm == nil or vm.available ~= true or vm.modifier == nil or vm.filter == nil then
        return "NOOP"
    end
    local polys = self:_getFieldPolygons(fieldId)
    if polys == nil or #polys == 0 then return "PROVIDER_REFUSAL" end
    if vm.hasPolygonOps ~= true then return "PROVIDER_REFUSAL" end
    for i = 1, #polys do
        local p = polys[i]
        if not finitePolygon(p) then return "PROVIDER_REFUSAL" end
        if not vm:_setPolygonRegion(p.vx, p.vz, p.n) then return "PROVIDER_REFUSAL" end
    end

    local anyOk = false
    for i = 1, #polys do
        local p = polys[i]
        local outcome, setRan = vm:fillUnwrittenPolygon(p.vx, p.vz, p.n, value)
        if outcome == "OK" then
            anyOk = true
        elseif outcome ~= "EMPTY_OUTLINE" then
            if outcome == "NOOP" and setRan then
                self:_logOnce(fieldId, "fill-no-change", string.format(
                    "Moisture: field %d parcel fill ran with no measurable change; field preserved", fieldId))
            end
            if anyOk then return "PARTIAL" end
            return outcome
        end
    end
    if anyOk then return "OK" end
    return "NOOP"
end

-- ------------------------------------------------------------
-- The field ground check (items 3 and 4)
-- ------------------------------------------------------------

--- Decide once per field per mission what the fine map may do for this field.
--- Runs only on the server, only on an active map, only after the restore
--- barrier. Called as the whole of post-barrier migrateFieldToMap and as the last
--- act of RSF-F245's EMPTY branches. Returns a decision tag (for diagnostics and
--- the bench) or nil when it did not run.
---@return string|nil decision
function SoilMoistureSystem:_checkFieldGround(fieldId)
    -- Explicit guards: the check never relies on its caller's server block.
    if g_server == nil then return nil end
    if not self:mapActive() then return nil end
    if not self:_missionWaterReady() then return nil end
    self._groundChecked = self._groundChecked or {}
    if self._groundChecked[fieldId] == true then return "ALREADY_CHECKED" end
    local d = self.fieldData[fieldId]
    if d == nil then return nil end

    -- Geometry fence: a refused or partial outline gets no probe, no decision and
    -- no flag. Only the retry doors walk it again.
    local polys = self:_getFieldPolygons(fieldId)
    local entry = self._fieldVerts[fieldId]
    if polys == nil or entry == nil or entry.partial == true then
        return "GEOMETRY_NOT_COMPLETE"
    end

    local probe = self:_parcelHasWrittenPixels(fieldId)
    if probe == "INVALID_FIELD_GEOMETRY" then return "GEOMETRY_NOT_COMPLETE" end
    if probe == "PROVIDER_REFUSAL" then
        self:_failNativeClosed("parcel probe refusal")
        return "PROBE_REFUSAL"
    end
    if probe == "UNPROVEN" then
        self._mapSeeded[fieldId] = true
        self._groundChecked[fieldId] = true
        return "PRESERVE_UNPROVEN"
    end

    local restoreRows = self._restoreRows or {}
    local restored = self._restoredMoisture or {}
    if restoreRows[fieldId] ~= nil then
        if probe == "PRESENT" then
            -- An ordinary restored field: its number comes only from the refresh.
            self._mapSeeded[fieldId] = true
            self._groundChecked[fieldId] = true
            restored[fieldId] = nil
            return "PRESERVE_RESTORED"
        end
        local entryR = restored[fieldId]
        if entryR == nil then
            -- The entry was already used: no number is invented.
            self._groundChecked[fieldId] = true
            return "BLANK_NO_ENTRY"
        end
        return self:_seedFieldGround(fieldId, d, entryR.value, entryR.kind)
    end

    if probe == "PRESENT" then
        self._groundChecked[fieldId] = true
        restored[fieldId] = nil
        if self._mapSeeded[fieldId] == true then
            -- Seeded earlier this mission (the barrier's fresh seed, or a reopened
            -- check whose outline still holds pixels): slot and state untouched.
            return "PRESERVE_SEEDED_EARLIER"
        end
        -- Renumbered or recycled ground: keep the pixels, never borrow an ignored
        -- old row, and read the field from what is really there.
        self._mapSeeded[fieldId] = true
        self:_markAggregateUnavailable(d, "NO_CURRENT_VALUE")
        return "PRESERVE_RENUMBERED"
    end

    -- No saved row, no written pixel.
    if self._mapSeeded[fieldId] == true then
        self._groundChecked[fieldId] = true
        restored[fieldId] = nil
        self:_markAggregateUnavailable(d, "NO_CURRENT_VALUE")
        return "BLANK_SEEDED_EARLIER"
    end
    return self:_seedFieldGround(fieldId, d, self:_seedBase(d), "NEW")
end

--- The seed (item 4). kind is SAVED, FRESH_START or NEW. Requires a recorded
--- current carrier on a TRUTH provider; a would-be seed without one paints
--- nothing, sets _groundChecked and logs once.
---@return string decision
function SoilMoistureSystem:_seedFieldGround(fieldId, d, base, kind)
    local restored = self._restoredMoisture or {}
    if self._carrierRecord == nil or self.providerMode ~= "TRUTH" then
        self._groundChecked[fieldId] = true
        self:_logOnce(fieldId, "carrier-unproven", string.format(
            "Moisture: field %d not seeded: carrier not proven current", fieldId))
        return "SEED_REFUSED_CARRIER"
    end
    if base == nil then
        self._groundChecked[fieldId] = true
        restored[fieldId] = nil
        self:_markAggregateUnavailable(d, "NO_CURRENT_VALUE")
        return "SEED_NO_BASE"
    end

    local fill = self:_fillParcelUnwritten(fieldId, base)
    if fill == "OK" then
        self._mapSeeded[fieldId] = true
        self._groundChecked[fieldId] = true
        restored[fieldId] = nil
        self:_advanceMoistureRevision()
        d.aggregateDirty = true
        if kind == "FRESH_START" then
            groundLog(string.format(
                "Moisture: field %d fresh start at its start value %.2f (its saved row carried no number)",
                fieldId, base))
        end
        -- Publish only what reads back, never the value it meant to paint.
        self:_refreshFieldAggregate(fieldId, d)
        return "SEEDED"
    elseif fill == "NOOP" then
        self._mapSeeded[fieldId] = true
        self._groundChecked[fieldId] = true
        return "SEED_NOOP_PRESERVED"
    elseif fill == "PARTIAL" then
        self:_advanceMoistureRevision()
        d.aggregateDirty = true
        self:_failNativeClosed("partial parcel seed")
        return "SEED_PARTIAL"
    end
    self:_failNativeClosed("parcel seed refusal")
    return "SEED_REFUSAL"
end

-- ------------------------------------------------------------
-- Member anchor (item 8)
-- ------------------------------------------------------------

--- A world point inside the field's outline for the two display-centre irrigation
--- calls: the display centre when it is a member, else the first member midpoint
--- between vertex i and vertex i+2 (wrapping) over the collection in order, else
--- nil. Cached beside the geometry entry and dropped with it.
---@return number|nil x, number|nil z
function SoilMoistureSystem:_memberAnchor(fieldId)
    local d = self.fieldData[fieldId]
    if d == nil then return nil, nil end
    local polys = self:_getFieldPolygons(fieldId)
    local entry = self._fieldVerts[fieldId]
    if polys == nil or entry == nil then return nil, nil end
    if entry.anchorResolved == true then return entry.anchorX, entry.anchorZ end
    local ax, az = nil, nil
    if type(d.centerX) == "number" and type(d.centerZ) == "number"
       and self:_pointInParcel(fieldId, d.centerX, d.centerZ) then
        ax, az = d.centerX, d.centerZ
    else
        for pi = 1, #polys do
            local p = polys[pi]
            for i = 1, p.n do
                local j = ((i + 1) % p.n) + 1
                local mx = (p.vx[i] + p.vx[j]) * 0.5
                local mz = (p.vz[i] + p.vz[j]) * 0.5
                if self:_pointInParcel(fieldId, mx, mz) then
                    ax, az = mx, mz
                    break
                end
            end
            if ax ~= nil then break end
        end
    end
    entry.anchorResolved = true
    entry.anchorX = ax
    entry.anchorZ = az
    return ax, az
end
