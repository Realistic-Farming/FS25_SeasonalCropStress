-- ============================================================
-- CsHelpDialog.lua
-- Static help / reference dialog for the PDA screen.
-- All content is defined in xml/gui/CsHelpDialog.xml.
--
-- Pattern: identical to CropConsultantDialog (MessageDialog base,
-- CsDialogLoader registration, confirmed FS25 v1.16 pattern).
-- No dynamic data — onOpen simply calls super.
-- ============================================================

CsHelpDialog = {}
local CsHelpDialog_mt = Class(CsHelpDialog, MessageDialog)

function CsHelpDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or CsHelpDialog_mt)
    return self
end

function CsHelpDialog:onCreate()
    local ok, err = pcall(function()
        CsHelpDialog:superClass().onCreate(self)
    end)
    if not ok then
        print("[CropStress] CsHelpDialog:onCreate() error: " .. tostring(err))
    end
end

function CsHelpDialog:onOpen()
    CsHelpDialog:superClass().onOpen(self)
end

function CsHelpDialog:onClose()
    CsHelpDialog:superClass().onClose(self)
end
