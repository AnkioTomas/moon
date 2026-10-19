--[[--
精简功能设置页（维护组）：列出可删除的 feature，点按标记 / 取消标记，重启 KOReader 后生效。

@module koplugin.book.features.manage.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

--- removed：已标记要删的 feature 目录名。
Setting.defaults = { removed = {} }

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local Manage = require("features.manage")
    local Row = require("ui.themes.widgets.row")
    local dir = require("features").DIR
    local rows = {}
    for _idx, item in ipairs(Manage.ITEMS) do
        local marked = Manage.isMarked(item.id)
        local present = Manage.exists(dir, item.id)
        if present or marked then
            rows[#rows + 1] = function(iw)
                return Row.widget({
                    width = iw, chevron = false, kind = "action", icon = "delete", title = item.label,
                    subtitle = item.subtitle,
                    status = not present and _("已删除") or marked and _("重启后删除") or "", status_on = marked,
                    callback = function()
                        if marked then
                            Manage.toggle(item.id)
                            desktop:updateView()
                            return
                        end
                        require("ui.themes.widgets.confirm"):new{
                            text = T(_("删除「%1」？重启 KOReader 后生效，之后更新月读也不会再装回来。"), item.label),
                            ok_text = _("删除"),
                            ok_callback = function()
                                Manage.toggle(item.id)
                                desktop:updateView()
                            end,
                        }:show()
                    end,
                })
            end
        end
    end
    return { { title = _("可删除的功能（再点一次取消；已删除的取消后更新月读即可找回）"), rows = rows } }
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "maintenance",
            order = 20,
            id = "manage", icon = "delete_sweep", title = _("精简功能"),
            subtitle = _("删除用不到的功能，减小体积与内存占用"),
            page = { title = _("精简功能"), sections = function() return sections(desktop) end },
        },
    }
end

return Setting
