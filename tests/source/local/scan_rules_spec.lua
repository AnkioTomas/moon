--[[--
source.local.common 扫盘规则：补充的书籍后缀、深目录（至多 8 层）。

@module tests.source.local.scan_rules_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local DIRS, FILES = {}, {}
local function add(parent, name, is_dir)
    DIRS[parent] = DIRS[parent] or {}
    table.insert(DIRS[parent], name)
    local p = parent .. "/" .. name
    if is_dir then DIRS[p] = DIRS[p] or {} else FILES[p] = true end
    return p
end
add("/root", "x.fb2.zip")
add("/root", "y.prc")
add("/root", "z.zip")
add(add(add(add("/root", "documents", true), "Author", true), "Title", true), "book.azw3")
local p = "/root"
for i = 1, 10 do p = add(p, "d" .. i, true) end
add(p, "too_deep.epub")

package.loaded["libs/libkoreader-lfs"] = {
    dir = function(path)
        local entries, i = DIRS[path] or {}, 0
        return function() i = i + 1 return entries[i] end, {}
    end,
    attributes = function(path, req)
        local attr = DIRS[path] and { mode = "directory" }
            or FILES[path] and { mode = "file", size = 1, modification = 0 } or nil
        if attr and type(req) == "string" then return attr[req] end
        return attr
    end,
}
package.loaded["source.local.common"] = nil
local Common = require("source.local.common")

for _idx, name in ipairs({ "x.FB2.ZIP", "y.prc", "a.htm", "a.xhtml", "a.doc", "a.odt" }) do
    Assert.is_true(Common.isBookFile(name), name)
end
Assert.is_false(Common.isBookFile("z.zip"))

-- 深目录照收，分类 / 系列取前两级；超过 8 层不下钻
local by = {}
for _idx, f in ipairs(Common.scanFiles("/root")) do by[f.path] = f end
local deep = by["/root/documents/Author/Title/book.azw3"]
Assert.not_nil(deep, "documents/作者/书名/ 第 4 层照样扫到")
Assert.eq(deep.category, "documents")
Assert.eq(deep.series, "Author")
Assert.not_nil(by["/root/x.fb2.zip"])
Assert.is_nil(by["/root/z.zip"])
Assert.is_nil(by[p .. "/too_deep.epub"])

package.loaded["libs/libkoreader-lfs"] = nil
package.loaded["source.local.common"] = nil
