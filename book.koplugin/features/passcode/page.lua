--[[--
锁屏密码设置行：开关、修改密码、忘记密码说明（入口见 setting.lua）。

关闭和修改都要先输对旧密码，否则拿到解锁状态设备的人能直接去掉锁。

@module koplugin.book.features.passcode.page
--]]

local Pad = require("features.passcode.pad")
local Passcode = require("features.passcode")
local Row = require("ui.themes.widgets.row")
local Toast = require("ui.themes.widgets.toast")
local Paths = require("utils.paths")
require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local Page = {}

--- 输两遍新密码，一致才保存。
---@param desktop BookDesktop
local function askNew(desktop)
    Pad:new{
        title = _("设置新密码（4～6 位数字）"),
        dismissable = true,
        on_submit = function(first)
            Pad:new{
                title = _("再次输入新密码"),
                dismissable = true,
                on_submit = function(second)
                    if second ~= first then return _("两次输入不一致") end
                    Passcode.setPin(second)
                    desktop:updateView()
                    Toast:new{ text = _("锁屏密码已设置") }:show()
                    return true
                end,
            }:show()
            return true
        end,
    }:show()
end

--- 先验旧密码再执行 fn。
---@param fn fun()
local function verifyThen(fn)
    Pad:new{
        title = _("输入当前密码"),
        dismissable = true,
        on_submit = function(pin)
            local ok, err = Passcode.verify(pin)
            if not ok then return err end
            fn()
            return true
        end,
    }:show()
end

---@param desktop BookDesktop
---@return (fun(width: number): table)[]
function Page.rows(desktop)
    return {
        function(iw)
            local on = Passcode.hasPin()
            return Row.widget({
                width = iw, icon = "lock", title = _("锁屏密码"),
                subtitle = _("开机和唤醒时需要输入数字密码"),
                toggle = on,
                callback = function()
                    if not on then return askNew(desktop) end
                    verifyThen(function()
                        Passcode.clear()
                        desktop:updateView()
                        Toast:new{ text = _("锁屏密码已关闭") }:show()
                    end)
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, icon = "password", title = _("修改密码"),
                enabled = Passcode.hasPin(),
                callback = function() verifyThen(function() askNew(desktop) end) end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, icon = "help", title = _("忘记密码"),
                subtitle = T(_("用 USB 连接电脑，删除 %1 和 %1.old 即可解除；密码只防旁人翻看，不加密书籍，也别用银行卡密码"),
                    Paths.sectionPath("passcode")),
            })
        end,
    }
end

return Page
