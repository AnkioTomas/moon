--[[--
Feature 快捷面板开关模板。复制本目录后按需改 `actions`；不需要开关就删掉本文件。

`scope` 只有 desktop（桌面快捷面板）和 reader（阅读快捷面板）。
开关追加在该侧内置项之后，顺序按 feature 目录名（经 Features.scan 扫描）。
id 必须和内置动作、其他 feature 都不重复。已写入 quick_panel_actions /
quick_panel_reader_actions 的 id 保持用户原来的启用和排序；不在这份列表里的新开关默认关。

    function Panel.actions()
        return {
            {
                id = "example",
                title = "标题", -- 界面文案用 gettext
                icon = "tune",
                scope = "reader",
                run = function(ctx) end,
            },
        }
    end

本模板返回空列表，扫描到也不会出现在面板上。
顶层不要 require 快捷面板：注册表加载开关时会进来，会绕回去。

@module koplugin.book.features.tpl.panel
--]]

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {}
end

return Panel
