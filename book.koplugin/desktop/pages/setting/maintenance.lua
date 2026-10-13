--[[-- 维护与关于设置项。
@module koplugin.book.desktop.pages.setting.maintenance
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Confirm = require("ui.themes.widgets.confirm")
local Icon = require("ui.themes.widgets.icon")
local QR = require("ui.themes.widgets.qr")
local Sheet = require("ui.themes.widgets.sheet")
local Text = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
local Cache = require("book.cache")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsMaintenance
local Maintenance = {}
local REPO_URL = "https://github.com/AnkioTomas/moon"
local REPO_HOST = "github.com/AnkioTomas/moon"
local QQ_GROUP_URL = "https://qm.qq.com/q/Q9FHByplqC"
local BUG_GROUP_URL = "https://qm.qq.com/q/btmL9F4Cl2"

--- 关于页正文：图标、名称、版本、简介、作者、仓库与许可证，居中排列。
---@param width number
---@return table
local function aboutBody(width)
    local t = Theme.current()
    local muted = { color = t.color.muted }
    local function gap(n) return VerticalSpan:new{ width = Theme.px(n) } end
    return VerticalGroup:new{
        align = "center",
        Icon.widget{ name = "info", size = 44 },
        gap(t.space.sm),
        Text.line("title", _("月读")),
        gap(t.space.xs),
        Text.line("caption", T(_("版本 %1"), require("bookversion")), muted),
        gap(t.space.md),
        Text.box("caption", _("面向 KOReader 的书库桌面，支持多数据源与阅读进度同步。"), width,
            { align = "center", color = t.color.muted, bg = t.dialog.bg }),
        gap(t.space.md),
        Text.line("body", "AnkioTomas"),
        Text.line("caption", REPO_HOST, muted),
        Text.line("caption", _("GNU GPLv3"), muted),
    }
end

--- 弹出「关于」：正文 + 外链与加群按钮（设备支持外部链接时才给「打开 GitHub」）。
local function showAbout()
    local items = { { widget = aboutBody }, { separator = true } }
    if Device:canOpenLink() then
        items[#items + 1] = { text = _("打开 GitHub"), callback = function() Device:openLink(REPO_URL) end }
    end
    items[#items + 1] = { buttons = {
        { text = _("书友交流群"), callback = function() QR:new{ text = QQ_GROUP_URL }:show() end },
        { text = _("Bug 反馈群"), callback = function() QR:new{ text = BUG_GROUP_URL }:show() end },
    } }
    items[#items + 1] = { text = _("关闭") }
    Sheet:new{ title = _("关于"), items = items }:show()
end

--- 造「清理缓存」设置行的构造器。
--- 缓存体积异步测量，结果缓存在设置页实例上，首次显示「计算中…」并在算完后重建设置页；
--- 清理会连带作废首页与书库状态，因为封面等资源就在 cache 里。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance:cacheRow(desktop)
    local page = desktop.settings
    return function(iw)
        local cache_size = page.cache_size_label or _("计算中…")
        if page.cache_size_label == nil and not page.cache_size_job then
            page.cache_size_job = Cache.sizeBytesAsync(function(bytes)
                page.cache_size_job = nil
                if desktop.closed then return end
                page.cache_size_label = bytes > 0
                    and (require("util").getFriendlySize(bytes) or tostring(bytes)) or "0"
                if desktop.tab == "settings" then desktop:updateView() end
            end)
        end
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "action", icon = "delete", title = _("清理缓存"), status = cache_size, status_on = true,
            callback = function()
                Confirm:new{
                    text = T(_("删除 .moon/cache（%1）？"), cache_size), ok_text = _("清理"),
                    ok_callback = function()
                        if page.cache_clear_job then return end
                        Toast:new{ text = _("正在清理缓存…"), timeout = 1 }:show()
                        local running = true
                        local job = Cache.clearAsync(function(ok)
                            running = false
                            page.cache_clear_job = nil
                            if desktop.closed then return end
                            if ok then
                                page.cache_size_label = "0"
                                desktop:onEvent("home_refresh")
                                desktop:onEvent("shelf_changed")
                                desktop:updateView()
                            end
                            Toast:new{ text = ok and _("已清理") or _("清理失败"), timeout = 2 }:show()
                        end)
                        -- 库清理失败时 clearAsync 同步回调，不能留下已结束的句柄挡住重试。
                        if running then page.cache_clear_job = job end
                    end,
                }:show()
            end,
        })
    end
end

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
                        toast:show()
                        UIManager:forceRePaint()
                        local counts, err = require("book.stats_koreader").import()
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

--- 造「关于」设置行的构造器，状态位显示当前版本号。
---@return fun(iw: number): table
function Maintenance:aboutRow()
    return function(iw)
        return Row.widget({ width = iw, kind = "nav", icon = "info", title = _("关于"), status = require("bookversion"), status_on = true, callback = showAbout })
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
