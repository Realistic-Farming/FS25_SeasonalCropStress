# Changelog

All notable changes to FS25_SeasonalCropStress will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Fixed
- **Alex Chen is the same neighbour after a reload, and never a namesake (RSF-F357, the consultant caller).** With FS25_NPCFavor present, the agronomist is now claimed through the host's own consultant door and kept by the number the host returns, instead of being adopted by name from whoever carries it or inserted into the host's town by hand. A pure multiplayer client reads her from the host's roster once it is complete and retries about once a second until she is there. If the host goes away, is too old to pair with, or shows more than one saved consultant, the link is cleared and the Agronomist page says why instead of showing a score; the standalone consultant alerts keep working on an old or absent host. The relationship value this mod saved before the update is kept as old evidence and re-saved as it was; it is no longer applied as a floor on the neighbour's trust (it may have been saved from a namesake), and you are told once that it could not be safely linked. Alerts raised before she is linked are kept, the latest eight, and shown once she is. Needs FS25_NPCFavor with saved neighbours (its RSF-F357 host); nothing to configure.
- **Translated text reads correctly in every language again (MAINTENANCE row 115).** 1137 lines across all 26 translation files had been saved with their UTF-8 read as a Western codepage, so accented letters, Cyrillic, Chinese, Japanese and Korean showed as runs of symbols such as "Ã¤" instead of "ä". Each line is decoded once back to its original text, and the dash those lines carried between two phrases is written as a hyphen. `tools/l10n_encoding_check.py` reports any line still double-encoded.

### Added
- Changelog file established (suite ruling 2026-08-22).
- Playtest fixes: CS_TOGGLE_HUD (RShift+M) and CS_EDIT_HUD (RShift+N) chord defaults, HUD/settings alignment, in-cab vehicle key hook.
- Control Center actions (suite Control Center, requires SettingsHub): `CS_OPEN_IRRIGATION`, `CS_OPEN_CONSULTANT`, `CS_OPEN_SETTINGS`.

### Fixed
- Multiplayer: Irrigate Now, the pivot remote, the schedule save, and the rain-key command and its result had no effect for a player joining a server. The engine hands an arriving event to readStream and then discards it, so each of the five never reached the code that does the work. Hosting a game or playing single player was never affected.

## [1.2.5.96] - 2026-08-22

- First entry under changelog tracking.
