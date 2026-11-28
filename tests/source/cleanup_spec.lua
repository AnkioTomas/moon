--[[-- 账号页数据清理：仅用户选择并确认后执行，本地 / WebDAV 隔离。没有记录的源不出现。 --]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local calls, clear_ok, snapshot = {}, true, nil
local order = {}
package.loaded["source.registry"] = {
    list = function() return {
        { id = "local", name = "本地" }, { id = "wechat", name = "微信读书" },
        { id = "disabled", name = "停用书源" }, { id = "ext.demo", name = "拓展书源" },
    } end,
    invalidate = function(id) order[#order + 1] = "invalidate:" .. id end,
    resolve = function(id) return { id = id } end,
}
package.loaded["reader.session"] = { current = function() return snapshot end }
package.loaded["source.auth"] = { changeAccount = function(id) order[#order + 1] = "version:" .. id end }
package.loaded["source.logout"] = { abort = function(id) order[#order + 1] = "abort:" .. id end }
package.loaded["book.store"] = { clearSourceData = function(id, opts)
    order[#order + 1] = "clear:" .. id
    calls[#calls + 1] = { id = id, opts = opts }
    return clear_ok
end }
local events, painted = {}, 0
local desktop = {
    source = { id = "wechat" },
    onEvent = function(_self, name) events[#events + 1] = name end,
    updateView = function() painted = painted + 1 end,
}
require("book.books_db")
require("book.note_db")
local DB = require("utils.db")
local toc = string.rep("x", 1000)
local payload = string.rep("y", 2000)
local IDS = "('wechat','local','disabled','ext.demo')"
DB.exec("DELETE FROM books WHERE source_id IN " .. IDS .. ";")
for _idx, tbl in ipairs({
    "notes", "pending_progress", "reading_stats", "review_cache",
    "chapter_summaries", "chapter_summary_pending",
    "chapters", "toc_entries", "toc_snapshots",
    "xray_entities", "xray_plots", "xray_scan", "xray_removed", "xray_chapter",
}) do
    DB.exec("DELETE FROM " .. tbl .. " WHERE source_id IN " .. IDS .. ";")
end
DB.exec("INSERT INTO books (source_id, stable_id, title, toc) VALUES ('wechat','w1','微信书',?);", toc)
DB.exec("INSERT INTO notes (source_id, stable_id, payload, updated_at) VALUES ('wechat','w1',?,1);", payload)
DB.exec("INSERT INTO books (source_id, stable_id, title) VALUES ('local','/mnt/a.epub','本地书');")
DB.exec("INSERT INTO books (source_id, stable_id, title) VALUES ('local','webdav://a','网盘书');")

local Cleanup = require("source.cleanup")
local measured = Cleanup.measure()
Assert.eq(measured.wechat[0].books.count, 1)
Assert.eq(measured.wechat[0].reading.count, 1)
Assert.is_true(measured.wechat[0].books.bytes >= #toc)
Assert.is_true(measured.wechat[0].reading.bytes >= #payload)
Assert.eq(measured["local"][0].books.count, 1)
Assert.eq(measured["local"][1].books.count, 1)
Assert.is_nil(measured.disabled)
Assert.is_nil(measured["ext.demo"])

Cleanup.pick(desktop)
local picker = Themed.last("list")
Assert.eq(picker.title, "数据清理")
Assert.len(picker.items, 3, "没有记录的源不出现，本地和 WebDAV 仍分开")
Assert.eq(picker.items[1].text, "本地书记录")
Assert.eq(picker.items[1].subtitle, "书籍 1 条")
Assert.eq(picker.items[2].text, "WebDAV 记录")
Assert.eq(picker.items[3].text, "微信读书")
Assert.eq(picker.items[3].subtitle, "书籍 1 条 · 阅读 1 条")
Assert.eq(picker.items[3].mandatory, require("util").getFriendlySize(
    measured.wechat[0].books.bytes + measured.wechat[0].reading.bytes))
Assert.len(calls, 0)

Themed.choose(picker, 3)
local form = Themed.last("settings")
Assert.eq(form.title, "微信读书")
Assert.is_false(form.items()[1].checked)
Assert.is_false(form.items()[3].checked)
form.buttons(form)[2].callback()
Assert.eq(Themed.last("toast").text, "请先选择要清理的数据")
Assert.is_nil(Themed.last("confirm"))
Assert.len(calls, 0)

form.items()[3].callback()
form.buttons(form)[2].callback()
local confirm = Themed.last("confirm")
Assert.is_true(confirm.text:find("书籍阅读记录", 1, true) ~= nil)
Assert.is_nil(confirm.text:find("书籍本地记录", 1, true))
Assert.is_true(confirm.text:find("不会删除书籍文件或远端数据", 1, true) ~= nil)
Assert.len(calls, 0, "弹出确认不等于执行清理")
confirm.ok_callback()
Assert.len(calls, 1)
Assert.eq(calls[1].id, "wechat")
Assert.is_true(calls[1].opts.reading)
Assert.is_false(calls[1].opts.books)
Assert.eq(table.concat(order, ","), "version:wechat,abort:wechat,invalidate:wechat,clear:wechat")
Assert.eq(table.concat(events, ","), "shelf_changed,stats_changed", "清理后不广播会自动同步的 SourceChanged")
Assert.eq(painted, 1)
Assert.is_true(Themed.last("progress_dialog").closed)
Assert.eq(Themed.last("toast").text, "已清理所选数据")

for index = 1, 2 do
    Cleanup.pick(desktop)
    Themed.choose(Themed.last("list"), index)
    form = Themed.last("settings")
    Assert.is_false(form.items()[1].checked, "每次打开默认不选")
    form.items()[1].callback()
    form.buttons(form)[2].callback()
    Themed.last("confirm").ok_callback()
    local call = calls[#calls]
    Assert.eq(call.id, "local")
    Assert.is_true(call.opts.books)
    Assert.is_false(call.opts.reading)
    Assert.eq(call.opts.stable_prefix, "webdav://")
    Assert.eq(call.opts.exclude, index == 1)
end

-- 只有阅读记录时不列出书籍开关。
DB.exec("DELETE FROM books WHERE source_id='wechat';")
Cleanup.pick(desktop)
picker = Themed.last("list")
local reading_only
for _idx, item in ipairs(picker.items) do
    if item.text == "微信读书" then reading_only = item end
end
Assert.eq(reading_only.subtitle, "阅读 1 条")
reading_only.callback()
form = Themed.last("settings")
Assert.eq(form.items()[1].title, "书籍阅读记录")
Assert.is_true(form.items()[2].note:find("约 1 条", 1, true) ~= nil)
Assert.is_nil(form.items()[3])

-- 取消、正在读、失败都不能显示清理成功。
Cleanup.pick(desktop)
Themed.choose(Themed.last("list"), 1)
form = Themed.last("settings")
form.buttons(form)[1].callback()
Assert.len(calls, 3)
snapshot = { identity = { source_id = "wechat" } }
Assert.is_false(Cleanup.perform("wechat", { reading = true }, desktop))
Assert.len(calls, 3)
Assert.eq(Themed.last("toast").text, "请先关闭此书源正在阅读的书")
snapshot, clear_ok = nil, false
Assert.is_false(Cleanup.perform("ext.demo", { books = true, reading = true }, desktop))
Assert.eq(calls[#calls].id, "ext.demo")
Assert.eq(Themed.last("toast").text, "部分数据清理失败，请重试")

DB.exec("DELETE FROM books WHERE source_id IN " .. IDS .. ";")
DB.exec("DELETE FROM notes WHERE source_id IN " .. IDS .. ";")
Cleanup.pick(desktop)
Assert.eq(Themed.last("list").items[1].text, "没有可清理的数据")
Assert.is_false(Themed.last("list").items[1].enabled)

return true
