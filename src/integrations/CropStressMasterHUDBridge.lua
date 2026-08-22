-- =========================================================
-- FS25 Seasonal Crop Stress - MasterHUD bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_MasterHUD. SeasonalCropStress ships standalone, so this
-- is delegate-when-present:
--   * MasterHUD installed -> SCS registers its whole HUD draw (the moisture/stress
--     overlay + the settings panel) as a self-draw. MasterHUD then owns the single
--     draw loop, the menu/dialog suspend, and cross-mod ordering, so SCS's HUD
--     stacks cleanly with the rest of the ecosystem instead of hooking
--     FSBaseMission.draw independently.
--   * MasterHUD absent -> SCS's own FSBaseMission.draw hook runs the exact same
--     draw, exactly as before.
--
-- subscribe() is MasterHUD's path for self-drawn content: the element draws its own
-- positioned content, MasterHUD only owns ordering + suspend. drawStack() is the
-- single source of the draw body (it delegates to CropStressManager:draw), shared
-- with the fallback hook so the two paths can never diverge.
-- =========================================================

-- BUILD 19:38: reload-safe like the HUD classes - the table AND the active flag
-- survive Ctrl+R, or the hot-reload delivery block at the end could never fire.
CropStressMasterHUDBridge = CropStressMasterHUDBridge or {}

-- Full-token id per the ecosystem NAMING-CONVENTION (client-local, re-registered
-- each session, not a save/wire lock key). Confirmed with Claude(A) 2026-07-16.
CropStressMasterHUDBridge.HUD_ID = "SeasonalCropStress_StressOverlay"
CropStressMasterHUDBridge.active = CropStressMasterHUDBridge.active or false   -- survives reload; register() re-derives it

-- The full SCS HUD draw. Delegates to the manager's own draw() (settings panel +
-- moisture/stress overlay, with the same enabled-gating), so the MasterHUD path and
-- the fallback FSBaseMission.draw hook run byte-for-byte the same body.
function CropStressMasterHUDBridge.drawStack()
    local mgr = g_cropStressManager or (g_currentMission and g_currentMission.cropStressManager)
    if mgr ~= nil and mgr.draw ~= nil then mgr:draw() end
end

-- Register with MasterHUD if present. Called at loadMission00Finished, after the
-- HUD has published its g_currentMission handle (Mission00.load).
function CropStressMasterHUDBridge.register(mgr)
    CropStressMasterHUDBridge.active = false

    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if hud == nil then
        print("[CropStress] MasterHUD not detected; crop-stress HUD uses its own draw hook")
        return
    end

    local ok, err = pcall(function()
        hud:subscribe(CropStressMasterHUDBridge.HUD_ID, {
            draw = CropStressMasterHUDBridge.drawStack,
        })
    end)

    if ok then
        CropStressMasterHUDBridge.active = true
        print("[CropStress] Registered crop-stress HUD with MasterHUD (single draw loop + menu-suspend)")
        -- BUILD 19:38 (Income bridge pattern): suite layout edit reaches the RF
        -- Moisture panel - MasterHUD's edit toggle enters/exits HUDOverlay's own
        -- edit mode (orange border, drag, corners).
        if hud.registerEditListener ~= nil then
            hud:registerEditListener(CropStressMasterHUDBridge.HUD_ID, {
                enter = function()
                    local m = g_cropStressManager
                        or (g_currentMission ~= nil and g_currentMission.cropStressManager or nil)
                    local ho = m ~= nil and m.hudOverlay or nil
                    if ho ~= nil and ho.enterEditMode ~= nil then ho:enterEditMode() end
                end,
                exit = function()
                    local m = g_cropStressManager
                        or (g_currentMission ~= nil and g_currentMission.cropStressManager or nil)
                    local ho = m ~= nil and m.hudOverlay or nil
                    if ho ~= nil and ho.editMode and ho.exitEditMode ~= nil then ho:exitEditMode() end
                end,
            })
        end
    else
        print(string.format("[CropStress] MasterHUD registration failed: %s (using own draw hook)", tostring(err)))
    end
end

-- =========================================================
-- Hot-reload delivery: register() only runs at mission load, so a push of this
-- file alone would define the new edit listener without ever registering it.
-- This top-level block re-runs the registration on reload.
--
-- BUILD 20:04 aftermath: delivery is NOT gated on .active any more. The 20:04
-- wave proved the gate can skip silently - the boot-time bridge on this session
-- predated the edit-listener code, and the gated block left the Moisture panel
-- with no listener on the live MasterHUD table while Fuel and Soil re-registered
-- (their register prints appear in log.txt at 20:05:59/20:06:05, CropStress
-- never printed). register() is idempotent (subscribe and registerEditListener
-- both replace by id), so firing on every live source pass is safe; on a cold
-- source pass the mission handle does not exist yet and this stays a no-op.
local __hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
if __hud ~= nil then
    pcall(function() CropStressMasterHUDBridge.register() end)
end
