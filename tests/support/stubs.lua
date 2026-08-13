--[[--
KOReader 模块替身：让插件逻辑在裸 LuaJIT 下可 require。

只 stub 测试真正碰到的模块；缺什么再补，别提前造整棵 UI 树。

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
        return function(s)
            return s
        end
    end
end

local function installSocketutil()
    package.preload["socketutil"] = function()
        return {
            USER_AGENT = "BookTest/0",
        }
    end
end

function Stubs.install()
    installUIManager()
    installLogger()
    installGettext()
    installSocketutil()
    clearQueue()
end

return Stubs
