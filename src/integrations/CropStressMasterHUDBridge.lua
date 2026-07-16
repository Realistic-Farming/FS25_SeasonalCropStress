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

CropStressMasterHUDBridge = {}

-- Full-token id per the ecosystem NAMING-CONVENTION (client-local, re-registered
-- each session, not a save/wire lock key). Confirmed with Claude(A) 2026-07-16.
CropStressMasterHUDBridge.HUD_ID = "SeasonalCropStress_StressOverlay"
CropStressMasterHUDBridge.active = false   -- MasterHUD present and we registered

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
    else
        print(string.format("[CropStress] MasterHUD registration failed: %s (using own draw hook)", tostring(err)))
    end
end
