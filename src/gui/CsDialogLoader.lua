-- ============================================================
-- CsDialogLoader.lua
-- Centralized dialog registration and management.
-- Adapted from FS25_NPCFavor/DialogLoader.lua (confirmed working FS25 v1.16).
--
-- Named CsDialogLoader (not DialogLoader) to avoid name collision if
-- FS25_NPCFavor is also loaded in the same Lua environment.
--
-- Pattern:
--   CsDialogLoader.register("MyDialog", MyClass, "gui/MyDialog.xml")
--   CsDialogLoader.show("MyDialog", "setData", ...)  -- sets data, then shows
--   CsDialogLoader.cleanup()                          -- call in FSBaseMission.delete
--
-- Dialogs are lazily loaded on first show() call.
-- ============================================================

CsDialogLoader = {}

-- Registry: name -> { class, xmlPath, instance, loaded }
CsDialogLoader.dialogs = {}

-- Mod directory (set once via init())
CsDialogLoader.modDirectory = nil

--- Set the mod base directory (with trailing slash).
function CsDialogLoader.init(modDir)
    CsDialogLoader.modDirectory = modDir
end

--- Register a dialog class and XML path for lazy loading.
-- @param name        Unique dialog name used as g_gui key
-- @param dialogClass Lua class table with a .new() function
-- @param xmlPath     Relative path from mod root to the XML file
function CsDialogLoader.register(name, dialogClass, xmlPath)
    if not name or not dialogClass or not xmlPath then
        print("[CropStress] CsDialogLoader.register() requires name, class, xmlPath")
        return
    end
    CsDialogLoader.dialogs[name] = {
        class   = dialogClass,
        xmlPath = xmlPath,
        instance = nil,
        loaded   = false,
    }
end

--- Ensure a dialog is loaded into g_gui (lazy — only loads once).
-- @param  name     Dialog name
-- @return boolean  true if loaded and ready
function CsDialogLoader.ensureLoaded(name)
    local entry = CsDialogLoader.dialogs[name]
    if not entry then
        print("[CropStress] CsDialogLoader ERROR: '" .. tostring(name) .. "' not registered")
        return false
    end

    if entry.loaded then return true end

    if not g_gui then
        print("[CropStress] CsDialogLoader ERROR: g_gui not available")
        return false
    end

    local modDir = CsDialogLoader.modDirectory
    if not modDir then
        print("[CropStress] CsDialogLoader ERROR: modDirectory not set — call CsDialogLoader.init() first")
        return false
    end

    local ok, err = pcall(function()
        -- Create instance, load XML.
        -- g_gui:loadGui() calls onCreate() on the instance, which calls
        -- superClass().onCreate() → FS25 auto-wires all elements by id into self.*.
        local instance = entry.class.new()
        g_gui:loadGui(modDir .. entry.xmlPath, name, instance)
        entry.instance = instance
        entry.loaded   = true
    end)

    if not ok then
        print("[CropStress] CsDialogLoader ERROR loading '" .. name .. "': " .. tostring(err))
        return false
    end

    if g_gui.guis and g_gui.guis[name] then
        print("[CropStress] CsDialogLoader '" .. name .. "' loaded OK")
        return true
    else
        print("[CropStress] CsDialogLoader WARNING: '" .. name .. "' not found in g_gui.guis after loadGui")
        entry.loaded = false
        return false
    end
end

--- Show a dialog, calling an optional data-setter method BEFORE showDialog().
-- This ensures onOpen() has pre-set data to display (NPCFavor confirmed pattern).
-- @param name        Dialog name
-- @param dataMethod  Optional string: method name to call on instance first
-- @param ...         Arguments forwarded to the data-setter
-- @return boolean    true if shown successfully
function CsDialogLoader.show(name, dataMethod, ...)
    if not CsDialogLoader.ensureLoaded(name) then return false end

    local entry = CsDialogLoader.dialogs[name]
    if not entry or not entry.instance then return false end

    -- Call data setter BEFORE showDialog() so onOpen() sees the data.
    if dataMethod and entry.instance[dataMethod] then
        local ok, err = pcall(entry.instance[dataMethod], entry.instance, ...)
        if not ok then
            print("[CropStress] CsDialogLoader ERROR calling " .. name .. ":" .. dataMethod .. "(): " .. tostring(err))
        end
    end

    local ok, err = pcall(function()
        g_gui:showDialog(name)
    end)

    if not ok then
        print("[CropStress] CsDialogLoader ERROR showing '" .. name .. "': " .. tostring(err))
        -- BUILD 18:15 abort-clean: showDialog pushes the dialog BEFORE onOpen runs,
        -- so an onOpen throw leaves a half-built shell on the GUI stack. Returning
        -- false without tearing it down is what left Esc showing a dialog that could
        -- not be clicked or closed. Close it so the failure is visible in the log
        -- rather than parked on the player's screen.
        pcall(function()
            if g_gui ~= nil and type(g_gui.closeDialog) == "function" then
                g_gui:closeDialog(entry.instance)
            end
        end)
        pcall(function() entry.instance:close() end)
        return false
    end

    return true
end

--- Return the stored dialog instance for direct method calls.
-- @param  name  Dialog name
-- @return Dialog instance or nil
function CsDialogLoader.getDialog(name)
    local entry = CsDialogLoader.dialogs[name]
    if entry then return entry.instance end
    return nil
end

--- Close a dialog if currently visible.
function CsDialogLoader.close(name)
    local entry = CsDialogLoader.dialogs[name]
    if entry and entry.instance then
        pcall(function() entry.instance:close() end)
    end
end

--- Reset all dialog instances (call in FSBaseMission.delete).
-- Resets loaded flag so the next mission load re-creates clean instances.
function CsDialogLoader.cleanup()
    for _, entry in pairs(CsDialogLoader.dialogs) do
        if entry.instance then
            pcall(function() entry.instance:close() end)
        end
        entry.instance = nil
        entry.loaded   = false
    end
end

print("[CropStress] CsDialogLoader loaded")
