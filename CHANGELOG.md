# Changelog

All notable changes to FS25_SeasonalCropStress will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Added
- Changelog file established (suite ruling 2026-08-22).
- Playtest fixes: CS_TOGGLE_HUD (RShift+M) and CS_EDIT_HUD (RShift+N) chord defaults, HUD/settings alignment, in-cab vehicle key hook.
- Control Center actions (suite Control Center, requires SettingsHub): `CS_OPEN_IRRIGATION`, `CS_OPEN_CONSULTANT`, `CS_OPEN_SETTINGS`.

### Fixed
- Multiplayer: Irrigate Now, the pivot remote, the schedule save, and the rain-key command and its result had no effect for a player joining a server. The engine hands an arriving event to readStream and then discards it, so each of the five never reached the code that does the work. Hosting a game or playing single player was never affected.

## [1.2.5.96] - 2026-08-22

- First entry under changelog tracking.
