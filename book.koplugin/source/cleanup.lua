--[[--
账号页的数据清理：选书源、选记录类型、二次确认。仅清本机，不删原书和远端数据。

@module koplugin.book.source.cleanup
--]]

require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local Cleanup = {}

---@param source_id string
---@param opts BookDataCleanup
---@param desktop BookDesktop|nil
---@return boolean
function Cleanup.perform(source_id, opts, desktop)
    local snapshot = require("reader.session").current()
    if snapshot and snapshot.identity.source_id == source_id then
        require("ui.themes.widgets.toast"):new{ text = _("请先关闭此书源正在阅读的书"), timeout = 3 }:show()
        return false
    end
    require("source.auth").changeAccount(source_id)
    require("source.logout").abort(source_id)
    local Registry = require("source.registry")
    Registry.invalidate(source_id)
    local ok = require("book.store").clearSourceData(source_id, opts)
    if desktop and not desktop.closed then
        if desktop.source and desktop.source.id == source_id then desktop.source = Registry.resolve(source_id) end
        desktop:onEvent("shelf_changed")
        desktop:onEvent("stats_changed")
        desktop:updateView()
    end
    require("ui.themes.widgets.toast"):new{
        text = ok and _("已清理所选数据") or _("部分数据清理失败，请重试"),
        timeout = ok and 2 or 3,
    }:show()
    return ok
end

---@param source_id string
---@param title string
---@param stable_prefix string|nil
---@param exclude boolean|nil
---@param desktop BookDesktop|nil
local function open(source_id, title, stable_prefix, exclude, desktop)
    local selected = { books = false, reading = false }
    require("ui.themes.widgets.settings"):new{
        title = title,
        items = function()
            return {
                { title = _("书籍本地记录"), toggle = true, checked = selected.books,
                  callback = function() selected.books = not selected.books end },
                { note = _("书库索引和目录缓存，不删除书籍文件") },
                { title = _("书籍阅读记录"), toggle = true, checked = selected.reading,
                  callback = function() selected.reading = not selected.reading end },
                { note = _("进度、统计、笔记、书签和分析数据") },
            }
        end,
        buttons = function(page)
            return {
                { text = _("取消"), callback = function() page:close() end },
                { text = _("清理所选数据"), callback = function()
                    if not selected.books and not selected.reading then
                        require("ui.themes.widgets.toast"):new{ text = _("请先选择要清理的数据"), timeout = 2 }:show()
                        return
                    end
                    local opts = {
                        books = selected.books, reading = selected.reading,
                        stable_prefix = stable_prefix, exclude = exclude,
                    }
                    local names = {}
                    if opts.books then names[#names + 1] = _("书籍本地记录") end
                    if opts.reading then names[#names + 1] = _("书籍阅读记录") end
                    require("ui.themes.widgets.confirm"):new{
                        text = T(_("清理「%1」的以下本机数据？\n\n%2\n\n不可撤销。不会删除书籍文件或远端数据；再次同步可能重新获取远端记录。"),
                            title, table.concat(names, "\n")),
                        ok_text = _("确认清理"),
                        ok_callback = function()
                            page:close()
                            local progress = require("ui.themes.widgets.progress_dialog"):new{
                                title = _("数据清理"), dismissable = false,
                            }
                            progress:showWhile(function() Cleanup.perform(source_id, opts, desktop) end)
                            progress:close()
                        end,
                    }:show()
                end },
            }
        end,
    }:show()
end

--- 包括停用的源，无需登录即可清理；本地书和 WebDAV 分成两个范围。
---@param desktop BookDesktop|nil
function Cleanup.pick(desktop)
    local items = {}
    for _idx, meta in ipairs(require("source.registry").list()) do
        if meta.id == "local" then
            items[#items + 1] = { text = _("本地书记录"), callback = function()
                open("local", _("本地书记录"), "webdav://", true, desktop)
            end }
            items[#items + 1] = { text = _("WebDAV 记录"), callback = function()
                open("local", _("WebDAV 记录"), "webdav://", false, desktop)
            end }
        else
            items[#items + 1] = { text = meta.name or meta.id, callback = function()
                open(meta.id, meta.name or meta.id, nil, nil, desktop)
            end }
        end
    end
    require("ui.themes.widgets.list"):new{ title = _("数据清理"), items = items }:show()
end

return Cleanup
