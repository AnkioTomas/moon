--[[--
翻页诊断：只观测，不改变翻页、刷新或事件处理。

默认开启，不必开 debug、也不用设置项。每次实际翻页写一行 ``book.diag page``；
超过约 100ms 的栏刷新、Footer 重画、UIManager 任务或重绘，以及一次 ``waitEvent``
返回不少于 2 个事件，另记 ``book.diag slow`` / ``book.diag input``。
日志走现有 ``utils.log`` 批量写入，不额外 flush。

钩子装在 ReaderReady、卸在关书 / 退出；不包装 ``scheduleIn``，以免破坏按函数引用取消定时器。
无法可靠计量时省略字段，不写臆造的队列深度。不记录书名或正文。

@module koplugin.book.reader.page_diag
--]]

local Perf = require("utils.perf")

--- LuaJIT / Lua 5.1 没有 table.pack / table.unpack。
local function pack(...)
    return { n = select("#", ...), ... }
end
local unpack = unpack or table.unpack

local Diag = {}

local SLOW_MS = 100
local CONTEXT_MS = 2000
local HISTORY = 6

local enabled = false
local installed = false
---@type { obj: table, name: string, orig: function, ours: function }[]
local hooks = {}
---@type { kind: string, ms: number, at: number }[]
local history = {}
local last_page_at
local last_page
local turn_n = 0
---@type { n: integer, kinds: string, at: number }|nil
local input_batch

--- 只走现有 info 批量写入，不额外 flush。
local function log(...)
    require("utils.log").info("book.diag", ...)
end

---@param kind string
---@param ms number
local function remember(kind, ms)
    local at = Perf.now()
    history[#history + 1] = { kind = kind, ms = ms, at = at }
    if #history > HISTORY then table.remove(history, 1) end
    return at
end

---@param at number
---@return string|nil
local function lastContext(at)
    if #history == 0 then return nil end
    local parts = {}
    for i = #history, 1, -1 do
        local item = history[i]
        local ago = math.max(0, math.floor(at - item.at + 0.5))
        if ago <= CONTEXT_MS then
            parts[#parts + 1] = string.format("%s:%dms@%dms_ago", item.kind, item.ms, ago)
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

--- 记录一次已发生的刷新或任务；仅 ≥100ms 写日志。未安装时为空操作。
---@param kind string
---@param started_at number
---@param extra { force: boolean, full: boolean }|nil
function Diag.record(kind, started_at, extra)
    if not enabled then return end
    local ms = Perf.elapsedMs(started_at)
    remember(kind, ms)
    if ms < SLOW_MS then return end
    if extra then
        log("slow", kind, ms, "ms",
            "force=" .. tostring(extra.force == true),
            "full=" .. tostring(extra.full == true))
    else
        log("slow", kind, ms, "ms")
    end
end

--- 翻页结束时调用：第一次只建基线；页码未变则跳过；实际翻页写一行。
---@param started_at number
---@param page number|nil
function Diag.notePageUpdate(started_at, page)
    if not enabled then return end
    local at = Perf.now()
    local ms = Perf.elapsedMs(started_at)
    local page_num = tonumber(page)
    if last_page ~= nil and page_num ~= nil and page_num == last_page then
        return
    end
    local prev = last_page_at
    last_page_at = at
    if page_num ~= nil then
        last_page = page_num
    end
    if prev == nil then
        return
    end
    turn_n = turn_n + 1
    local args = { "page", "n=" .. turn_n }
    if page_num ~= nil then
        args[#args + 1] = "page=" .. tostring(page_num)
    end
    args[#args + 1] = "interval_ms=" .. math.max(0, math.floor(at - prev + 0.5))
    args[#args + 1] = "update_ms=" .. ms
    local ctx = lastContext(at)
    if ctx then
        args[#args + 1] = "last=" .. ctx
    end
    if input_batch and (at - input_batch.at) <= CONTEXT_MS then
        args[#args + 1] = "input_batch=" .. tostring(input_batch.n)
        if input_batch.kinds ~= "" then
            args[#args + 1] = "input=" .. input_batch.kinds
        end
        args[#args + 1] = "input_ago_ms=" .. math.max(0, math.floor(at - input_batch.at + 0.5))
    end
    log(unpack(args))
end

--- 只输出事件类型名，不含坐标、文本或书名。
---@param ev any
---@return string
local function eventKind(ev)
    if type(ev) == "string" then
        if #ev <= 40 and ev:find("^[%w_]+$") then return ev end
        return "event"
    end
    if type(ev) ~= "table" then return "unknown" end
    local name
    local handler = ev.handler
    if type(handler) == "string" and handler:sub(1, 2) == "on" and #handler <= 42 then
        name = handler:sub(3)
        if not name:find("^[%w_]+$") then name = nil end
    end
    local ges
    local args = ev.args
    local first = type(args) == "table" and args[1]
    if type(first) == "table" and type(first.ges) == "string" and first.ges:find("^[%w_]+$") then
        ges = first.ges
        local direction = first.direction
        if type(direction) == "string" and direction:find("^[%a]+$") then
            ges = ges .. ":" .. direction
        end
    end
    if name and ges then return name .. ":" .. ges end
    return name or ges or "event"
end

---@param events any
local function observeBatch(events)
    if type(events) ~= "table" then return end
    local n, kinds = 0, {}
    for i, ev in ipairs(events) do
        n = i
        kinds[i] = eventKind(ev)
    end
    if n == 0 then return end
    input_batch = { n = n, kinds = table.concat(kinds, ","), at = Perf.now() }
    if n >= 2 then
        log("input", "batch=" .. n, "kinds=" .. input_batch.kinds)
    end
end

--- 队列长度是准确的；due 仅在每项都有可比较的 time 时才给出。
---@param ui table
---@return integer|nil due
---@return integer|nil queued
local function peekTasks(ui)
    local queue = ui and ui._task_queue
    if type(queue) ~= "table" then return nil, nil end
    local queued = #queue
    local ok, time = pcall(require, "ui/time")
    if not ok or type(time) ~= "table" or type(time.now) ~= "function" then
        return nil, queued
    end
    local clock = time.now()
    if clock == nil then return nil, queued end
    local due = 0
    for i = 1, queued do
        local task = queue[i]
        if type(task) ~= "table" or task.time == nil then
            return nil, queued
        end
        if task.time <= clock then due = due + 1 end
    end
    return due, queued
end

---@param obj table
---@param name string
---@param wrap fun(orig: function): function
---@return boolean
local function hook(obj, name, wrap)
    if type(obj) ~= "table" or type(obj[name]) ~= "function" then return false end
    for i = 1, #hooks do
        if hooks[i].obj == obj and hooks[i].name == name then return false end
    end
    local orig = obj[name]
    local ours = wrap(orig)
    obj[name] = ours
    hooks[#hooks + 1] = { obj = obj, name = name, orig = orig, ours = ours }
    return true
end

local function hookUIManager()
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or type(UIManager) ~= "table" then return end
    hook(UIManager, "_checkTasks", function(orig)
        return function(self, ...)
            local due, queued = peekTasks(self)
            local started = Perf.now()
            local packed = pack(orig(self, ...))
            local ms = Perf.elapsedMs(started)
            remember("uimanager.tasks", ms)
            if ms >= SLOW_MS then
                local parts = { "slow", "uimanager.tasks", ms, "ms" }
                if queued ~= nil then parts[#parts + 1] = "queued=" .. queued end
                if due ~= nil then parts[#parts + 1] = "due=" .. due end
                log(unpack(parts))
            end
            return unpack(packed, 1, packed.n)
        end
    end)
    hook(UIManager, "_repaint", function(orig)
        return function(self, ...)
            local started = Perf.now()
            local packed = pack(orig(self, ...))
            local ms = Perf.elapsedMs(started)
            remember("uimanager.repaint", ms)
            if ms >= SLOW_MS then
                log("slow", "uimanager.repaint", ms, "ms")
            end
            return unpack(packed, 1, packed.n)
        end
    end)
end

local function hookInput()
    local ok, Device = pcall(require, "device")
    local input = ok and type(Device) == "table" and Device.input
    if type(input) ~= "table" then return end
    hook(input, "waitEvent", function(orig)
        return function(self, ...)
            local packed = pack(orig(self, ...))
            observeBatch(packed[1])
            return unpack(packed, 1, packed.n)
        end
    end)
end

function Diag.uninstall()
    for i = #hooks, 1, -1 do
        local item = hooks[i]
        if item.obj[item.name] == item.ours then
            item.obj[item.name] = item.orig
        end
    end
    hooks = {}
    installed = false
    enabled = false
    history = {}
    last_page_at = nil
    last_page = nil
    turn_n = 0
    input_batch = nil
end

--- 阅读会话开始时安装；已安装则保持原钩子。
---@return boolean
function Diag.install()
    if installed then
        enabled = true
        return true
    end
    enabled = true
    hookUIManager()
    hookInput()
    installed = true
    return true
end

function Diag.isInstalled()
    return installed
end

function Diag.isEnabled()
    return enabled
end

return Diag
