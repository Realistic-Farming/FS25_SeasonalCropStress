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
- [ ] Strip the Precision Farming overlay to a stand-down stub (PrecisionFarmingOverlay.lua currently activates integration mode on detection). Critical, house rule.
- [ ] Remove the FSBaseMission.draw hook that calls the no-op HUD stub; monitoring stays on the PDA screen (CsPDAScreen).
- [ ] Add the companion read API on `cropStressManager` (getMoisture / getStress) for CropDisease and RandomWorldEvents.

## Mid-term (this season)
- [ ] StateLedger, NetworkSync, MasterHUD, SettingsHub migration (Point 1-4), coordinated with the rebuild.
- [ ] Remove the internal `soilMoistureSystem = soilSystem` alias in favour of the formal companion API.

## Long-term / aspirational
- [ ] Deeper stress model (crop-specific tolerances, recovery curves) as part of the rebuild with the new assets.

## Cross-mod / ecosystem dependencies
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional FS25_MoistureSystem (external).
- [ ] Read by CropDisease, RandomWorldEvents, MarketDynamics, FarmTablet.
- [ ] All four bedrock migrations (blocks on: StateLedger, NetworkSync, MasterHUD, SettingsHub).

## Deferred / parked
- Any Precision Farming compatibility: never. Detect-to-stand-down only.
