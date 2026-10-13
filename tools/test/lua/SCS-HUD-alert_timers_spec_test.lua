--!load: src/HUDOverlay.lua
-- HUDOverlay timers that update(dt) counts in milliseconds (BaseMission.lua:770):
-- the critical-alert auto-hide (two minutes) and the edit-mode border pulse
-- (4 radians per second, period about 1571 ms).

local function hud()
    local h = setmetatable({}, { __index = HUDOverlay })
    h.isInitialized, h.isVisible, h.editMode = true, false, false
    h.firstRunShown = true
    h.lastResolution = { g_screenWidth, g_screenHeight }
    h.rebuildTimer, h.animTimer, h.autoHideTimer = 0, 0, 0
    h.autoShowActive, h.forecastDirty = false, false
    h.detectRowClick = function() end
    h.rebuildForecast = function() end
    h.rebuildDisplayRows = function() end
    h.displayRows = { { fieldId = 1 } }   -- toggle() builds stub rows only when this is empty
    return h
end

local function frames(h, n, dt)
    for _ = 1, n do h:update(dt) end
end

-- A: a critical alert keeps the HUD up for two minutes of frames
do
    local h = hud()
    h:onCriticalThreshold({ fieldId = 3 })
    T.eq("A1a [reached: the alert shows the hidden HUD]", tostring(h.isVisible) .. ":" .. tostring(h.autoShowActive), "true:true")
    frames(h, 7, 20)
    T.eq("A1b NAMED: 140 ms after the alert the HUD is still shown (the old 120 hid it at 120 ms)", h.isVisible, true)
    frames(h, 5999 - 7, 20)
    T.eq("A1c NAMED: at 119,980 ms of 20 ms frames the HUD is still shown", h.isVisible, true)
    frames(h, 1, 20)
    T.eq("A1d NAMED: at 120,000 ms it hides", h.isVisible, false)
    T.eq("A1e and the auto-show state clears", tostring(h.autoShowActive) .. ":" .. tostring(h.autoHideTimer), "false:0")
end

do
    local h = hud()
    h:onCriticalThreshold({ fieldId = 3 })
    frames(h, 100, 20)
    h:toggle()
    h:toggle()
    frames(h, 6000, 20)
    T.eq("A2 a player who re-shows the HUD cancels the auto-hide", h.isVisible, true)
end

-- P: the edit-mode pulse
do
    local h = hud()
    local period = 2 * math.pi / HUDOverlay.PULSE_RAD_PER_MS
    T.near("P1a [the pulse rate is 4 rad per second]", HUDOverlay.PULSE_RAD_PER_MS * 1000, 4, 1e-12)
    T.near("P1b NAMED: the pulse period is about 1571 ms", period, 1570.796, 0.001)
    h.animTimer = 0
    T.near("P2a pulse at t = 0 is mid", h:editPulse(), 0.5, 1e-12)
    h.animTimer = period / 4
    T.near("P2b a quarter period later it peaks", h:editPulse(), 1.0, 1e-9)
    h.animTimer = period
    T.near("P2c one period later it is back at mid", h:editPulse(), 0.5, 1e-9)
    h.animTimer = 0
    h.isVisible = true    -- update() returns before advancing animTimer while the HUD is hidden
    local worst, prev = 0, h:editPulse()
    for _ = 1, 120 do
        h:update(16)
        local now = h:editPulse()
        worst = math.max(worst, math.abs(now - prev))
        prev = now
    end
    T.eq("P3a [reached: 120 frames of 16 ms advanced the pulse clock]", h.animTimer, 1920)
    T.ok("P3b NAMED: at 16 ms frames the pulse moves at most 0.04 per frame (smooth, not jitter)", worst <= 0.04, "worst step " .. worst)
end
