--[[-- 账号页数据清理：仅用户选择并确认后执行，本地 / WebDAV 隔离。 --]]

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
local Cleanup = require("source.cleanup")
Cleanup.pick(desktop)
local picker = Themed.last("list")
Assert.eq(picker.title, "数据清理")
Assert.len(picker.items, 5, "所有书源都可清理，本地和 WebDAV 分开")
Assert.eq(picker.items[1].text, "本地书记录")
Assert.eq(picker.items[2].text, "WebDAV 记录")
Assert.eq(picker.items[4].text, "停用书源")
Assert.eq(picker.items[5].text, "拓展书源")
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

-- 取消、正在读、失败都不能显示清理成功。
Cleanup.pick(desktop)
Themed.choose(Themed.last("list"), 5)
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

return true
