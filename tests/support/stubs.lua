--[[--
KOReader 模块替身：让插件逻辑在裸 LuaJIT 下可 require。

只 stub 测试真正碰到的模块；缺什么再补，别提前造整棵 UI 树。

数据目录：datastorage 指向仓库根 `config` 软链（见 support.config）。

@module tests.support.stubs
--]]

local Stubs = {}

local _queue = {}

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
        local logger = {}
        function logger.dbg() end
        function logger.info() end
        function logger.warn() end
        function logger.err() end
        return logger
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

--- 把 DataStorage 指到仓库根 config/（模拟器数据目录）
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
    Config.setupNativePath()
    Config.installUtilStub()
    installUIManager()
    installLogger()
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
