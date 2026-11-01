--[[--
段评的阅读快捷面板：显示开关，以及给本地书关联微信读书书目。

显示开关写当前页实际用的那份 `show_paragraph_reviews`：本章属主源自己有段评就写它，
否则写微信读书（本地书、京东读书借段评）。和书源设置页是同一处，不另存一份。

@module koplugin.book.features.reviews.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

--- 当前阅读页段评画线由哪个源的开关控制。
--- 第二个返回值：true = 本章属主源自己的段评，false = 借微信读书。
---@return string|nil
---@return boolean
local function sourceId()
    local cur = require("reader.session").current()
    local identity = cur and cur.identity
    if not identity or identity.ephemeral then return nil, false end
    local source = identity.source
    if identity.chapter_idx and source and source.paragraphHotspotsAsync then
        return source.id, true
    end
    local wechat = require("source.registry").resolve("wechat")
    if wechat and wechat:configured() then return wechat.id, false end
    return nil, false
end

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "reviews_show",
            title = _("显示段评"),
            icon = "forum",
            scope = "reader",
            keep_open = true,
            ---@param ctx BookQuickPanelContext|nil
            ---@return boolean
            available = function(ctx)
                local ui = ctx and ctx.ui
                if not ui then return true end
                local id, own = sourceId()
                if not id then return false end
                if own then return true end
                return require("features.reviews.link").available(ui)
            end,
            active = function()
                local id = sourceId()
                return id ~= nil and require("source.review_setting").enabled(id)
            end,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                local id = sourceId()
                if not id then return end
                local ReviewSetting = require("source.review_setting")
                ReviewSetting.set(id, not ReviewSetting.enabled(id))
                local ui = ctx.ui
                if ui and ui.dialog then
                    require("ui/uimanager"):setDirty(ui.dialog, "ui")
                end
            end,
        },
        {
            id = "wechat_reviews_link",
            title = _("关联微信段评"),
            icon = "forum",
            scope = "reader",
            ---@param ctx BookQuickPanelContext|nil
            ---@return boolean
            available = function(ctx)
                local ui = ctx and ctx.ui
                return not ui or require("features.reviews.link").available(ui)
            end,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                require("features.reviews.link").open(ctx.ui)
            end,
        },
    }
end

return Panel
