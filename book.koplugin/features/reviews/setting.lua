--[[--
段评配置键（settings/reviews.lua）与设置：往桌面「查词」页追加「段评」分节。

显示开关归微信读书源（`show_paragraph_reviews`，在源设置页），这里只管画线样式。

@module koplugin.book.features.reviews.setting
--]]

local _ = require("gettext")

local Setting = {}

-- book_reviews_mark_style：dashed 虚线 / solid 实线。
-- chapter_links：章会话的书（微信读书、京东读书）借段评用的关联，按「源 id\0书目 id」记，见 features.reviews.linked。
Setting.defaults = {
    book_reviews_mark_style = "dashed",
    chapter_links = {},
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "reader",
            order = 15,
            icon = "rate_review",
            title = _("段评"),
            subtitle = _("他人段评的页内标记"),
            page = {
                title = _("段评"),
                sections = function()
                    local MoonSettings = require("utils.settings")
                    local Row = require("ui.themes.widgets.row")
                    local reviews = MoonSettings.get("features.reviews")
                    local solid = reviews.book_reviews_mark_style == "solid"
                    return {
                        {
                            title = _("段评"),
                            rows = {
                                function(iw)
                                    return Row.widget({
                                        width = iw, chevron = true,
                                        kind = "nav", icon = "border_style", title = _("段评下划线样式"),
                                        status = solid and _("实线") or _("虚线"),
                                        callback = function()
                                            reviews.book_reviews_mark_style = solid and "dashed" or "solid"
                                            MoonSettings.save("features.reviews", reviews)
                                            local ui = require("apps/reader/readerui").instance
                                            if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
                                            desktop:updateView()
                                        end,
                                    })
                                end,
                            },
                        },
                    }
                end,
            },
        },
    }
end

return Setting
