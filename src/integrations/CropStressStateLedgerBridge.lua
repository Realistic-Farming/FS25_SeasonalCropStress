-- =========================================================
-- FS25 Seasonal Crop Stress - StateLedger bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_StateLedger. SeasonalCropStress ships standalone, so
-- this is strictly delegate-when-present:
--   * StateLedger installed  -> the master save file is the LOAD source of truth
--     (careerSavegame.xml is still written every save as a safety copy, so
--     removing the ledger later never loses moisture / stress / irrigation data).
--   * StateLedger absent     -> nothing changes; careerSavegame.xml is primary.
--
-- On the first load after installing the ledger onto an existing save, the ledger
-- has no crop-stress block yet (deserialize delivers nil), so loadFromXMLFile
-- falls back to importing the existing careerSavegame.xml. From then on the ledger
-- carries the state.
--
-- The cross-mod handle is g_currentMission.stateLedger (the bare g_stateLedger
-- global is only visible inside StateLedger's own mod environment). Registration
-- is order-independent: StateLedger delivers our deserialize exactly once, whether
-- we register before or after it parses the master file. SCS reads ledger state in
-- Mission00.onStartMission (and the field-ready updater), both later than the
-- loadMission00Finished registration, so deserialize has fired by read time (the
-- same phase ordering SoilFertilizer's bridge relies on).
--
-- Settings do NOT live here: they go to SettingsHub (SeasonalSettingsHubBridge),
-- with cropStressSettings.xml as their own sidecar fallback.
-- =========================================================

CropStressStateLedgerBridge = {}

-- Provisional module id. This is the persistence KEY inside the master file, so it
-- must be locked with Claude(A) before any release (a later rename orphans saved
-- crop-stress data). Follows the locked <Mod>_<Thing> convention, matching the
-- StateLedger build brief (SeasonalCropStress_State).
CropStressStateLedgerBridge.MODULE_ID = "SeasonalCropStress_State"
CropStressStateLedgerBridge.SCHEMA    = 1

CropStressStateLedgerBridge.active       = false   -- ledger present and we registered
CropStressStateLedgerBridge.delivered    = false   -- deserialize has fired (once)
CropStressStateLedgerBridge.pendingState = nil     -- cached table from deserialize (nil = new/no block)

-- Compose the full crop-stress state via the persistence handler's table
-- serializer. Mirrors exactly what saveToXMLFile writes into careerSavegame.xml.
function CropStressStateLedgerBridge.buildState(mgr)
    local out = { schema = CropStressStateLedgerBridge.SCHEMA }
    if mgr ~= nil and mgr.saveLoad ~= nil and mgr.saveLoad.buildStateTable ~= nil then
        out.state = mgr.saveLoad:buildStateTable()
    end
    return out
end

-- Apply the cached ledger state into the manager. Returns true if a real block was
-- applied, false when there is nothing to apply (new save / no block yet).
function CropStressStateLedgerBridge.applyState(mgr)
    local data = CropStressStateLedgerBridge.pendingState
    if type(data) ~= "table" or mgr == nil then return false end
    if mgr.saveLoad == nil or mgr.saveLoad.applyStateTable == nil then return false end
    return mgr.saveLoad:applyStateTable(data.state)
end

-- True when the ledger is the source of truth for this load (present, registered,
-- and it delivered an actual block). When present but empty, loadFromXMLFile
-- imports the existing careerSavegame.xml instead.
function CropStressStateLedgerBridge.hasLedgerState()
    return CropStressStateLedgerBridge.active
        and CropStressStateLedgerBridge.delivered
        and CropStressStateLedgerBridge.pendingState ~= nil
        and CropStressStateLedgerBridge.pendingState.state ~= nil
end

-- Register with StateLedger if present. Called at loadMission00Finished, after the
-- ledger has published its g_currentMission handle (Mission00.load).
function CropStressStateLedgerBridge.register(mgr)
    -- Reset per-load so a map swap / reload starts clean.
    CropStressStateLedgerBridge.active       = false
    CropStressStateLedgerBridge.delivered    = false
    CropStressStateLedgerBridge.pendingState = nil

    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then
        print("[CropStress] StateLedger not detected; crop-stress data uses its own careerSavegame.xml")
        return
    end
    if mgr == nil then return end

    local ok, err = pcall(function()
        ledger:registerModule(CropStressStateLedgerBridge.MODULE_ID, {
            serialize = function()
                return CropStressStateLedgerBridge.buildState(mgr)
            end,
            deserialize = function(data)
                CropStressStateLedgerBridge.delivered    = true
                CropStressStateLedgerBridge.pendingState = data   -- nil on a brand-new save
            end,
        })
    end)

    if ok then
        CropStressStateLedgerBridge.active = true
        print(string.format("[CropStress] Registered with StateLedger as '%s' (careerSavegame.xml kept as safety copy)",
            CropStressStateLedgerBridge.MODULE_ID))
    else
        print(string.format("[CropStress] StateLedger registration failed: %s (falling back to careerSavegame.xml)", tostring(err)))
    end
end
