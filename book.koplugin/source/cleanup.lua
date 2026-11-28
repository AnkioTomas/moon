--[[--
账号页的数据清理：选书源、选记录类型、二次确认。仅清本机，不删原书和远端数据。
没有记录的源不出现。条数和占用是库内文本的估算，不含书籍文件。

@module koplugin.book.source.cleanup
--]]

require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local Cleanup = {}

--- 每行除文本外的粗略开销。数字列（统计、进度）否则会估成 0。
local ROW_OVERHEAD = 32

--- 书籍本地记录：清掉的就是这些表。表达式只加文本列的字节。
local BOOK_TABLES = {
    { "books", "IFNULL(length(toc),0)+IFNULL(length(intro),0)+IFNULL(length(meta),0)+IFNULL(length(reader_prefs),0)+IFNULL(length(title),0)+IFNULL(length(authors),0)+IFNULL(length(cover),0)+IFNULL(length(path),0)+IFNULL(length(stable_id),0)+IFNULL(length(category),0)+IFNULL(length(series),0)" },
    { "chapters", "IFNULL(length(path),0)+IFNULL(length(stable_id),0)" },
    { "toc_entries", "IFNULL(length(title),0)+IFNULL(length(origin),0)+IFNULL(length(extra),0)+IFNULL(length(uid),0)+IFNULL(length(stable_id),0)" },
    { "toc_snapshots", "IFNULL(length(stable_id),0)" },
}

--- 阅读记录。分析表不在时跳过，不因此去加载对应功能。
local READING_TABLES = {
    { "pending_progress", "IFNULL(length(locator),0)+IFNULL(length(extra),0)+IFNULL(length(chapter_title),0)+IFNULL(length(synced),0)+IFNULL(length(stable_id),0)" },
    { "notes", "IFNULL(length(payload),0)+IFNULL(length(stable_id),0)" },
    { "reading_stats", "IFNULL(length(stable_id),0)+IFNULL(length(record_type),0)" },
    { "review_cache", "IFNULL(length(payload),0)+IFNULL(length(key),0)+IFNULL(length(stable_id),0)" },
    { "chapter_summaries", "IFNULL(length(summary),0)+IFNULL(length(extra),0)+IFNULL(length(title),0)+IFNULL(length(stable_id),0)" },
    { "chapter_summary_pending", "IFNULL(length(messages),0)+IFNULL(length(title),0)+IFNULL(length(error),0)+IFNULL(length(stable_id),0)" },
    { "xray_entities", "IFNULL(length(description),0)+IFNULL(length(aliases),0)+IFNULL(length(name),0)+IFNULL(length(role),0)+IFNULL(length(occupation),0)+IFNULL(length(stable_id),0)" },
    { "xray_plots", "IFNULL(length(description),0)+IFNULL(length(characters),0)+IFNULL(length(title),0)+IFNULL(length(time),0)+IFNULL(length(stable_id),0)" },
    { "xray_scan", "IFNULL(length(digest),0)+IFNULL(length(stable_id),0)" },
    { "xray_removed", "IFNULL(length(name),0)+IFNULL(length(stable_id),0)" },
    { "xray_chapter", "IFNULL(length(stable_id),0)" },
}

---@param name string
---@return boolean
local function hasTable(name)
    return require("utils.db").rowexec(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", name) ~= nil
end

---@return { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }
local function emptyScope()
    return { books = { count = 0, bytes = 0 }, reading = { count = 0, bytes = 0 } }
end

--- 按源汇总可清理的条数和文本占用。local 再按是否 webdav:// 拆开；其它源合成一份。
--- 返回 [source_id][0|1] = scope。没有行的源不出现。
---@return table<string, table<integer, { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }>>
function Cleanup.measure()
    local DB = require("utils.db")
    local out = {}
    local function add(source_id, dav, kind, count, bytes)
        if type(source_id) ~= "string" or source_id == "" or count <= 0 then return end
        -- 只有本地书按 webdav:// 拆成两个入口；其它源合成一份。
        local slot = source_id == "local" and dav or 0
        local by_source = out[source_id]
        if not by_source then
            by_source = {}
            out[source_id] = by_source
        end
        local scope = by_source[slot]
        if not scope then
            scope = emptyScope()
            by_source[slot] = scope
        end
        local part = scope[kind]
        part.count = part.count + count
        part.bytes = part.bytes + bytes
    end
    local function scan(tables, kind)
        for _idx, spec in ipairs(tables) do
            local name, expr = spec[1], spec[2]
            if hasTable(name) then
                local result, nrows = DB.query(string.format([[
                    SELECT source_id,
                           CASE WHEN instr(stable_id, 'webdav://')=1 THEN 1 ELSE 0 END,
                           COUNT(*),
                           COALESCE(SUM(%s), 0)
                    FROM %s
                    GROUP BY source_id, CASE WHEN instr(stable_id, 'webdav://')=1 THEN 1 ELSE 0 END;
                ]], expr, name))
                for i = 1, result and nrows or 0 do
                    local count = tonumber(result[3][i]) or 0
                    local bytes = (tonumber(result[4][i]) or 0) + count * ROW_OVERHEAD
                    add(result[1][i], tonumber(result[2][i]) or 0, kind, count, bytes)
                end
            end
        end
    end
    scan(BOOK_TABLES, "books")
    scan(READING_TABLES, "reading")
    return out
end

---@param scope { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }
---@return integer
local function totalCount(scope)
    return scope.books.count + scope.reading.count
end

---@param scope { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }
---@return integer
local function totalBytes(scope)
    return scope.books.bytes + scope.reading.bytes
end

---@param bytes integer
---@return string
local function friendly(bytes)
    return require("util").getFriendlySize(bytes) or T(_("%1 B"), 0)
end

---@param scope { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }
---@return string
local function scopeLine(scope)
    local bits = {}
    if scope.books.count > 0 then bits[#bits + 1] = T(_("书籍 %1 条"), scope.books.count) end
    if scope.reading.count > 0 then bits[#bits + 1] = T(_("阅读 %1 条"), scope.reading.count) end
    if #bits == 2 then return T(_("%1 · %2"), bits[1], bits[2]) end
    return bits[1] or ""
end

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

---@param part { count: integer, bytes: integer }
---@param explain string
---@return string
local function partNote(part, explain)
    return T(_("约 %1 条，%2。%3"), part.count, friendly(part.bytes), explain)
end

---@param source_id string
---@param title string
---@param stable_prefix string|nil
---@param exclude boolean|nil
---@param desktop BookDesktop|nil
---@param scope { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }
local function open(source_id, title, stable_prefix, exclude, desktop, scope)
    local selected = { books = false, reading = false }
    require("ui.themes.widgets.settings"):new{
        title = title,
        items = function()
            local items = {}
            if scope.books.count > 0 then
                items[#items + 1] = { title = _("书籍本地记录"), toggle = true, checked = selected.books,
                    callback = function() selected.books = not selected.books end }
                items[#items + 1] = { note = partNote(scope.books, _("书库索引和目录缓存，不删除书籍文件")) }
            end
            if scope.reading.count > 0 then
                items[#items + 1] = { title = _("书籍阅读记录"), toggle = true, checked = selected.reading,
                    callback = function() selected.reading = not selected.reading end }
                items[#items + 1] = { note = partNote(scope.reading, _("进度、统计、笔记、书签和分析数据")) }
            end
            return items
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

---@param items table[]
---@param text string
---@param source_id string
---@param stable_prefix string|nil
---@param exclude boolean|nil
---@param desktop BookDesktop|nil
---@param scope { books: { count: integer, bytes: integer }, reading: { count: integer, bytes: integer } }
local function addItem(items, text, source_id, stable_prefix, exclude, desktop, scope)
    if totalCount(scope) <= 0 then return end
    items[#items + 1] = {
        text = text,
        subtitle = scopeLine(scope),
        mandatory = friendly(totalBytes(scope)),
        callback = function() open(source_id, text, stable_prefix, exclude, desktop, scope) end,
    }
end

--- 包括停用的源，无需登录即可清理。没有记录的不列出；本地书和 WebDAV 仍分成两个范围。
---@param desktop BookDesktop|nil
function Cleanup.pick(desktop)
    local measured = Cleanup.measure()
    local items = {}
    for _idx, meta in ipairs(require("source.registry").list()) do
        local by_source = measured[meta.id]
        if meta.id == "local" then
            if by_source and by_source[0] then
                addItem(items, _("本地书记录"), "local", "webdav://", true, desktop, by_source[0])
            end
            if by_source and by_source[1] then
                addItem(items, _("WebDAV 记录"), "local", "webdav://", false, desktop, by_source[1])
            end
        elseif by_source and by_source[0] then
            addItem(items, meta.name or meta.id, meta.id, nil, nil, desktop, by_source[0])
        end
    end
    if #items == 0 then
        items[1] = { text = _("没有可清理的数据"), enabled = false, keep_open = true }
    end
    require("ui.themes.widgets.list"):new{ title = _("数据清理"), items = items }:show()
end

return Cleanup
