# Vision: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit (Point 1-6, ecosystem-map, notes).
> Last updated: 2026-07-08

## 1. One-line purpose
Weather and season put crops under stress: heat, cold, drought and soil moisture reduce yield when conditions turn against a crop, so planting date and weather actually matter.

## 2. Problem it solves
FS25 crops are weather-indifferent once planted; a heatwave or a cold snap costs nothing. SeasonalCropStress adds per-field moisture and stress that scale yield by season and weather, giving timing and crop choice real consequences.

## 3. Design pillars
- **Zero Precision Farming.** SeasonalCropStress must detect PF only to stand down. The current PF overlay integration is a violation to strip to a stand-down stub (house rule).
- **Season and moisture driven.** Stress is a function of the calendar, weather, and soil moisture, not a flat penalty.
- **Readable, not noisy.** Monitoring lives on the PDA screen; the old HUD overlay is a no-op stub to remove.
- **Standalone-first, ecosystem-aware.** Fully functional alone; exposes moisture/stress for peers when present.

## 4. Role in the ecosystem
- Public handle on `g_currentMission.cropStressManager` (all lowercase), confirmed from source.
- Reads from (consumes): RandomWorldEvents (`g_currentMission.randomWorldEvents`), and optionally FS25_MoistureSystem (external, `g_modIsLoaded`).
- Read by (consumers): CropDisease (moisture, to modulate disease spread), RandomWorldEvents (stress, to scale field event penalties), MarketDynamics (`cropStressManager`), FarmTablet SeasonalCropStressApp. Today there is no public read surface; the audit (Point 6) adds a stable companion API (getMoisture / getStress are internal only right now).
- Core-API registration status (specced in Point 1-6, not yet wired):
  - StateLedger (save/load): planned.
  - NetworkSync (MP state): planned.
  - MasterHUD (overlays): planned (the FSBaseMission.draw hook calling the no-op stub is removed; monitoring stays on the PDA screen).
  - SettingsHub (admin settings): planned.

## 5. Explicit non-goals
- No Precision Farming integration. The PF overlay must become a stand-down stub before any rebuild.
- Not a soil-nutrient system (that is SoilFertilizer). This is moisture/stress only.

## 6. Success criteria
- Crops visibly lose yield under out-of-season or hostile weather, recover under good conditions.
- PF is detected only to stand down; no PF behaviour remains.
- Peers (CropDisease, RandomWorldEvents, MarketDynamics) can read moisture/stress through a stable API.

## 7. Open questions for the audit
- A rebuild is in progress (external assets, issue #89); the audit points are the target spec. Confirm the companion read API shape (getMoisture(fieldId), getStress(fieldId)) as the public surface.
- The internal `soilMoistureSystem = soilSystem` alias signals a prior external-exposure attempt; confirm it is removed in favour of the formal companion API.
