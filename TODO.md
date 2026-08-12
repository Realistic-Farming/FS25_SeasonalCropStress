# TODO: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] SCS-021 drying VPD (2026-08-12): the drying model learns what humidity is. `WeatherIntegration.lua` gains `computeVPDMultiplier` (Tetens SVP, `(vpd/VPD_REF)^0.40` clamped 0.40-2.20 after the exponent) plus three function edits: `getHumidity()` reads WeatherGuard's `getCurrentSky().humidity` + `humidityDefaulted` FIRST (percent normalized once, second return added), `update()` unpacks both, `getHourlyEvapMultiplier()` uses the VPD term only when humidity is live (defaulted = today's formula bit for bit), and `getMoistureForecast()` feeds the helper the drying window whole (`getForecastHumidity(day)`; nil keeps the linear term silently). `csStatus`'s sky line appends "(humidity defaulted)" when the flag is true. 31 assertions in SCS-021-drying_vpd_spec_test.lua. Merged to development in PR #119.
- [x] SCS-036 soil-type publication (2026-08-12): SoilFertilizer's `MaterialWetness` probe now gets an answer. Four edits: (1) `enumerateFields` backfills an existing record with no `soilType` (count includes backfilled records); (2+3) `CropStressMoistureInitEvent` and `CropStressNetworkSyncBridge` stop writing the `"loamy"` placeholder (an absent key is detectable; the placeholder was the same string as a real answer); (4) `CropStressManager:getFieldSoilType(fieldId)` published in the companion read API block with the DERIVED-FROM-FIELD-ID warning header, and SoilFertilizer added to the companion list. Pull-only, nil-never-substitute. SF's existing probe needs no change. 12 assertions in SCS-036-soil_type_publication_spec_test.lua. PR feat/SCS-036 open.
- [x] Strip PrecisionFarmingOverlay.lua: DONE. The PF overlay/integration was removed wholesale (commit 77b3064); zero `PrecisionFarming` references remain in any .lua (verified 2026-07-15). Zero-PF house rule satisfied.
- [x] "Remove the FSBaseMission.draw hook that calls the no-op HUD stub": closed as WRONG PREMISE. main.lua:246 `FSBaseMission.draw` drives the REAL moisture HUD (`CropStressManager:draw` -> `HUDOverlay`), not a no-op stub. Keep the hook.
- [x] Façade WIDENING (B3.2b): DONE. Read-only, nil/neutral-safe getters for the irrigation-ops + economy consumers: `getIrrigationRate`, `isFieldIrrigated`, `getIrrigationSystems` (mutation-safe snapshot, keeps the coveredFields ipairs contract), `getIrrigationSchedule` (active systems only), `getFieldPolygonWorld`, `getCriticalAlertHint`, `getTemperature`, `getEvaporativeDemand`. All delegate to existing subsystem methods; CropConsultant migrated onto the alert-hint getter. Heat-fold SETTLED: `getStress` is moisture-only, SCS-010/013 read the heat pair. Test: `tools/test/facade_readapi_test.lua` (35 assertions).
- [x] Companion read API façade (B3.2): DONE. Formal `CropStressManager:getMoisture`/`:getStress` added + readers migrated (83aef10). B3.3 (remove the `soilMoistureSystem = soilSystem` alias) is BLOCKED, see Blocked section: FarmTablet still reads the alias as its primary moisture source, so it stays until FarmTablet migrates to the facade.
- [x] `getIrrigationCostsEnabled` getter (212ceaa): a nil-safe read of the irrigation-costs-enabled flag, added to the facade for TaxMod's SCS-011 deductible-expense mirror (the first B3.2b consumer, in-game verified).

## Bugs
- [x] F93 CRITICAL: the temperature read was a permanent 15.0. `getTemperatureFromWeather()` probed `env.weatherSystem:getTemperature()`, but there is no WeatherSystem class in FS25 (Environment.weather is a Weather instance), so every probe missed and every heat-driven behaviour was inert while looking healthy. Fix: WeatherGuard first (`g_currentMission.weatherGuard:getCurrentSky().temperature`, the certified temperatureUpdater route), then the certified vanilla `Weather:getCurrentTemperature()` (exists, certified at VehicleSystem.lua:158 + decompile Weather.lua:671-672). Test: `tools/test/lua/weather_temp_f93_test.lua` (8 assertions).
- [x] CRITICAL: the harvest yield penalty had NEVER run. `CropStressModifier.installHarvestHook()` was invoked from `FSBaseMission.onAllVehiclesLoaded`, which does not fire (and is in no reference doc; the old comment citing NPCFavor and CoursePlay as witnesses was false, neither uses it). `Cutter.processCutterArea` was never wrapped, so stress accumulated, displayed and persisted while taking nothing. Certified in-game 2026-07-30 on savegame14: with `csForceStress` at 1.0, litres per area held flat at 0.4 L/m2 before and after. Moved to `Mission00.onStartMission` (the point SoilFertilizer proves works for `Combine`/`FillUnit`/`Mower` spec hooks) plus a readiness-guarded per-frame backstop in `FSBaseMission.update`.
- [ ] **RELEASE GATE (do not ship without it):** the fix above switches ON a yield penalty that has been inert since the mod shipped, so **drop-time messaging is part of the fix, not optional** (Arissani ruling 2026-07-30). Release notes must say, in plain words, that drought now actually costs yield and that the cap ships deliberately gentle for this season. Suggested wording: *"Fixed: drought stress never actually reduced your harvest. It does now. Because this has been inactive since release, the maximum loss ships at the gentle end (30%) rather than the old 60% default, so existing farms are not punished mid-season. Saves still on the old default are migrated to 30% automatically; if you had deliberately set your own value it is left alone. The full figure will be revisited in the suite-wide balance pass."*
- [x] Witcombe join load-gates: buildFieldMap called before g_fieldManager.fields populated on MP join, producing empty field map. Added field-readiness guards in CropStressMoistureInitEvent:run() and CropStressNetworkSyncBridge._onReadState(). Commit 3969c44, pushed 2026-07-28.
- [x] CRITICAL (house rule): PF integration mode active on detection - RESOLVED. No PF code path remains after 77b3064; nothing left to stand down.
- [x] SCS-001: created overlay handle in `initialize()`, replaced bare `drawFilledRect` calls (fixed, merged to main).
- [x] SCS-002 / SCS-003: additional SeasonalCropStress bugs fixed in 2026-07-26 bug sweep, merged to main.

## Features / enhancements
- [x] Release gate (2026-08-04): `ReleaseGate.lua` with the `cs_89_rebuild` and `moisture_coupling` rows, both noted "not built yet; locks when it lands" (Arissani 2026-08-03). F93 ships stable and is not in the registry. `experimentalSystems` opt-in (default false, orthogonal to difficulty) through `CropStressSettings` defaults/load/save/validate, the MP bulk sync (count 10 to 11), the SettingsHub mirror and a settings-panel row. `csRelease` status command. 23 assertions in release_gate_test.lua.
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

## Esc doors + map buttons (2026-08-06)
- [x] Moisture map overlay button restored via retained-page pattern (CsPDAScreen._retainedDeepScreen + _ensureDeepPageInjectable). DONE in code, deployed.
- [~] In-game observation pending: confirm the moisture overlay button opens the screen with no Farm Tablet installed, and that the Esc rail still shows exactly one Realistic Farming tab.

## Esc panel buttons UI fixes (2026-08-07)
- [x] Bottom-bar buttons were disabled while the Esc menu is paused; fixed via showWhenPaused.
- [x] Cross-mod resolution: callbacks now resolve Soil classes via the g_currentMission handoff (MDM builds the door first when installed). Deployed and verified in-game.
- [x] Help button shows only on the Soil module; the Crop Stress module shows Back only (the Soil guide is Soil-specific).

## Module page dots always visible (2026-08-07)
- [x] The Esc RF module page dots were hidden while Worker Costs or Market Dynamics was active, so WC never read as the 3rd module. All four RfPdaMenuPage copies now keep them visible. Built, deployed, PR open.

## SCS-018 per-cell moisture store (2026-08-08)
- [x] Per-cell store + shared grid + single write path in SoilMoistureSystem (relief threshold/cap, derived aggregate, positional getter).
- [x] Per-cell pivot/drip/sprayer water + Irrigate Now server routing (new CropStressIrrigateNowEvent).
- [x] Packed persistence both doors (StateLedger SCHEMA 2 + careerSavegame.xml leaf).
- [x] Daily TimeGuard `simulation` accrual + day-hook fallback + version-skew guard.
- [x] RealisticWeather moisture unwind (2 writes + 2 step-asides removed; RW stays weather-only).
- [x] Three offline benches (relief sparsity, drainage conservation, real-scheduler catch-up). Suite 162/0.
- [x] SCS-018 positional read facade fixed: CropStressManager.getMoisture forwards x, z to SoilMoistureSystem (the 1-arg facade was the uncommitted gap; SF-18 consumes the positional read). Suite 162/0.
- [~] In-game acceptance owed: hollow stays wetter over dry days; continuity on old saves; skip lands exactly; cell round-trip on both save paths; Irrigate Now survives broadcast on a client; RW map moisture evolves on our model.


## SCS-037 round 2 live (2026-08-10)
- [x] Comment correction only: the round-2 rain-switch reconstruction is LIVE because the Water Record delegate ships (SF PR #811). CropStressManager.lua comment and the SCS-037 bench framing updated to say so. No code change, suite 381/0.
- [x] VERIFIED in-game (2026-08-10): caught-up hour multiplies per-hour consumers by the elapsed span. 16x 24h ticks across a full year, 24.0x evap measured, clean log. A literal 72h tick is unreachable via sleep (one day per action) and unnecessary: 24x is the identical code path.
- [~] Money leg still open: with pivot 516 running on schedule, note the farm balance, do one sleep, expect a ~24h operating-cost drop (addMoney is not console-logged, so read the balance).
- [~] Round 2 rain-switch reconstruction still open: needs Experimental Systems ON to open the ground_material gate.
- [~] In-game skip test owed: ~72h skip with a dry field and an active pivot; moisture drop, stress and irrigation cost each read about 72x a single hour in csStatus.

## IrrigationScheduleDialog crash after F154 (2026-08-10)
- [x] Root cause: system.wearLevel nil (F154 deleted the wear setter) -> updatePerformance threw on nil in onOpen, dialog left visible but dead.
- [x] Fix: wearLevel or 0 in the two readouts. Suite 382/0, deployed.
- [~] In-game confirm: open the irrigation schedule dialog and interact/close normally.
