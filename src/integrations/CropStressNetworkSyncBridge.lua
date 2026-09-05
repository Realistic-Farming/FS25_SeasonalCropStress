-- =========================================================
-- FS25 Seasonal Crop Stress - NetworkSync bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_NetworkSync (bedrock mod 2). SeasonalCropStress ships
-- standalone, so this is strictly delegate-when-present:
--   * NetworkSync installed -> the ongoing hourly moisture/stress broadcast is
--     folded into NetworkSync's single 1Hz whole-field-map batch instead of a
--     per-hour CropStressMoistureInitEvent.
--   * NetworkSync absent     -> nothing changes; the hourly broadcast fires as
--     before.
--
-- WHAT WE DELEGATE, AND WHAT WE DO NOT:
--   * Delegated: the ongoing per-hour moisture/stress push (onHourlyTick). When
--     the bridge is active that site calls markFieldDirty() instead of
--     broadcasting; NetworkSync reserializes the whole field map on the next 1Hz
--     tick and broadcasts it once.
--   * NOT delegated: the join full-sync (sendInitialClientState sends settings
--     via CropStressSettingsSyncEvent + the field snapshot via
--     CropStressMoistureInitEvent). That path stays live as the join guarantee.
--     Settings are SettingsHub's domain, not NetworkSync's, so they are untouched
--     here.
--
-- The wire payload mirrors CropStressMoistureInitEvent exactly: per field the
-- fieldId plus moisture and stress. No soilType on the wire (clients keep their
-- own, corrected by enumerateFields), matching the event's run().
--
-- The cross-mod handle is g_currentMission.networkSync (the bare g_networkSync
-- global is only visible inside NetworkSync's own mod environment). Registration
-- is order-independent.
-- =========================================================

CropStressNetworkSyncBridge = CropStressNetworkSyncBridge or {}

-- Provisional module id. This is the network CHANNEL and the join-snapshot key, so
-- it must be locked with Claude(A) before release (a later rename desyncs a mixed
-- lobby). Follows the locked <Mod>_<Thing> convention shared with StateLedger.
CropStressNetworkSyncBridge.MODULE_ID = "SeasonalCropStress_Sync"
CropStressNetworkSyncBridge.CHANNEL   = "SeasonalCropStress_Sync"

CropStressNetworkSyncBridge.active = false   -- NetworkSync present and we registered

local function clamp01(v)
    v = tonumber(v) or 0
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Resolve the manager from the canonical global (visible inside our own mod env),
-- with the mission handle as a fallback.
local function getManager()
    return g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
end

-- =========================================================
-- Pure serialize / deserialize (server writes, client reads)
-- =========================================================

-- Flatten moisture/stress into one primitive array (the shape NetworkSync expects).
-- arr[1] = field count, then per field: fieldId, moisture, stress.
function CropStressNetworkSyncBridge.serializeFields(fieldData, fieldStress)
    local arr = { 0 }   -- slot 1 reserved for the count
    local n = 0
    for fieldId, entry in pairs(fieldData or {}) do
        n = n + 1
        arr[#arr + 1] = fieldId
        arr[#arr + 1] = (entry and entry.moisture) or 0.0
        arr[#arr + 1] = (fieldStress and fieldStress[fieldId]) or 0.0
    end
    arr[1] = n
    return arr
end

-- Rebuild moisture + stress maps from the flat array. Pure: no live apply. Never
-- crashes on a short or malformed array.
function CropStressNetworkSyncBridge.deserializeFields(arr)
    local fieldData   = {}
    local fieldStress = {}
    if type(arr) ~= "table" then return fieldData, fieldStress end

    local i = 1
    local count = tonumber(arr[i]) or 0
    i = i + 1

    for _ = 1, count do
        local fieldId = arr[i]; i = i + 1
        if fieldId == nil then break end
        local moisture = clamp01(arr[i]); i = i + 1
        local stress   = clamp01(arr[i]); i = i + 1
        fieldData[fieldId]   = { moisture = moisture }
        fieldStress[fieldId] = stress
    end
    return fieldData, fieldStress
end

-- =========================================================
-- NetworkSync callbacks (plain functions - called with no self)
-- =========================================================

-- Server: hand NetworkSync the whole moisture/stress map for the next batch.
function CropStressNetworkSyncBridge._onWriteState()
    local mgr = getManager()
    local soilSystem     = mgr and mgr.soilSystem
    local stressModifier = mgr and mgr.stressModifier
    return CropStressNetworkSyncBridge.serializeFields(
        soilSystem and soilSystem.fieldData or {},
        stressModifier and stressModifier.fieldStress or {}
    )
end

-- Client: apply a received whole moisture/stress map. Mirrors
-- CropStressMoistureInitEvent:run - update existing moisture, create a minimal
-- entry for a not-yet-enumerated field, set stress, then rebuild the field map.
-- SCS-039 v2.1 (SDS 3.8): the NetworkSync aggregate may update legacy scalars
-- only while the SCS fine map is NOT the current authority. Once the SCS event
-- barrier has published a current fine map (isMoistureMapCurrent), the mirror
-- must not fight it; it can never seed fine staging or claim fine currentness.
function CropStressNetworkSyncBridge._onReadState(arr)
    if g_server ~= nil then return end   -- server never applies its own state

    local mgr = getManager()
    if mgr == nil or mgr.soilSystem == nil or mgr.stressModifier == nil then return end
    if mgr.soilSystem.isMoistureMapCurrent ~= nil and mgr.soilSystem:isMoistureMapCurrent() then
        return   -- a current SCS fine map owns the ground; the mirror stands down
    end

    local fieldData, fieldStress = CropStressNetworkSyncBridge.deserializeFields(arr)

    for fieldId, entry in pairs(fieldData) do
        local existing = mgr.soilSystem.fieldData[fieldId]
        if existing ~= nil then
            existing.moisture = entry.moisture
        else
            -- [SCS-036] NO soilType key: an absent key is detectable and the
            -- backfill (enumerateFields) repairs it on the next rebuild. The
            -- old "loamy" placeholder was the same string as a real answer, so
            -- no code could tell them apart. The hourly loop already lands
            -- missing classes on loam, so the join window behaves identically
            -- to today and the first rebuild makes the value right.
            mgr.soilSystem.fieldData[fieldId] = { moisture = entry.moisture }
        end
        mgr.stressModifier.fieldStress[fieldId] = fieldStress[fieldId] or 0.0
    end

    -- Rebuild field map only when fields are ready; on MP join the field manager
    -- may not yet be populated. The field-ready updater handles initial enumeration.
    -- BUILD 19:47: same shape as the init event. State above is applied every time; the
    -- map walk is the part that waits for the player to be in.
    if g_currentMission ~= nil and g_currentMission.isMissionStarted == true
        and mgr.buildFieldMap ~= nil and g_fieldManager ~= nil and g_fieldManager.fields ~= nil then
        mgr:buildFieldMap()
    end
end

-- =========================================================
-- Public: flag the module dirty for the next 1Hz batch.
-- =========================================================
-- Called at the hourly broadcast site when the bridge is active. Per-hour
-- granularity collapses to "the field map changed"; NetworkSync reserializes the
-- whole map once on the next tick. No-op when not active.
function CropStressNetworkSyncBridge.markFieldDirty()
    if not CropStressNetworkSyncBridge.active then return end
    local ns = (g_currentMission and g_currentMission.networkSync) or g_networkSync
    if ns ~= nil then ns:markDirty(CropStressNetworkSyncBridge.MODULE_ID) end
end

-- =========================================================
-- Registration (loadMission00Finished)
-- =========================================================
function CropStressNetworkSyncBridge.register(mgr)
    -- Reset per-load so a map swap / reload starts clean.
    CropStressNetworkSyncBridge.active = false

    local ns = (g_currentMission and g_currentMission.networkSync) or g_networkSync
    if ns == nil then
        print("[CropStress] NetworkSync not detected; MP moisture sync uses its own event classes")
        return
    end

    -- SCS-039 v2.1 (SDS 3.8): the bridge is active only when the outer pcall
    -- succeeds AND registerModule returns EXACTLY true. A non-throwing nil/false
    -- return was previously misread as an active registration.
    local registered = false
    local ok, err = pcall(function()
        registered = ns:registerModule(CropStressNetworkSyncBridge.MODULE_ID, {
            channel      = CropStressNetworkSyncBridge.CHANNEL,
            onWriteState = CropStressNetworkSyncBridge._onWriteState,
            onReadState  = CropStressNetworkSyncBridge._onReadState,
        })
    end)

    if ok and registered == true then
        CropStressNetworkSyncBridge.active = true
        print(string.format("[CropStress] Registered with NetworkSync as '%s' (hourly moisture broadcast now batches through NetworkSync)",
            CropStressNetworkSyncBridge.MODULE_ID))
    else
        CropStressNetworkSyncBridge.active = false
        print(string.format("[CropStress] NetworkSync registration failed or refused: %s (falling back to moisture event class)",
            tostring(err)))
    end
end
