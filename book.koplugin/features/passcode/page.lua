--[[--
锁屏密码设置行：开关、修改密码、忘记密码说明（入口见 setting.lua）。

关闭和修改都要先输对旧密码，否则拿到解锁状态设备的人能直接去掉锁。

@module koplugin.book.features.passcode.page
--]]

local Passcode = require("features.passcode")
local Row = require("ui.themes.widgets.row")
local Toast = require("ui.themes.widgets.toast")
local Paths = require("utils.paths")
require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local Page = {}

--- 输两遍新密码（或手势），一致才保存；保存即覆盖旧方式。
---@param desktop BookDesktop
---@param mode "pin"|"pattern"
local function askNew(desktop, mode)
    local pattern = mode == "pattern"
    local Input = require(pattern and "features.passcode.pattern" or "features.passcode.pad")
    Input:new{
        title = pattern and _("设置新手势（至少 4 个点）") or _("设置新密码（4～6 位数字）"),
        dismissable = true,
        on_submit = function(first)
            Input:new{
                title = pattern and _("再次绘制新手势") or _("再次输入新密码"),
                dismissable = true,
                on_submit = function(second)
                    if second ~= first then return pattern and _("两次绘制不一致") or _("两次输入不一致") end
                    Passcode.setPin(second, mode)
                    desktop:updateView()
                    Toast:new{ text = pattern and _("手势密码已设置") or _("锁屏密码已设置") }:show()
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
    local pattern = Passcode.mode() == "pattern"
    require(pattern and "features.passcode.pattern" or "features.passcode.pad"):new{
        title = pattern and _("绘制当前手势") or _("输入当前密码"),
        dismissable = true,
        on_submit = function(pin)
            local ok, err = Passcode.verify(pin)
            if not ok then return err end
            fn()
            return true
        end,
    }:show()
end

--- 开关行：本方式已开则验证后关闭；没开则（已有另一种方式时先验证）设置，覆盖另一种。
---@param desktop BookDesktop
---@param mode "pin"|"pattern"
---@param spec table icon / title / subtitle
---@return fun(width: number): table
local function modeRow(desktop, mode, spec)
    return function(iw)
        local on = Passcode.hasPin() and Passcode.mode() == mode
        return Row.widget({
            width = iw, icon = spec.icon, title = spec.title, subtitle = spec.subtitle,
            toggle = on,
            callback = function()
                if on then
                    return verifyThen(function()
                        Passcode.clear()
                        desktop:updateView()
                        Toast:new{ text = _("锁屏密码已关闭") }:show()
                    end)
                end
                if Passcode.hasPin() then return verifyThen(function() askNew(desktop, mode) end) end
                askNew(desktop, mode)
            end,
        })
    end
end

---@param desktop BookDesktop
---@return (fun(width: number): table)[]
function Page.rows(desktop)
    return {
        modeRow(desktop, "pin", { icon = "lock", title = _("数字密码"),
            subtitle = _("开机和唤醒时需要输入数字密码") }),
        modeRow(desktop, "pattern", { icon = "gesture", title = _("手势密码"),
            subtitle = _("开机和唤醒时需要绘制手势；与数字密码二选一") }),
        function(iw)
            return Row.widget({
                width = iw, icon = "password", title = _("修改密码"),
                enabled = Passcode.hasPin(),
                callback = function() verifyThen(function() askNew(desktop, Passcode.mode()) end) end,
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
