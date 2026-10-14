-- scs234_listener_world.lua
--
-- Keeps every listener main.lua registers with addModEventListener, so a bench can
-- deliver a mouse event the way the engine does: listener:mouseEvent(posX, posY,
-- isDown, isUp, button). Load it after maint165_main_world.lua (which makes
-- addModEventListener a no-op) and before main.lua.

SCS234Listeners = {}
function addModEventListener(listener)
    SCS234Listeners[#SCS234Listeners + 1] = listener
end
