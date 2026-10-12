--[[-- book.sidecar：用真实 KOReader DocSettings 与真实文件系统验证 .sdr 的删除与迁移。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local frontend = io.open(require("support.config").root() .. "/koreader/frontend/docsettings.lua", "r")
if not frontend then
    Assert.skip("需要本机 koreader/ 克隆")
    return true
end
frontend:close()
-- 真实 frontend util 离线加载不了（ffi 原生库）：在 support.config 的精简桩上补 move 用到的两个，语义照抄 frontend/util.lua
local Paths = require("utils.paths")
local util = require("util")
util.makePath = function(path) Paths.ensureDir(path); return true end
util.splitFileNameSuffix = function(file)
    if file == nil or file == "" then return "", "" end
    if string.find(file, "%.") == nil then return file, "" end
    return file:match("(.*)%.(.*)")
end

local location = "doc"
G_reader_settings = {
    readSetting = function(_, key, default)
        if key == "document_metadata_folder" then return location end
        return default
    end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}

local calls = {}
package.loaded["readhistory"] = {
    fileDeleted = function(_, path) calls[#calls + 1] = "history-del:" .. path end,
    updateItem = function(_, from, to) calls[#calls + 1] = "history-mv:" .. from .. ">" .. to end,
}
package.loaded["readcollection"] = {
    removeItem = function(_, path) calls[#calls + 1] = "coll-del:" .. path end,
    updateItem = function(_, from, to) calls[#calls + 1] = "coll-mv:" .. from .. ">" .. to end,
}
package.loaded["ui/widget/booklist"] = {
    resetBookInfoCache = function(path) calls[#calls + 1] = "info:" .. path end,
}

local dir = require("support.config").dir() .. "/sidecar"
local function write(path, data)
    Paths.ensureDir(path:match("(.+)/[^/]+$"))
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end
local function exists(path)
    return require("libs/libkoreader-lfs").attributes(path, "mode") ~= nil
end
require("ffi/util").purgeDir(dir)

local Sidecar = require("book.sidecar")
local DocSettings = require("docsettings")

-- 边车位置以 KOReader 为准：去掉最后一个后缀再加 .sdr（这次 bug 就是拼成了 a.pdf.sdr）
Assert.eq(DocSettings:getSidecarDir(dir .. "/crop.pdf"), dir .. "/crop.sdr")

-- 删除：.sdr 交给 KOReader 的 DocSettings.updateLocation（与原生文件管理器同一入口），历史 / 收藏 / 书目缓存一起清
do
    calls = {}
    local book = dir .. "/crop.pdf"
    local real_update = DocSettings.updateLocation
    DocSettings.updateLocation = function(path, new_path)
        calls[#calls + 1] = "sdr-del:" .. path .. ":" .. tostring(new_path)
    end
    Sidecar.remove(book)
    DocSettings.updateLocation = real_update
    Assert.contains(calls, "sdr-del:" .. book .. ":nil")
    Assert.contains(calls, "history-del:" .. book)
    Assert.contains(calls, "coll-del:" .. book)
    Assert.contains(calls, "info:" .. book)
end

-- 移动（改分类）：边车跟到新目录，历史与收藏改指新路径
do
    calls = {}
    local from, to = dir .. "/a.epub", dir .. "/科幻/a.epub"
    write(from, "epub")
    write(dir .. "/a.sdr/metadata.epub.lua", "return {}")
    Paths.ensureDir(dir .. "/科幻")
    assert(os.rename(from, to))
    local ok, err = Sidecar.move(from, to)
    Assert.is_true(ok, err)
    Assert.is_false(exists(dir .. "/a.sdr"))
    Assert.is_true(exists(dir .. "/科幻/a.sdr/metadata.epub.lua"))
    Assert.contains(calls, "history-mv:" .. from .. ">" .. to)
    Assert.contains(calls, "coll-mv:" .. from .. ">" .. to)
end

-- 换格式（排版替换 x.mobi → x.epub）：新旧边车是同一个目录，原样不动，不把旧格式的元数据抄过去
do
    write(dir .. "/x.sdr/metadata.mobi.lua", "return {}")
    local ok = Sidecar.move(dir .. "/x.mobi", dir .. "/x.epub")
    Assert.is_true(ok)
    Assert.is_true(exists(dir .. "/x.sdr/metadata.mobi.lua"))
    Assert.is_false(exists(dir .. "/x.sdr/metadata.epub.lua"))
end

-- 搬不动（目标已被占成非空目录）：报错给调用方回滚
do
    write(dir .. "/b.sdr/metadata.epub.lua", "return {}")
    write(dir .. "/新/b.sdr/keep", "x")
    local ok, err = Sidecar.move(dir .. "/b.epub", dir .. "/新/b.epub")
    Assert.is_false(ok)
    Assert.not_nil(err)
    Assert.is_true(exists(dir .. "/b.sdr/metadata.epub.lua"), "原边车不丢")
end

-- hash 位置按内容寻址，路径变了也不搬；历史照常更新
do
    location = "hash"
    calls = {}
    write(dir .. "/h.sdr/metadata.epub.lua", "return {}")
    Assert.is_true(Sidecar.move(dir .. "/h.epub", dir .. "/科幻/h.epub"))
    Assert.is_true(exists(dir .. "/h.sdr/metadata.epub.lua"))
    Assert.contains(calls, "history-mv:" .. dir .. "/h.epub>" .. dir .. "/科幻/h.epub")
    location = "doc"
end

require("ffi/util").purgeDir(dir)
return true
