--[[-- 当前书籍字体映射快捷入口。
@module koplugin.book.features.fontmap.panel
--]]

require("l10n").apply()
local _ = require("gettext")
local Panel = {}

function Panel.actions()
    return { {
        id = "fontmap", title = _("书内字体映射"), icon = "font_download", scope = "reader",
        available = function(ctx)
            local FontMap = require("features.fontmap")
            return FontMap.supported() and (not ctx or not ctx.ui or FontMap.available(ctx.ui))
        end,
        run = function(ctx)
            local FontMap = require("features.fontmap")
            if not FontMap.available(ctx.ui) then return end
            if not ctx.ui._book_fontmap then ctx.ui._book_fontmap = FontMap.new(ctx.ui) end
            ctx.ui._book_fontmap:start(true)
        end,
    } }
end

return Panel
