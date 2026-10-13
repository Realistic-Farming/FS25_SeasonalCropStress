-- =========================================================
-- ScsRainstarPumpPower
-- BUILD 22:25 - the EMP pump is the Rainstar's power source.
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
--
-- What counts as powered
-- ----------------------
-- ScsPumpHoseConnection already back-links the reel on connect (partner.rwsmVirtualPump)
-- and clears it on disconnect, so the Rainstar can see its own supply hose without any
-- new plumbing. Powered means: that pump still names THIS reel as its partner, and the
-- pump is running. Both halves matter - a connected hose on a dead pump is not power.
--
-- Everything else defers to superFunc, so a tractor on the drawbar behaves exactly as
-- before and the pump path is purely additive. No Motorized on the Rainstar, no fake
-- attach, no invented PTO.
-- =========================================================

ScsRainstarPumpPower = ScsRainstarPumpPower or {}

function ScsRainstarPumpPower.prerequisitesPresent(specializations)
    return true
end

function ScsRainstarPumpPower.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(
        vehicleType, "getIsPowered", ScsRainstarPumpPower.getIsPowered)
end

--- True only while a live supply hose from a RUNNING pump reaches this reel.
local lastDiagTime = 0
local DIAG_INTERVAL_MS = 5000

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

local function diagPumpPower(vehicle)
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    if now - lastDiagTime < DIAG_INTERVAL_MS then return end
    lastDiagTime = now
    local pump = vehicle ~= nil and vehicle.rwsmVirtualPump or nil
    if pump == nil then
        print("[CropStress] PumpPower diag: no rwsmVirtualPump on Rainstar")
        return
    end
    local partnerOk = "n/a"
    if type(pump.getScsHosePartner) == "function" then
        local ok, partner = pcall(pump.getScsHosePartner, pump)
        partnerOk = ok and (partner == vehicle and "match" or "MISMATCH") or "error"
    end
    local running = "n/a"
    if ScsPumpHoseConnection ~= nil and type(ScsPumpHoseConnection.getIsPumpRunning) == "function" then
        local ok, r = pcall(ScsPumpHoseConnection.getIsPumpRunning, pump)
        running = ok and tostring(r) or "error"
    end
    print(string.format("[CropStress] PumpPower diag: partner=%s running=%s powered=%s",
        partnerOk, running, tostring(poweredByPump(vehicle))))
end

function ScsRainstarPumpPower:getIsPowered(superFunc)
    if poweredByPump(self) then
        return true
    end
    diagPumpPower(self)
    local isPowered, warning = superFunc(self)
    if not isPowered and self.getAttacherVehicle ~= nil then
        local ok, attacher = pcall(self.getAttacherVehicle, self)
        -- Unhitched and unpowered: the vanilla warning tells the player to attach to a
        -- vehicle with a motor, which is no longer the only way to run this reel. Say
        -- what actually works instead of repeating an instruction that is now half true.
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

print("[CropStress] ScsRainstarPumpPower loaded")
