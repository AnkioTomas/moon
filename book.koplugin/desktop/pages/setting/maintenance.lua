--[[-- 维护设置项。关于（版本、主页、加群）在设置根页「我的设备」。
@module koplugin.book.desktop.pages.setting.maintenance
--]]

local UIManager = require("ui/uimanager")
local Confirm = require("ui.themes.widgets.confirm")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsMaintenance
local Maintenance = {}

--- 清除当前源的本地阅读统计；不向远端发送删除请求。
---@param desktop table
---@return fun(iw: number): table
function Maintenance:clearStatsRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "action", icon = "delete_sweep", title = _("清除当前源统计"),
            subtitle = _("仅清除本地数据，不影响云端"), status_on = true,
            callback = function()
                local source = desktop.source
                local source_id = source and source.id
                if not source_id then
                    Toast:new{ text = _("当前没有可用数据源"), timeout = 2 }:show()
                    return
                end
                Confirm:new{
                    text = T(_("清除“%1”当前源的全部本地阅读统计？"), source.name or source_id),
                    ok_text = _("清除"),
                    ok_callback = function()
                        local ok = require("book.stats_db").deleteLocal(source_id)
                        if desktop.home then desktop:onEvent("home_refresh") end
                        desktop:onEvent("stats_changed")
                        desktop:updateView()
                        Toast:new{ text = ok and _("已清除本地统计") or _("清除统计失败"), timeout = 2 }:show()
                    end,
                }:show()
            end,
        })
    end
end

--- 导入 KOReader 自带统计插件的阅读记录；纯本地操作，不推给任何源。
---@param desktop table
---@return fun(iw: number): table
function Maintenance:importKoreaderStatsRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "action", icon = "download", title = _("导入 KOReader 统计"),
            subtitle = _("按书匹配书库，已有的记录不会重复导入"), status_on = true,
            callback = function()
                Confirm:new{
                    text = _("把 KOReader 自带统计插件的阅读记录导入月读？只导入书库里能对上的书。"),
                    ok_text = _("导入"),
                    ok_callback = function()
                        local toast = require("ui.themes.widgets.progress_dialog"):new{
                            title = _("导入 KOReader 统计"), text = _("正在导入…"), dismissable = false,
                        }
                        local counts, err = toast:showWhile(function()
                            UIManager:forceRePaint()
                            return require("book.stats_koreader").import()
                        end)
                        toast:close()
                        if not counts then
                            Toast:new{ text = err == "missing" and _("没有找到 KOReader 统计数据")
                                or _("导入失败"), timeout = 2 }:show()
                            return
                        end
                        if counts.rows > 0 then
                            if desktop.home then desktop:onEvent("home_refresh") end
                            desktop:onEvent("stats_changed")
                            desktop:updateView()
                        end
                        Toast:new{
                            text = T(_("已导入 %1 本书的 %2 条记录，%3 本书在书库中未找到"),
                                counts.books, counts.rows, counts.unmatched),
                            timeout = 3,
                        }:show()
                    end,
                }:show()
            end,
        })
    end
end

--- 造「调试日志」开关；控制 DEBUG/INFO，WARN/ERROR 始终写入独立日志。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance:debugLogRow(desktop)
    return function(iw)
        local enabled = MoonSettings.get("utils").book_debug_enabled
        return Row.widget({
            width = iw,
            icon = "bug_report", title = _("调试日志"),
            toggle = enabled,
            callback = function()
                MoonSettings.get("utils").book_debug_enabled = not enabled
                MoonSettings.save("utils")
                desktop:updateView()
            end,
        })
    end
end

--- 造「关闭桌面」设置行的构造器。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance:closeRow(desktop)
    return function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "close", title = _("关闭桌面"), callback = function() desktop:onClose() end })
    end
end

return Maintenance
