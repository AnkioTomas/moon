--[[--
book.open：按 Book 身份解析属主源，只消费源返回的物理文档。

@module tests.book.open_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local resolved_id
local opened_identity
local shown = {}
local open_callbacks = {}
local reader_callbacks = {}
local closed = {}

local source = {
    openBookAsync = function(_, identity, opts, cb)
        opened_identity = identity
        Assert.is_nil(opts)
        open_callbacks[#open_callbacks + 1] = cb
        return { cancel = function() end }
    end,
}
package.preload["source.registry"] = function()
    return {
        resolve = function(id)
            resolved_id = id
            return source
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["book.store"] = function()
    return { rememberMany = function() end }
end
package.preload["ui.reader.session"] = function()
    error("book.open must not load reader session")
end

local UIManager = require("ui/uimanager")
function UIManager:close(widget)
    closed[#closed + 1] = widget
end

local ReaderUI = { instance = nil }
function ReaderUI:showReader(path, provider, seamless, is_provider_forced, after_open_callback)
    Assert.is_nil(provider)
    Assert.is_nil(seamless)
    Assert.is_nil(is_provider_forced)
    shown[#shown + 1] = path
    reader_callbacks[#reader_callbacks + 1] = after_open_callback
end
package.preload["apps/reader/readerui"] = function()
    return ReaderUI
end

local Open = require("book.open")
local book = {
    source_id = "moon",
    stable_id = "book-1",
    title = "整本书",
}

-- source_id 是源选择的唯一真相；Open 不读取 source.type。
ReaderUI.instance = nil
local desktop = { detail = {} }
local detail = desktop.detail
local plugin = { desktop = desktop }
Open.book(plugin, book)
open_callbacks[1]("/library/book.epub")
Stubs.flush()
Assert.eq(resolved_id, "moon")
Assert.eq(opened_identity.source, source)
Assert.eq(opened_identity.book, book)
Assert.eq(shown[1], "/library/book.epub")
Assert.eq(plugin.desktop, desktop)
Assert.len(closed, 0)

-- Reader 成功初始化后再下一拍关闭桌面，不能先暴露底层 FileManager。
reader_callbacks[1]()
Assert.eq(plugin.desktop, desktop)
Assert.len(closed, 0)
Stubs.flush()
Assert.is_nil(plugin.desktop)
Assert.eq(closed[1], detail)
Assert.eq(closed[2], desktop)

-- 用户已切到其他文档时，丢弃本次 ReaderReady 交接。
ReaderUI.instance = { document = { file = "/other.epub" } }
Open.book({ desktop = {} }, book)
open_callbacks[2]("/library/book.epub")
Stubs.flush()
Assert.len(shown, 1)

-- 旧回调已排入 nextTick 后又打开新书，旧路径不得抢先启动 Reader。
ReaderUI.instance = nil
Open.book({ desktop = {} }, book)
open_callbacks[3]("/old.epub")
Open.book({ desktop = {} }, book)
open_callbacks[4]("/new.epub")
Stubs.flush()
Assert.eq(shown[#shown], "/new.epub")
Assert.len(shown, 2)

-- 打开失败时 Reader 不调用成功回调，Book 桌面必须继续保留。
local failed_plugin = { desktop = {} }
ReaderUI.instance = nil
Open.book(failed_plugin, book)
open_callbacks[5]("/broken.epub")
Stubs.flush()
Assert.eq(failed_plugin.desktop ~= nil, true)
