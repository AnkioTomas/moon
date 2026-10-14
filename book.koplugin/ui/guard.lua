--[[--
插件入口的错误隔离：KOReader 不保护事件处理和回调，插件抛错会直接带崩整个阅读器。

只包插件自己拥有的入口（生命周期、阅读事件、features 钩子、打开桌面）：出错时写日志，
弹全屏错误页（版本 + 位置 + 堆栈，可复制）让用户反馈，出错的这次调用视为未处理。
业务内部不要用它，异常应一路冒到入口。

  BookPlugin.onPageUpdate = Guard.wrap("onPageUpdate", Session.onPageUpdate)
  Guard.call("feature bars.onCreate", fn, plugin)

@module koplugin.book.ui.guard
--]]

local logger = require("utils.log")

local Guard = {}

--- 错误页在屏上时后续错误只记日志：每页都抛的 bug 不能刷出一摞对话框。
local showing = false

--- UI 依赖全在这里延迟加载：guard 挂在 main / desktop / features 顶上，只有出错才需要它们。
---@param label string
---@param trace string
local function show(label, trace)
    require("l10n").apply()
    local _ = require("gettext")
    local Device = require("device")
    local T = require("ffi/util").template
    local TextViewer = require("ui.themes.widgets.text_viewer")
    local Toast = require("ui.themes.widgets.toast")
    local report = T(_("月读版本：%1\nKOReader：%2\n设备：%3\n位置：%4\n\n%5"),
        require("bookversion"), require("version"):getShortVersion(), Device.model, label, trace)
    local dialog
    dialog = TextViewer:new{
        title = _("月读出错了"),
        text = _("月读遇到了一个错误，已跳过出错的操作。请复制或截图下面的信息反馈给开发者。") .. "\n\n" .. report,
        close_callback = function() showing = false end,
        buttons = {
            { text = _("关闭"), callback = function() dialog:close() end },
            {
                text = _("复制"),
                variant = "primary",
                callback = function()
                    Device.input.setClipboardText(report)
                    Toast:new{ text = _("已复制"), timeout = 2 }:show()
                end,
            },
            {
                -- 出错后不想继续用：关掉错误页和所有月读窗口（与退出兜底同一路径），回到 KOReader 文件管理器。
                text = _("关闭月读"),
                callback = function()
                    dialog:close()
                    require("ui.exit_windows").close()
                end,
            },
        },
    }
    dialog:show()
end

---@param label string
---@param trace string
local function report(label, trace)
    logger.error("guard", label, trace)
    logger.flush()
    if showing then return end
    showing = true
    -- 错误页自己都起不来（UI 模块缺失 / 主题坏了）就没法报告，交还 KOReader 崩溃流程，别吞。
    local ok, ui_err = pcall(show, label, trace)
    if not ok then
        showing = false
        error(trace .. "\n\n[guard] " .. tostring(ui_err), 0)
    end
end

---@param label string
---@param ok boolean
local function settle(label, ok, ...)
    if ok then return ... end
    report(label, (...))
end

--- 调 fn；成功原样返回其结果，抛错则报告并返回 nil（事件视为未处理）。
---@param label string 出错位置，写进日志和错误页
---@param fn function
function Guard.call(label, fn, ...)
    return settle(label, xpcall(fn, debug.traceback, ...))
end

--- 抛过错的绘制入口（按 label）：每次重绘都会再抛，关掉错误页又重绘，不停画就是死循环。
local broken = {}

--- 绘制入口专用：抛错一次后这个 label 本进程内不再画（叠加层缺失，阅读 / 桌面操作照常）。
---@param label string
---@param fn function
function Guard.paint(label, fn, ...)
    if broken[label] then return end
    local ok, err = xpcall(fn, debug.traceback, ...)
    if ok then return end
    broken[label] = true
    report(label, err)
end

--- 返回受保护的 fn，供直接挂成事件处理函数。
---@param label string
---@param fn function
---@return function
function Guard.wrap(label, fn)
    return function(...) return Guard.call(label, fn, ...) end
end

return Guard
