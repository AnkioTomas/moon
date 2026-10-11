--[[--
Feature 设置模板。复制本目录后按需改 `defaults` / `entries`；既无配置也无设置页就删掉本文件。

配置存 settings/<name>.lua：读 `require("utils.settings").get("features.<name>")`（可就地改），
写 `save("features.<name>")`。`defaults` 是默认值；`keys` 列出没有默认值但要持久的键。
两者里的键首次访问时会从旧分区（reader/display/maintenance/pinyin/quickpanel）搬过来。
只有配置、没有设置页时可以不写 `entries`。

`entries` 的条目按层级合并进设置页（规则见 desktop/pages/setting/tree.lua），每条必须有 `order`：
  - `group`：挂到根页分组（library 书库、desktop 桌面、reader 阅读、system 系统、maintenance 维护）。
    带 `page` 是导航行，点开叠层（标题、可选 preview、sections）；带 `row = fn(iw)` 是直接放在分组里的行。
  - `parent`：往已有页面追加分节，`sections = fn()`。核心页面 id 有 display、lookup 等，
    feature 页面 id 是 feature:<name>:<id>。

    function Setting.entries(desktop)
        return {
            {
                id = "main", -- 同 feature 多条时区分；省略则用序号
                group = "reader",
                order = 200, -- 核心行 10..90，已有 feature 100..150
                icon = "tune",
                title = "标题", -- 界面文案用 gettext
                subtitle = "说明",
                page = {
                    title = "标题",
                    sections = function()
                        return { { title = "标题", rows = {} } }
                    end,
                },
            },
        }
    end

本模板返回空列表，扫描到也不会出现在设置页。

@module koplugin.book.features.tpl.setting
--]]

local Setting = {}

Setting.defaults = {}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {}
end

return Setting
