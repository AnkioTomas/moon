--[[--
source.local.common 扫盘规则：补充的书籍后缀；按文件夹分类开（3 层结构）/ 关（不派生分类、不限层数、跳过软链接目录）。

@module tests.source.local.scan_rules_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local DIRS, FILES, LINKS = {}, {}, {}
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
add(p, "very_deep.epub")
-- 指回根目录的软链接目录：flat 模式下跳过
add("/root", "loop", true)
DIRS["/root/loop"] = DIRS["/root"]
LINKS["/root/loop"] = true

local function attr(path)
    return DIRS[path] and { mode = "directory" }
        or FILES[path] and { mode = "file", size = 1, modification = 0 } or nil
end
package.loaded["libs/libkoreader-lfs"] = {
    dir = function(path)
        local entries, i = DIRS[path] or {}, 0
        return function() i = i + 1 return entries[i] end, {}
    end,
    attributes = function(path, req)
        local a = attr(path)
        if a and type(req) == "string" then return a[req] end
        return a
    end,
    symlinkattributes = function(path, req)
        local a = LINKS[path] and { mode = "link" } or attr(path)
        if a and type(req) == "string" then return a[req] end
        return a
    end,
}
package.loaded["source.local.common"] = nil
local Common = require("source.local.common")

for _idx, name in ipairs({ "x.FB2.ZIP", "y.prc", "a.htm", "a.xhtml", "a.doc", "a.odt" }) do
    Assert.is_true(Common.isBookFile(name), name)
end
Assert.is_false(Common.isBookFile("z.zip"))

local function scan(flat)
    local by = {}
    for _idx, f in ipairs(Common.scanFiles("/root", flat)) do
        Assert.is_nil(by[f.path], "不重复：" .. f.path)
        by[f.path] = f
    end
    return by
end

-- 开（默认）：原 3 层结构，第 4 层及更深不收
local on = scan(false)
Assert.not_nil(on["/root/x.fb2.zip"])
Assert.not_nil(on["/root/y.prc"])
Assert.is_nil(on["/root/z.zip"])
Assert.is_nil(on["/root/documents/Author/Title/book.azw3"])
Assert.is_nil(on[p .. "/very_deep.epub"])
-- 分类模式也不跟软链接目录：/root/loop 指回根，不能把根里的书再扫一遍
Assert.is_nil(on["/root/loop/x.fb2.zip"])

-- 关：不看目录结构，不派生分类 / 系列；不限层数；软链接目录跳过
local off = scan(true)
local deep = off["/root/documents/Author/Title/book.azw3"]
Assert.not_nil(deep)
Assert.is_nil(deep.category)
Assert.is_nil(deep.series)
Assert.not_nil(off[p .. "/very_deep.epub"], "不限层数")
for path in pairs(off) do
    Assert.is_nil(path:find("/loop/", 1, true), "软链接目录不下钻")
end

-- 读不了的子目录：记日志跳过并回报，兄弟照扫；根读不了照旧抛错
local DENIED = { ["/root/documents"] = true }
local lfsStub = package.loaded["libs/libkoreader-lfs"]
local stubDir = lfsStub.dir
lfsStub.dir = function(path)
    if DENIED[path] then error("cannot open " .. path .. ": Permission denied") end
    return stubDir(path)
end
local log, warned = require("utils.log"), nil
local realWarn = log.warn
log.warn = function(...) warned = table.concat({ ... }, " ") end
local files, skipped = Common.scanFiles("/root", true)
log.warn = realWarn
Assert.eq(1, #skipped)
Assert.eq("/root/documents", skipped[1])
Assert.matches(warned, "book local scan skip unreadable dir /root/documents")
local seen = {}
for _idx, f in ipairs(files) do seen[f.path] = true end
Assert.not_nil(seen["/root/x.fb2.zip"])
Assert.not_nil(seen[p .. "/very_deep.epub"])
Assert.is_nil(seen["/root/documents/Author/Title/book.azw3"])
DENIED["/root"] = true
Assert.is_false(pcall(Common.scanFiles, "/root", true))
lfsStub.dir = stubDir

package.loaded["libs/libkoreader-lfs"] = nil
package.loaded["source.local.common"] = nil
