--[[--
远程管理服务：生命周期 + 文件系统 IO + 设置页菜单行。

模块级单例（FM / Reader 两个插件实例共享一份 server）；
KOReader UI 依赖全部函数内延迟加载（离线测试只碰 server.lua）。

范围 = KOReader 数据目录的上级目录；书籍根目录若在范围外则作为独立入口。
KOReader 根、字体、插件、设置、Book 数据及书籍根目录不可删除或移动。
下载/列表/变更由 handlers 直接落 lfs/os，
上传先落临时文件再移入目标目录（重名加 " (n)"，跨设备退化为流式复制）。

@module koplugin.book.remote.init
--]]

local logger = require("logger")
local Settings = require("utils.settings")
local Text = require("utils.text")
local _ = require("gettext")

local Remote = {}

local _server = nil ---@type table|nil server 实例（也是 insertZMQ 的句柄）
local _resume = false ---@type boolean suspend 前在跑，resume 时恢复
local _temp_seq = 0
--- Kindle 实际打孔的端口：stop 必须用它拆规则，不能读当前配置（运行中改端口会泄漏旧规则）
local _punched_port = nil ---@type number|nil

--- 构造可访问根、快捷入口和保护路径。全部转成真实绝对路径，堵住软链接逃逸。
--- 注意字体/插件/本插件目录在部分环境是软链（模拟器指向源码树）：
--- roots/快捷入口必须落 realpath 后的路径，否则快捷入口永远被 containment 拒掉。
local function storageLayout()
    local DataStorage = require("datastorage")
    local ffiUtil = require("ffi/util")
    local data = assert(ffiUtil.realpath(DataStorage:getFullDataDir()), "KOReader data dir unavailable")
    local root = ffiUtil.dirname(data)
    local local_cfg = Settings.getSource("local")
    local book = ffiUtil.realpath(local_cfg.path or "")
        or ffiUtil.realpath(G_reader_settings:readSetting("home_dir") or "")
        or root
    local function real(p)
        return ffiUtil.realpath(p) or p
    end
    local fonts = real(data .. "/fonts")
    local plugins = real(data .. "/plugins")
    local plugin_self = real(plugins .. "/book.koplugin")
    local roots = {}
    for _, r in ipairs({ root, book, fonts, plugins, plugin_self }) do
        local dup = false
        for _, existing in ipairs(roots) do
            if Text.pathContains(existing, r) then
                dup = true
                break
            end
        end
        if not dup then
            roots[#roots + 1] = r
        end
    end
    return {
        root = root,
        roots = roots,
        home = book, -- 页面默认路径：书籍根目录
        shortcuts = {
            { label = "KOReader 字体", path = fonts },
            { label = "KOReader 插件", path = plugins },
            { label = "书籍根目录", path = book },
        },
        protected = {
            root,
            data,
            fonts,
            plugins,
            plugin_self,
            data .. "/settings",
            data .. "/settings.reader.lua",
            data .. "/.moon",
            book,
        },
    }
end

local _layout

local function layout()
    if not _layout then
        _layout = storageLayout()
    end
    return _layout
end

local function allowed(path)
    for _, root in ipairs(layout().roots) do
        if Text.pathContains(root, path) then
            return true
        end
    end
    return false
end

local function existingPath(path)
    local real = require("ffi/util").realpath(path)
    if real and allowed(real) then
        return real
    end
    logger.warn("book remote reject:", path, "→", real)
end

--- 目标尚不存在时，以真实父目录校验范围。
local function newPath(path)
    local ffiUtil = require("ffi/util")
    local parent = ffiUtil.realpath(ffiUtil.dirname(path))
    if not parent or not allowed(parent) then
        logger.warn("book remote reject new:", path, "→", parent)
        return nil
    end
    return parent .. "/" .. ffiUtil.basename(path)
end

local function isProtected(path)
    path = require("ffi/util").realpath(path) or path
    for _, protected in ipairs(layout().protected) do
        -- 删除/移动祖先同样会带走重要路径，必须一起挡住。
        if path == protected or Text.pathContains(path, protected) then
            return true
        end
    end
    return false
end

--- 展示级 protected 判定：与 isProtected 同逻辑但免 realpath——目录列表每个
--- entry 都调一次，realpath 是一趟 FFI syscall，大目录下成百上千次会卡 UI。
--- 安全不降级：删除/改名在 deleteRecursive/renameTo 内部仍走 isProtected 全量校验。
local function isProtectedDisplay(path)
    for _, protected in ipairs(layout().protected) do
        if path == protected or Text.pathContains(path, protected) then
            return true
        end
    end
    return false
end

---@return number
function Remote.port()
    return tonumber(Settings.get().remote_port) or 9528
end

---@return boolean
function Remote.autostartOn()
    return Settings.get().remote_autostart == true
end

---@param on boolean
function Remote.setAutostart(on)
    local c = Settings.get()
    c.remote_autostart = on and true or false
    Settings.save(c)
end

---@param port number
function Remote.setPort(port)
    local c = Settings.get()
    c.remote_port = port
    Settings.save(c)
end

---@return boolean
function Remote.isRunning()
    return _server ~= nil
end

-- ── handlers（server 的全部 IO 接缝）──────────────────

--- 目录列表：目录优先、按名称排序；非目录返回 nil, err。
---@param path string
---@return table[]|nil, any
local function listDir(path)
    local lfs = require("libs/libkoreader-lfs")
    path = existingPath(path)
    if not path then
        return nil, "path outside managed roots"
    end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "directory" then
        return nil, "not a directory"
    end
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok or not iter then
        return nil, "cannot open"
    end
    local entries = {}
    for name in iter, state do
        -- .sdr 是 KOReader 的边车目录（进度/书签/笔记），不是可管理文件，不显示
        if name ~= "." and name ~= ".." and name:sub(-4) ~= ".sdr" then
            local a = lfs.attributes(path .. "/" .. name)
            if a then
                entries[#entries + 1] = {
                    name = name,
                    dir = a.mode == "directory",
                    size = a.mode == "file" and a.size or nil,
                    mtime = a.modification,
                }
            end
        end
    end
    table.sort(entries, function(x, y)
        if x.dir ~= y.dir then
            return x.dir
        end
        return x.name < y.name
    end)
    return entries
end

--- 下载解析：存在且是普通文件。
---@param path string
---@return string|nil
local function resolveDownload(path)
    path = existingPath(path)
    if not path then
        return nil
    end
    if require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
        return nil
    end
    return path
end

--- 流式复制（os.rename 跨设备失败时的退路）；失败不留半截目标。
---@return boolean|nil, any
local function copyFile(src, dst)
    local input, err = io.open(src, "rb")
    if not input then
        return nil, err
    end
    local output
    output, err = io.open(dst, "wb")
    if not output then
        input:close()
        return nil, err
    end
    while true do
        local chunk = input:read(64 * 1024)
        if not chunk then
            break
        end
        if not output:write(chunk) then
            input:close()
            output:close()
            pcall(os.remove, dst)
            return nil, "write failed"
        end
    end
    input:close()
    output:close()
    return true
end

--- 上传落位：重名加 " (n)"；os.rename 失败（跨设备）退化为复制。
---@param temp string
---@param dir string
---@param name string
---@param cb fun(ok: boolean|nil, err: any)
local function saveUpload(temp, dir, name, cb)
    local lfs = require("libs/libkoreader-lfs")
    dir = existingPath(dir)
    if not dir then
        cb(nil, "path outside managed roots")
        return
    end
    local stem, ext = name:match("^(.*)(%.[^.]*)$")
    stem, ext = stem or name, ext or ""
    local target, n = dir .. "/" .. name, 2
    while lfs.attributes(target) do
        target = string.format("%s/%s (%d)%s", dir, stem, n, ext)
        n = n + 1
    end
    local ok, err = os.rename(temp, target)
    if not ok then
        ok, err = copyFile(temp, target)
    end
    pcall(os.remove, temp)
    cb(ok, err)
end

---@param path string
---@return boolean|nil, any
local function mkdirOne(path)
    local lfs = require("libs/libkoreader-lfs")
    path = newPath(path)
    if not path then
        return nil, "path outside managed roots"
    end
    if lfs.attributes(path) then
        return nil, "already exists"
    end
    return lfs.mkdir(path)
end

--- 递归删除（文件直接删；目录先清内容）。
---@param path string
---@return boolean|nil, any
local function deleteRecursive(path)
    local lfs = require("libs/libkoreader-lfs")
    if isProtected(path) then
        return nil, "protected path"
    end
    path = existingPath(path)
    if not path then
        return nil, "path outside managed roots"
    end
    local attr = lfs.attributes(path)
    if not attr then
        return nil, "not found"
    end
    if attr.mode == "directory" then
        local ok, iter, state = pcall(lfs.dir, path)
        if not ok or not iter then
            return nil, "cannot open"
        end
        for name in iter, state do
            if name ~= "." and name ~= ".." then
                local d_ok, d_err = deleteRecursive(path .. "/" .. name)
                if not d_ok then
                    return nil, d_err
                end
            end
        end
        return lfs.rmdir(path)
    end
    return os.remove(path)
end

---@param path string
---@param to string
---@return boolean|nil, any
local function renameTo(path, to)
    local lfs = require("libs/libkoreader-lfs")
    if isProtected(path) or isProtected(to) then
        return nil, "protected path"
    end
    path, to = existingPath(path), newPath(to)
    if not path or not to then
        return nil, "path outside managed roots"
    end
    if not lfs.attributes(path) then
        return nil, "not found"
    end
    if lfs.attributes(to) then
        return nil, "target exists"
    end
    return os.rename(path, to)
end

--- 当前激活的输入框：窗口栈自上而下找第一个鸭子判定命中的 InputDialog
--- （._input_widget 带可调用的 addChars）。两点注意：
--- 1) 不能只查栈顶——用户正在输入时栈顶是 VirtualKeyboard（独立 widget）；
--- 2) 调试模式下 KOReader dbg:guard 把方法包成 __call 表，type 检查会误杀，
---    必须用可调用判定而不是 type=="function"。
---@return table|nil InputText 实例
local function activeInputWidget()
    local UIManager = require("ui/uimanager")
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        local iw = w and w._input_widget
        if not w.invisible and type(iw) == "table" then
            local f = iw.addChars
            local mt = type(f) == "table" and getmetatable(f)
            if type(f) == "function" or (mt and mt.__call) then
                return iw
            end
        end
    end
    return nil
end

---@return { active: boolean, text: string|nil }
local function getInput()
    local widget = activeInputWidget()
    if not widget then
        return { active = false }
    end
    -- 共享剪贴板：带全文的把设备文本拉到网页端；getText 失败不拖垮状态查询
    local ok, text = pcall(function()
        return widget:getText() or ""
    end)
    return { active = true, text = ok and text or "" }
end

--- 远程输入：经 addChars 在光标处追加（正常键入路径，含撤销/重绘）。
---@param text string
---@return boolean|nil, any
local function setInput(text)
    local widget = activeInputWidget()
    if not widget then
        return nil, "no active input"
    end
    widget:addChars(text)
    require("ui/uimanager"):setDirty(widget, "ui")
    return true
end

-- ── 共享剪贴板 ────────────────────────────────────────
--
-- 设备侧一切「复制」都汇到 Device.input.setClipboardText（阅读划线复制、
-- 链接复制、输入框长按复制、翻译复制……），在这里包一层镜像到 _clip，
-- GET /api/clipboard 读的就是它；setClipboard 写回并同步进激活输入框。
-- 直接读 Device.input.getClipboardText 会穿透到平台层（SDL/Android 系统
-- 剪贴板），拿不到内部复制历史，所以必须自己镜像。

local _clip = "" ---@type string 设备最后复制的文本镜像
local _clip_hooked = false

local function hookClipboard()
    if _clip_hooked then
        return
    end
    local Device = require("device")
    if not (Device:hasClipboard() and Device.input) then
        return
    end
    local orig = Device.input.setClipboardText
    Device.input.setClipboardText = function(text)
        _clip = text or ""
        return orig(text)
    end
    _clip_hooked = true
end

---@return { text: string }
local function getClipboard()
    return { text = _clip }
end

--- 网页 → 设备：写设备剪贴板 + 同步进激活输入框（无激活框只写剪贴板）。
---@param text string
local function setClipboard(text)
    _clip = text or ""
    local ok, Device = pcall(require, "device")
    if ok and Device:hasClipboard() and Device.input then
        pcall(Device.input.setClipboardText, text)
    end
    local widget = activeInputWidget()
    if widget then
        widget:setText(text)
        require("ui/uimanager"):setDirty(widget, "ui")
    end
end

local function tempPath(_name)
    local Paths = require("utils.paths")
    Paths.ensureCacheRoot()
    _temp_seq = _temp_seq + 1
    return string.format(
        "%s/upload-%d-%d.part",
        Paths.cacheDir(),
        os.time(),
        _temp_seq
    )
end

-- ── 启停 ─────────────────────────────────────────────

--- Kindle 防火墙打孔（照 httpinspector 语义：start 打、stop 堵）。
--- 端口必须用打孔时记下的 _punched_port：运行中改了端口的话，读当前配置
--- 会拆错规则，把旧端口的 ACCEPT 永久留在 iptables 里。
---@param add boolean
local function kindleHole(add)
    local Device = require("device")
    if not Device:isKindle() then
        return
    end
    local verb = add and "-A" or "-D"
    local port = Remote.port()
    if not add then
        port = _punched_port or port
    end
    _punched_port = add and port or nil
    os.execute(string.format(
        "iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        verb, port))
    os.execute(string.format(
        "iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        verb, port))
end

--- 启动服务（幂等）。
---@return boolean ok, string|nil err
function Remote.start()
    if Remote.isRunning() then
        return true
    end
    _layout = storageLayout()
    local server = require("remote.server").new {
        host = "*",
        port = Remote.port(),
        root = _layout.root,
        roots = _layout.roots,
        home = _layout.home,
        shortcuts = _layout.shortcuts,
        handlers = {
            list_dir = listDir,
            resolve_download = resolveDownload,
            save = saveUpload,
            mkdir = mkdirOne,
            delete = deleteRecursive,
            rename = renameTo,
            temp_path = tempPath,
            is_protected = isProtectedDisplay,
            get_input = getInput,
            set_input = setInput,
            get_clipboard = getClipboard,
            set_clipboard = setClipboard,
        },
    }
    local started, serr = server:start()
    if not started then
        return false, serr
    end
    hookClipboard()
    kindleHole(true)
    _server = server
    require("ui/uimanager"):insertZMQ(server)
    logger.info("book remote started on port", Remote.port())
    return true
end

function Remote.stop()
    if not Remote.isRunning() then
        return
    end
    require("ui/uimanager"):removeZMQ(_server)
    _server:stop()
    _server = nil
    kindleHole(false)
    logger.info("book remote stopped")
end

-- ── 生命周期（main.lua 一行转发）───────────────────────

--- 插件 init：autostart 开启时自举（双实例调用幂等）。
function Remote.bootstrap()
    if Remote.autostartOn() then
        require("ui/uimanager"):nextTick(function()
            local ok, err = Remote.start()
            if not ok then
                logger.warn("book remote autostart failed:", err)
            end
        end)
    end
end

function Remote.onSuspend()
    _resume = Remote.isRunning()
    Remote.stop()
end

function Remote.onResume()
    if _resume or Remote.autostartOn() then
        _resume = false
        local ok, err = Remote.start()
        if not ok then
            logger.warn("book remote resume failed:", err)
        end
    end
end

function Remote.onExit()
    Remote.stop()
end

-- ── 设置页菜单行 ─────────────────────────────────────

--- 本机局域网 IP：UDP setpeername 只查路由表不发包，getsockname 拿到出口网卡地址。
--- 不能用 dns.toip(gethostname())：多数设备 /etc/hosts 把主机名映射到 127.0.0.1。
---@return string|nil
local function localIP()
    local ok, socket = pcall(require, "socket")
    if not ok or not socket.udp then
        return nil
    end
    local s = socket.udp()
    if not s then
        return nil
    end
    local ip
    -- 203.0.113.1 是 RFC 5737 文档保留段，必然走默认路由（同 NetworkMgr:hasDefaultRoute）
    if s:setpeername("203.0.113.1", "53") then
        ip = s:getsockname()
    end
    s:close()
    return ip
end

--- 状态行文案：运行中给可访问地址（IP 尽力而为），否则「未运行」。
---@return string status, boolean running
local function statusLabel()
    if not Remote.isRunning() then
        return _("未运行"), false
    end
    return string.format("http://%s:%d", localIP() or _("本机IP"), Remote.port()), true
end

--- 运行状态文案：运行中给可访问地址，否则「未运行」。
---@return string status, boolean running
function Remote.status()
    return statusLabel()
end

--- 设置页「文件管理」子页行构建数组（供 ui/desktop/settings.lua）。
---@param desktop table
---@return function[]
function Remote.menuRows(desktop)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local SettingRow = require("ui.components.settingrow")
    local T = require("ffi/util").template

    local function rebuild()
        if not desktop._closed then
            desktop:rebuild()
        end
    end

    local rows = {}

    rows[#rows + 1] = function(iw)
        local status, running = statusLabel()
        return SettingRow.build(iw, {
            kind = "toggle",
            icon = "folder",
            title = _("远程管理服务"),
            status = status,
            status_on = running,
            callback = function()
                if Remote.isRunning() then
                    Remote.stop()
                    rebuild()
                    return
                end
                local ok, err = Remote.start()
                if not ok then
                    UIManager:show(InfoMessage:new {
                        text = T(_("启动失败：%1"), tostring(err)),
                        timeout = 3,
                    })
                    rebuild()
                    return
                end
                UIManager:show(InfoMessage:new {
                    text = T(_("服务已启动：%1"), statusLabel()),
                    timeout = 4,
                })
                rebuild()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        return SettingRow.build(iw, {
            kind = "nav",
            icon = "dns",
            title = _("端口"),
            status = tostring(Remote.port()),
            status_on = true,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new {
                    title = _("端口"),
                    input = tostring(Remote.port()),
                    input_type = "number",
                    buttons = { {
                        {
                            text = _("取消"),
                            id = "close",
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("保存"),
                            is_enter_default = true,
                            callback = function()
                                local port = tonumber(dialog:getInputValue())
                                if port and port >= 1 and port <= 65535 then
                                    Remote.setPort(math.floor(port))
                                    if Remote.isRunning() then
                                        Remote.stop()
                                        Remote.start()
                                    end
                                    rebuild()
                                end
                                UIManager:close(dialog)
                            end,
                        },
                    } },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        })
    end

    rows[#rows + 1] = function(iw)
        local on = Remote.autostartOn()
        return SettingRow.build(iw, {
            kind = "toggle",
            icon = "power",
            title = _("开机自启"),
            status = on and _("开") or _("关"),
            status_on = on,
            callback = function()
                Remote.setAutostart(not on)
                rebuild()
            end,
        })
    end

    return rows
end

return Remote
