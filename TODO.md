# TODO: FS25_SeasonalCropStress

> Ecosystem role: **Soil and Crops** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [ ] Strip PrecisionFarmingOverlay.lua to a stand-down stub (it currently activates integration mode on PF detection). Critical, house rule.
- [ ] Remove the FSBaseMission.draw hook that calls the no-op HUD stub.
- [ ] Add the companion read API (getMoisture(fieldId), getStress(fieldId)); remove the `soilMoistureSystem = soilSystem` alias.

## Bugs
- [!] CRITICAL (house rule): PF integration mode is active on detection. Zero PF compatibility is required across the ecosystem; this must become a stand-down stub.

## Features / enhancements
- [ ] Bedrock migration per Point 1-4 (coordinate with the ongoing rebuild, issue #89).

## Cross-mod integration
- [ ] StateLedger / NetworkSync / MasterHUD / SettingsHub migration.
- [ ] Reads RandomWorldEvents (`randomWorldEvents`); optional external FS25_MoistureSystem.
- [ ] Read by CropDisease (moisture), RandomWorldEvents (stress), MarketDynamics, FarmTablet.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] Companion API shape confirmation (waits on: rebuild direction, issue #89, external assets).
