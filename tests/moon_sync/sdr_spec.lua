--[[--
书籍自定义设置：进度和划线不进同步文件；空设置第一次不能盖掉远端。

@module tests.moon_sync.sdr_spec
--]]

local Assert = require("support.assert")
package.preload["json"] = function()
    local JSON = require("support.json_stub")
    return { encode = JSON.encode, decode = JSON.decode }
end
package.loaded["json"] = nil

local Sdr = require("moon_sync.sdr")
local BookDB = require("book.books_db")

local exported = Sdr.exportSettings({
    css = "body{}",
    highlight_color = "red",
    last_xpointer = "/body/p[1]",
    highlight = { { 1 } },
    doc_path = "/mnt/us/book.epub",
    partial_md5_checksum = "abc",
    bookmarks = { 1 },
})
Assert.eq(exported.css, "body{}")
Assert.eq(exported.highlight_color, "red")
Assert.is_nil(exported.last_xpointer)
Assert.is_nil(exported.highlight)
Assert.is_nil(exported.doc_path)
Assert.is_nil(exported.partial_md5_checksum)
Assert.is_nil(exported.bookmarks)
Assert.is_true(Sdr.hasContent({
    settings = exported, reader_prefs = "", custom_metadata = {}, cover_ext = "",
}))
Assert.is_true(not Sdr.hasContent({
    settings = {}, reader_prefs = "", custom_metadata = {}, cover_ext = "",
}))

local data = {
    css = "old",
    font_size = 20,
    last_xpointer = "/keep",
    doc_path = "/local/book.epub",
    highlight = { page = 1 },
}
Sdr.applySettings(data, { css = "new", last_xpointer = "/remote", doc_path = "/remote/book.epub" })
Assert.eq(data.css, "new")
Assert.is_nil(data.font_size)
Assert.eq(data.last_xpointer, "/keep")
Assert.eq(data.doc_path, "/local/book.epub")
Assert.eq(data.highlight.page, 1)

local left = Sdr.fingerprint({
    settings = { css = "a", font = "b" },
    reader_prefs = "",
    custom_metadata = {},
    cover_ext = "",
    cover_hash = "",
})
local right = Sdr.fingerprint({
    settings = { font = "b", css = "a" },
    reader_prefs = "",
    custom_metadata = {},
    cover_ext = "",
    cover_hash = "",
})
Assert.eq(left, right)
Assert.is_true(Sdr.coverExtOk("jpg"))
Assert.is_true(not Sdr.coverExtOk("lua"))

local function act(spec)
    spec.trusted = spec.trusted ~= false
    spec.file_mtime = spec.file_mtime or 0
    return Sdr.action(spec)
end

Assert.eq(act({ hash = "h", can_write = true, has_content = true }), "push")
Assert.eq(act({ hash = "h", can_write = true, has_content = false }), "skip")
Assert.eq(act({
    hash = "empty", remote_mtime = 50, can_write = true, has_content = false, file_mtime = 80,
}), "pull")
Assert.eq(act({
    seen = { mtime = 10, hash = "font" }, hash = "empty", remote_mtime = 10,
    can_write = true, has_content = false, file_mtime = 40,
}), "push")
Assert.eq(act({
    seen = { mtime = 10, hash = "font" }, hash = "font", remote_mtime = 10,
    can_write = true, has_content = true, file_mtime = 90,
}), "skip")
Assert.eq(act({
    seen = { mtime = 10, hash = "font" }, hash = "font", remote_mtime = 30,
    can_write = true, has_content = true, file_mtime = 90,
}), "pull")
Assert.eq(act({
    hash = "font", remote_mtime = 20, can_write = true, has_content = true, file_mtime = 50,
}), "push")
Assert.eq(act({
    hash = "font", remote_mtime = 80, can_write = true, has_content = true, file_mtime = 50,
}), "pull")
Assert.eq(act({
    hash = "font", remote_mtime = 80, can_write = true, has_content = true, file_mtime = 50, trusted = false,
}), "push")
Assert.eq(act({
    hash = "empty", remote_mtime = 80, can_write = true, has_content = false, trusted = false,
}), "skip")
Assert.eq(act({
    hash = "prefs", remote_mtime = 40, can_write = false, has_content = true,
}), "prefs")
Assert.eq(act({ hash = "prefs", can_write = false, has_content = true }), "skip")
Assert.eq(act({
    seen = { mtime = 40, hash = "prefs", prefs_only = true },
    hash = "prefs", remote_mtime = 40, can_write = true, has_content = true, file_mtime = 10,
}), "pull")
Assert.eq(act({
    seen = { mtime = 40, hash = "prefs", prefs_only = true },
    hash = "prefs", remote_mtime = 40, can_write = true, has_content = true, trusted = false,
}), "skip")

local groups = Sdr.bySource({
    { source_id = "kindle", stable_id = "book-1", path = "/a.epub" },
    { source_id = "bad/id", stable_id = "book-1", path = "/b.epub" },
})
Assert.eq(groups.kindle["book-1"].path, "/a.epub")
Assert.is_nil(groups["bad/id"])

BookDB.upsert({ source_id = "sdr-keep", stable_id = "alive", title = "t", path = "/books/alive.epub" })
BookDB.setReaderPrefs("sdr-gone", "tomb", "{\"css\":\"x\"}")
local found_alive, found_tomb = false, false
for _i, row in ipairs(BookDB.sidecarBooks()) do
    if row.source_id == "sdr-keep" and row.stable_id == "alive" then
        found_alive = true
        Assert.eq(row.path, "/books/alive.epub")
    end
    if row.source_id == "sdr-gone" then found_tomb = true end
end
Assert.is_true(found_alive)
Assert.is_true(not found_tomb)
