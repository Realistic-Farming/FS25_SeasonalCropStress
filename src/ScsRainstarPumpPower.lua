-- =========================================================
-- ScsRainstarPumpPower
-- BUILD 22:25 - the EMP pump is the Rainstar's power source.
-- BUILD 17:16 - walk-up Turn on/off via ExternalVehicleControl
--              (scsToggleRainstar + SCS_TOGGLE_PUMP). Soft getIsPowered kept.
--
-- Why the reel demanded a tractor
-- ------------------------------
-- Rainstar's <attachable> block carries no <power> element, and the schema default
-- for vehicle.attachable.power#requiresExternalPower is TRUE. So unattached, with no
-- Motorized specialization of its own, Attachable:getIsPowered returned
-- (false, attachToPowerWarning). TurnOnVehicle.getCanBeTurnedOn gates on getIsPowered,
-- so the sprinkler could never be switched on without a tractor on the drawbar.
--
-- The tempting fix is requiresExternalPower="false" in the XML. That is wrong: it makes
-- the reel permanently self-powered, so it would run with no tractor AND no pump, and
-- "no EMP path -> cannot stay on" would fail. Power has to be conditional on the pump
-- actually running, which is a runtime question, so it belongs in an overwrite.
-- =========================================================

ScsRainstarPumpPower = {}

ScsRainstarPumpPower.currentModName = g_currentModName

local function rpTr(key, fallback)
    if g_i18n ~= nil then
        if g_i18n:hasText(key) then
            return g_i18n:getText(key)
        end
        local env = ScsRainstarPumpPower.currentModName
        if env ~= nil and g_i18n:hasText(key, env) then
            return g_i18n:getText(key, env)
        end
    end
    return fallback
end

local function rpEnsurePlayerTriggerFlag(node)
    if node == nil or node == 0 then
        return
    end
    if CollisionFlag == nil or CollisionFlag.PLAYER == nil then
        return
    end
    if CollisionFlag.getHasMaskFlagSet ~= nil
            and CollisionFlag.getHasMaskFlagSet(node, CollisionFlag.PLAYER) then
        return
    end
    if getCollisionMask == nil or setCollisionMask == nil or bit32 == nil then
        return
    end
    local ok, mask = pcall(getCollisionMask, node)
    if not ok or mask == nil then
        return
    end
    pcall(setCollisionMask, node, bit32.bor(mask, CollisionFlag.PLAYER))
end

function ScsRainstarPumpPower.prerequisitesPresent(specializations)
    return true
end

function ScsRainstarPumpPower.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(
        vehicleType, "getIsPowered", ScsRainstarPumpPower.getIsPowered)
end

function ScsRainstarPumpPower.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ScsRainstarPumpPower)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterExternalActionEvents", ScsRainstarPumpPower)
end

function ScsRainstarPumpPower:onLoad(savegame)
    local triggerNode = I3DUtil.indexToObject(self.components, "RootCol", self.i3dMappings)
    if triggerNode == nil and self.rootNode ~= nil then
        triggerNode = self.rootNode
    end
    rpEnsurePlayerTriggerFlag(triggerNode)
    self.spec_scsRainstarPumpPower = self.spec_scsRainstarPumpPower or {}
end

--- True only while a live supply hose from a RUNNING pump reaches this reel.
local function poweredByPump(vehicle)
    local pump = vehicle ~= nil and vehicle.rwsmVirtualPump or nil
    if pump == nil then
        return false
    end
    if type(pump.getScsHosePartner) == "function" then
        local ok, partner = pcall(pump.getScsHosePartner, pump)
        if not ok or partner ~= vehicle then
            return false
        end
    end
    if ScsPumpHoseConnection == nil or type(ScsPumpHoseConnection.getIsPumpRunning) ~= "function" then
        return false
    end
    local ok, running = pcall(ScsPumpHoseConnection.getIsPumpRunning, pump)
    return ok and running == true
end

function ScsRainstarPumpPower:getIsPowered(superFunc)
    if poweredByPump(self) then
        return true
    end
    local isPowered, warning = superFunc(self)
    if not isPowered and self.getAttacherVehicle ~= nil then
        local ok, attacher = pcall(self.getAttacherVehicle, self)
        if ok and attacher == nil then
            local text = warning
            if g_i18n ~= nil and type(g_i18n.getText) == "function" then
                local okTr, t = pcall(g_i18n.getText, g_i18n, "cs_rainstar_needs_pump")
                if okTr and type(t) == "string" and t ~= "" and t ~= "cs_rainstar_needs_pump" then
                    text = t
                end
            end
            return false, text
        end
    end
    return isPowered, warning
end

-- ------------------------------------------------------------
-- BUILD 17:16 walk-up Turn on / off (dedicated SCS_TOGGLE_PUMP, not ENTER_EXIT)
-- ------------------------------------------------------------

function ScsRainstarPumpPower:onRegisterExternalActionEvents(trigger, name, xmlFile, key)
    if name == "scsToggleRainstar" then
        local data = self:registerExternalActionEvent(
            trigger, name,
            ScsRainstarPumpPower.externalRegister,
            ScsRainstarPumpPower.externalUpdate)
        if self.spec_scsRainstarPumpPower ~= nil then
            self.spec_scsRainstarPumpPower.evcData = data
        end
    end
end

function ScsRainstarPumpPower.actionText(vehicle)
    if vehicle ~= nil and vehicle.getIsTurnedOn ~= nil then
        local ok, on = pcall(vehicle.getIsTurnedOn, vehicle)
        if ok and on == true then
            return rpTr("action_SCS_TURN_OFF_RAINSTAR", "Turn off Rainstar")
        end
    end
    return rpTr("action_SCS_TURN_ON_RAINSTAR", "Turn on Rainstar")
end

function ScsRainstarPumpPower.toggle(vehicle)
    if vehicle == nil or vehicle.setIsTurnedOn == nil then
        return
    end

    local isOn = false
    if vehicle.getIsTurnedOn ~= nil then
        local ok, value = pcall(vehicle.getIsTurnedOn, vehicle)
        isOn = ok and value == true
    end

    if isOn then
        pcall(vehicle.setIsTurnedOn, vehicle, false)
        return
    end

    if not poweredByPump(vehicle) then
        local msg = rpTr("warning_SCS_RAINSTAR_NEED_HOSE_PUMP", "Connect hose and start pump first")
        if g_currentMission ~= nil and g_currentMission.hud ~= nil
                and g_currentMission.hud.addSideNotification ~= nil then
            pcall(g_currentMission.hud.addSideNotification, g_currentMission.hud, msg)
        elseif vehicle.setWarningMessage ~= nil then
            pcall(vehicle.setWarningMessage, vehicle, msg, 2000)
        else
            print("[CropStress] " .. tostring(msg))
        end
        return
    end

    -- Soft power is live; setIsTurnedOn goes through TurnOnVehicle events.
    pcall(vehicle.setIsTurnedOn, vehicle, true)
end

function ScsRainstarPumpPower.externalRegister(data, vehicle)
    local action = InputAction.SCS_TOGGLE_PUMP
    if action == nil then
        return
    end
    local function onAction(_, actionName, inputValue, callbackState, isAnalog)
        ScsRainstarPumpPower.toggle(vehicle)
        ScsRainstarPumpPower.externalUpdate(data, vehicle)
    end
    local _, actionEventId = g_inputBinding:registerActionEvent(
        action, data, onAction, false, true, false, true)
    data.actionEventId = actionEventId
    if actionEventId ~= nil then
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    end
    ScsRainstarPumpPower.externalUpdate(data, vehicle)
end

function ScsRainstarPumpPower.externalUpdate(data, vehicle)
    if data == nil or data.actionEventId == nil then
        return
    end
    g_inputBinding:setActionEventText(data.actionEventId, ScsRainstarPumpPower.actionText(vehicle))
    g_inputBinding:setActionEventActive(data.actionEventId, true)
end

print("[CropStress] ScsRainstarPumpPower loaded (BUILD 17:16 EVC turn-on)")
