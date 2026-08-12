--[[--
Moon 目录布局（$DATA/.moon）

  .moon/
    cache/
      cover/     封面
      book/      书籍
    settings/
      common.lua
      moon.lua / wechat.lua / webdav.lua / legado.lua

@module koplugin.book.moon.paths
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local P = {}

local function ensureDir(path)
    if not path or path == "" then
        return
    end
    if lfs.attributes(path, "mode") == "directory" then
        return
    end
    local parent = path:match("(.+)/[^/]+/?$")
    if parent and parent ~= "" and parent ~= path then
        ensureDir(parent)
    end
    lfs.mkdir(path)
end

function P.root()
    return DataStorage:getDataDir() .. "/.moon"
end

function P.cacheDir()
    return P.root() .. "/cache"
end

function P.bookDir()
    return P.cacheDir() .. "/book"
end

function P.coverDir()
    return P.cacheDir() .. "/cover"
end

function P.settingsDir()
    return P.root() .. "/settings"
end

function P.commonPath()
    return P.settingsDir() .. "/common.lua"
end

function P.sourcePath(id)
    id = tostring(id or "moon")
    return P.settingsDir() .. "/" .. id .. ".lua"
end

--- 确保 .moon 目录树存在
function P.ensureLayout()
    ensureDir(P.root())
    ensureDir(P.cacheDir())
    ensureDir(P.bookDir())
    ensureDir(P.coverDir())
    ensureDir(P.settingsDir())
end

return P
