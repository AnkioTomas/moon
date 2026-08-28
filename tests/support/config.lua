--[[--
测试用 KOReader 数据目录接线。

数据目录是仓库根 `test/`（沙箱，git 忽略），由 tests/run.sh 建好并经 KO_HOME 传入。
**不是** 模拟器的 `config/`：测试会往里写配置、sqlite 与缓存，落到真实数据上会改坏用户配置。
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

--- 沙箱数据目录：KO_HOME 优先（tests/run.sh 设置），否则仓库根 test/。
---@return string
local function resolveDataDir()
    local home = os.getenv("KO_HOME")
    if type(home) == "string" and home ~= "" then
        return (home:gsub("/+$", ""))
    end
    return ROOT .. "/test"
end

local DATA_DIR = resolveDataDir()

--- 仓库根
---@return string
function Config.root()
    return ROOT
end

--- KOReader 数据目录（测试沙箱，非模拟器 config/）
---@return string
function Config.dir()
    return DATA_DIR
end

--- 沙箱配置是否就绪（tests/run.sh 会建；直接 luajit 跑 run.lua 时可能没有）
---@return boolean
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

--- 挂上 native 库（libkoreader-lfs 等），供 Paths / LuaSettings 使用。
--- 沙箱里的 libs 是软链到模拟器构建产物，只读。
---@return boolean 库不可用时返回 false，相关 spec 自行跳过
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
            -- 与 frontend/util.lua 同语义（输入框 charlist 按 UTF-8 字符存储）
            splitToChars = function(text)
                local chars = {}
                for char in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                    chars[#chars + 1] = char
                end
                return chars
            end,
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
