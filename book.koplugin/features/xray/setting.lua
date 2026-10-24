--[[--
X-Ray 配置键（settings/xray.lua）与设置：往桌面「查词」页追加「X-Ray」分节。

@module koplugin.book.features.xray.setting
--]]

local _ = require("gettext")

local Setting = {}

-- book_xray_quality：save 节约 / standard 标准 / high 高质量。
-- book_xray_mark_style：dashed 虚线 / solid 实线。
Setting.defaults = {
    book_xray_enabled = true,
    book_xray_show_marks = false,
    book_xray_auto = false,
    book_xray_quality = "standard",
    book_xray_mark_style = "dashed",
}

local QUALITY_NEXT = { save = "standard", standard = "high", high = "save" }
local QUALITY_LABEL = {
    save = function() return _("节约") end,
    standard = function() return _("标准") end,
    high = function() return _("高质量") end,
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
            group = "reader",
            order = 13,
            icon = "person_search",
            title = _("X-Ray"),
            subtitle = _("人物、地点与专有名词的识别"),
            page = {
                title = _("X-Ray"),
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
                                        subtitle = _("默认关闭；也可在阅读快捷面板里随时开关，点标记查看详情"),
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
                                    local auto = xray.book_xray_auto
                                    return Row.widget({
                                        width = iw, chevron = false,
                                        kind = "toggle", icon = "auto_mode", title = _("X-Ray 自动识别"),
                                        subtitle = _("翻到新章自动识别本章人物，读过大半再带上下一章；有网才跑，会消耗 AI 额度"),
                                        status = (on and auto) and _("开") or _("关"),
                                        status_on = on and auto,
                                        callback = function()
                                            if not on then return end
                                            xray.book_xray_auto = not auto
                                            save()
                                        end,
                                    })
                                end,
                                function(iw)
                                    local quality = QUALITY_NEXT[xray.book_xray_quality] and xray.book_xray_quality or "standard"
                                    return Row.widget({
                                        width = iw, chevron = true,
                                        kind = "nav", icon = "savings", title = _("X-Ray 识别档位"),
                                        subtitle = _("节约：只看当前页；标准：带本章前文与前 5 章摘要；高质量：前 10 章摘要，实体更多"),
                                        status = QUALITY_LABEL[quality](),
                                        callback = function()
                                            xray.book_xray_quality = QUALITY_NEXT[quality]
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
        },
    }
end

return Setting
