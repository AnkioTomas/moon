--[[-- CSS 字体发现：字体族列表、简写、转义、HTML 样式与只读 EPUB 扫描。 --]]
local Assert = require("support.assert")
local Scan = require("features.fontmap.scan")
local function names(found)
    local list = {}
    for name in pairs(found) do list[#list + 1] = name end
    table.sort(list)
    return table.concat(list, "|")
end
Assert.eq(names(Scan.css('p{font-family:"楷体", KaiTi, serif}')), "KaiTi|楷体")
Assert.eq(names(Scan.css("p{FONT-FAMILY: Noto Sans CJK SC, sans-serif!important}")), "Noto Sans CJK SC")
Assert.eq(names(Scan.css([[/*font-family:Fake*/p{content:"font-family:Another";font-family:'A,B', "A\"B"}]])), 'A"B|A,B')
Assert.eq(names(Scan.css([[p{font-family:"\6977 \4f53 ", monospace}]])), "楷体")
Assert.eq(names(Scan.css([[p{font:italic bold 12px/1.5 "Example Serif", serif}]])), "Example Serif")
Assert.eq(names(Scan.css([[p{font-family:var(--body-font);font-family:inherit}]])), "")
local found = {}
local links = Scan.markup([[<html><head><style>p{font-family:StyleFont}</style>
<link rel="stylesheet" href="styles.css"></head><body>
<!-- <span style="font-family:Comment"> -->
<span STYLE="font-family:&quot;Inline Font&quot;">Example</span>
<font face="Legacy Font">Text</font><p>font-family:NotCSS</p></body></html>]], found)
Assert.eq(names(found), "Inline Font|Legacy Font|StyleFont")
Assert.eq(links[1], "styles.css")
local _fonts, imports = Scan.css([[@import "first.css"; @import url("second.css") screen; @import url(css/third.css);]])
Assert.eq(table.concat(imports, "|"), "first.css|second.css|css/third.css")
found = {}
links = Scan.markup([[<script>const x = '<p style="font-family:Script">';</script>
<style>@import "inline.css";</style><link rel=stylesheet href=bare.css>]], found)
Assert.eq(names(found), "")
Assert.eq(table.concat(links, "|"), "inline.css|bare.css")

local entries = {
    { path = "OPS/styles.css", mode = "file", data = 'p{font-family:"EPUB Font"}' },
    { path = "OPS/chapter.xhtml", mode = "file", data = '<p style="font-family:Inline">Test</p>' },
    { path = "OPS/font.ttf", mode = "file", data = "font-family:NotCSS" },
}
local closed = false
local fail = false
package.loaded["ffi/archiver"] = { Reader = { new = function()
    return {
        open = function() return true end,
        iterate = function()
            local idx = 0
            return function() idx = idx + 1; return entries[idx] end
        end,
        extractToMemory = function(self, path)
            if fail then self.err = "broken CSS entry"; return nil end
            for _idx, entry in ipairs(entries) do if path == entry.path then return entry.data end end
        end,
        close = function() closed = true end,
    }
end } }
Assert.eq(table.concat(Scan.book("book.epub"), "|"), "EPUB Font|Inline")
Assert.is_true(closed)
fail, closed = true, false
Assert.errors(function() Scan.book("broken.epub") end, "broken CSS entry")
Assert.is_true(closed, "失败也要关闭归档")

-- 外链 CSS 与 @import 递归只读本地，循环导入不重复扫描，不碰网络。
local dir = require("support.config").dir()
local files = {
    [dir .. "/fontmap-scan.html"] = '<link rel="stylesheet" href="fontmap-first.css">',
    [dir .. "/fontmap-first.css"] = '@import "fontmap-second.css"; p{font-family:First}',
    [dir .. "/fontmap-second.css"] = '@import "fontmap-first.css"; @import "https://example.invalid/remote.css"; p{font-family:Second}',
}
for path, data in pairs(files) do
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    file:close()
end
package.loaded["ffi/util"] = { realpath = function(path) return path end }
local detected = Scan.book(dir .. "/fontmap-scan.html")
for path in pairs(files) do assert(os.remove(path)) end
Assert.eq(table.concat(detected, "|"), "First|Second")
