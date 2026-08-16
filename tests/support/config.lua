--[[--
测试用 KOReader 数据目录接线。

仓库根 `config` 软链 → 模拟器数据目录。
本模块只解决「数据目录在哪」；读/写配置一律走 moon.settings。

  local Config = require("support.config")
  local Settings = require("moon.settings")  -- 或 Config.settings()
  Settings.get()
  Settings.getSource("wechat")

禁止再手写 koreader-emulator-… 路径，也禁止 loadfile 配置文件。

@module tests.support.config
--]]

local Config = {}

local function resolveRoot()
    if type(_G.BOOK_TEST_ROOT) == "string" and _G.BOOK_TEST_ROOT ~= "" then
        return _G.BOOK_TEST_ROOT
    end
    local src = debug.getinfo(1, "S").source
    if type(src) == "string" and src:sub(1, 1) == "@" then
        local root = src:sub(2):match("(.+)/tests/support/[^/]+$")
        if root and root ~= "" then
            return root
        end
    end
    return "."
end

local ROOT = resolveRoot()

--- 仓库根
function Config.root()
    return ROOT
end

--- KOReader 数据目录（= 根目录 config 软链）
function Config.dir()
    return ROOT .. "/config"
end

--- config 软链是否可用
function Config.available()
    local f = io.open(Config.dir() .. "/.moon/settings/common.lua", "r")
    if not f then
        return false
    end
    f:close()
    return true
end

--- 配置 API（= moon.settings）
---@return table
function Config.settings()
    return require("utils.settings")
end

--- 挂上模拟器 native 库（libkoreader-lfs 等），供 Paths / LuaSettings 使用
function Config.setupNativePath()
    local dir = Config.dir()
    local mark = dir .. "/libs/libkoreader-lfs.so"
    local f = io.open(mark, "r")
    if not f then
        return false
    end
    f:close()
    -- require("libs/libkoreader-lfs") → $DATA/libs/libkoreader-lfs.so
    local entry = dir .. "/?.so"
    if not package.cpath:find(entry, 1, true) then
        package.cpath = entry .. ";" .. package.cpath
    end
    return true
end

--- 顶掉 frontend util 的 ffi 依赖；LuaSettings.flush 只需要 writeToFile
function Config.installUtilStub()
    if package.preload["util"] then
        return
    end
    package.preload["util"] = function()
        return {
            -- 与 frontend/util.lua 同语义：lua_dofile_ready 时包成可 dofile 的
            -- "-- path\nreturn <data>"（漏掉这层会让模拟器下次读到"损坏"配置）
            writeToFile = function(data, file, _force_flush, lua_dofile_ready)
                if lua_dofile_ready then
                    data = table.concat({ "-- ", file, "\nreturn ", data, "\n" })
                end
                local fh, err = io.open(file, "w")
                if not fh then
                    error(err or ("cannot write " .. tostring(file)))
                end
                fh:write(data)
                fh:close()
                return true
            end,
            -- 与 koreader/frontend/util.lua 同实现（http/webdav.lua 需要）
            urlEncode = function(url, preserve_chars)
                local char_to_hex = function(c)
                    return string.format("%%%02X", string.byte(c))
                end
                preserve_chars = preserve_chars or ""
                local pattern = string.format("([%s%s])", "^%w%-%._~", preserve_chars)
                if url == nil then
                    return
                end
                url = url:gsub("\n", "\r\n")
                url = url:gsub(pattern, char_to_hex)
                return url
            end,
            urlDecode = function(url)
                if url == nil then
                    return
                end
                return (url:gsub("%%(%x%x)", function(x)
                    return string.char(tonumber(x, 16))
                end))
            end,
            -- 与 koreader/frontend/util.lua partialMD5 同实现
            partialMD5 = function(filepath)
                if not filepath then
                    return
                end
                local file = io.open(filepath, "rb")
                if not file then
                    return
                end
                local md5 = require("ffi/sha2").md5
                local bit = require("bit")
                local step, size = 1024, 1024
                local update = md5()
                for i = -1, 10 do
                    file:seek("set", bit.lshift(step, 2 * i))
                    local sample = file:read(size)
                    if sample then
                        update(sample)
                    else
                        break
                    end
                end
                file:close()
                return update()
            end,
        }
    end
end

return Config
