--[[--
书源设置页的「显示段评」开关（晋江 / 起点等匿名可读段评的源共用）。

@module koplugin.book.source.review_setting
--]]

local _ = require("gettext")

local ReviewSetting = {}

---@param source_id string
---@return boolean
function ReviewSetting.enabled(source_id)
    return require("utils.settings").getSource(source_id).show_paragraph_reviews == true
end

--- 设置页的一行（`Row.widget` 工厂）。
---@param source_id string
---@param plugin table|nil
---@return fun(iw: integer): table
function ReviewSetting.row(source_id, plugin)
    return function(iw)
        local on = ReviewSetting.enabled(source_id)
        return require("ui.themes.widgets.row").widget({ width = iw, chevron = false, kind = "toggle", icon = "forum",
            title = _("显示段评"), subtitle = _("阅读时给有他人段评的段落末尾画线，点按查看；需联网"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                local settings = require("utils.settings")
                local cfg = settings.getSource(source_id)
                cfg.show_paragraph_reviews = not on
                settings.saveSource(source_id, cfg)
                if plugin and plugin.desktop then plugin.desktop:updateView() end
            end })
    end
end

return ReviewSetting
