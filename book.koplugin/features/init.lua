--[[--
Feature 生命周期分发。

`list` 是唯一登记处：条目为目录名，对应模块 `features.<name>`；顺序即调用顺序
（monkey-patch 同一 KOReader 方法的 feature 靠它定先后），不扫目录。

钩子都是可选的模块函数，名字就是 KOReader 事件名（onCreate 除外），参数只有插件实例；
要分侧就看 `plugin.ui.document`（有文档 = 阅读器侧）。别用 `plugin.desktop`：那是桌面窗口，FM 侧也常为 nil。

  onCreate(plugin)            每个插件实例 init 时（FM / Reader 各一份），feature 自行防重入
  onSuspend(plugin)           休眠前
  onResume(plugin)            唤醒后
  onExit(plugin)              KOReader 退出
  onNetworkConnected(plugin)  网络恢复
  onReaderReady(plugin)       阅读页就绪（reader/page.lua 发出，早于首绘 UpdatePos）

KOReader 事件（Dispatcher 动作、FrontlightStateChanged 这类广播）写进模块的 `events` 表：
键是事件名（不带 on），值是 `fn(plugin, ...)`；插件自身没处理的事件经 `Features.handleEvent` 转过来，
返回 true 即视为已处理、不再往后传。feature 不往插件实例上挂方法。

每个 feature 的钩子经 `ui.guard` 隔离：一个抛错弹错误页，不影响其余 feature。实现就在 `features/<name>/`，这里只登记生命周期钩子与 KOReader 事件。

下面四个约定文件都经 `Features.scan` 扫描目录收集（按目录名排序），不经本文件、不看 `list`：

可选 `features/<name>/setting.lua`（设置页收集）：
  - `defaults` / `keys`：本 feature 的配置键与默认值，落盘到 settings/<name>.lua，经 `utils.settings.get("features.<name>")` 读、
    `save("features.<name>")` 写（keys 是无默认值但要从旧分区迁移的持久键）。规则与核心拥有者相同，见 utils/settings.lua。
  - `entries(desktop)` 返回条目数组，按层级合并进设置页：`group` 挂到根页分组（导航页或直接放行），
    `parent` 往已有页面追加分节；每条带 `order`。格式与校验见 `desktop/pages/setting/tree.lua`。
    没有 entries 就不出现在设置页。`utils.settings` 读默认值也会加载它（阅读器侧也会），顶层别 require 界面模块。

可选 `features/<name>/events.lua`：返回 `{ [事件名] = fn(...) }`，订阅核心发出的数据事件（如 book_identity_changed），
由 `utils.event` 在插件 init 时登记。和模块里的 `events` 表（KOReader 事件）是两回事。

可选 `features/<name>/panel.lua`：`actions()` 返回数组，每条是一个快捷面板开关，`scope` 为 desktop 或 reader。
由快捷面板注册表（features/panel/actions/registry.lua）加载时收集，追加在该侧内置开关之后。

可选 `features/<name>/topbar.lua`：`items()` 返回桌面顶栏项数组（BookTopBarItem，见 desktop/topbar），
由顶栏首次用到时收集，追加在核心项之后；设置页的开关与预览读同一份数据。

@module koplugin.book.features
--]]

local Guard = require("ui.guard")

local Features = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
local scanned = {}

--- 扫描 features/ 下提供 `<file>.lua` 的目录名，按名字排序；每种文件本进程只扫一次。
---@param file string 约定文件名（不带 .lua），如 "setting" / "events" / "panel"
---@return string[]
function Features.scan(file)
    if scanned[file] then return scanned[file] end
    local lfs = require("libs/libkoreader-lfs")
    local names = {}
    for name in lfs.dir(DIR) do
        if name:sub(1, 1) ~= "." and lfs.attributes(DIR .. "/" .. name .. "/" .. file .. ".lua", "mode") == "file" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    scanned[file] = names
    return names
end

-- 顺序即 onCreate 先后。bars / sidebar 没有 onCreate，排前面只影响设置页里的行序。
Features.list = {
    "clock", -- 最先：时区要在其它 feature 按本地时间算东西之前生效
    "nightmode",
    "panel",
    "azw3",
    "bars",
    "sidebar",
    "xray",
    "ai",
    "reviews",
    "rare",
    "translate",
    "reflow",
    "animation",
    "dictionary",
    "ocr",
    "baike",
    "lockscreen",
    "passcode", -- 必须在 remote 之前：remote 的 onCreate / onResume 要看到已锁
    "keyboard",
    "ime",
    "remote",
    "update",
}

---@param hook string
---@param plugin BookPlugin
function Features.emit(hook, plugin)
    for _idx, name in ipairs(Features.list) do
        local fn = require("features." .. name)[hook]
        if fn then Guard.call("feature " .. name .. "." .. hook, fn, plugin) end
    end
end

-- handler 名（on + 事件名）→ { label, fn } 数组，首次分发时按 list 顺序建好。
local routes

---@param event table KOReader Event（handler / args）
---@param plugin BookPlugin
---@return boolean handled
function Features.handleEvent(event, plugin)
    if not routes then
        routes = {}
        for _idx, name in ipairs(Features.list) do
            for ev, fn in pairs(require("features." .. name).events or {}) do
                local handler = "on" .. ev
                routes[handler] = routes[handler] or {}
                table.insert(routes[handler], { label = "feature " .. name .. ".events." .. ev, fn = fn })
            end
        end
    end
    local list = routes[event.handler]
    if not list then return false end
    for _idx, route in ipairs(list) do
        if Guard.call(route.label, route.fn, plugin, unpack(event.args, 1, event.args.n)) then return true end
    end
    return false
end

return Features
