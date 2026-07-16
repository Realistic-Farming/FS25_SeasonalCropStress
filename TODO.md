# TODO: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Strip PrecisionFarmingOverlay.lua: DONE. The PF overlay/integration was removed wholesale (commit 77b3064); zero `PrecisionFarming` references remain in any .lua (verified 2026-07-15). Zero-PF house rule satisfied.
- [x] "Remove the FSBaseMission.draw hook that calls the no-op HUD stub": closed as WRONG PREMISE. main.lua:246 `FSBaseMission.draw` drives the REAL moisture HUD (`CropStressManager:draw` -> `HUDOverlay`), not a no-op stub. Keep the hook.
- [x] Companion read API façade (B3.2): DONE. Formal `CropStressManager:getMoisture`/`:getStress` added + readers migrated (83aef10). B3.3 (remove the `soilMoistureSystem = soilSystem` alias) is BLOCKED, see Blocked section: FarmTablet still reads the alias as its primary moisture source, so it stays until FarmTablet migrates to the facade.

## Bugs
- [x] CRITICAL (house rule): PF integration mode active on detection - RESOLVED. No PF code path remains after 77b3064; nothing left to stand down.

## Features / enhancements
- [x] Bedrock migration per Point 1-4: all four now BUILT. SettingsHub was already live; StateLedger + NetworkSync + MasterHUD (B3.4) were built this session against the SoilFertilizer reference, delegate-when-present. Not shipped until the SCS module-ids are locked with Claude(A) + a single-host in-game smoke passes.

## Cross-mod integration
- [x] StateLedger / NetworkSync / MasterHUD bridges - BUILT (`src/integrations/CropStress*Bridge.lua`) against the SoilFertilizer reference, delegate-when-present, each mission-bound (`g_currentMission.<handle>`). New self-test harness added (`tools/test/`, mirrors SF): Lua 5.1 syntax + NetworkSync + StateLedger round-trip tests (38 assertions green). SF's own ids are locked (`SoilFertilizer_Soil`/`_Sync`, ledger 46d1afe); SCS registers its OWN ids - `SeasonalCropStress_State` (StateLedger), `SeasonalCropStress_Sync` (NetworkSync), `SCS_StressOverlay` (MasterHUD) - proposed to Claude(A) for lock before release.
- Carry forward two verified contracts (do not regress): coverage detection uses the real field polygon, never a label-point box; `system.coveredFields` is an ARRAY of farmland ids - consumers must `ipairs` it.
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional external FS25_MoistureSystem.
- [ ] Read by CropDisease (moisture), RandomWorldEvents (stress), MarketDynamics, FarmTablet.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] `soilMoistureSystem` alias removal (B3.3): read-path confirmed, there IS an active consumer. FarmTablet `IncomeApp.lua:345` reads `mgr.soilMoistureSystem` as its PRIMARY moisture source (duck-typed `:getMoisture` fallback at :412), not the formal facade. So the alias stays until FarmTablet's IncomeApp is migrated to `mgr:getMoisture`/`:getStress` (a FarmTablet-repo change + its own in-game verify). Alias kept meanwhile (harmless one-liner).
- [!] Before RELEASE, the 3 bedrock bridges (B3.4, now built) need: SCS module-ids locked with Claude(A) + a single-host in-game smoke (the reframed MP gate).
