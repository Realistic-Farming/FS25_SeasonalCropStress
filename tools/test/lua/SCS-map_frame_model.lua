-- SCS-map_frame_model.lua
--
-- The engine under the map frame's mouse chain, MODELED so a bar can start from
-- production's own entry point rather than from the handler. Same model as
-- SoilFertilizer's SG10-051-map_frame_model.lua (#1035), for Crop Stress's hooks.
--
-- CsMapHooks installs itself at file load by wrapping InGameMenuMapFrame.mouseEvent
-- through Utils.overwrittenFunction (the shared pairs-safe chain) and appending its HUD
-- draw to InGameMenuMapFrame.draw. The chain runs every registered handler BEFORE the
-- engine's own mouseEvent, which is why the click leak travels this path: the frame does
-- not have to be visible for the handler to see the event.
--
-- Loaded BEFORE src/ui/CsMapHooks.lua so the install block finds a frame to wrap.

--- The engine's own leaf behaviour. GuiElement:mouseEvent (gui/elements/GuiElement.lua:502)
--- walks its children only while visible and hands back whether the event was consumed;
--- with no children that is eventUsed unchanged. The counter proves the chain reached the
--- engine at all.
InGameMenuMapFrame = InGameMenuMapFrame or {}
InGameMenuMapFrame.engineMouseCalls = 0
InGameMenuMapFrame.engineDrawCalls = 0

function InGameMenuMapFrame.mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    InGameMenuMapFrame.engineMouseCalls = InGameMenuMapFrame.engineMouseCalls + 1
    return eventUsed == true
end

function InGameMenuMapFrame.draw(self)
    InGameMenuMapFrame.engineDrawCalls = InGameMenuMapFrame.engineDrawCalls + 1
end

--- Utils as the engine defines it, only the two the install block uses.
Utils = Utils or {}

--- newFunc receives (self, superFunc, ...) and decides whether to call on.
function Utils.overwrittenFunction(oldFunc, newFunc)
    return function(...)
        return newFunc(select(1, ...), oldFunc, select(2, ...))
    end
end

--- Both run; the appended one cannot suppress the original.
function Utils.appendedFunction(oldFunc, newFunc)
    return function(...)
        if oldFunc ~= nil then oldFunc(...) end
        return newFunc(...)
    end
end

--- Reset between cases so a count means "this case".
function InGameMenuMapFrame.resetModel()
    InGameMenuMapFrame.engineMouseCalls = 0
    InGameMenuMapFrame.engineDrawCalls = 0
end
