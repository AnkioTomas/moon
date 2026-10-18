--[[--
阅读页顶栏、底栏的设置入口。页内容仍由 features.bars.page 画。

@module koplugin.book.features.bars.setting
--]]

local _ = require("gettext")

local Setting = {}

-- 布局是有序列表 { { id, align }, ... }，不在列表里的组件就是关；features.bars.layout 用它做缺省。
Setting.defaults = {
    book_reader_top_bar = true,
    book_reader_bottom_bar = true,
    book_reader_replace_top_bar = true,
    book_reader_replace_bottom_bar = true,
    book_reader_bar_icons = true,
    book_reader_top_bar_divider = false,
    book_reader_bottom_bar_divider = false,
    book_reader_top_bar_layout = {
        { id = "chapter", align = "left" },
        { id = "clock", align = "right" },
    },
    book_reader_bottom_bar_layout = {
        { id = "progress_bar", align = "left" },
        { id = "percent", align = "right" },
        { id = "chapter_idx", align = "right" },
        { id = "remaining", align = "right" },
    },
}

--- 无默认值的持久键：顶栏高度（读取时由 features.bars.layout 夹到合法范围）。
Setting.keys = { "book_reader_top_bar_height" }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local function item(which, id, order, icon, title, subtitle)
        return {
            id = id,
            group = "reader",
            order = order,
            icon = icon,
            title = title,
            subtitle = subtitle,
            page = {
                title = title,
                preview = function(width)
                    return require("features.bars.page"):page(desktop, which).preview(width)
                end,
                sections = function()
                    return require("features.bars.page"):page(desktop, which).sections
                end,
            },
        }
    end
    return {
        item("top", "top", 40, "vertical_align_top", _("阅读页顶栏"), _("页面顶部的信息组件")),
        item("bottom", "bottom", 50, "horizontal_rule", _("阅读页底栏"), _("进度条、百分比等")),
    }
end

return Setting
