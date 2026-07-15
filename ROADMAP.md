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
- [x] Strip the Precision Farming overlay: DONE. Removed wholesale in 77b3064; zero PF refs remain in any .lua (verified 2026-07-15).
- [x] "Remove the FSBaseMission.draw hook": closed as wrong premise - the draw hook drives the real moisture HUD, not a no-op stub. Kept.
- [ ] Add the companion read API façade on `cropStressManager` (getMoisture / getStress) for CropDisease and RandomWorldEvents (B3.2). The subsystem-level getters already exist; this is the formal façade.

## Mid-term (this season)
- [~] StateLedger, NetworkSync, MasterHUD migration (Point 1-4), folded into the #89 rebuild (GO 2026-07-15). SettingsHub already built. Gated on locking the SF module ids with Claude(A) (B3.4).
- [ ] Remove the internal `soilMoistureSystem = soilSystem` alias in favour of the formal companion API, after confirming FarmTablet's read path (B3.3).

## Long-term / aspirational
- [ ] Deeper stress model (crop-specific tolerances, recovery curves) as part of the rebuild with the new assets.

## Cross-mod / ecosystem dependencies
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional FS25_MoistureSystem (external).
- [ ] Read by CropDisease, RandomWorldEvents, MarketDynamics, FarmTablet.
- [ ] All four bedrock migrations (blocks on: StateLedger, NetworkSync, MasterHUD, SettingsHub).

## Deferred / parked
- Any Precision Farming compatibility: never. Detect-to-stand-down only.
