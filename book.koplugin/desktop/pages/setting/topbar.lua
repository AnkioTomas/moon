--[[-- 顶部状态栏设置。
@module koplugin.book.desktop.pages.setting.topbar
--]]

local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsTopbar
local TopbarSettings = {}

-- 行与预览都读顶栏自己的项（含 feature 的项）：label / icon 是设置行，sample / bar_icon 是预览样例
-- （时钟不画图标，wifi 只有图标）。

---@param desktop table
---@return table
function TopbarSettings:rows(desktop)
    local home = MoonSettings.get("desktop")
    local config = home.home_topbar_items
    local rows = {}
    for _idx, item in ipairs(require("desktop.topbar").items()) do
        local enabled = config[item.id] ~= false
        rows[#rows + 1] = function(iw)
            return Row.widget({
                width = iw,
                icon = item.icon,
                title = item.label,
                toggle = enabled,
                callback = function()
                    config[item.id] = not enabled
                    MoonSettings.save("desktop", home)
                    desktop:onEvent("topbar_changed")
                    desktop:updateView()
                end,
            })
        end
    end
    return rows
end

--- 已启用项按真顶栏左右分栏（同一套 TopBar.metric / TopBar.row）。
---@param width number
---@return table
function TopbarSettings.preview(width)
    local Overlay = require("desktop.pages.setting.overlay")
    local TopBar = require("desktop.topbar")
    local bar_h = TopBar.height()
    local left, right = {}, {}
    for _idx, item in ipairs(TopBar.items()) do
        if TopBar.visible(item.id) then
            local side = item.align == "left" and left or right
            side[#side + 1] = TopBar.metric(item.sample, item.bar_icon)
        end
    end
    if #left + #right == 0 then
        return Overlay.previewPlaceholder(width, bar_h, _("无"))
    end
    return Overlay.previewBox(width, TopBar.row(math.max(1, width - 2), math.max(1, bar_h - 2), left, right), bar_h)
end

return TopbarSettings
