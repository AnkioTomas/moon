--[[--
段评配置键（settings/reviews.lua）与设置：阅读分组里的「段评」页。

各账号的显示开关仍是该源的 `show_paragraph_reviews`（书源设置页、阅读快捷面板写同一处）。
这一页列出有段评的已启用源，就地开关；画线样式也在这里。

@module koplugin.book.features.reviews.setting
--]]

local MarkStyle = require("reader.mark_style")
local _ = require("gettext")

local Setting = {}

local FONT_MIN, FONT_MAX = 80, 200

Setting.KEYS = { style = "book_reviews_mark_style", gray = "mark_gray", opacity = "mark_opacity", offset = "mark_offset" }

--- 已启用、且能力清单里有「他人段评」的源。
--- 段评方法在源实例上，require 到的是门面，不能拿来判断。
---@return BookSourceMeta[]
local function reviewAccounts()
    local mark = _("他人段评")
    local out = {}
    for _idx, meta in ipairs(require("source.registry").listEnabled()) do
        for _i, ability in ipairs(meta.abilities or {}) do
            if ability == mark then
                out[#out + 1] = meta
                break
            end
        end
    end
    return out
end

-- book_reviews_mark_style：dashed 虚线 / solid 实线 / dotted 点状。
-- mark_offset：线相对默认位置的上下微调（像素，-10–10，负数靠近文字）。
-- mark_gray：线的灰度（深浅，0 白–100 黑）；mark_opacity：线的不透明度（10–100），与底色混合。
-- font_scale：段评列表正文字号百分比（80–200，设置页「段评字号」调整）。
-- chapter_links：章会话的书（微信读书、京东读书）借段评用的关联，按「源 id\0书目 id」记，见 features.reviews.linked。
Setting.defaults = {
    book_reviews_mark_style = "dashed",
    mark_gray = 73,
    mark_opacity = 100,
    mark_offset = 0,
    font_scale = 100,
    replies_pos = "left",
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
                docs = "/manual/reader/ui/reviews",
                sections = function()
                    local MoonSettings = require("utils.settings")
                    local ReviewSetting = require("source.review_setting")
                    local Row = require("ui.themes.widgets.row")
                    local reviews = MoonSettings.get("features.reviews")
                    local function redraw()
                        MoonSettings.save("features.reviews", reviews)
                        local ui = require("apps/reader/readerui").instance
                        if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
                        desktop:updateView()
                    end
                    local accounts = {}
                    for _idx, meta in ipairs(reviewAccounts()) do
                        accounts[#accounts + 1] = function(iw)
                            local on = ReviewSetting.enabled(meta.id)
                            return Row.widget({
                                width = iw, chevron = false, kind = "toggle", icon = "forum",
                                title = meta.name,
                                subtitle = _("阅读时给有他人段评的段落末尾画线，点按查看；需联网"),
                                status = on and _("开") or _("关"), status_on = on,
                                callback = function()
                                    ReviewSetting.set(meta.id, not on)
                                    local ui = require("apps/reader/readerui").instance
                                    if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
                                    desktop:updateView()
                                end,
                            })
                        end
                    end
                    local sections = {}
                    if accounts[1] then
                        sections[#sections + 1] = { title = _("账号"), rows = accounts }
                    end
                    local rows = MarkStyle.rows(reviews, Setting.KEYS, {
                        style = _("段评下划线样式"),
                        position = _("段评下划线位置"),
                        position_title = _("段评下划线位置（负数靠近文字）"),
                        gray = _("段评下划线灰度"),
                        opacity = _("段评下划线透明度"),
                    }, redraw)
                    rows[#rows + 1] = function(iw)
                        return Row.widget({
                            width = iw, chevron = true,
                            kind = "nav", icon = "format_size", title = _("段评字号"),
                            status = reviews.font_scale .. "%",
                            callback = function()
                                require("ui.themes.widgets.spin"):new{
                                    title = _("段评字号"),
                                    fields = { { value = reviews.font_scale, min = FONT_MIN, max = FONT_MAX,
                                        step = 10, format = function(v) return v .. "%" end } },
                                    callback = function(pct)
                                        reviews.font_scale = pct
                                        MoonSettings.save("features.reviews", reviews)
                                        desktop:updateView()
                                    end,
                                }:show()
                            end,
                        })
                    end
                    rows[#rows + 1] = function(iw)
                        return Row.choice({
                            width = iw,
                            icon = "forum",
                            title = _("回复按钮位置"),
                            items = {
                                { value = "left", text = _("左侧") },
                                { value = "right", text = _("右侧") },
                            },
                            current = reviews.replies_pos or "left",
                            on_select = function(value)
                                reviews.replies_pos = value
                                MoonSettings.save("features.reviews", reviews)
                                local ui = require("apps/reader/readerui").instance
                                if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
                                desktop:updateView()
                            end,
                        })
                    end
                    sections[#sections + 1] = { title = _("段评"), rows = rows }
                    return sections
                end,
            },
        },
    }
end

return Setting
