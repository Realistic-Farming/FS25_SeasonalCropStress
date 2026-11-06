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
- Give Crop Stress's verbose-log console toggle its own `csDebugLog` name so it does not collide with Cultivator Settings' `csDebug` command or remove that command on mission unload.

## [1.2.6.1] - 2026-10-14

> **This is not a final release.** It gives everyone, testers and players, new or returning, everything we have built so far, so nobody has to wait on an old version any longer. The Realistic Farming suite is far from done: we are still building and expanding every mod, and completing it could take months, possibly a year. Expect changes and rough edges along the way, and please report anything that looks wrong.

### Fixed
- **Clicking a field row in the moisture HUD selects it again** and fills the 5-day forecast, both in HUD edit mode and from a vehicle cab with a mouse cursor showing (reported on 1.2.6.0). Edit mode no longer fights the vehicle camera in a cab.

## [1.2.6.0] - 2026-10-12

> **This is not a final release.** It gives everyone, testers and players, new or returning, everything we have built so far, so nobody has to wait on an old version any longer. The Realistic Farming suite is far from done: we are still building and expanding every mod, and completing it could take months, possibly a year. Expect changes and rough edges along the way, and please report anything that looks wrong.

### Added
- **Finite irrigation water:** pumps and water sources hold real water. Scheduled irrigation plans, covers and draws from them, Irrigate Now checks what is really there, and the Agronomy difficulty dial (with Settings Hub) sets how fast irrigation drains a pump.
- **Pivot rain key:** pivots pause in rain and resume after it (fitted pause, sensor and gate), with Auto and Manual modes applied on load. A Reinke A22 pivot is included, and the shop pivot was swapped for a water tank and pump.
- **Thirsty Ground:** dry ground absorbs irrigation more slowly, and water a patch rejects gets one chance to run off onto the lowest neighbouring patch of the same field.
- **Rainstar irrigation:** walk-up watering, and control and reports from the PDA and the Realistic Farming Esc page.
- **Moisture map:** the crop moisture map draws per-pixel moisture through the game's own map overlay, with irrigator water and seeds shown from load.
- **Crop Stress Field Guide** and a live yield-loss readout. Field lists are grouped by GPS outline.
- With Soil & Fertilizer installed, the moisture HUD flags each field's weeds (W), pests (P), scouted disease (D) and fertilizer need (F), and drought stress uses Soil's crop nutrient window when Soil reports it.
- A moisture HUD show/hide toggle and actions in the Control Center; the HUD follows the base game's theme, with an independent forecast pane and width resizing.

### Changed
- **Soil moisture is Crop Stress's own.** With Realistic Weather installed, Crop Stress takes only the weather (temperature and rain) from it and keeps its own moisture scale, so its Healthy and Critical thresholds no longer apply to Realistic Weather's crop ranges.
- Moisture is saved and restored truthfully: an unknown reading stays unknown instead of reading as 0, and a field's ground recovers after a restore.
- Switching Seasonal Crop Stress off now really switches it off: harvests take no drought cut, other mods stop reading its moisture, and its HUD, PDA and map show no readings.
- Multiplayer: Show Moisture HUD, Crop Alerts and Alert Cooldown are each player's own; a setting changed from the Farm Tablet reaches every player at once; a client admin's heat wave runs on the host after a rights check.

### Fixed
- **The Crop Moisture map's labels show text again** instead of "Missing ..." messages (reported on 1.2.5.96).
- Translations: 1,137 garbled lines in all 26 language files are decoded, the PDA is fully translated, French Canadian reads French, the Korean Field Detail label is fixed, and the title and description read correctly in the mod manager.
- Clicks on other Esc menu pages no longer open the Crop Stress screen or change the moisture map.
- The pivot no longer grabs numpad 2, 4, 6 and 8, keyboard defaults are bound with live Controls hints, and the pump no longer plays a wood-chipper sound when turned on.
- A HUD crash on fields with no moisture reading is fixed, and water source names and pump registration no longer stop saves from loading.
- With Time Guard 1.0.0.0, the daily moisture settle runs on Crop Stress's own day tracking.

### Fixed
- **Field relief forms even when a field's outline could not be read at load.** With the 2 m moisture map off (the default), each field's wetter hollows and drier rises are worked out once, after the fields are ready. If one field of a farmland could not be read at that moment, the pass used to be switched off for the rest of the session and that farmland stayed flat. It now waits for the farmland's whole outline and runs once as soon as it can be read, on the host at the next hourly retry and on each player's machine the next time it reads a spot there. Nothing to configure. (MAINTENANCE row 91.)
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
