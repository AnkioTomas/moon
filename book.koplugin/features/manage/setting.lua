--[[--
功能开关设置页（维护组）：列出可停用的 feature，点按停用 / 再启用，重启 KOReader 后生效。

@module koplugin.book.features.manage.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

--- disabled：已停用的 feature 目录名。
Setting.defaults = { disabled = {} }

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local Manage = require("features.manage")
    local Row = require("ui.themes.widgets.row")
    local rows = {}
    for _idx, item in ipairs(Manage.items()) do
        local marked = Manage.isMarked(item.id)
        rows[#rows + 1] = function(iw)
            return Row.widget({
                width = iw, chevron = false, kind = "action", icon = "delete", title = item.label,
                subtitle = item.subtitle,
                status = marked and _("重启后停用") or "", status_on = marked,
                callback = function()
                    if marked then
                        Manage.toggle(item.id)
                        desktop:updateView()
                        return
                    end
                    local text = T(_("停用「%1」？重启 KOReader 后生效，可随时再启用。"), item.label)
                        .. "\n" .. T(_("包含：%1"), table.concat(item.abilities, _("、")))
                    require("ui.themes.widgets.confirm"):new{
                        text = text,
                        ok_text = _("停用"),
                        ok_callback = function()
                            Manage.toggle(item.id)
                            desktop:updateView()
                        end,
                    }:show()
                end,
            })
        end
    end
    return { { title = _("可停用的功能（再点一次取消停用）"), rows = rows } }
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "maintenance",
            order = 20,
            id = "manage", icon = "delete_sweep", title = _("功能开关"),
            subtitle = _("停用用不到的功能，减少内存占用"),
            page = { title = _("功能开关"), sections = function() return sections(desktop) end },
        },
    }
end

return Setting
