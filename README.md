<div align="center">

# 🌱 FS25 Seasonal Crop Stress
### *Soil Moisture & Irrigation Manager*

[![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_SeasonalCropStress/total?style=for-the-badge&logo=github&color=4caf50&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_SeasonalCropStress/releases)
[![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_SeasonalCropStress?style=for-the-badge&logo=tag&color=76c442&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_SeasonalCropStress/releases/latest)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey?style=for-the-badge&logo=creativecommons&logoColor=white)](https://creativecommons.org/licenses/by-nc-nd/4.0/)
<a href="https://paypal.me/TheCodingDad">
  <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate via PayPal" height="50">
</a>

<br>

> *"I planted wheat in June and had a perfect field by August — until I didn't. Three days without rain during heading and I lost 40% of my yield. Never ignored the moisture gauge again."*

<br>

**FS25 farms look lush even when your crops are quietly dying of thirst. This mod changes that.**

Real soil moisture physics. Heat evaporates. Rain replenishes. Sandy soil drains fast; clay holds longer. When moisture drops below critical thresholds during the windows that matter most — wheat during heading, corn during pollination — stress accumulates and your yield shrinks. Place a center-pivot irrigator, schedule it, and protect what you've grown.

`Singleplayer` • `Multiplayer (host-authoritative)` • `Persistent saves` • `EN / DE / FR / IT / NL / PL`

</div>

> [!TIP]
> Want to be part of our community? Share tips, report issues, and chat with other farmers on the **[FS25 Modding Community Discord](https://discord.gg/Th2pnq36)**!

---

## ✨ Features

### 💧 Soil Moisture Simulation

Every field independently tracks its moisture level (0–100%) driven by real in-game conditions.

| | Feature | Description |
|---|---|---|
| 💧 | **Per-field moisture tracking** | Each field has its own moisture level driven by weather |
| 🌡️ | **Seasonal evapotranspiration** | Heat and season affect how fast fields dry out |
| 🪨 | **Soil type modifiers** | Sandy drains 40% faster · Clay retains 30% longer · Loam is baseline |
| ☁️ | **Weather integration** | Rain events replenish moisture automatically |
| 💾 | **Full persistence** | Moisture and stress state saves with your farm |

### 🌾 Crop Stress & Yield

Eight crops have critical growth windows where water is essential. Let them dry out and pay at harvest.

| Crop | Critical Window | Moisture Threshold |
|---|---|---|
| 🌾 Wheat | Heading (Stage 3–4) | 35% |
| 🌾 Barley | Heading (Stage 3–4) | 30% |
| 🌽 Corn | Pollination (Stage 4–5) | 40% |
| 🌼 Canola | Flowering (Stage 2–3) | 45% |
| 🌻 Sunflower | Head fill (Stage 3–4) | 30% |
| 🫘 Soybeans | Pod fill (Stage 3–4) | 40% |
| 🟣 Sugar Beet | Bulking (Stage 2–4) | 50% |
| 🥔 Potato | Tuber fill (Stage 2–4) | 55% |

Stress accumulates each in-game hour when moisture is below the threshold during a critical window. At harvest, yield is reduced proportionally — up to **60% loss** at maximum stress. Fields with no stress harvest at full yield.

### 💦 Irrigation Infrastructure

Three placeables in **Shop → Buildings → Tools**:

| Placeable | Description |
|---|---|
| **Center Pivot** | Large circular coverage up to 200m radius |
| **Water Pump** | Powers nearby irrigation systems — place near any water source |
| **Drip Line** | Precise linear coverage along a field row |

Set irrigation schedules per system (active days and hours), including overnight wrap-around schedules. Use *Irrigate Now* for instant manual activation.

### 📊 Moisture HUD

Press `Shift+M` to open the field overlay. Shows every field growing a stress-tracked crop with:
- Color-coded moisture bar: **green** (≥40%) · **yellow** (≥25%) · **red** (<25%)
- Current growth stage
- Stress indicator (`!`) when drought stress is actively building
- **5-day moisture forecast** strip for the selected field

Drag the panel anywhere on screen by right-clicking to enter Edit Mode, then left-click dragging.

### 🌿 Crop Consultant

Press `Shift+C` for a risk-ranked field summary with plain-language recommendations.

Three alert tiers fire automatically as fields dry out:

```
💙 INFO     (40–50%)  "Field X getting dry — monitor conditions"       4s
🟡 WARNING  (25–40%)  "Field X moisture low — irrigation recommended"  6s
🔴 CRITICAL  (<25%)   "Field X at drought threshold — irrigate NOW!"   10s
```

12-hour per-field cooldown prevents alert spam. Alerts can be disabled or adjusted in Settings.

---

## ⚙️ Settings

Open via **ESC → Settings → Game Settings → Seasonal Crop Stress**.

| Setting | Options | Notes |
|---|---|---|
| **Enable mod** | On / Off | Stops simulation and hides HUD when disabled |
| **Difficulty** | Easy / Normal / Hard | Scales stress rate and evaporation speed |
| **Evaporation Rate** | Slow / Normal / Fast | Fine-tune independently of difficulty |
| **Max Yield Loss** | 30% / 45% / 60% / 75% | Cap how much drought can hurt your harvest |
| **Critical Threshold** | 15% / 25% / 35% | Moisture level that triggers stress accumulation |
| **Irrigation Costs** | On / Off | Enable or disable hourly running costs |
| **Crop Alerts** | On / Off | Toggle the alert system entirely |
| **Alert Cooldown** | 4h / 8h / 12h / 24h | Control how often the same field can alert |
| **Debug Mode** | On / Off | Verbose simulation logging to `log.txt` |

> [!NOTE]
> Settings are **server-authoritative** in multiplayer — the host's settings are pushed to all clients on join.

---

## 🔌 Optional Mod Integration

All integrations are detected at runtime and fail gracefully if the mod is not installed.

| Mod | What it adds |
|---|---|
| **FS25_RealisticWeather** | Moisture sourced from RW's density map. Irrigation writes back to RW. Harvest penalty deferred to RW — no double-dipping. |
| **FS25_NPCFavor** | Alex Chen appears as an Agronomist NPC with favor quests: soil samples, irrigation checks, emergency water calls. |
| **FS25_SoilFertilizer** | Soil pH and organic matter adjust evapotranspiration per field. |
| **CoursePlay / AutoDrive** | Vehicle positions used for irrigation coverage refinement. |
| **UsedPlus** | Irrigation costs tracked in UsedPlus finance manager. Equipment wear degrades pump output. |

---

## 🛠️ Installation

**1. Download** `FS25_SeasonalCropStress.zip` from the [latest release](https://github.com/TheCodingDad-TisonK/FS25_SeasonalCropStress/releases/latest).

**2. Copy** the ZIP (do not extract) to your mods folder:

| Platform | Path |
|---|---|
| 🪟 Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\` |
| 🍎 macOS | `~/Library/Application Support/FarmingSimulator2025/mods/` |

**3. Enable** *Seasonal Crop Stress* in the in-game mod manager.

**4. Load** any career save — the mod activates automatically on load.

---

## 🎮 Quick Start

```
1. Load your farm — moisture monitoring activates immediately
2. Press Shift+M   → open the Field Moisture HUD
3. Click a field   → see its 5-day moisture forecast strip
4. Press Shift+C   → open the Crop Consultant for risk summary
5. Green = healthy · Yellow = needs attention · Red = irrigate NOW
6. Place a Water Pump near water, then a Center Pivot within 500m
7. Press E near the pivot (or Shift+I) → set your irrigation schedule
8. At harvest, drought-stressed fields yield less — plan ahead
```

> [!TIP]
> Open **ESC → Help → Seasonal Crop Stress** for a full in-game guide covering everything from reading the HUD to understanding growth stages.

---

## ⌨️ Key Bindings

| Keys | Action |
|---|---|
| `Shift+M` | Toggle the Field Moisture HUD |
| `Shift+I` | Open Irrigation Schedule dialog |
| `Shift+C` | Open Crop Consultant dialog |
| `E` *(near pivot)* | Open schedule for that specific system |
| `RMB` *(on HUD)* | Toggle Edit Mode — drag with `LMB` to reposition |

---

## 🖥️ Console Commands

Open the developer console with the **`~`** key:

| Command | Arguments | Description |
|---|---|---|
| `csHelp` | — | List all Crop Stress commands |
| `csStatus` | — | System overview: fields, moisture, stress totals |
| `csSetMoisture` | `<fieldId> <0-1>` | Manually set a field's moisture level |
| `csForceStress` | `<fieldId>` | Force maximum stress on a field |
| `csSimulateHeat` | `[days]` | Simulate N days of extreme heat (no rain) |
| `csDebug` | — | Toggle verbose debug logging to `log.txt` |

---

## ⚠️ Known Limitations

| Issue | Details |
|---|---|
| 🎨 **Placeholder 3D assets** | Irrigation placeables use minimal geometry. Center pivot arm does not rotate visually. Final art is in production. |
| 🔮 **Weather forecast** | 5-day forecast uses linear projection — does not reflect FS25's internal rain forecast events. |
| 🌐 **Multiplayer** | Simulation runs on host only. Clients see synced state but have no direct simulation authority. |
| 🤝 **NPCFavor progress** | NPC favor quest progress does not persist across savegame reloads in v1.0. |

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, code standards, and the PR checklist.

Found a bug? [Open an issue](https://github.com/TheCodingDad-TisonK/FS25_SeasonalCropStress/issues/new/choose) — the template will guide you through what information is needed.

---

## 📋 Changelog

- **1.2.5.0** - Release gate. Experimental systems ship locked until deliberately released. Turn them on under the mod's settings, independent of difficulty. No systems are gated yet; the future #89 rebuild and moisture coupling rows are noted but not built. The F93 temperature fix stays in the stable baseline.

---

## 📝 License

This mod is licensed under **[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)**.

You may share it in its original form with attribution. You may not sell it, modify and redistribute it, or reupload it under a different name or authorship. Contributions via pull request are explicitly permitted and encouraged.

**Author:** TisonK · **Version:** 1.2.5.0

© 2026 TisonK — See [LICENSE](LICENSE) for full terms.

---

<div align="center">

*Farming Simulator 25 is published by GIANTS Software. This is an independent fan creation, not affiliated with or endorsed by GIANTS Software.*

*Water your fields or lose your harvest.* 🌾

</div>
