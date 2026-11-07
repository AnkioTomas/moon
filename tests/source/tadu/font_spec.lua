--[[--
精确轮廓还原 Unicode；轮廓起点和次序不影响结果，属性不解码，失败不缓存。

@module tests.source.tadu.font_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local SHA = require("ffi/sha2")
local ffi = require("ffi")
local original_loadlib = ffi.loadlib
local path = Config.dir() .. "/tadu-font-fixture.ttf"
local tmpname = os.tmpname
os.tmpname = function() return path end
local bytes = "\0\1\0\0fixture"
local original = '<p title="的">的&amp;&#x7684;<b>原</b></p>'
local decoded = '<p title="的">甲&amp;甲<b>原</b></p>'
local shapes = {
    { { 0, 0 }, { 20, 0 }, { 20, 20 }, { 0, 20 } },
    { { 30, 10 }, { 50, 10 }, { 50, 30 }, { 30, 30 } },
}
local index = {
    [SHA.sha256("64|1,0,0;1,20,0;1,20,20;1,0,20|1,30,10;1,50,10;1,50,30;1,30,30")] = 0x7532,
}
package.loaded["json"] = { decode = function(_data) return index end }
local rotated, unknown, invalid, load_failed, pending
local options, worker_result, closed, html, message, completed
local face = { glyph = { advance = { x = 64 * 64 } } }
ffi.loadlib = function(name, version)
    Assert.eq(name, "freetype")
    Assert.eq(version, "6")
    return { FT_Load_Char = function(value, cp, flags)
        Assert.eq(value, face)
        Assert.eq(cp, 30340)
        Assert.eq(flags, 10, "轮廓不能受像素 hinting 影响")
        if load_failed then return 7 end
        local outline = { n_contours = 2, n_points = 8, contours = {}, points = {}, tags = {} }
        local at = 0
        for i = 1, 2 do
            local polygon = shapes[rotated and 3 - i or i]
            for j = 1, 4 do
                local point = polygon[(j + (rotated and 1 or 0) - 1) % 4 + 1]
                outline.points[at] = { x = point[1] * 64, y = point[2] * 64 }
                outline.tags[at] = 1
                at = at + 1
            end
            outline.contours[i - 1] = at - 1
        end
        if unknown then outline.points[0].x = outline.points[0].x + 64 end
        face.glyph.outline = outline
        return 0
    end }
end
package.loaded["ffi/freetype"] = {
    newFaceSize = function(font_path, size)
        Assert.eq(font_path, path)
        Assert.eq(size, 2048)
        local file = assert(io.open(font_path, "rb"))
        Assert.eq(file:read("*a"), bytes)
        file:close()
        if invalid then error("invalid font") end
        return {
            face = face,
            hasGlyph = function(_self, cp) return cp == 30340 end,
            done = function() closed = closed + 1 end,
        }
    end,
}
package.loaded["workers.job"] = {
    run = function(worker, opts)
        options = opts
        local ok, result = pcall(worker)
        worker_result = result
        if not pending then
            if ok then opts.on_done(result) else opts.on_failed(result) end
        end
        return { cancel = function() opts.on_cancelled() end }
    end,
}
local Ext = require("utils.extension")
local hook_count = #Ext.list("reader.doc_settings")
local Font = require("source.tadu.font")
Assert.eq(#Ext.list("reader.doc_settings"), hook_count, "解码不能强制更改阅读器字体设置")
local function run()
    html, message, completed, closed = nil, nil, 0, 0
    local job = Font.restoreAsync(original, bytes, function(value, err)
        html, message, completed = value, err, completed + 1
    end)
    return job
end
local function cleaned()
    Assert.is_nil(io.open(path, "rb"), "完成、失败或取消均不保留原字体")
end
run()
Assert.is_nil(message)
Assert.eq(html, decoded, "替换正文及实体，不替换标签属性")
Assert.eq(closed, 1)
Assert.eq(completed, 1)
Assert.eq(options.kind, "light")
cleaned()
rotated = true
run()
Assert.eq(html, decoded, "轮廓换起点、换次序仍是同一字形")
rotated = false
unknown = true
run()
Assert.is_nil(html, "未知字形不能保存错码正文")
Assert.matches(message, "字体还原失败")
Assert.eq(closed, 1)
cleaned()
unknown, invalid = false, true
run()
Assert.is_nil(html)
Assert.matches(message, "invalid font")
cleaned()
invalid, load_failed = false, true
run()
Assert.is_nil(html)
Assert.matches(message, "glyph load failed")
cleaned()
load_failed = false
bytes = "<html>CDN error</html>"
run()
Assert.is_nil(html)
Assert.matches(message, "字体还原失败")
cleaned()
bytes = "\0\1\0\0fixture"
local open = io.open
io.open = function(name, mode)
    if name == path and mode == "wb" then return nil, "permission denied" end
    return open(name, mode)
end
run()
Assert.is_nil(html)
Assert.matches(message, "permission denied")
io.open = open
pending = true
run():cancel()
Assert.is_true(worker_result.html ~= nil)
Assert.eq(completed, 0, "取消不交付成功")
cleaned()
pending = false
ffi.loadlib = original_loadlib
os.tmpname = tmpname

package.loaded["source.tadu.client"] = {
    contentAsync = function(_id, _part, cb) cb(decoded) end,
}
local Chapter = require("source.chapter")
local open_async = Chapter.openAsync
local document
Chapter.openAsync = function(_source, identity, _book, _opts, ops, cb)
    ops.fetchContent(identity, { idx = 1, uid = "1", title = "章名" }, function(payload)
        payload.book_title = identity.book.title
        document = Chapter.render(payload)
        cb("fixture.html")
    end)
end
require("source.tadu").new():openBookAsync({
    source_id = "tadu", stable_id = "font-fixture", book = { title = "书名" },
}, { chapter_idx = 1 }, function() end)
Chapter.openAsync = open_async
Assert.is_true(document:find(decoded, 1, true) ~= nil)
Assert.matches(document, "<title>书名</title>")
Assert.is_nil(document:match("@font%-face"), "缓存是普通 Unicode，不依赖嵌入字体")
