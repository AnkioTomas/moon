--[[--
desktop.open：按 Book 身份解析属主源，只消费源返回的物理文档。

@module tests.book.open_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local resolved_id
local touched
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
local Themed = require("support.theme_stubs")
Themed.install()
package.preload["book.store"] = function()
    return { rememberMany = function() end, touch = function(path) touched = path return true end }
end
package.preload["reader.session"] = function()
    error("desktop.open must not load reader session")
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

package.preload["reader.prefs"] = function() return { BIG_BOOK_BYTES = 20 * 1024 * 1024 } end
local sidecar = false
package.preload["docsettings"] = function() return { hasSidecarFile = function() return sidecar end } end

local Open = require("desktop.open")
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

-- 可选 on_done：真正交给 Reader 时才回调成功（先于 showReader）；失败也要回调。
local done_ok, shown_at_done
Open.book({ desktop = {} }, book, function(ok)
    done_ok, shown_at_done = ok, #shown
end)
open_callbacks[6]("/library/book.epub")
Assert.is_nil(done_ok)
Stubs.flush()
Assert.is_true(done_ok)
Assert.eq(shown_at_done + 1, #shown)
done_ok = nil
Open.book({ desktop = {} }, book, function(ok) done_ok = ok end)
open_callbacks[7](nil, "boom")
Assert.is_false(done_ok)

-- 用户已在读别的文档：放弃交接，回调失败而不是谎报成功。
done_ok = nil
ReaderUI.instance = { document = { file = "/other.epub" } }
local shown_before = #shown
Open.book({ desktop = {} }, book, function(ok) done_ok = ok end)
open_callbacks[8]("/library/book.epub")
Stubs.flush()
Assert.is_false(done_ok)
Assert.len(shown, shown_before)
ReaderUI.instance = nil

-- 源已自行展示（在线漫画查看器）：算成功，不开阅读器、不提示、不关桌面。
done_ok = nil
local handled_plugin = { desktop = {} }
local toasts = #Themed.all("toast")
Open.book(handled_plugin, book, function(ok) done_ok = ok end)
open_callbacks[9](nil, nil, { handled = true })
Stubs.flush()
Assert.is_true(done_ok)
Assert.len(shown, shown_before)
Assert.len(Themed.all("toast"), toasts)
Assert.is_true(handled_plugin.desktop ~= nil)

-- 超大 EPUB 首次打开（没有 sidecar）：先弹确认，说明是 KOReader 排版引擎的限制；确认后才交给 Reader。
do
    local lfs = require("libs/libkoreader-lfs")
    local real_attributes = lfs.attributes
    lfs.attributes = function(path, what)
        if path == "/library/huge.epub" and what == "size" then return 40 * 1024 * 1024 end
        return real_attributes(path, what)
    end
    ReaderUI.instance = nil
    local before = #shown
    done_ok = nil
    Open.book({ desktop = {} }, book, function(ok) done_ok = ok end)
    open_callbacks[#open_callbacks]("/library/huge.epub")
    Stubs.flush()
    Assert.len(shown, before)
    local confirm = Themed.last("confirm")
    Assert.matches(confirm.text, "不是月读的问题")
    Assert.matches(confirm.text, "KOReader 排版引擎")
    confirm.cancel_callback()
    Assert.is_false(done_ok)
    Assert.len(shown, before)

    Open.book({ desktop = {} }, book, function(ok) done_ok = ok end)
    open_callbacks[#open_callbacks]("/library/huge.epub")
    Stubs.flush()
    Themed.last("confirm").ok_callback()
    Assert.is_true(done_ok)
    Assert.eq(shown[#shown], "/library/huge.epub")

    -- 开过的书（有 sidecar）不再提示
    sidecar = true
    local confirms = #Themed.all("confirm")
    Open.book({ desktop = {} }, book)
    open_callbacks[#open_callbacks]("/library/huge.epub")
    Stubs.flush()
    Assert.len(Themed.all("confirm"), confirms)
    Assert.eq(shown[#shown], "/library/huge.epub")
    lfs.attributes = real_attributes
end

-- 上次读的是排版版（衍生版）：源返回原书路径，改回上次的版本并重新登记。
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. dir)
    local origin, derived = dir .. "/a.epub", dir .. "/reflow.epub"
    io.open(derived, "w"):close()
    package.loaded["reader.session.derived_note"] = { originOf = function(file) return file == derived and origin or nil end }
    package.loaded["book.books_db"] = { get = function() return { path = derived } end }
    ReaderUI.instance = nil
    Open.book({ desktop = {} }, book)
    open_callbacks[#open_callbacks](origin)
    Stubs.flush()
    Assert.eq(shown[#shown], derived)
    Assert.eq(touched, derived)

    -- 上次的文件不是这本书的衍生版：照源返回的路径开。
    package.loaded["book.books_db"] = { get = function() return { path = "/else/b.epub" } end }
    Open.book({ desktop = {} }, book)
    open_callbacks[#open_callbacks](origin)
    Stubs.flush()
    Assert.eq(shown[#shown], origin)
    package.loaded["book.books_db"] = nil
    package.loaded["reader.session.derived_note"] = nil
    os.execute("rm -rf " .. dir)
end
