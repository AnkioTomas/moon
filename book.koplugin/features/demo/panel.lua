--[[--
Feature 快捷面板开关模板。复制本目录后按需改 `actions`；不需要开关就删掉本文件。

约定：属于某个 feature 的快捷开关只写在 `features/<name>/panel.lua`，
不往 `features/panel/actions/` 里加（那里只放 KOReader 原生能力与核心阅读会话）。

`scope` 只有 desktop（桌面快捷面板）和 reader（阅读快捷面板）。
开关追加在该侧内置项之后，顺序按 feature 目录名（经 Features.scan 扫描）。
id 必须和内置动作、其他 feature 都不重复，上线后不能改名。已写入 quick_panel_actions /
quick_panel_reader_actions 的 id 保持用户原来的启用和排序；不在这份列表里的新开关默认关
（想默认开就加进 `features/panel/setting.lua` 的 defaults）。

字段（注册时校验，不合法直接报错）：
- 必填：`id` / `title` / `icon`（Material 图标名）/ `scope`
- 多语言：`title` 必须经 gettext（`_()`），源字符串即简体中文；新文案同时加进
  `l10n/en.lua` 与 `l10n/zh_TW.lua`（tests/l10n_spec.lua 双向校验）；模块顶部 `require("l10n").apply()`
- 二选一：`run(ctx)` 自己执行；或 `event` 广播 KOReader 事件名
- 可选：`available(ctx)` 是否显示。设置页调用时 `ctx.ui` 为 nil，要能勾选就返回 true；
  `active(ctx)` 是否高亮；`active_icon` 高亮时的图标；`keep_open` 点完不关面板（随后刷新）；
  `refresh_delay` keep_open 时延迟几秒再刷新（状态要等设备回填，如 Wi-Fi）
- 可选 `hold(ctx)`：长按，用来打开该开关的详情 / 设置页（如 Wi-Fi 网络列表）；总是先关面板，
  没有 `hold` 的按钮不接长按手势
- `ctx.ui`：阅读面板是当前 ReaderUI，桌面面板为 nil
- available / active / run 抛错不吞：会冒到面板入口的 guard 弹错误页

    require("l10n").apply()
    local _ = require("gettext")

    function Panel.actions()
        return {
            {
                id = "example",
                title = _("示例开关"),
                icon = "tune",
                scope = "reader",
                available = function(ctx) return not (ctx and ctx.ui) or ctx.ui.document ~= nil end,
                run = function(ctx) end,
            },
        }
    end

本模板返回空列表，扫描到也不会出现在面板上。
注册表首次用到时会一次性 require 全部 panel.lua：顶层不要 require 快捷面板（会绕回去），
也不要 require 重模块，放进 run / available 里延迟加载。

@module koplugin.book.features.demo.panel
--]]

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {}
end

return Panel
