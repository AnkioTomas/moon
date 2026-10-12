--[[-- 优化排版快捷动作。
@module koplugin.book.features.reflow.panel
--]]

local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {{
        id = "reflow",
        title = _("优化排版"),
        icon = "auto_fix_high",
        scope = "reader",
        --- 本地 TXT/MOBI 整书阅读时可排版。
        ---@param ctx BookQuickPanelContext|nil
        ---@return boolean
        available = function(ctx)
            local ui = ctx and ctx.ui
            if not ui then
                return true
            end
            local session = require("reader.session").current()
            local identity = session and session.identity
            return require("features.reflow").canReflow(identity)
        end,
        --- 先预览章节目录，确认后再转换替换。
        run = function()
            require("features.reflow").startFromReader(require("reader.session").current().identity)
        end,
    }}
end

return Panel
