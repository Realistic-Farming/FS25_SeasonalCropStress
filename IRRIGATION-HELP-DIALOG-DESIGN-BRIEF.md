# Design Brief: Irrigation Setup Help Dialog

- **Feature Name:** Irrigation Setup Help Dialog
- **Source Issue:** GitHub #89
- **Design Owner:** Arissani (PIPELINE - Drafting required)
- **Status:** Design brief only. Implementation blocked until Antler22's 3D assets ship.
- **Date:** 2026-07-28

## Summary

A dedicated in-game help dialog that walks players through placing, connecting, and operating irrigation placeables (center pivot, drip line, water pump). Existing documentation in the modDesc helpLines and the static CsHelpDialog covers irrigation at a high level but lacks the step-by-step procedural guidance that multiplayer sessions require when players are coordinating infrastructure setup across a shared map.

## Dependency

**Antler22's 3D assets (pivot/drip placeables)** are still WIP. The placeable Lua code and XML definitions exist (`placeables/centerPivot/`, `placeables/dripIrrigationLine/`, `placeables/waterPump/`), and IrrigationManager registration/coverage logic is complete, but the final 3D models and placement behaviors depend on the shipped assets. Implementation of the help dialog itself is not blocked by the assets, but the dialog content (placement instructions, coverage visualization descriptions) should reference the final asset behavior, not placeholder descriptions. Design and content authoring can proceed now; implementation should be gated on asset delivery.

## Design Intent

The dialog exists because:

1. **MP coordination gap.** In multiplayer, one player may place irrigation infrastructure while another manages fields. Existing help text (modDesc helpLines page 5, CsHelpDialog irrigation section) explains what the systems do but not how to set them up step-by-step. New MP players joining an established farm need actionable guidance, not reference documentation.

2. **Placement-order confusion.** The IrrigationManager auto-connects systems to the nearest water pump within 500m (`IrrigationManager.MAX_PUMP_DISTANCE`, `IrrigationManager.lua:13`). Players often place pivots first and wonder why they show "Disconnected" - the pump must be placed nearby. The help dialog should make this ordering explicit.

3. **Coverage verification gap.** After placement, players need to verify that the pivot or drip line actually covers their fields. The existing covered-fields list in IrrigationScheduleDialog shows field IDs but not how to adjust placement if coverage is wrong.

4. **First-time experience.** The mod shows a first-run hint (`cs_hud_first_run` in translation_en.xml:11) pointing to ESC > Help, but that help page is static text. A context-sensitive help dialog opened from the irrigation panel or PDA would be more discoverable.

## Trigger (PROPOSED)

The dialog should be reachable from multiple entry points:

| Entry Point | Where | How |
|-------------|-------|-----|
| PDA Help button | CsPDAScreen, existing Help button (MENU_EXTRA_2, `CsPDAScreen.lua:134`) | Opens CsHelpDialog which should include an "Irrigation Setup" section or link |
| Irrigation Schedule dialog | IrrigationScheduleDialog, new "?" button in the title bar area | Opens a context-sensitive help page focused on the current system type (pivot vs drip) |
| First-time placement hint | On first irrigation placeable placement | A blinking warning or tooltip (g_currentMission:showBlinkingWarning) with "Press Shift+I then ? for setup help" |
| Console command | New `csIrrHelp` command | Opens the help dialog directly |

**PROPOSED:** The primary trigger is a "?" button added to the IrrigationScheduleDialog header area. This gives context-sensitive help (the dialog already knows whether the system is pivot or drip via `system.type`). The PDA Help button continues to open the general CsHelpDialog which should be expanded with irrigation setup content.

## Content

The dialog should cover these sections in order:

### 1. Placement Basics
- Three placeable types available in the build menu:
  - **Center Pivot** (`placeables/centerPivot/centerPivot.lua`) - large circular coverage, radius configurable per XML
  - **Drip Line** (`placeables/dripIrrigationLine/dripLine.lua`) - linear coverage along field rows
  - **Water Pump** (`placeables/waterPump/waterPump.lua`) - required to power either system
- Each is registered in modDesc.xml storeItems (lines 209-213)
- Placeable type specializations registered in modDesc.xml (lines 192-195)

### 2. Connection Order
- Place the **Water Pump first**, or at least before expecting systems to activate
- Pumps must be within 500m of irrigation systems (`IrrigationManager.MAX_PUMP_DISTANCE`)
- Pressure falls off with distance: 30% loss at max range (`IrrigationManager.PRESSURE_FALLOFF`)
- The IrrigationScheduleDialog shows "Connected" or "Disconnected" in the water source row

### 3. Coverage Verification
- After placing a pivot/drip, open the Irrigation Schedule (Shift+I) to see "Covered Fields"
- If no fields appear, the system needs repositioning
- Coverage detection uses real field polygon intersection, not label points (`IrrigationManager:detectCoveredFields`, line 199)
- Pivot coverage is a circle around the placement point; drip coverage is a line between start/end points

### 4. Scheduling and Operation
- Set active days (Mon-Sun toggle buttons) and start/end hour window
- "Irrigate Now" button applies one hour of irrigation immediately (bypasses schedule)
- Hourly schedule check runs automatically (`IrrigationManager:hourlyScheduleCheck`, line 351)

### 5. Multiplayer Notes
- Only farm owners or members with build rights can place irrigation placeables
- All players can view the Irrigation Schedule dialog
- Schedule changes by any authorized player take effect immediately for all
- The "Irrigate Now" button triggers a one-time moisture boost that applies server-side

### 6. Troubleshooting
- "Disconnected" water source: place a pump within 500m, or move the system closer
- "0 fields covered": reposition the pivot/drip to overlap field boundaries
- Pressure/efficiency shows less than 100%: system is too far from the pump (move pump closer)
- Irrigation not running: check that the current day/hour matches the schedule, and that active days are toggled on (green = active)

## UI Pattern (PROPOSED)

Follow the existing **CsDialogLoader / MessageDialog** pattern used by all three existing dialogs:

- **CsHelpDialog** (`src/ui/CsHelpDialog.lua`, `xml/gui/CsHelpDialog.xml`) - static reference dialog, two-column layout, 900x640px
- **IrrigationScheduleDialog** (`gui/IrrigationScheduleDialog.lua`, `gui/IrrigationScheduleDialog.xml`) - interactive dialog, 820x540px
- **CropConsultantDialog** (`gui/CropConsultantDialog.lua`, `gui/CropConsultantDialog.xml`) - interactive dialog with dynamic content

**Option A (PROPOSED): Expand existing CsHelpDialog.** Add a third irrigation-focused section to the existing two-column CsHelpDialog. This avoids creating a new dialog class and keeps all help content in one place. The existing CsHelpDialog has room in its right column (currently Crop Stress, Irrigation summary, Shortcuts at `CsHelpDialog.xml:82-126`).

**Option B: New dedicated IrrigationHelpDialog.** A separate MessageDialog registered via CsDialogLoader with irrigation-specific content. More discoverable from the IrrigationScheduleDialog's "?" button but adds a new dialog class.

**Recommendation:** Option A for the general help page (expand CsHelpDialog), plus a lightweight context overlay or tooltip triggered from the "?" button in IrrigationScheduleDialog. This keeps the dialog count low while providing context-sensitive guidance where it matters.

## Localization

The mod currently ships 9 translation files (not 26 as TODO.md suggests):

- `translation_en.xml`, `translation_de.xml`, `translation_fr.xml`, `translation_it.xml`, `translation_nl.xml`, `translation_cz.xml`, `translation_da.xml`, `translation_pl.xml`, `translation_uk.xml`

New strings needed (PROPOSED, English only - translations follow after design approval):

| Key | English Text | Notes |
|-----|-------------|-------|
| `cs_help_irr_setup_hdr` | Irrigation Setup Guide | Section header in CsHelpDialog |
| `cs_help_irr_setup_1` | Place a Water Pump from the build menu near a water source. Pumps power irrigation systems within 500m. | Step 1 |
| `cs_help_irr_setup_2` | Place a Center Pivot or Drip Line on your field. The pivot covers a circular area; the drip line covers along its length. | Step 2 |
| `cs_help_irr_setup_3` | Open Irrigation Schedule (Shift+I) and check "Covered Fields". If none appear, reposition the system. | Step 3 |
| `cs_help_irr_setup_4` | Set your active days and time window, then save. The system activates automatically during scheduled hours. | Step 4 |
| `cs_help_irr_setup_5` | In multiplayer, any farm member can place irrigation but only farm owners can modify schedules. | MP note |
| `cs_help_irr_setup_mp` | Multiplayer: All players see the same irrigation state. Schedule changes sync automatically. | MP detail |
| `cs_help_irr_troub_hdr` | Troubleshooting | Section header |
| `cs_help_irr_troub_1` | Disconnected: Place a water pump within 500m of the system. | Troubleshoot 1 |
| `cs_help_irr_troub_2` | No fields covered: Reposition the pivot or drip line to overlap field boundaries. | Troubleshoot 2 |
| `cs_help_irr_troub_3` | Low efficiency: The system is far from its pump. Move the pump closer for better pressure. | Troubleshoot 3 |
| `cs_irr_help_btn` | ? | Button label in IrrigationScheduleDialog |

## Integration Points

| System | File | Integration |
|--------|------|-------------|
| CsDialogLoader registration | `main.lua:239` | Add `CsDialogLoader.register("IrrigationHelpDialog", ...)` if using Option B |
| CsPDAScreen Help button | `src/ui/CsPDAScreen.lua:149-151` | Already opens CsHelpDialog; no change needed for Option A |
| IrrigationScheduleDialog | `gui/IrrigationScheduleDialog.lua` | Add "?" button handler and CsDialogLoader.show call |
| modDesc.xml helpLines | `modDesc.xml:219-377` | Expand page 5 (Irrigation) with setup steps |
| Translation files | `translations/translation_*.xml` | Add new string keys |
| IrrigationManager constants | `src/IrrigationManager.lua:13-14` | Reference in help text (MAX_PUMP_DISTANCE=500, PRESSURE_FALLOFF=0.3) |

## Open Questions for Arissani

1. **Option A vs Option B:** Expand existing CsHelpDialog or create a new IrrigationHelpDialog? The CsHelpDialog already has an irrigation section (lines 97-107 of CsHelpDialog.xml) but it is only two lines of text.

2. **Context sensitivity:** Should the "?" button in IrrigationScheduleDialog open the full help page or a compact tooltip/overlay? A compact overlay is lighter but limits how much guidance can be shown.

3. **First-time prompt:** Should the mod show a one-time popup when the first irrigation placeable is placed, directing the player to the help dialog? This is common in FS25 mods but can feel intrusive.

4. **Placement ghost/preview:** The help dialog could describe what a placement preview looks like, but this depends on Antler22's final asset behavior. Should the content reference placement previews or stay generic?

5. **MP role permissions:** The brief assumes "any farm member can place, only owners can modify schedules." Confirm this matches the intended FS25 placeable permission model for irrigation-type placeables.

## Implementation Scope (PROPOSED)

| Work Item | Files Affected | Estimate |
|-----------|---------------|----------|
| Expand CsHelpDialog XML | `xml/gui/CsHelpDialog.xml` | Add ~60 lines of new content elements |
| Add "?" button to IrrigationScheduleDialog | `gui/IrrigationScheduleDialog.xml`, `gui/IrrigationScheduleDialog.lua` | ~30 lines XML, ~15 lines Lua |
| Translation strings (EN) | `translations/translation_en.xml` | ~12 new `<text>` entries |
| Translation strings (8 other locales) | `translations/translation_*.xml` | Same keys, 8 files |
| modDesc.xml helpLines expansion | `modDesc.xml` | Expand page 5 content |
| Console command (optional) | `main.lua` | ~10 lines |

**Total estimate:** ~200 lines of new/modified code, plus translations. This is a small feature by line count but requires Arissani's content review for accuracy and tone.

## References

- IrrigationManager: `src/IrrigationManager.lua` (coverage detection, scheduling, activation)
- IrrigationScheduleDialog: `gui/IrrigationScheduleDialog.lua` (existing UI for schedule editing)
- CsHelpDialog: `src/ui/CsHelpDialog.lua`, `xml/gui/CsHelpDialog.xml` (existing help dialog)
- CsDialogLoader: `src/gui/CsDialogLoader.lua` (dialog registration pattern)
- CsPDAScreen: `src/ui/CsPDAScreen.lua` (PDA screen with Help button)
- modDesc.xml: `modDesc.xml` (helpLines, placeable registrations, input bindings)
- Translation EN: `translations/translation_en.xml` (existing string keys)
- ROADMAP.md line 31: existing reference to issue #89
