--!load: src/HUDOverlay.lua
-- HUDOverlay row-rebuild throttle. update(dt) receives milliseconds
-- (BaseMission.lua:770 adds dt to mission time; :796-798 pass the same dt to
-- mod listeners), so the once-per-second throttle compares against 1000 ms, and
-- onMoistureUpdated's force still rebuilds on the very next tick.

local function hud()
    local h = setmetatable({}, { __index = HUDOverlay })
    h.isInitialized, h.isVisible, h.editMode = true, true, false
    h.lastResolution = { g_screenWidth, g_screenHeight }
    h.rebuildTimer, h.animTimer, h.autoHideTimer = 0, 0, 0
    h.autoShowActive, h.forecastDirty = false, false
    h.rebuilds = 0
    h.detectRowClick = function() end
    h.rebuildForecast = function() end
    h.rebuildDisplayRows = function(self) self.rebuilds = self.rebuilds + 1 end
    return h
end

local function frames(h, n, dt)
    for _ = 1, n do h:update(dt) end
end

do
    local h = hud()
    frames(h, 49, 20)
    T.eq("R1a [reached: 980 ms of 20 ms frames, no rebuild yet]", h.rebuilds, 0)
    frames(h, 1, 20)
    T.eq("R1b the rows rebuild once 1000 ms have passed", h.rebuilds, 1)
    frames(h, 100, 20)
    T.eq("R1c NAMED: over 3000 ms of 20 ms frames the rows rebuild 3 times, not once per frame", h.rebuilds, 3)
end

do
    local h = hud()
    frames(h, 10, 20)
    local before = h.rebuilds
    h:onMoistureUpdated({ fieldId = 9 })
    frames(h, 1, 20)
    T.eq("R2a NAMED: a moisture update forces a rebuild on the next tick", h.rebuilds, before + 1)
    frames(h, 1, 20)
    T.eq("R2b and the throttle resumes after it", h.rebuilds, before + 1)
end
