-- maint165_main_world.lua
--
-- The engine surface main.lua touches when the game loads it and runs its mission
-- hooks: the hook tables it appends to, Utils.appendedFunction, and a console that
-- records every addConsoleCommand. Nothing here builds a manager, a subsystem or a
-- registration: main.lua's own Mission00.load creates the manager, and its own
-- loadMission00Finished registers the console commands.
--
-- source() is a no-op here. The engine would load each module from the mod folder;
-- on the bench a test --!loads the modules it needs, before main.lua.

g_currentModDirectory = g_currentModDirectory or "FS25_SeasonalCropStress/"
g_currentModName = g_currentModName or "FS25_SeasonalCropStress"
function source(_path) end
function addModEventListener(_listener) end

Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(orig, fn)
    return function(...)
        if orig ~= nil then orig(...) end
        return fn(...)
    end
end

Mission00 = Mission00 or {}
FSBaseMission = FSBaseMission or {}
FSCareerMissionInfo = FSCareerMissionInfo or {}
Vehicle = Vehicle or {}

-- The console: addConsoleCommand(name, description, functionName, target), as the
-- base game calls it (AISystem.lua:82 at game 1.24.0.0). A command runs as
-- target[functionName](target, args...), and the console shows whatever the handler
-- returns, which is how base-game handlers are written (AISystem.lua:536-601 and
-- AdsSystem.lua:98 return their output instead of printing it). The echo itself
-- happens in the engine, which the decompile does not show: this model is read from
-- control flow, not seen in game.
MAINT165Console = { commands = {} }
function addConsoleCommand(name, description, functionName, target)
    MAINT165Console.commands[name] = { description = description, functionName = functionName, target = target }
end
function removeConsoleCommand(name) MAINT165Console.commands[name] = nil end

local function collect(...) return select("#", ...), { ... } end

--- Run a registered command. Returns { returned = how many values the handler
--- returned, echoed = what the console would show for them }, or nil if the name is
--- not registered.
function MAINT165Console.run(name, ...)
    local c = MAINT165Console.commands[name]
    if c == nil then return nil end
    local n, values = collect(c.target[c.functionName](c.target, ...))
    local echoed = {}
    for i = 1, n do echoed[i] = tostring(values[i]) end
    return { returned = n, echoed = echoed }
end
