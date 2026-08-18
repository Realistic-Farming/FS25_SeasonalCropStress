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
- [x] SCS PDA visual pass (2026-08-18): the Crop Stress PDA (Esc RF page and the legacy Overview/Irrigation page) now ships complete localization. English gained the two keys the CS desk used only through fallbacks (`cs_rf_pda_crop_mixed`, `cs_rf_pda_pivot_switch`), the hardcoded CROP CONSULTANT link text now reads from the translation file, and the 17 languages that were missing the whole Esc `cs_rf_pda_*` block got it filled as `[EN]` placeholders (the repo convention) so no PDA string renders as a raw key. The legacy page's tab bar now uses the sibling Soil/Market geometry (58px bar at y=668, divider at 666) so the tab labels and the footer buttons stop crowding each other.
- [x] Map sidebar l10n + spacing (2026-08-18): the map sidebar's legend, average card and info box no longer render missing l10n strings. The 16 `cs_map_*` keys those draw calls use were never in any translation file; they now exist in all 26 languages, and the overlay's `tr` helper rejects unresolved keys (raw key, `$l10n_` literal, "MISSING" variants) so a missing key always falls back to English instead of rendering raw. The three blocks are separated by a dedicated 18px card gap so the sidebar reads as separate cards.
- [x] SCS-021 drying VPD (2026-08-12): a hot dry wind takes moisture out faster than a hot still muggy day, and the simulation can now tell them apart. WeatherGuard's live humidity (with its honest defaulted flag) feeds a VPD multiplier in the hourly evap term and the moisture forecast; absent real data, drying is today's behaviour bit for bit. STABLE, adds no surface. 31 assertions in SCS-021-drying_vpd_spec_test.lua. Merged to development in PR #119.
- [x] SCS-036 soil-type publication (2026-08-12): the soil class SCS already detects and stores is now published. `getFieldSoilType` on the companion read API, a backfill for records that predate the class, and the two wire handlers stop writing a plausible-looking placeholder nobody could tell from the real answer. SoilFertilizer's shipped `MaterialWetness` probe starts succeeding with no change on its side. STABLE, adds no surface. 12 assertions in SCS-036-soil_type_publication_spec_test.lua. Merged to development in PR #120.
- [x] SCS-038 priced draw (2026-08-12): irrigation costs what it draws. A distant or low-pressure source now prices a higher effective hourly cost (`operationalCostPerHour / pressureMultiplier`), and the LIFT term for uphill pumping ships designed-in and neutral (XML `liftCoeff` at 0.0, heights captured at registration). Neutral beside a pump: exactly the XML number. STABLE, adds no surface. 13 assertions in SCS-038-priced_draw_spec_test.lua. PR feat/SCS-038 open.
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

## 2026-08-14 (Fred): F160 - the weekly irrigation schedule honours the picked days
- [x] The day-of-week index was read from env.currentDayInPeriod, which the base game pins at 1 on a default save (daysPerPeriod defaults to 1), so a weekday schedule ran every day and unticking day one stopped the pivot forever. IrrigationManager:dayOfWeekIndex now derives the index from the monotonic day modulo 7, so the weekend-off entries are reachable.
- [x] scs160_schedule_day_index_test.lua at 17 assertions; suite 465/0; deployed 1.2.5.71.
- [~] In-game (owed): a weekday pivot rests on the weekend and a Wednesday-only schedule runs Wednesdays on a fresh save.

## 2026-08-14 (Fred): F158 - the irrigation water bill goes to the system's owner
- [x] The running cost resolved the farm from the local player: on a dedicated server nothing was billed all season (no local player), on a listen server every system was billed to the host (the farmer paid for his neighbours). The bill now resolves each system's owner from its placeable at charge time (getOwnerFarmId), the base-game water-charge pattern. registerIrrigationSystem holds the placeable; deregister removes it when the placeable goes.
- [x] scs158_dedi_farm_resolution_test.lua at 12 assertions; suite 448/0; deployed 1.2.5.70.
- [~] In-game (owed): a dedi with pivots on two farms, each farm billed for its own; a sold-and-rebought pivot billed to the new owner.

## 2026-08-14 (Fred): soil-moisture coupling + Arrow-2 compaction (SCS-side)
- [x] Arrow-2 compaction half: SF compaction read adds a critical-moisture modifier (compacted fields stress/alert earlier on a drying swing). The soil-moisture coupling: drought (<30%) reduces effective nutrient uptake, Poor SF nutrient status hits harder, scaling the drying-deficit stress accrual. All SCS-side reads of SF getFieldInfo, never a write (firewall holds). Waterlog stays a noted future refinement (would break the no-deficit contract).
- [x] soil_moisture_coupling_test.lua at 8 assertions; suite 480/0; deployed 1.2.5.73.
- [~] In-game (owed): a compacted field alerts earlier on a dry spell; a drought on poor soil stresses harder than on good soil.

## 2026-08-14 (Fred): SCS-020 transpiration feedback
- [x] The growth family's condition scales only the transpiration share of evapotranspiration (a blocked cell stays wetter, an excellent cell dries faster); the soil-evaporation share is never scaled. Duck-typed read of SF's getFieldGrowthSummary, neutral 1.0 when absent; SCS remains sole writer of moisture. No new write, no new persistence, no surface.
- [x] scs020_transpiration_feedback_test.lua at 10 assertions; suite 490/0; deployed 1.2.5.74.
- [~] In-game (owed): a blocked field stays visibly wetter; an excellent-credit field dries faster over a dry spell.

## 2026-08-15 (Wizard): Crop Moisture heat sheet + hose-peer log-flood fix
- [x] CsMoistureMapOverlay now fills each owned farmland with a sampled tile grid (polygon walk + point-in-polygon ported into SCS, no SoilFertilizer dependency), one ramp feeding both the tiles and the legend, display-only (no density-map writes, HUD thresholds untouched). Merged #138; 1.2.5.77.
- [x] ScsPumpHoseConnection guards every hose-joint read behind phVehicleAlive (component-root liveness) and drops dead peers on the same frame they die, stopping the client log flood and a stale hose prompt after a sale. Merged #137; 1.2.5.77.

## 2026-08-16 (Tyson): MP join d.cells nil crash fix
- [x] SoilMoistureSystem.lua: nil-init guards for d.cells, d.cellCount, d.cellSum in both materialiseRelief and _writeCell. Field data entries created via MP moisture sync events before the full structure was built caused cascading packetReceived errors (540+ in 8 seconds). Merged #140; 1.2.5.95.
