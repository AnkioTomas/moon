--[[--
蓝牙后端：kindle-hid-passthrough（https://github.com/zampierilucas/kindle-hid-passthrough）。

那边的守护进程接管蓝牙芯片，并在本机开 HTTP 接口 127.0.0.1:8321（GET，回 JSON）。
本模块只是它的客户端，蓝牙状态以守护进程为准。三态：

  off      接口不通（守护进程没跑）
  stopped  接口在、蓝牙关（/stop 之后接口常驻）
  on       蓝牙开

打开：off 先拉起守护进程，等接口起来再按 stopped / on 处理；stopped 调 /start。关闭调 /stop。
配对、连接都是守护进程里的异步操作，这里发起后轮询到结果为止。

后端接口（khp / sync 包装的 kindle、kobo 共用，由 init.lua 选用）：
available()、status(cb)、setEnabled(on, cb)、setConnected(dev, connect, cb)、scan(on_update, on_done)、pair(dev, cb)。

@module koplugin.book.features.bluetooth.khp
--]]

require("l10n").apply()

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local API = "http://127.0.0.1:8321"
local BINARY = "/mnt/us/kindle_hid_passthrough/kindle-hid-passthrough"
local WAIT_SECONDS = 15
local STEP_SECONDS = 2
local MAX_STEPS = 45

local Khp = {}

---@return boolean
function Khp.available()
    return require("libs/libkoreader-lfs").attributes(BINARY, "mode") == "file"
end

--- GET 接口。守护进程回 ok=false 时把它的 error 当错误。
---@param path string
---@param cb fun(data: table|nil, err: any)
---@return HttpJob
local function get(path, cb)
    return Request.get(API .. path, { timeout = 5, connect_timeout = 2, accept = "application/json" }, function(body, err)
        if err then return cb(nil, err) end
        -- body 来自外部进程，不是 JSON 就当无效响应。
        local ok, data = pcall(JSON.decode, body)
        if not ok or type(data) ~= "table" then return cb(nil, _("蓝牙服务返回了无效数据")) end
        if data.ok == false then return cb(nil, data.error or _("未知错误")) end
        cb(data)
    end)
end

--- JSON 解出的设备带元表，缺 name 键时会顺着 __index 取到同名方法；这里拷成普通表。
---@param list table[]|nil
---@return BookBluetoothDevice[]
local function plain(list)
    local out = {}
    for i, dev in ipairs(list or {}) do
        local name = rawget(dev, "name")
        out[i] = {
            address = dev.address,
            protocol = dev.protocol,
            name = type(name) == "string" and name ~= "" and name or nil,
        }
    end
    return out
end

---@param cb fun(st: BookBluetoothStatus)
function Khp.status(cb)
    get("/status", function(data)
        cb({
            state = not data and "off" or (data.daemon_running and "on" or "stopped"),
            devices = plain(data and data.devices),
            connections = plain(data and data.connections),
        })
    end)
end

--- 每秒读一次 /status，直到 pred 成立或 seconds 秒用完。
---@param pred fun(st: BookBluetoothStatus): boolean
---@param seconds number
---@param cb fun(ok: boolean)
local function waitFor(pred, seconds, cb)
    Khp.status(function(st)
        if pred(st) then return cb(true) end
        if seconds <= 0 then return cb(false) end
        UIManager:scheduleIn(1, function() waitFor(pred, seconds - 1, cb) end)
    end)
end

--- 后台拉起守护进程（setsid 脱离 KOReader，KOReader 退出它也不退）。
local function spawn()
    os.execute(string.format(
        "(setsid %s --daemon </dev/null >/dev/null 2>&1 &) 2>/dev/null || (%s --daemon </dev/null >/dev/null 2>&1 &)",
        BINARY, BINARY))
end

--- 守护进程创建的 uhid 节点。Sysfs 在 /devices/virtual/misc/uhid/ 下，uniq 是蓝牙地址。
---@param content string
---@param address string|nil 只取这一台；nil 取全部
---@return string[] /dev/input/eventN
local function uhidPaths(content, address)
    local want = address and address:upper()
    local paths = {}
    for block in (content .. "\n\n"):gmatch("(.-)\n\n") do
        local sysfs = block:match("S: Sysfs=(%S+)")
        if sysfs and sysfs:find("uhid", 1, true) then
            local uniq = block:match("U: Uniq=(%S+)")
            if not want or (uniq and uniq:upper() == want) then
                local handlers = block:match("H: Handlers=([^\n]+)") or ""
                for node in handlers:gmatch("event%d+") do
                    paths[#paths + 1] = "/dev/input/" .. node
                end
            end
        end
    end
    return paths
end

--- 拆节点之前先放开 KOReader 抓着的事件设备。
--- 触摸屏、电源键管道和这只 fd 在同一次 select 里。节点没了 fd 还在，
--- select 每次都被它唤醒，别的设备没有机会被读：点按没了，电源键进不了锁屏。
--- 时钟走 UIManager 定时器，不经过这只 fd，所以还在走。
--- 失败时把还在的节点重新打开。KOReader 没起来（测试）时设备模块不在，直接跳过。
---@param address string|nil
---@return string[]|nil 实际关掉的路径
local function releaseUhid(address)
    local Device = package.loaded["device"]
    local input = Device and Device.input
    if not input or type(input.opened_devices) ~= "table" then return nil end
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    -- 读失败返回 nil。拼进 gmatch 会抛错，这次关闭就发不出去。
    if type(content) ~= "string" then return nil end
    local closed = {}
    for _idx, path in ipairs(uhidPaths(content, address)) do
        if input.opened_devices[path] then
            local ok, err = pcall(input.close, input, path)
            -- close 不抛错也不代表 fd 已离开轮询表（C 层没认这笔 fd 时映射还在）。
            if ok and not input.opened_devices[path] then
                closed[#closed + 1] = path
            elseif not ok then
                require("utils.log").warn("book.bluetooth release uhid:", path, err)
            end
        end
    end
    if not closed[1] then return nil end
    -- 翻页器被收成单点 digitizer（BTN_TOUCH + ABS_X/Y），和触摸屏共用槽位。
    -- 拆节点不会补一次抬起，槽位停在按下，之后的点按都算进这次没结束的手势。
    if input.resetState then
        local ok, err = pcall(input.resetState, input)
        if not ok then require("utils.log").warn("book.bluetooth reset input:", err) end
    end
    return closed
end

---@param paths string[]|nil
local function reopenUhid(paths)
    local Device = package.loaded["device"]
    local input = Device and Device.input
    if not paths or not input or type(input.opened_devices) ~= "table" then return end
    local lfs = require("libs/libkoreader-lfs")
    for _idx, path in ipairs(paths) do
        if lfs.attributes(path, "mode") and not input.opened_devices[path] then
            local ok, err = pcall(input.open, input, path)
            if not ok then require("utils.log").warn("book.bluetooth reopen uhid:", path, err) end
        end
    end
end

---@param on boolean
---@param cb fun(ok: boolean, err: any)
function Khp.setEnabled(on, cb)
    Khp.status(function(st)
        if (st.state == "on") == on then return cb(true) end
        if st.state == "off" then
            spawn()
            return waitFor(function(s) return s.state ~= "off" end, WAIT_SECONDS, function(up)
                if not up then return cb(false, _("蓝牙服务没有启动，详见 /var/log/hid_passthrough.log")) end
                Khp.setEnabled(on, cb)
            end)
        end
        local released = not on and releaseUhid(nil) or nil
        get(on and "/start" or "/stop", function(_data, err)
            if err then
                reopenUhid(released)
                return cb(false, err)
            end
            waitFor(function(s) return (s.state == "on") == on end, WAIT_SECONDS, function(done)
                if not done then reopenUhid(released) end
                cb(done, not done and _("蓝牙状态没有变化，详见 /var/log/hid_passthrough.log") or nil)
            end)
        end)
    end)
end

---@param st BookBluetoothStatus
---@param address string
---@return boolean
local function connected(st, address)
    for _idx, conn in ipairs(st.connections) do
        if conn.address:upper() == address:upper() then return true end
    end
    return false
end

--- 连接 / 断开已配对设备，等到连接表变化为止。
---@param dev BookBluetoothDevice
---@param connect boolean
---@param cb fun(ok: boolean, err: any)
function Khp.setConnected(dev, connect, cb)
    local addr = Text.urlEncode(dev.address)
    local path = connect and ("/connect?addr=" .. addr .. "&protocol=" .. Text.urlEncode(dev.protocol or "ble"))
        or ("/disconnect?addr=" .. addr)
    local released = not connect and releaseUhid(dev.address) or nil
    get(path, function(_data, err)
        if err then
            reopenUhid(released)
            return cb(false, err)
        end
        waitFor(function(s) return connected(s, dev.address) == connect end, WAIT_SECONDS, function(done)
            if not done then reopenUhid(released) end
            cb(done, not done and (connect and _("连接超时，请确认设备已开机并在附近") or _("断开超时")) or nil)
        end)
    end)
end

--- 每 STEP_SECONDS 秒 GET 一次 path，step 返回 true 继续；最多 steps 次。
---@param path string
---@param steps integer
---@param step fun(data: table|nil, err: any, last: boolean): boolean|nil
---@return CancelHandle
local function poll(path, steps, step)
    local job, tick
    local left = steps
    tick = function()
        left = left - 1
        job = get(path, function(data, err)
            job = nil
            if step(data, err, left <= 0) and left > 0 then UIManager:scheduleIn(STEP_SECONDS, tick) end
        end)
    end
    UIManager:scheduleIn(STEP_SECONDS, tick)
    return {
        cancel = function()
            UIManager:unschedule(tick)
            if job then job:cancel() end
            job = nil
        end,
    }
end

--- 扫描附近的 HID 设备。扫描中 on_update(devices) 多次，结束 on_done(devices, err) 一次。
---@param on_update fun(devices: BookBluetoothDevice[])
---@param on_done fun(devices: BookBluetoothDevice[]|nil, err: any)
---@return CancelHandle
function Khp.scan(on_update, on_done)
    local handle = { inner = nil }
    local job = get("/scan", function(_data, err)
        if err then return on_done(nil, err) end
        handle.inner = poll("/scan-status", MAX_STEPS, function(data, poll_err, last)
            if not data then on_done(nil, poll_err) return false end
            if data.scanning and not last then on_update(plain(data.devices)) return true end
            on_done(plain(data.devices))
            return false
        end)
    end)
    function handle.cancel()
        job:cancel()
        if handle.inner then handle.inner.cancel() end
    end
    return handle
end

--- 配对；成功后守护进程把设备写进 devices.conf 并自动连接。
---@param dev BookBluetoothDevice
---@param cb fun(ok: boolean, err: any)
---@return CancelHandle
function Khp.pair(dev, cb)
    local handle = { inner = nil }
    local path = "/pair?addr=" .. Text.urlEncode(dev.address) .. "&protocol=" .. Text.urlEncode(dev.protocol or "ble")
    if dev.name then path = path .. "&name=" .. Text.urlEncode(dev.name) end
    local job = get(path, function(_data, err)
        if err then return cb(false, err) end
        handle.inner = poll("/pair-status", MAX_STEPS, function(data, poll_err, last)
            if data and data.pairing and not last then return true end
            if data and data.pairing then
                cb(false, _("配对超时"))
            else
                cb(data ~= nil, poll_err)
            end
            return false
        end)
    end)
    function handle.cancel()
        job:cancel()
        if handle.inner then handle.inner.cancel() end
    end
    return handle
end

return Khp
