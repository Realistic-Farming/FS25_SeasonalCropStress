# Roadmap: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v1.2.0.0
- Audit reference: ecosystem-dev-tracking Point 1-6 (FS25_SeasonalCropStress, 2026-06-30)
- Baseline date: 2026-06-30

## Near-term (next release cycle)
- [x] Witcombe join load-gates (3969c44): buildFieldMap deferred until post-join in MP moisture init event and NetworkSync bridge, preventing empty field map on client join. Pushed 2026-07-28.
- [x] Strip the Precision Farming overlay: DONE. Removed wholesale in 77b3064; zero PF refs remain in any .lua (verified 2026-07-15).
- [x] "Remove the FSBaseMission.draw hook": closed as wrong premise - the draw hook drives the real moisture HUD, not a no-op stub. Kept.
- [x] Companion read API façade on `cropStressManager` (getMoisture / getStress) for CropDisease and RandomWorldEvents (B3.2): DONE (83aef10).
- [x] Widen the façade (B3.2b): DONE. Added read-only, nil/neutral-safe getters for the irrigation-ops + economy consumers (SCS-006/007/008/009/011/012/015/016): `getIrrigationRate`, `isFieldIrrigated`, `getIrrigationSystems` (mutation-safe snapshot; preserves the coveredFields ipairs-array contract), `getIrrigationSchedule` (active systems only), `getFieldPolygonWorld`, `getCriticalAlertHint`, plus the heat pair `getTemperature` / `getEvaporativeDemand`. Each delegates to an existing subsystem method (no new tracking). Heat-fold call SETTLED: `getStress` stays a moisture-drought scalar only (folds no temperature); SCS-010 (market heat) and SCS-013 (livestock heat) read the heat pair instead. Covered by `tools/test/facade_readapi_test.lua` (35 assertions).
- [x] `getIrrigationCostsEnabled` getter (212ceaa): first B3.2b consumer live. TaxMod's SCS-011 mirror reads it to book irrigation operating cost as a deductible expense (in-game verified).
- [x] Short-month weather tune (e6a4fce): `SEASON_RAIN_PROB` reshaped to SoilFertilizer's Normal climate shape so SCS moisture and SF's #740 short-month rain fill agree on seasonality. Shape-matched, with a day-vs-hour unit gap flagged for a later retune.

## Mid-term (this season)
- [x] StateLedger, NetworkSync, MasterHUD migration (Point 1-4) (B3.4): BUILT (cda747b) against the SoilFertilizer reference, delegate-when-present, with a new self-test harness (round-trip tests, 38 assertions green). SettingsHub was already built. Module ids LOCKED by Claude(A) 2026-07-16 (ledger fab67d6): `SeasonalCropStress_State` (SCHEMA 1) + `SeasonalCropStress_Sync`; the client-local HUD id was renamed to the full-token `SeasonalCropStress_StressOverlay` for naming-convention consistency (was `SCS_StressOverlay`). Release gate now reduces to a single-host in-game smoke (the reframed MP gate). Not merged, not released.
- [!] Remove the internal `soilMoistureSystem = soilSystem` alias (B3.3): confirmed FarmTablet `IncomeApp.lua:345` still reads it as its primary moisture source, so migrate FarmTablet to the facade first, then remove. Alias kept meanwhile.

## Long-term / aspirational
- [ ] Deeper stress model (crop-specific tolerances, recovery curves) as part of the rebuild with the new assets.
- [ ] Irrigation help dialog (issue #89): in-game guidance for irrigation setup once Antler22's 3D assets ship. Design decision needed: dedicated help dialog vs existing documentation. See ecosystem ledger 2026-07-26.

## Cross-mod / ecosystem dependencies
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional FS25_MoistureSystem (external).
- [ ] Read by CropDisease, RandomWorldEvents, MarketDynamics, FarmTablet.
- [ ] All four bedrock migrations (blocks on: StateLedger, NetworkSync, MasterHUD, SettingsHub).

## Deferred / parked
- Any Precision Farming compatibility: never. Detect-to-stand-down only.
