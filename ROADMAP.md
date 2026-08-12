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
- [x] SCS-021 drying VPD (2026-08-12): a hot dry wind takes moisture out faster than a hot still muggy day, and the simulation can now tell them apart. WeatherGuard's live humidity (with its honest defaulted flag) feeds a VPD multiplier in the hourly evap term and the moisture forecast; absent real data, drying is today's behaviour bit for bit. STABLE, adds no surface. 31 assertions in SCS-021-drying_vpd_spec_test.lua. PR feat/SCS-021 open.
- [x] Release gate (2026-08-04): wired per Arissani's 2026-08-03 lock set. The #89 rebuild and the moisture coupling LOCK when built (both unbuilt today; the two registry rows are noted as such). F93 ships STABLE, it is a fix not a system. `ReleaseGate.lua` + `experimentalSystems` opt-in (default false, orthogonal to difficulty) through settings/persistence/MP sync/SettingsHub/panel + `csRelease` status command. 145 assertions green.
- [x] F93 temperature fix (2026-08-02): the temperature read was a permanent 15.0. `getTemperatureFromWeather()` probed a nonexistent `weatherSystem` class; it now delegates to WeatherGuard's `getCurrentSky().temperature` first (the certified temperatureUpdater route via the mission bridge), then the certified vanilla `Weather:getCurrentTemperature()`. Heat-driven behaviours were inert while looking healthy; this unblocks them. Covered by `tools/test/lua/weather_temp_f93_test.lua` (8 assertions).
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


## 2026-08-06 (Fred): Esc RF doors + map moisture button restored
- [x] With the RF Esc door live, the legacy menuCropStress Esc page is stood down, which nilled inGameMenu[pageName] and killed the moisture map overlay button (it read the nil page and returned silently).
- [x] The moisture map button works again via the retained-page pattern: stand-down keeps the deep page on CsPDAScreen._retainedDeepScreen, and toggle re-injects it into InGameMenu paging without restoring the Esc tab icon. In-game observation still pending.

## 2026-08-07 (Fred): module page dots always visible
- [x] The Esc RF module selector hid its page dots when Worker Costs or Market Dynamics was the active module. Soil and Crop Stress always showed theirs, so WC never read as the 3rd module and the left panel was inconsistent. All four RfPdaMenuPage copies now keep the dots visible (dots = N, chrome unchanged, per the esc-rf-pda umbrella brief). Built, deployed, PR open.

## 2026-08-08 (Fred): SCS-018 per-cell moisture store (combined spatial-soil drop, head)
- [x] Moisture is now a property of the ground, cell by cell, on the same grid SoilFertilizer uses (10m at 4x, 20m at 8x, 40m at 16x). Cells materialise where relief exceeds the threshold or water is applied; the field scalar stays the derived aggregate. Single write path, packed persistence (StateLedger SCHEMA 2 + XML), daily settle via the TimeGuard `simulation` flow class with a day-hook fallback, per-cell pivot/drip/sprayer water, Irrigate Now server-routed, and the RealisticWeather moisture unwind (RW stays a weather source only). Three offline benches green (relief sparsity, drainage conservation, real-scheduler catch-up). In-game observation owed (acceptance checks in the brief).

## 2026-08-08 (Fred): SCS-018 positional read facade fixed
- [x] The SCS-018 contract claimed getMoisture(fieldId, x, z) shipped, but the CropStressManager facade forwarded only fieldId, so SF-18's positional reads degraded to the field aggregate. SoilMoistureSystem already had the positional getter; the facade now forwards x, z. One-arg callers unchanged. Suite 162/0 across 9 files. Built and deployed. The SF-18 keystone (FS25_SoilFertilizer) consumes the positional read.


## 2026-08-10 (Fred): SCS-037 round 2 is live - the rain switch across a skip
- [x] The Water Record delegate exists now (SF PR #811), so getSkipRainHours binds to g_currentMission.soilFertilityManager:getWaterDaysInLast per SoilFertilizer's own cross-boundary rule, instead of the three-field-deep path it refused to take. Round 2 reconstructs rain-bearing hours across a skipped span from SF-49's per-day verdicts: 72 hours with 2 of 3 recorded days wet yields 48 rain hours, and the daily settle stays on its own clock per the one-clock rule. The nil paths are kept on purpose, they are still the honest answer when the record is absent or the gate is closed.
- [x] The stale "IT IS INERT TODAY" comment block in CropStressManager.lua and the matching "inertness guard" framing in the SCS-037 bench were corrected to state round 2 is live. No code change: the consumer already probed for the delegate and its bench already covered the live path. Suite 381/0 across 14 files; syntax clean.
- [x] The caught-up hour is VERIFIED in-game (2026-08-10): the edge detector fires once per clock jump carrying the full elapsed span, and every per-hour consumer multiplies by it. 16 consecutive 24h ticks across a full in-game year, Field 53 evap 0.0076/hr -> 0.1825 (24.0x), Field 51 0.0059 -> 0.1410 (23.9x). Clean log, zero errors. The "72h" figure in the brief was an example span: the sleep UI advances one day per action, so a single 72h tick cannot occur, and 24x is the identical code path, so that is not a real gap. Still open and test configuration only: the money-leg balance read (pivot running, one sleep) and round 2 with Experimental Systems ON.
- [~] The 72-hour skip test is owed in-game: sleep or fast-forward about 72 hours on a save with a dry field and an active pivot, then read csStatus; the moisture drop, the stress accrual and the money charged should each be about 72x a single hour.

## 2026-08-10 (Fred): IrrigationScheduleDialog crashes on open after F154 - fixed
- [x] F154 retired the UsedPlus wear bridge and deleted updateSystemWearLevel, leaving system.wearLevel nil on every system. The schedule dialog read that field in updatePerformance and threw on nil during onOpen, leaving the dialog visible with input never initialised (could not be interacted with or closed). Found in-game on the 72h skip test.
- [x] Fixed by reading wear as system.wearLevel or 0. Per F154 the wear factor is a permanent multiply by one after the retirement, so nil and zero are the same number and no player-observable behaviour changes (F154 invariant 1). F154 bench gains the dialog-consumer assertion. Suite 382/0, syntax clean, built and deployed.
- [~] Re-open the dialog in-game on the fixed zip to confirm it interacts and closes normally.
