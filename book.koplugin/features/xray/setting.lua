--[[--
X-Ray 配置键（settings/xray.lua）与设置：往桌面「划词与查询」页追加「X-Ray」分节。

@module koplugin.book.features.xray.setting
--]]

local _ = require("gettext")

local Setting = {}

-- book_xray_mark_style：dashed 虚线 / solid 实线。
Setting.defaults = {
    book_xray_enabled = true,
    book_xray_show_marks = true,
    book_xray_mark_style = "dashed",
}

--- 改了画线相关设置：作废标注缓存并重画打开中的阅读页。
local function refreshMarks()
    require("features.xray.marks").invalidate()
    local ui = require("apps/reader/readerui").instance
    if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "lookup",
            order = 40,
            sections = function()
                local MoonSettings = require("utils.settings")
                local Row = require("ui.themes.widgets.row")
                local xray = MoonSettings.get("features.xray")
                local on, marks_on = xray.book_xray_enabled, xray.book_xray_show_marks
                local solid = xray.book_xray_mark_style == "solid"
                local function save()
                    MoonSettings.save("features.xray", xray)
                    desktop:updateView()
                end
                return {
                    {
                        title = _("X-Ray"),
                        rows = {
                            function(iw)
                                return Row.widget({
                                    width = iw, chevron = false,
                                    kind = "toggle", icon = "person_search", title = _("X-Ray 功能"),
                                    status = on and _("开") or _("关"), status_on = on,
                                    callback = function()
                                        xray.book_xray_enabled = not on
                                        require("features.xray.marks").invalidate()
                                        save()
                                    end,
                                })
                            end,
                            function(iw)
                                return Row.widget({
                                    width = iw, chevron = false,
                                    kind = "toggle", icon = "format_underlined", title = _("X-Ray 实体画线"),
                                    status = (on and marks_on) and _("开") or _("关"),
                                    status_on = on and marks_on,
                                    callback = function()
                                        if not on then return end
                                        xray.book_xray_show_marks = not marks_on
                                        refreshMarks()
                                        save()
                                    end,
                                })
                            end,
                            function(iw)
                                return Row.widget({
                                    width = iw, chevron = true,
                                    kind = "nav", icon = "border_style", title = _("X-Ray 下划线样式"),
                                    status = solid and _("实线") or _("虚线"),
                                    callback = function()
                                        xray.book_xray_mark_style = solid and "dashed" or "solid"
                                        refreshMarks()
                                        save()
                                    end,
                                })
                            end,
                        },
                    },
                }
            end,
        },
    }
end

return Setting
