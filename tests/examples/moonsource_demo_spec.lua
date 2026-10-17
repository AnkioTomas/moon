--[[--
examples/moonsource-demo.koplugin：经源注册表发现，并按契约接到月读的书架 / 目录 / 按章打开。

@module tests.examples.moonsource_demo_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")

package.preload["utils.settings"] = function()
    local common = { active_source = "local" }
    return { get = function() return common end, save = function() end }
end
for _idx, id in ipairs({ "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }) do
    package.loaded["source." .. id] = {
        meta = function() return { id = id, name = id, type = "book" } end,
        new = function() return { id = id } end,
    }
end

local reconciled, toc_put, opened = nil, nil, nil
package.loaded["source.shelf"] = {
    reconcile = function(source_id, books)
        reconciled = { source_id = source_id, books = books }
        return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    end,
}
package.loaded["source.toc"] = {
    put = function(source_id, stable_id, toc)
        toc_put = { source_id = source_id, stable_id = stable_id, toc = toc }
        return true
    end,
}
local function open(kind)
    return function(source, identity, book, opts, ops, cb)
        opened = { kind = kind, source = source, identity = identity, opts = opts, ops = ops }
        cb("/fake/" .. kind .. ".html")
        return { cancel = function() end }
    end
end
package.loaded["source.chapter"] = { openAsync = open("async"), openWithUi = open("ui") }

package.loaded["pluginloader"] = {
    enabled_plugins = { Config.selfPlugin(), { path = Config.root() .. "/examples/moonsource-demo.koplugin" } },
}
package.loaded["source.registry"] = nil
local Registry = require("source.registry")

local meta = Registry.meta("ext.demo")
Assert.eq(meta.type, "chapter")
Assert.eq(Registry.list()[8].id, "ext.demo", "第三方源排在 7 个内置源之后")

local source = Registry.resolve("ext.demo")
Assert.eq(source.id, "ext.demo")
Assert.is_true(source:configured())
Assert.is_true(Registry.isEnabled("ext.demo"))

-- 书架：全量同步交快照给书库对账；只推脏行时没有远端可推，跳过。
local result
source:syncBooksAsync(nil, function(r) result = r end)
Stubs.flush()
Assert.eq(result.pulled, 1)
Assert.eq(reconciled.source_id, "ext.demo")
Assert.eq(reconciled.books[1].stable_id, "demo-1")
source:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
Stubs.flush()
Assert.is_true(result.skipped)

-- 目录：写进书库缓存再回传。
local identity = { source_id = "ext.demo", stable_id = "demo-1", book = reconciled.books[1] }
local toc
source:loadTocAsync(identity, function(t) toc = t end)
Stubs.flush()
Assert.len(toc, 3)
Assert.eq(toc_put.stable_id, "demo-1")

-- 开书走带进度窗的公共实现，切章走无窗版本；正文交纯文本由月读排版。
local path
source:openBookAsync(identity, nil, function(p) path = p end)
Assert.eq(path, "/fake/ui.html")
Assert.eq(opened.source, source)
source:openBookAsync(identity, { chapter_idx = 2 }, function(p) path = p end)
Assert.eq(path, "/fake/async.html")
local payload
opened.ops.fetchContent(identity, toc[2], function(p) payload = p end)
Stubs.flush()
Assert.eq(payload.title, toc[2].title)
Assert.matches(payload.text, "示例书源")
