--[[--
KOReader 模块替身：让插件逻辑在裸 LuaJIT 下可 require。

只 stub 测试真正碰到的模块；缺什么再补，别提前造整棵 UI 树。

数据目录：datastorage 指向仓库根 `config` 软链（见 support.config）。

@module tests.support.stubs
--]]

local Stubs = {}

local _queue = {}

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function commandOk(command)
    local result = os.execute(command)
    return result == true or result == 0
end

local function installIfMissing(name, loader)
    if package.preload[name] or package.loaded[name] then
        return
    end
    package.preload[name] = loader
end

--- 裸 LuaJIT 没有 KOReader 的 lfs 名称；测试只需要基础 POSIX 文件操作。
local function installLfs()
    installIfMissing("libs/libkoreader-lfs", function()
        local lfs = {}

        function lfs.attributes(path, name)
            local quoted = shellQuote(path)
            local pipe = io.popen(
                "(stat -c '%F|%s|%Y' -- " .. quoted
                .. " 2>/dev/null || stat -f '%HT|%z|%m' " .. quoted .. " 2>/dev/null)"
            )
            if not pipe then return nil end
            local line = pipe:read("*l")
            pipe:close()
            if not line then return nil end
            local kind, size, modification = line:match("^([^|]+)|(%d+)|(%d+)$")
            local attr = {
                mode = kind and kind:lower():find("directory", 1, true) and "directory" or "file",
                size = tonumber(size),
                modification = tonumber(modification),
            }
            return name and attr[name] or attr
        end

        lfs.symlinkattributes = lfs.attributes

        function lfs.mkdir(path)
            if commandOk("mkdir -- " .. shellQuote(path) .. " 2>/dev/null") then
                return true
            end
            return nil, "mkdir failed"
        end

        function lfs.rmdir(path)
            return os.remove(path)
        end

        function lfs.dir(path)
            local pipe = assert(io.popen("ls -A1 " .. shellQuote(path) .. " 2>/dev/null"))
            local names = { ".", ".." }
            for name in pipe:lines() do
                names[#names + 1] = name
            end
            pipe:close()
            local index = 0
            local function nextName()
                index = index + 1
                return names[index]
            end
            return nextName, {}
        end

        function lfs.touch(path, atime, mtime)
            local fh = io.open(path, "ab")
            if not fh then return nil, "touch failed" end
            fh:close()
            local timestamp = mtime or atime
            if timestamp and not commandOk(
                "touch -m -d @" .. tostring(math.floor(timestamp)) .. " -- " .. shellQuote(path)
                .. " 2>/dev/null || touch -m -t \"$(date -r "
                .. tostring(math.floor(timestamp)) .. " +%Y%m%d%H%M.%S)\" " .. shellQuote(path)
                .. " 2>/dev/null"
            ) then
                return nil, "touch timestamp failed"
            end
            return true
        end

        function lfs.currentdir()
            local pipe = assert(io.popen("pwd"))
            local path = pipe:read("*l")
            pipe:close()
            return path
        end

        return lfs
    end)
end

local function installFfiUtil()
    installIfMissing("ffi/util", function()
        local util = {}

        function util.template(str, ...)
            local params = { n = select("#", ...), ... }
            if params.n == 0 then return str end
            return (str:gsub("%%([1-9][0-9]?)", function(i)
                return params[tonumber(i)]
            end))
        end

        function util.basename(path)
            local stripped = tostring(path):match(".*[^/]") or "/"
            return stripped:match("([^/]+)$") or "/"
        end

        function util.dirname(path)
            local stripped = tostring(path):gsub("/+$", "")
            local parent = stripped:match("^(.*)/[^/]*$")
            if not parent or parent == "" then return "." end
            return parent
        end

        function util.copyFile(from, to)
            local input, err = io.open(from, "rb")
            if not input then return err end
            local output, out_err = io.open(to, "wb")
            if not output then input:close(); return out_err end
            output:write(input:read("*a"))
            input:close()
            output:close()
        end

        function util.purgeDir(path)
            local lfs = require("libs/libkoreader-lfs")
            local iter, state = lfs.dir(path)
            while true do
                local name = iter(state)
                if not name then break end
                if name ~= "." and name ~= ".." then
                    local full = path .. "/" .. name
                    if lfs.attributes(full, "mode") == "directory" then
                        local ok, err = util.purgeDir(full)
                        if not ok then return ok, err end
                    else
                        local ok, err = os.remove(full)
                        if not ok then return ok, err end
                    end
                end
            end
            return os.remove(path)
        end

        function util.orderedPairs(values)
            local keys = {}
            for key in pairs(values) do keys[#keys + 1] = key end
            table.sort(keys)
            local index = 0
            return function()
                index = index + 1
                local key = keys[index]
                if key ~= nil then return key, values[key] end
            end
        end

        return util
    end)
end

local function installSha2()
    installIfMissing("ffi/sha2", function()
        local sha2 = {}

        local function digest(command, value)
            local path = os.tmpname()
            local file = assert(io.open(path, "wb"))
            file:write(value)
            file:close()
            local pipe = assert(io.popen(command .. " " .. shellQuote(path)))
            local line = pipe:read("*l")
            pipe:close()
            os.remove(path)
            return assert(line and line:match("^([0-9a-fA-F]+)")):lower()
        end

        local function hasher(command, value)
            if value ~= nil then return digest(command, value) end
            local chunks = {}
            return function(chunk)
                if chunk ~= nil then
                    chunks[#chunks + 1] = chunk
                    return
                end
                return digest(command, table.concat(chunks))
            end
        end

        function sha2.md5(value)
            return hasher("md5sum", value)
        end

        function sha2.sha256(value)
            return hasher("sha256sum", value)
        end

        return sha2
    end)
end

local function installLuaSettings()
    installIfMissing("luasettings", function()
        local LuaSettings = {}
        LuaSettings.__index = LuaSettings

        local function serialize(value)
            local kind = type(value)
            if kind == "string" then return string.format("%q", value) end
            if kind == "number" or kind == "boolean" or kind == "nil" then
                return tostring(value)
            end
            assert(kind == "table", "unsupported settings value: " .. kind)
            local parts = { "{" }
            for key, nested in pairs(value) do
                parts[#parts + 1] = "[" .. serialize(key) .. "]=" .. serialize(nested) .. ","
            end
            parts[#parts + 1] = "}"
            return table.concat(parts)
        end

        function LuaSettings:open(path)
            local ok, data = pcall(dofile, path)
            return setmetatable({
                file = path,
                data = ok and type(data) == "table" and data or {},
            }, self)
        end

        function LuaSettings:reset(data)
            self.data = data
            return self
        end

        function LuaSettings:readSetting(key, default)
            if self.data[key] == nil and default ~= nil then self.data[key] = default end
            return self.data[key]
        end

        function LuaSettings:saveSetting(key, value)
            self.data[key] = value
            return self
        end

        function LuaSettings:delSetting(key)
            self.data[key] = nil
            return self
        end

        function LuaSettings:has(key)
            return self.data[key] ~= nil
        end

        function LuaSettings:flush()
            if not self.file then return self end
            local file = assert(io.open(self.file, "w"))
            file:write("-- ", self.file, "\nreturn ", serialize(self.data), "\n")
            file:close()
            return self
        end

        return LuaSettings
    end)
end

local function installLeafStubs()
    installIfMissing("ffi/blitbuffer", function()
        return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
    end)
    installIfMissing("ffi/posix", function()
        return {}
    end)
    installIfMissing("ui/event", function()
        local Event = {}
        function Event:new(name, ...)
            return { handler = "on" .. name, args = { ... } }
        end
        return Event
    end)
    installIfMissing("ui/widget/verticalspan", function()
        local VerticalSpan = {}
        function VerticalSpan:new(options)
            return options or {}
        end
        return VerticalSpan
    end)
end

local function clearQueue()
    _queue = {}
end

--- 立刻执行（及嵌套调度的）nextTick / scheduleIn 回调
function Stubs.flush()
    local guard = 0
    while #_queue > 0 do
        guard = guard + 1
        if guard > 1000 then
            error("stubs.flush: queue runaway")
        end
        local batch = _queue
        _queue = {}
        for i = 1, #batch do
            batch[i]()
        end
    end
end

function Stubs.reset()
    clearQueue()
end

local function installUIManager()
    package.preload["ui/uimanager"] = function()
        local UIManager = {}
        function UIManager:nextTick(fn)
            _queue[#_queue + 1] = fn
        end
        function UIManager:scheduleIn(_delay, fn)
            _queue[#_queue + 1] = fn
        end
        function UIManager:unschedule(fn)
            for i = #_queue, 1, -1 do
                if _queue[i] == fn then
                    table.remove(_queue, i)
                end
            end
        end
        function UIManager:show(widget)
        end
        function UIManager:close(widget)
        end
        function UIManager:setDirty(widget, refresh)
        end
        return UIManager
    end
end

local function installLogger()
    package.preload["logger"] = function()
        -- levels/setLevel 是给真实 dbg.lua 用的：它被 geometry 链间接 require，
        -- 缺了就在 turnOff() 里索引 nil 崩掉整个 spec
        local logger = {
            levels = { dbg = 1, info = 2, warn = 3, err = 4 },
        }
        function logger.dbg() end
        function logger.info() end
        function logger.warn() end
        function logger.err() end
        function logger:setLevel() end
        return logger
    end
end

local function installBookLog()
    package.preload["utils.log"] = function()
        local log = {}
        function log.dbg() end
        function log.info() end
        function log.warn() end
        function log.error() end
        log.err = log.error
        function log.start() end
        function log.flush() end
        return log
    end
end

local function installGettext()
    package.preload["gettext"] = function()
        -- 可索引 callable table：current_lang/translation 供 l10n 模块与测试读写；
        -- __call 保持恒等（返回源串），避免 en 目录合并后污染其它测试的文案断言
        local GetText = {
            current_lang = "C",
            translation = {},
        }
        return setmetatable(GetText, {
            __call = function(_, s)
                return s
            end,
        })
    end
end

local function installSocketutil()
    package.preload["socketutil"] = function()
        return {
            USER_AGENT = "BookTest/0",
        }
    end
end

local function installJson()
    -- Api/Auth 顶层 require("json")；离线测用不到真实编解码时顶个空壳即可
    package.preload["json"] = function()
        return {
            encode = function(v)
                error("json.encode not stubbed for this test: " .. type(v), 2)
            end,
            decode = function(v)
                error("json.decode not stubbed for this test", 2)
            end,
        }
    end
end

--- 把 DataStorage 指到测试沙箱数据目录（support.config，非模拟器 config/）
local function installDataStorage()
    package.preload["datastorage"] = function()
        local Config = require("support.config")
        local dir = Config.dir()
        local DS = {}
        function DS:getDataDir()
            return dir
        end
        function DS:getSettingsDir()
            return dir .. "/settings"
        end
        function DS:getDocSettingsDir()
            return dir .. "/docsettings"
        end
        function DS:getDocSettingsHashDir()
            return dir .. "/hashdocsettings"
        end
        function DS:getHistoryDir()
            return dir .. "/history"
        end
        function DS:getPatchesDir()
            return dir .. "/patches"
        end
        return DS
    end
end

function Stubs.install()
    -- 先接线数据目录与 native 库，再装其它 stub
    local Config = require("support.config")
    local has_native = Config.setupNativePath()
    local frontend = io.open(Config.root() .. "/koreader/frontend/ui/uimanager.lua", "r")
    local has_frontend = frontend ~= nil
    if frontend then frontend:close() end
    Config.installUtilStub()
    if not has_native then
        installLfs()
        installSha2()
    end
    if not has_frontend then
        installFfiUtil()
        installLuaSettings()
        installLeafStubs()
    end
    installUIManager()
    installLogger()
    installBookLog()
    installGettext()
    installSocketutil()
    installJson()
    installDataStorage()
    -- 离线 LuaJIT 无 LUA52COMPAT，缺 table.pack（ffi/util.template 需要）
    if not table.pack then
        table.pack = function(...)
            return { n = select("#", ...), ... }
        end
    end
    clearQueue()
end

return Stubs
