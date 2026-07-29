# TODO: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Strip PrecisionFarmingOverlay.lua: DONE. The PF overlay/integration was removed wholesale (commit 77b3064); zero `PrecisionFarming` references remain in any .lua (verified 2026-07-15). Zero-PF house rule satisfied.
- [x] "Remove the FSBaseMission.draw hook that calls the no-op HUD stub": closed as WRONG PREMISE. main.lua:246 `FSBaseMission.draw` drives the REAL moisture HUD (`CropStressManager:draw` -> `HUDOverlay`), not a no-op stub. Keep the hook.
- [x] Façade WIDENING (B3.2b): DONE. Read-only, nil/neutral-safe getters for the irrigation-ops + economy consumers: `getIrrigationRate`, `isFieldIrrigated`, `getIrrigationSystems` (mutation-safe snapshot, keeps the coveredFields ipairs contract), `getIrrigationSchedule` (active systems only), `getFieldPolygonWorld`, `getCriticalAlertHint`, `getTemperature`, `getEvaporativeDemand`. All delegate to existing subsystem methods; CropConsultant migrated onto the alert-hint getter. Heat-fold SETTLED: `getStress` is moisture-only, SCS-010/013 read the heat pair. Test: `tools/test/facade_readapi_test.lua` (35 assertions).
- [x] Companion read API façade (B3.2): DONE. Formal `CropStressManager:getMoisture`/`:getStress` added + readers migrated (83aef10). B3.3 (remove the `soilMoistureSystem = soilSystem` alias) is BLOCKED, see Blocked section: FarmTablet still reads the alias as its primary moisture source, so it stays until FarmTablet migrates to the facade.
- [x] `getIrrigationCostsEnabled` getter (212ceaa): a nil-safe read of the irrigation-costs-enabled flag, added to the facade for TaxMod's SCS-011 deductible-expense mirror (the first B3.2b consumer, in-game verified).

## Bugs
- [x] Witcombe join load-gates: buildFieldMap called before g_fieldManager.fields populated on MP join, producing empty field map. Added field-readiness guards in CropStressMoistureInitEvent:run() and CropStressNetworkSyncBridge._onReadState(). Commit 3969c44, pushed 2026-07-28.
- [x] CRITICAL (house rule): PF integration mode active on detection - RESOLVED. No PF code path remains after 77b3064; nothing left to stand down.
- [x] SCS-001: created overlay handle in `initialize()`, replaced bare `drawFilledRect` calls (fixed, merged to main).
- [x] SCS-002 / SCS-003: additional SeasonalCropStress bugs fixed in 2026-07-26 bug sweep, merged to main.

## Features / enhancements
- [x] Short-month weather tune (e6a4fce): `SEASON_RAIN_PROB` reshaped to match SoilFertilizer's Normal climate shape, so SCS moisture and SF's #740 short-month rain fill agree on wet/dry seasonality. Shape-matched, not a raw copy (a day-vs-hour unit gap remains for a later retune with Arissani).
- [x] Bedrock migration per Point 1-4: all four now BUILT. SettingsHub was already live; StateLedger + NetworkSync + MasterHUD (B3.4) were built this session against the SoilFertilizer reference, delegate-when-present. Not shipped until the SCS module-ids are locked with Claude(A) + a single-host in-game smoke passes.

## Cross-mod integration
- [x] StateLedger / NetworkSync / MasterHUD bridges - BUILT (`src/integrations/CropStress*Bridge.lua`) against the SoilFertilizer reference, delegate-when-present, each mission-bound (`g_currentMission.<handle>`). New self-test harness added (`tools/test/`, mirrors SF): Lua 5.1 syntax + NetworkSync + StateLedger round-trip tests (38 assertions green). SCS module ids LOCKED by Claude(A) 2026-07-16 (ledger fab67d6): `SeasonalCropStress_State` (SCHEMA 1) + `SeasonalCropStress_Sync`; the client-local HUD id was renamed to the full-token `SeasonalCropStress_StressOverlay` for naming-convention consistency (was `SCS_StressOverlay`).
- Carry forward two verified contracts (do not regress): coverage detection uses the real field polygon, never a label-point box; `system.coveredFields` is an ARRAY of farmland ids - consumers must `ipairs` it.
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional external FS25_MoistureSystem.
- [ ] Read by CropDisease (moisture), RandomWorldEvents (stress), MarketDynamics, FarmTablet.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] `soilMoistureSystem` alias removal (B3.3): read-path confirmed, there IS an active consumer. FarmTablet `IncomeApp.lua:345` reads `mgr.soilMoistureSystem` as its PRIMARY moisture source (duck-typed `:getMoisture` fallback at :412), not the formal facade. So the alias stays until FarmTablet's IncomeApp is migrated to `mgr:getMoisture`/`:getStress` (a FarmTablet-repo change + its own in-game verify). Alias kept meanwhile (harmless one-liner).
- [~] Before RELEASE, the 3 bedrock bridges (B3.4): module-ids now LOCKED (fab67d6), so the gate reduces to a single-host in-game smoke (the reframed MP gate). Not merged, not released.
