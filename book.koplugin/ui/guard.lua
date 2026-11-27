--[[--
插件入口的错误隔离：KOReader 不保护事件处理和回调，插件抛错会直接带崩整个阅读器。

只包插件自己拥有的入口（生命周期、阅读事件、features 钩子、打开桌面）：出错时写日志，
弹全屏错误页（版本 + 位置 + 堆栈，可复制）让用户反馈，出错的这次调用视为未处理。
业务内部不要用它，异常应一路冒到入口。

堆栈帧里若出现其它 `.koplugin`（排除 guard 自身帧），归到该插件：引导用户找对应作者，
不要把锅甩给月读。`module not found` 展开的 package.path（`no file`）不是堆栈帧，
不能拿来甩锅——一次 require 失败会把每个已装插件目录都列进去。
`http.mirror` / `http.release` 是月读对外的模块，缺了是月读毁约，不归调用方。

  BookPlugin.onPageUpdate = Guard.wrap("onPageUpdate", Session.onPageUpdate)
  Guard.call("feature bars.onCreate", fn, plugin)

@module koplugin.book.ui.guard
--]]

local logger = require("utils.log")

local Guard = {}

--- 错误页在屏上时后续错误只记日志：每页都抛的 bug 不能刷出一摞对话框。
local showing = false

--- guard.lua 所在插件根（…/xxx.koplugin）；目录名随安装名变，不能写死 book.koplugin。
local GUARD_SRC = debug.getinfo(1, "S").source
local PLUGIN_ROOT = GUARD_SRC:match("^@(.*)/ui/guard%.lua$")
local OURS = (PLUGIN_ROOT and PLUGIN_ROOT:match("([^/\\]+%.koplugin)$")) or "book.koplugin"
local PLUGINS_PARENT = PLUGIN_ROOT and PLUGIN_ROOT:match("^(.*)/[^/\\]+$")

--- 月读删过、已发布插件仍在 require 的模块。缺它们是月读的契约破裂。
local MOON_MODULES = {
    ["http.mirror"] = true,
    ["http.release"] = true,
}

--- 堆栈帧里扫到的其它 `.koplugin`：必须在磁盘上真有这个目录，否则当月读自己的错
--- （避免路径被污染 / 残留字符串时甩锅给根本不存在的插件名）。
--- 只认 `路径:行号:`，不认 module-not-found 的 `no file` 搜索路径。
---@param trace string
---@return string[]|nil
function Guard.foreignPlugins(trace)
    trace = tostring(trace)
    local missing = trace:match("module '([%w_%.]+)' not found")
    if missing and MOON_MODULES[missing] then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local seen, list = {}, {}
    for line in trace:gmatch("[^\r\n]+") do
        if not line:find("[/\\]ui[/\\]guard%.lua", 1) then
            local name = line:match("([^/\\]+%.koplugin)[/\\].-:%d+:")
            if name and name ~= OURS and not seen[name] then
                -- 目录不在月读同级 plugins/ 下就不甩锅：堆栈字符串可能被污染，或残留已删插件路径。
                local dir = PLUGINS_PARENT and (PLUGINS_PARENT .. "/" .. name)
                if dir and lfs.attributes(dir, "mode") == "directory" then
                    seen[name] = true
                    list[#list + 1] = name
                end
            end
        end
    end
    if #list == 0 then return nil end
    return list
end

---@param dir string foo.koplugin
---@return string foo
local function pluginLabel(dir)
    return (dir:gsub("%.koplugin$", ""))
end

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

    local foreign = Guard.foreignPlugins(trace)
    local title, guide, ownership
    if foreign then
        local labels = {}
        for i, dir in ipairs(foreign) do labels[i] = pluginLabel(dir) end
        local joined = table.concat(labels, _("、"))
        title = T(_("插件「%1」出错了"), joined)
        guide = T(_("这个错误看起来来自插件「%1」，不是月读本身。请把下面的信息反馈给该插件的作者，而不是月读。"), joined)
        ownership = T(_("归属：其它插件 %1"), table.concat(foreign, ", "))
    else
        title = _("月读出错了")
        guide = _("月读遇到了一个错误，已跳过出错的操作。请复制或截图下面的信息反馈给开发者。")
        ownership = _("归属：月读")
    end

    local report = ownership .. "\n" .. T(_("月读版本：%1\nKOReader：%2\n设备：%3\n位置：%4\n\n%5"),
        require("bookversion"), require("version"):getShortVersion(), Device.model, label, trace)
    local dialog
    dialog = TextViewer:new{
        title = title,
        text = guide .. "\n\n" .. report,
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
