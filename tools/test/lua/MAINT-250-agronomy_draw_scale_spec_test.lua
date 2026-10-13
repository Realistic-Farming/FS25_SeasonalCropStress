-- MAINT-250-agronomy_draw_scale_spec_test.lua
--
-- MAINTENANCE row 250 (Bob's fleet sweep row 9): the Agronomy dial scales finite irrigation water draw
-- in a game.
--
-- THE DEFECT THIS PINS (development 99d25f4): IrrigationManager:resolveFiniteWaterDrawScale
-- (src/IrrigationManager.lua:279-292) read g_currentMission.optionScalingResolver, a field no mod
-- assigns, and called it with colon calls, an "AGRO" key and the wrong argument order, so the scale
-- was always 1.0 whatever the Agronomy dial said.
--
-- THE FIX: the SCS-023 build brief's section 5 call as written (:126-132): the bundled
-- OptionScalingResolver called statically, readProfile on the mission's SettingsHub, and the
-- declaration { id = "finiteWaterDrawScale", dial = "agronomy", base = 1.0, neutral = 1.0 }.
--
-- THE ENTRY-POINT BAR IS GROUP E. The draw scale enters where production enters it: the hourly act's
-- planFiniteWater (CropStressManager.lua:712, on a finite-water hour), which resolves the scale once
-- and draws pressure x hours x scale from each finite source. The real OptionScalingResolver is loaded;
-- SettingsHub is reachable only as the mission's handle and carries the Option-Scaling spine's profile
-- the way SettingsHub's OptionScalingSpine registers it (module "OptionScalingSpine": preset,
-- dial_<dial>, switch_<dial>, read by OptionScalingResolver.readProfile through getValue). The water
-- source is registered through registerWaterSource; the scheduled system is the player's placed pivot,
-- as SCS-023's own bench sets it.
--
--   E0  the world: no mod assigns g_currentMission.optionScalingResolver; SettingsHub is on the mission
--   E1  Punishing (Agronomy 2.0): six scheduled hours draw 8.4 (1.4 a system-hour), not 6
--   E2  Relaxed (Agronomy 0.0): they draw 4.2 (0.7 a system-hour)
--   E3  Standard (Agronomy 1.0): 6.0, the neutral
--   E4  the Agronomy dial switched off: 6.0
--   E5  no SettingsHub: 6.0
--
--!load: src/integrations/OptionScalingResolver.lua, src/IrrigationManager.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

--- SettingsHub on the mission, holding the spine's values as OptionScalingSpine registers them.
local function hubWith(values)
  local hub = { values = values }
  function hub:getValue(module, key)
    if module ~= OptionScalingResolver.MODULE then return nil end
    return self.values[key]
  end
  return hub
end

local function spine(preset, agronomy, agronomyOn)
  return {
    [OptionScalingResolver.PRESET_KEY] = preset,
    [OptionScalingResolver.dialKey("agronomy")] = agronomy,
    [OptionScalingResolver.switchKey("agronomy")] = agronomyOn,
  }
end

--- One finite-water hour span: a 48-unit source, one scheduled pivot at pressure 1.0, six hours, no rain.
local function drawn(hub)
  g_currentMission = { settingsHub = hub }
  local mgr = IrrigationManager.new(nil)
  mgr.waterSources = {}
  mgr:registerWaterSource({
    id = 1, x = 0, y = 0, z = 0, waterFlowCapacity = 1000,
    waterUnitsCapacity = 48.0, waterRemaining = 48.0, ownerFarmId = 1,
    waterUnitsRefillPerRainHour = 2.0,
  })
  mgr.systems = {
    [10] = { id = 10, waterSourceId = 1, pressureMultiplier = 1.0,
             schedule = { startHour = 0, endHour = 24, activeDays = {true,true,true,true,true,true,true} } },
  }
  local plan = mgr:planFiniteWater(6, 1 * 24 + 6, 0.0, false)
  return plan.sourceRows[1] and plan.sourceRows[1].consumed
end

group("E0", function()
  g_currentMission = { settingsHub = hubWith(spine("punishing", 2.0, true)) }
  T.eq("E0 no mod assigns g_currentMission.optionScalingResolver", g_currentMission.optionScalingResolver, nil)
  T.ok("E0 the resolver is the bundled class", type(OptionScalingResolver) == "table" and OptionScalingResolver.MODULE == "OptionScalingSpine")
end)

group("E1", function()
  T.near("E1 Punishing: six scheduled hours draw 8.4 (1.4 a system-hour)", drawn(hubWith(spine("punishing", 2.0, true))), 8.4, 1e-9)
end)

group("E2", function()
  T.near("E2 Relaxed: six scheduled hours draw 4.2 (0.7 a system-hour)", drawn(hubWith(spine("relaxed", 0.0, true))), 4.2, 1e-9)
end)

group("E3", function()
  T.near("E3 Standard: the neutral 6.0", drawn(hubWith(spine("standard", 1.0, true))), 6.0, 1e-9)
end)

group("E4", function()
  T.near("E4 the Agronomy dial switched off: 6.0", drawn(hubWith(spine("punishing", 2.0, false))), 6.0, 1e-9)
end)

group("E5", function()
  T.near("E5 no SettingsHub: 6.0", drawn(nil), 6.0, 1e-9)
end)
