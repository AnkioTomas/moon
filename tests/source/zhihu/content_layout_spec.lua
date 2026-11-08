--[[--
知乎章末排版：备案号清理、缓存升级、正文坐标与失败时的原文件保护。

@module tests.source.zhihu.content_layout_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Content = require("source.zhihu.content")
local Fs = require("utils.fs")
local prefix = '<html><body><p data-block-key="keep">正文里的备案号说明不能删。</p>'
local watermark = '<span id="vipyxcode" style="opacity:0.5">备美号:YXXBfixture</span>'
local raw = prefix .. "<p>" .. watermark .. "</p></body></html>"
local html = Content.prepare(raw)
Assert.is_true(html:find(prefix, 1, true) ~= nil, "前面的原文节点和属性逐字保留")
Assert.is_nil(html:find("vipyxcode", 1, true))
Assert.is_nil(html:find("YXXBfixture", 1, true), "按稳定的元素 id 清理，不依赖可能被字体扰乱的文字")
Assert.is_true(html:find("<p></p>", 1, true) ~= nil, "保留空段落，不挪动其它节点编号")
Assert.is_true(html:find(Content.FOOTER .. "</body>", 1, true) ~= nil)
Assert.eq(Content.prepare(html), html, "重开书不能重复追加章评区")

local path = Config.dir() .. "/zhihu_layout_fixture.html"
local file = assert(io.open(path, "wb")); assert(file:write(raw)); file:close()
Assert.is_true(Content.reuse(path))
Assert.eq(Fs.read(path), html, "旧章节离线原地升级，不重新下载正文")
Assert.is_true(Content.reuse(path))
Assert.is_nil(io.open(path .. ".part", "rb"))
os.remove(path)

local archive = {
    { path = "mimetype", data = "application/epub+zip", mode = "file" },
    { path = "META-INF/container.xml", data = "<container/>", mode = "file" },
    { path = "OEBPS/chapter_001.xhtml", data = prefix .. "</body></html>", mode = "file" },
    { path = "OEBPS/chapter_002.xhtml",
        data = '<html><body><p id="last">结尾正文。</p><p>备美号:YXXBfixture</p></body></html>', mode = "file" },
}
local copied, compression, fail_write, writes = {}, {}, false, 0
package.loaded["ffi/archiver"] = {
    Reader = { new = function()
        return {
            open = function() return true end,
            close = function() end,
            iterate = function()
                local idx = 0
                return function() idx = idx + 1; return archive[idx] end
            end,
            extractToMemory = function(_reader, name)
                for _idx, entry in ipairs(archive) do if entry.path == name then return entry.data end end
            end,
        }
    end },
    Writer = { new = function()
        local writer = {}
        function writer:open(dest)
            self.path = dest
            copied, compression = {}, {}
            writes = writes + 1
            return true
        end
        function writer:setZipCompression(method) self.compression = method end
        function writer:addFileFromMemory(name, data)
            if fail_write then self.err = "disk full"; return false end
            copied[name], compression[name] = data, self.compression
            return true
        end
        function writer:close()
            local output = assert(io.open(self.path, "wb"))
            output:write("rewritten archive"); output:close()
        end
        return writer
    end },
}
path = Config.dir() .. "/zhihu_layout_fixture.epub"
file = assert(io.open(path, "wb")); file:write("original archive"); file:close()
local ok, err = Content.upgradeStory(path, raw)
Assert.is_true(ok)
Assert.is_nil(err)
Assert.eq(compression.mimetype, "store")
Assert.eq(copied["OEBPS/chapter_001.xhtml"], archive[3].data, "原有分片不重新排版")
Assert.is_true(copied["OEBPS/chapter_002.xhtml"]:find('<p id="last">结尾正文。</p>', 1, true) ~= nil)
Assert.is_nil(copied["OEBPS/chapter_002.xhtml"]:find("YXXBfixture", 1, true))
Assert.is_true(copied["OEBPS/chapter_002.xhtml"]:find(Content.FOOTER, 1, true) ~= nil)
Assert.eq(copied["META-INF/container.xml"], "<container/>")
local before = writes
local original_last = archive[4].data
archive[4].data = copied["OEBPS/chapter_002.xhtml"]
Assert.is_true(Content.upgradeStory(path, raw))
Assert.eq(writes, before, "已升级的 EPUB 不再重写")
archive[4].data = original_last
fail_write = true
ok, err = Content.upgradeStory(path, raw)
Assert.is_nil(ok)
Assert.eq(err, "disk full")
Assert.eq(Fs.read(path), "rewritten archive", "失败时不能删掉上一次完整的 EPUB")
Assert.is_nil(io.open(path .. ".part", "rb"))
os.remove(path)
