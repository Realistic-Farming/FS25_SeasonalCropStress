-- =========================================================
-- CsLiveKeyLabel - truthful Controls chord for an InputAction
-- =========================================================
-- George-verified path (extract InputBinding / InputHelper):
--   g_inputBinding:getActionBindings() -> action:getActiveBindings()
--   prefer keyboard binding; build full chord from binding.axisNames
--   display via KeyboardHelper.getDisplayKeyName(Input[axisName])
-- Empty authoritative bindings -> localized Unbound (not factory default).
-- Non-keyboard-only bindings -> localized Keyboard unbound (not whole-action Unbound).
-- Missing API/data / malformed bindings / failed action lookup -> localized unavailable.
-- Action identity from getActionByName / nameActions only (not InputAction constants).
-- Never use single-axis helpers (lossy for chords).
-- Never present factory default as a live label.
-- =========================================================

CsLiveKeyLabel = CsLiveKeyLabel or {}

CsLiveKeyLabel.STATUS_UNBOUND = "rf_live_key_unbound"
CsLiveKeyLabel.STATUS_KEYBOARD_UNBOUND = "rf_live_key_keyboard_unbound"
CsLiveKeyLabel.STATUS_UNAVAILABLE = "rf_live_key_unavailable"

local function localize(key, fallback)
    if g_i18n ~= nil then
        if type(g_i18n.hasText) == "function" then
            local ok, has = pcall(g_i18n.hasText, g_i18n, key)
            if ok and has then
                local ok2, text = pcall(g_i18n.getText, g_i18n, key)
                if ok2 and type(text) == "string" and text ~= "" and text ~= key then
                    return text
                end
            end
        end
        if type(g_i18n.getText) == "function" then
            local ok, text = pcall(g_i18n.getText, g_i18n, key)
            if ok and type(text) == "string" and text ~= "" and text ~= key then
                return text
            end
        end
    end
    return fallback
end

function CsLiveKeyLabel.unboundText()
    return localize(CsLiveKeyLabel.STATUS_UNBOUND, "Unbound")
end

function CsLiveKeyLabel.keyboardUnboundText()
    return localize(CsLiveKeyLabel.STATUS_KEYBOARD_UNBOUND, "Keyboard unbound")
end

function CsLiveKeyLabel.unavailableText()
    return localize(CsLiveKeyLabel.STATUS_UNAVAILABLE, "unavailable")
end

local function isKeyboardBinding(binding)
    if type(binding) ~= "table" then
        return false
    end
    if binding.isKeyboard == true then
        return true
    end
    if binding.isMouse == true or binding.isGamepad == true then
        return false
    end
    if type(binding.axisNames) ~= "table" or Input == nil then
        return false
    end
    if #binding.axisNames == 0 then
        return false
    end
    for _, axisName in ipairs(binding.axisNames) do
        if type(axisName) ~= "string" or Input[axisName] == nil then
            return false
        end
    end
    return true
end

local function bindingLooksMalformed(binding)
    if type(binding) ~= "table" then
        return true
    end
    if binding.axisNames ~= nil and type(binding.axisNames) ~= "table" then
        return true
    end
    if type(binding.axisNames) == "table" then
        for _, axisName in ipairs(binding.axisNames) do
            if type(axisName) ~= "string" then
                return true
            end
        end
    end
    return false
end

local function selectPrimaryKeyboardBinding(bindings)
    if type(bindings) ~= "table" then
        return nil
    end
    local selected = nil
    for _, binding in ipairs(bindings) do
        if isKeyboardBinding(binding) then
            local selectedIndex = selected ~= nil and tonumber(selected.index) or math.huge
            local bindingIndex = tonumber(binding.index) or math.huge
            local selectedPositive = selected ~= nil and selected.axisComponent == "+"
            local bindingPositive = binding.axisComponent == "+"
            if selected == nil
                or bindingIndex < selectedIndex
                or (bindingIndex == selectedIndex and bindingPositive and not selectedPositive) then
                selected = binding
            end
        end
    end
    return selected
end

local function displayNameForAxis(axisName)
    if axisName == nil or Input == nil or KeyboardHelper == nil then
        return nil
    end
    if type(KeyboardHelper.getDisplayKeyName) ~= "function" then
        return nil
    end
    local keyId = Input[axisName]
    if keyId == nil then
        return nil
    end
    local ok, name = pcall(KeyboardHelper.getDisplayKeyName, keyId)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

local function formatChord(binding)
    if binding == nil or type(binding.axisNames) ~= "table" or #binding.axisNames == 0 then
        return nil
    end
    local parts = {}
    for _, axisName in ipairs(binding.axisNames) do
        local name = displayNameForAxis(axisName)
        if name == nil then
            return nil
        end
        parts[#parts + 1] = name
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " + ")
end

local function resolveActionObject(actionName)
    -- Engine-shaped identity only (InputBinding:getActionByName / nameActions).
    -- Do not fall back to InputAction[actionName]; that constant may not be the map key.
    if g_inputBinding == nil then
        return nil
    end
    if type(g_inputBinding.getActionByName) == "function" then
        local okA, a = pcall(g_inputBinding.getActionByName, g_inputBinding, actionName)
        if okA and a ~= nil then
            return a
        end
    end
    if type(g_inputBinding.nameActions) == "table" then
        local a = g_inputBinding.nameActions[actionName]
        if a ~= nil then
            return a
        end
    end
    return nil
end

function CsLiveKeyLabel.resolve(actionName)
    if actionName == nil or actionName == "" then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end
    if g_inputBinding == nil or type(g_inputBinding.getActionBindings) ~= "function" then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end
    if KeyboardHelper == nil or type(KeyboardHelper.getDisplayKeyName) ~= "function" then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end
    if Input == nil then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end

    local okMap, actionBindings = pcall(g_inputBinding.getActionBindings, g_inputBinding)
    if not okMap or type(actionBindings) ~= "table" then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end

    local actionObject = resolveActionObject(actionName)
    if actionObject == nil then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end

    local bindings = actionBindings[actionObject]
    if bindings == nil and type(actionObject.getActiveBindings) == "function" then
        local okB, b = pcall(actionObject.getActiveBindings, actionObject)
        if okB then
            bindings = b
        end
    end
    if type(bindings) ~= "table" then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end

    if #bindings == 0 then
        return CsLiveKeyLabel.unboundText(), "unbound"
    end

    for _, binding in ipairs(bindings) do
        if bindingLooksMalformed(binding) then
            return CsLiveKeyLabel.unavailableText(), "unavailable"
        end
    end

    local keyboard = selectPrimaryKeyboardBinding(bindings)
    if keyboard == nil then
        -- Bindings exist but none are keyboard: do not imply the whole action is unbound.
        return CsLiveKeyLabel.keyboardUnboundText(), "keyboard_unbound"
    end

    local chord = formatChord(keyboard)
    if chord == nil then
        return CsLiveKeyLabel.unavailableText(), "unavailable"
    end
    return chord, "live"
end

function CsLiveKeyLabel.get(actionName)
    local label = CsLiveKeyLabel.resolve(actionName)
    return label
end

function CsLiveKeyLabel.subscribe(target, callback)
    if g_messageCenter == nil or MessageType == nil or MessageType.INPUT_BINDINGS_CHANGED == nil then
        return nil
    end
    if type(callback) ~= "function" then
        return nil
    end
    local ok = pcall(g_messageCenter.subscribe, g_messageCenter, MessageType.INPUT_BINDINGS_CHANGED, callback, target)
    if not ok then
        return nil
    end
    return function()
        pcall(g_messageCenter.unsubscribe, g_messageCenter, MessageType.INPUT_BINDINGS_CHANGED, target)
    end
end

-- =========================================================
-- Live chord substitution in shipped label text
-- KEYBINDS-R220-20261006 part C
-- =========================================================
-- Two entry points, for the two shapes of text this suite actually ships:
--
--   expand(text)                    "{CS_TOGGLE_HUD}" -> the live chord. For strings
--                                   we own, where an explicit placeholder is clearer
--                                   than pattern matching a stale default.
--   relabel(text, action, staleKey) "Right Shift+M"   -> the live chord. For strings
--                                   we are NOT editing, above all translated ones.
--
-- Both resolve at call time and cache nothing, so a remap under Options shows up the
-- next time the text is built, with no restart and no cache to invalidate. Neither
-- ever writes a factory default as a live label: when the action carries no keyboard
-- binding the helper's own status text is used, which is the contract the five
-- existing LiveKeyLabel helpers already follow.
--
-- Why the phrase list is ordered longest first: walking left over a single word
-- strands the qualifier, turning "Right Shift+M" into "Right <chord>". That is a real
-- defect, proved against the shipped SoilLiveHint with a fengari harness, and it would
-- fire on every translated label in this mod, because all 26 translations ship the
-- English "Right Shift" rather than a localised form.
--
-- Why a sentinel: a live chord is itself of the form "<modifier> + <KEY>", so writing
-- one straight into the text leaves a fresh target for the passes that have not run
-- yet, and a second pass would overwrite the first. Matches become a marker that
-- contains no "+" and no modifier word; the real chord goes in once, at the end.
--
-- The word lists are not invented. They are the modifier and qualifier words our own
-- existing human-authored translations actually contain: Shift, Alt and the French
-- Maj, with "Right" as the one qualifier. Every other leading word in that corpus is
-- a sentence verb (Press, Pressione, Presione, Premi, Trykk, Tekan, painamalla,
-- Apasati, Stiskne), which must never be consumed or the sentence loses its verb.

CsLiveKeyLabel.MODIFIER_WORDS  = { "Shift", "Ctrl", "Control", "Alt", "Strg", "Maj" }
CsLiveKeyLabel.QUALIFIER_WORDS = { "Right", "Left" }

local SENTINEL = string.char(1) .. "RFCHORD" .. string.char(1)

local function isWordChar(c)
    return c ~= "" and c ~= nil and string.match(c, "[%w_]") ~= nil
end

local function chordPhrases()
    local out = {}
    -- qualifier plus modifier first, so the longest match wins
    for _, q in ipairs(CsLiveKeyLabel.QUALIFIER_WORDS) do
        for _, m in ipairs(CsLiveKeyLabel.MODIFIER_WORDS) do
            out[#out + 1] = q .. " " .. m
            out[#out + 1] = string.upper(q) .. " " .. string.upper(m)
        end
    end
    for _, m in ipairs(CsLiveKeyLabel.MODIFIER_WORDS) do
        out[#out + 1] = m
        out[#out + 1] = string.upper(m)
    end
    return out
end

--- Replace every "<modifier phrase>+<KEY>" label for one key with `chord`.
---@param text string
---@param staleKey string the key token exactly as the shipped string prints it, "M"
---@param chord string the replacement, normally a live chord
---@return string text, number replacedCount
function CsLiveKeyLabel.swapStaleChord(text, staleKey, chord)
    if type(text) ~= "string" or text == "" then return text, 0 end
    if type(staleKey) ~= "string" or staleKey == "" then return text, 0 end
    if type(chord) ~= "string" or chord == "" then return text, 0 end
    if string.find(text, "+", 1, true) == nil then return text, 0 end

    local replaced = 0
    for _, phrase in ipairs(chordPhrases()) do
        for _, joiner in ipairs({ "+", " + ", " +", "+ " }) do
            local needle = phrase .. joiner .. staleKey
            local i = 1
            while true do
                local s, e = string.find(text, needle, i, true)
                if s == nil then break end
                local after = (e < #text) and string.sub(text, e + 1, e + 1) or ""
                local before = (s > 1) and string.sub(text, s - 1, s - 1) or ""
                -- the key must end the token and the phrase must start a word, so
                -- "+M" does not match inside "+MX" and "Shift" not inside "Upshift"
                if not isWordChar(after) and not isWordChar(before) then
                    text = string.sub(text, 1, s - 1) .. SENTINEL
                           .. string.sub(text, e + 1)
                    replaced = replaced + 1
                    i = s + #SENTINEL
                else
                    i = e + 1
                end
            end
        end
    end

    if replaced > 0 then
        local i = 1
        while true do
            local s, e = string.find(text, SENTINEL, i, true)
            if s == nil then break end
            text = string.sub(text, 1, s - 1) .. chord .. string.sub(text, e + 1)
            i = s + #chord
        end
    end
    return text, replaced
end

--- Replace a stale label for one action with that action's live chord.
--- Leaves the text alone only when the helper cannot produce any label at all.
---@param text string
---@param actionName string
---@param staleKey string
---@return string
function CsLiveKeyLabel.relabel(text, actionName, staleKey)
    local label = CsLiveKeyLabel.get(actionName)
    if type(label) ~= "string" or label == "" then
        return text
    end
    local out = CsLiveKeyLabel.swapStaleChord(text, staleKey, label)
    return out
end

--- Replace every "{ACTION_NAME}" placeholder with that action's live chord.
---@param text string
---@return string
function CsLiveKeyLabel.expand(text)
    if type(text) ~= "string" or text == "" then return text end
    if string.find(text, "{", 1, true) == nil then return text end
    local out = string.gsub(text, "{([A-Z][A-Z0-9_]*)}", function(actionName)
        local label = CsLiveKeyLabel.get(actionName)
        if type(label) ~= "string" or label == "" then
            return CsLiveKeyLabel.unavailableText()
        end
        return label
    end)
    return out
end
