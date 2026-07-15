# TODO: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Strip PrecisionFarmingOverlay.lua: DONE. The PF overlay/integration was removed wholesale (commit 77b3064); zero `PrecisionFarming` references remain in any .lua (verified 2026-07-15). Zero-PF house rule satisfied.
- [x] "Remove the FSBaseMission.draw hook that calls the no-op HUD stub": closed as WRONG PREMISE. main.lua:246 `FSBaseMission.draw` drives the REAL moisture HUD (`CropStressManager:draw` -> `HUDOverlay`), not a no-op stub. Keep the hook.
- [~] Companion read API: getMoisture/getStress already exist on the subsystems (`SoilMoistureSystem:getMoisture`, `CropStressModifier:getStress`). Still open: a formal façade on `cropStressManager` (B3.2) and removing the `soilMoistureSystem = soilSystem` alias after confirming FarmTablet's read path (B3.3).

## Bugs
- [x] CRITICAL (house rule): PF integration mode active on detection - RESOLVED. No PF code path remains after 77b3064; nothing left to stand down.

## Features / enhancements
- [~] Bedrock migration per Point 1-4: SettingsHub built. StateLedger / NetworkSync / MasterHUD are the #89 rebuild's main remaining work (B3.4), gated on locking the SF module ids (`SoilFertilizer_Soil` / `SoilFertilizer_Sync`) with Claude(A) first.

## Cross-mod integration
- [~] StateLedger / NetworkSync / MasterHUD bridges - the #89 rebuild is GO (2026-07-15) and underway. SettingsHub already built. Build the 3 against the SoilFertilizer reference pattern with a per-bridge network round-trip test (SF mock-stream harness). Gated on locking the SF module ids with Claude(A) before they ship as persistence/wire keys.
- Carry forward two verified contracts (do not regress): coverage detection uses the real field polygon, never a label-point box; `system.coveredFields` is an ARRAY of farmland ids - consumers must `ipairs` it.
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional external FS25_MoistureSystem.
- [ ] Read by CropDisease (moisture), RandomWorldEvents (stress), MarketDynamics, FarmTablet.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] `soilMoistureSystem` alias removal (B3.3) waits on A-side confirming FarmTablet's read path (alias vs the new façade).
- [!] The 3 bedrock bridges (B3.4) wait on the SF module-id lock with Claude(A).
