--[[--
source.local.common 扫盘规则：书籍判定（KOReader 格式登记表 + 静态兜底）、目录深度与软链接去重、默认书库目录。

@module tests.source.local.scan_rules_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

-- 虚拟目录树：/root/loop 是指回 /root 的软链接；/deep 链 10 层
local DIRS, FILES, REAL = {}, {}, {}
local function dir(p) DIRS[p] = DIRS[p] or {} end
local function add(parent, name, is_dir)
    dir(parent)
    table.insert(DIRS[parent], name)
    local p = parent .. "/" .. name
    if is_dir then dir(p) else FILES[p] = true end
    return p
end
add("/root", "a.epub")
add("/root", "cover.jpg")
add("/root", "x.fb2.zip")
add("/root", "y.prc")
add("/root", "z.zip")
local docs = add("/root", "documents", true)
local author = add(docs, "Author", true)
local title = add(author, "Title", true)
add(title, "book.azw3")
add("/root", "loop", true)
REAL["/root/loop"] = "/root"
DIRS["/root/loop"] = DIRS["/root"]
local p = "/root"
for i = 1, 10 do p = add(p == "/root" and "/root" or p, "d" .. i, true) end
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
    mkdir = function() return true end,
}
package.loaded["ffi/util"] = { realpath = function(path) return REAL[path] or path end }
package.loaded["document/documentregistry"] = nil
package.preload["document/documentregistry"] = function()
    return { filetype_provider = { epub = {}, azw3 = {}, cbr = {}, jpg = {}, zip = {}, ["fb2.zip"] = {} } }
end
package.loaded["source.local.common"] = nil
local Common = require("source.local.common")

-- 书籍判定：登记表里的书格式收，图片 / 通用 zip 不收；静态兜底覆盖 prc / htm / xhtml / doc / odt / fb2.zip
Assert.is_true(Common.isBookFile("x.cbr"), "KOReader 登记了的格式")
Assert.is_false(Common.isBookFile("cover.jpg"), "图片不是书")
Assert.is_false(Common.isBookFile("z.zip"), "通用 zip 不是书")
for _idx, name in ipairs({ "x.FB2.ZIP", "y.prc", "a.htm", "a.xhtml", "a.doc", "a.odt", "a.AZW3" }) do
    Assert.is_true(Common.isBookFile(name), name)
end
Assert.is_false(Common.isBookFile("README"))

-- 扫盘：深目录照收（分类 / 系列取前两级），软链接环不重复，超过 8 层不再下钻
local files = Common.scanFiles("/root")
local by = {}
for _idx, f in ipairs(files) do
    Assert.is_nil(by[f.path], "软链接环不产生重复：" .. f.path)
    by[f.path] = f
end
local deep = by["/root/documents/Author/Title/book.azw3"]
Assert.not_nil(deep, "documents/作者/书名/ 第 4 层照样扫到")
Assert.eq(deep.category, "documents")
Assert.eq(deep.series, "Author")
Assert.not_nil(by["/root/x.fb2.zip"])
Assert.not_nil(by["/root/y.prc"])
Assert.is_nil(by["/root/cover.jpg"])
Assert.is_nil(by["/root/z.zip"])
Assert.is_nil(by[p .. "/too_deep.epub"], "超过最大深度不下钻")
for path in pairs(by) do
    Assert.is_nil(path:find("/loop/", 1, true), "不经软链接环重复进入")
end

-- 默认书库目录：未配置时用 KOReader home_dir；WebDAV 模式不套用
local saved = G_reader_settings
G_reader_settings = { readSetting = function(_, key) return key == "home_dir" and "/root/documents/" or nil end }
Assert.eq(Common.rootPath({ path = "" }), "/root/documents")
Assert.eq(Common.rootPath({}), "/root/documents")
Assert.eq(Common.rootPath({ path = "/root" }), "/root", "已配置的优先")
Assert.eq(Common.rootPath({ path = "", webdav_url = "https://dav" }), "")
G_reader_settings = { readSetting = function() return "/missing" end }
Assert.eq(Common.rootPath({}), "", "主目录不存在就仍是未配置")
G_reader_settings = saved

for _idx, name in ipairs({ "libs/libkoreader-lfs", "ffi/util", "document/documentregistry", "source.local.common" }) do
    package.loaded[name] = nil
    package.preload[name] = nil
end
