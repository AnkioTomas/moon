--[[--
远程管理服务：生命周期 + 文件系统 IO + 截图分享入口。

模块级单例（FM / Reader 两个插件实例共享一份 server）；
KOReader UI 依赖全部函数内延迟加载（离线测试只碰 server.lua）。

范围 = KOReader 数据目录的上级目录；书籍根目录若在范围外则作为独立入口。
KOReader 根、字体、插件、设置、Book 数据及书籍根目录不可删除或移动。
下载和单次元数据查询直接落 lfs/os；目录扫描、递归删除、跨设备复制串行跑 worker。
上传先落临时文件再移入目标目录（重名加 " (n)"，跨设备退化为后台流式复制）。

@module koplugin.book.remote.init
--]]

local logger = require("utils.log")
local Settings = require("utils.settings")
local Text = require("utils.text")
local _ = require("gettext")

local Remote = {
    _server = nil, ---@type table|nil server 实例（也是 insertZMQ 的句柄）
    _resume = false, ---@type boolean suspend 前在跑，resume 时恢复
    _temp_seq = 0,
    --- Kindle 实际打孔的端口：stop 必须用它拆规则，不能读当前配置（运行中改端口会泄漏旧规则）
    _punched_port = nil, ---@type number|nil
    _layout = nil,
    _io_queue = {},
    _io_job = nil,
    _io_stopping = false,
    _clip = "", ---@type string 设备最后复制的文本镜像
    _clip_hooked = false,
}


--- 构造可访问根、快捷入口和保护路径。全部转成真实绝对路径，堵住软链接逃逸。
--- 注意字体/插件/本插件目录在部分环境是软链（模拟器指向源码树）：
--- roots/快捷入口必须落 realpath 后的路径，否则快捷入口永远被 containment 拒掉。
local function storageLayout()
    local DataStorage = require("datastorage")
    local ffiUtil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")
    local Paths = require("utils.paths")
    local data = assert(ffiUtil.realpath(DataStorage:getFullDataDir()), "KOReader data dir unavailable")
    local root = ffiUtil.dirname(data)
    local local_cfg = Settings.getSource("local")
    local book = ffiUtil.realpath(local_cfg.path or "")
        or ffiUtil.realpath(G_reader_settings:readSetting("home_dir") or "")
        or root
    --- realpath 取不到（路径尚不存在等）时退回原串，保证 roots 里没有 nil。
    ---@param p string
    ---@return string
    local function real(p)
        return ffiUtil.realpath(p) or p
    end
    local fonts = real(data .. "/fonts")
    local plugins = real(data .. "/plugins")
    local plugin_self = real(plugins .. "/book.koplugin")
    local screenshot_dir = real(G_reader_settings:readSetting("screenshot_dir") or (data .. "/screenshots"))
    Paths.ensureScreensaverDir()
    local wallpapers = Paths.screensaverDir()
    if lfs.attributes(wallpapers, "mode") ~= "directory" then
        lfs.mkdir(wallpapers)
    end
    wallpapers = real(wallpapers)
    local moon = real(Paths.root())
    local crash_log = real(data .. "/crash.log")
    local plugin_log = real(data .. "/.moon/book.log")
    -- 凭证路径必须和被校验的目标一样是真实路径，否则 .moon/settings 被软链后前缀比较失效。
    local settings_dir = real(data .. "/settings")
    local reader_settings = real(data .. "/settings.reader.lua")
    local moon_dir = real(data .. "/.moon")
    local roots = {}
    for _, r in ipairs({ root, book, fonts, plugins, plugin_self, screenshot_dir }) do
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
            { label = "截图文件夹", path = screenshot_dir },
            { label = "锁屏壁纸", path = wallpapers },
            { label = "月读数据目录", path = moon },
            {
                label = "KOReader 崩溃日志", path = crash_log, kind = "file", name = "crash.log",
                missing = "尚未生成 KOReader 崩溃日志。",
            },
            {
                label = "插件日志", path = plugin_log, kind = "file", name = "book.log",
                missing = "插件日志尚未生成。",
            },
        },
        protected = {
            root,
            data,
            fonts,
            plugins,
            plugin_self,
            settings_dir,
            reader_settings,
            moon_dir,
            book,
        },
        -- 凭证所在：protected 只挡删除/改名（判定的是「祖先」），下载读取要另挡
        -- 「这些路径之内」，否则 /download 能把 moon token、zlib 密码、AI key 拉走。
        secret = {
            settings_dir,
            reader_settings,
            moon_dir,
        },
        public_files = {
            [crash_log] = true,
            [plugin_log] = true,
        },
        public_dirs = { wallpapers },
    }
end

--- 取存储布局（首次调用时构造并缓存；start 会重新构造一次刷新配置变更）。
---@return table
local function layout()
    if not Remote._layout then
        Remote._layout = storageLayout()
    end
    return Remote._layout
end

--- 路径是否落在任一 managed root 之内。
---@param path string 真实绝对路径
---@return boolean
local function allowed(path)
    for _, root in ipairs(layout().roots) do
        if Text.pathContains(root, path) then
            return true
        end
    end
    return false
end

--- 已存在路径的范围校验：先 realpath（堵软链逃逸）再查 roots，越界返回 nil 并记警告。
---@param path string
---@return string|nil 真实绝对路径
local function existingPath(path)
    local real = require("ffi/util").realpath(path)
    if real and allowed(real) then
        return real
    end
    logger.warn("book remote reject:", path, "→", real)
end

--- 目标尚不存在时，以真实父目录校验范围。
---@param path string
---@return string|nil 真实父目录 + 原基名
local function newPath(path)
    local ffiUtil = require("ffi/util")
    local parent = ffiUtil.realpath(ffiUtil.dirname(path))
    if not parent or not allowed(parent) then
        logger.warn("book remote reject new:", path, "→", parent)
        return nil
    end
    return parent .. "/" .. ffiUtil.basename(path)
end

--- 变更操作的全量保护判定：realpath 后命中重要路径本身或其祖先即拒。
---@param path string
---@return boolean
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

--- 配置/凭证文件本身或其目录内：一律不许读出去。
---@param path string
---@return boolean
local function isSecret(path)
    if layout().public_files[path] then return false end
    for _, public_dir in ipairs(layout().public_dirs) do
        if Text.pathContains(public_dir, path) then
            return false
        end
    end
    for _, secret in ipairs(layout().secret) do
        if path == secret or Text.pathContains(secret, path) then
            return true
        end
    end
    return false
end

--- 展示级 protected 判定：与 isProtected 同逻辑但免 realpath——目录列表每个
--- entry 都调一次，realpath 是一趟 FFI syscall，大目录下成百上千次会卡 UI。
--- 安全不降级：删除/改名在 deleteRecursive/renameTo 内部仍走 isProtected 全量校验。
---@param path string
---@return boolean
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
    return Remote._server ~= nil
end

-- 文件系统重活串行跑子进程：避免阻塞 UI，也避免多个远程请求同时 fork 撑爆设备。
local function pumpIO()
    if Remote._io_job or Remote._io_stopping or #Remote._io_queue == 0 then return end
    local item = table.remove(Remote._io_queue, 1)
    Remote._io_job = true -- Job.run 失败时会同步回调；先放哨兵避免回调后被覆盖。

    local function finish(result, err)
        Remote._io_job = nil
        item.done(result, err)
        pumpIO()
    end

    local job = require("workers.job").run(item.worker, {
        name = item.name,
        timeout = 30 * 60,
        on_done = function(result) finish(result) end,
        on_failed = function(err)
            if item.cleanup then item.cleanup() end
            finish(nil, err)
        end,
        on_cancelled = function()
            if item.cleanup then item.cleanup() end
            finish(nil, "cancelled")
        end,
    })
    if Remote._io_job then Remote._io_job = job end
end

---@param name string
---@param operation fun(): any, any
---@param cb fun(value: any, err: any)
---@param cleanup fun()|nil
local function runFilesystem(name, operation, cb, cleanup)
    Remote._io_queue[#Remote._io_queue + 1] = {
        name = name,
        worker = function()
            local value, err = operation()
            if not value then
                return { ok = false, error = tostring(err or "operation failed") }
            end
            return { ok = true, value = value }
        end,
        done = function(result, worker_err)
            if not result then
                cb(nil, worker_err)
            elseif result.ok then
                cb(result.value)
            else
                cb(nil, result.error)
            end
        end,
        cleanup = cleanup,
    }
    pumpIO()
end

local function stopFilesystemJobs()
    Remote._io_stopping = true
    if type(Remote._io_job) == "table" then Remote._io_job:cancel() end
    Remote._io_job = nil
    for _, item in ipairs(Remote._io_queue) do
        if item.cleanup then item.cleanup() end
    end
    Remote._io_queue = {}
    Remote._io_stopping = false
end

-- ── handlers（server 的全部 IO 接缝）──────────────────

--- 目录列表：目录优先、按名称排序；非目录返回 nil, err。
---@param path string
---@return table[]|nil, any
local function listDir(path)
    local lfs = require("libs/libkoreader-lfs")
    local resolved = existingPath(path)
    if not resolved then
        return nil, "path outside managed roots"
    end
    path = resolved
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

---@param path string
---@param cb fun(entries: table[]|nil, err: any)
local function listDirAsync(path, cb)
    runFilesystem("remote-list", function()
        return listDir(path)
    end, cb)
end

--- 下载解析：存在、是普通文件、且不是配置/凭证。
---@param path string
---@return string|nil
local function resolveDownload(path)
    local resolved = existingPath(path)
    if not resolved then
        return nil
    end
    path = resolved
    if require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
        return nil
    end
    if isSecret(path) then
        logger.warn("book remote reject download of config file:", path)
        return nil
    end
    return path
end

--- 流式复制（os.rename 跨设备失败时的退路）；失败不留半截目标。
---@param src string
---@param dst string
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
    local failure
    while true do
        local chunk, read_err = input:read(64 * 1024)
        if not chunk then
            failure = read_err
            break
        end
        local written, write_err = output:write(chunk)
        if not written then
            failure = write_err or "write failed"
            break
        end
    end
    local input_ok, input_err = input:close()
    local output_ok, output_err = output:close()
    failure = failure or (not input_ok and (input_err or "read close failed"))
        or (not output_ok and (output_err or "write close failed"))
    if failure then
        os.remove(dst)
        return nil, failure
    end
    return true
end

--- 上传落位：重名策略由网页明确传入；os.rename 失败（跨设备）退化为复制。
---@param temp string
---@param dir string
---@param name string
---@param cb fun(ok: boolean|nil, err: any)
---@param conflict "overwrite"|"skip"|"rename"|nil
local function saveUpload(temp, dir, name, cb, conflict)
    local lfs = require("libs/libkoreader-lfs")
    local resolved = existingPath(dir)
    if not resolved then
        cb(nil, "path outside managed roots")
        return
    end
    dir = resolved
    local stem, ext = name:match("^(.*)(%.[^.]*)$")
    stem, ext = stem or name, ext or ""
    local target, n = dir .. "/" .. name, 2
    local existing = lfs.attributes(target)
    -- 询问阶段与实际落位之间可能有竞态；默认退化为保留两者，绝不静默覆盖。
    if conflict == "ask" and existing then
        conflict = "rename"
    end
    if conflict == "skip" and existing then
        pcall(os.remove, temp)
        cb(true)
        return
    end
    if conflict == "rename" then
        while lfs.attributes(target) do
            target = string.format("%s/%s (%d)%s", dir, stem, n, ext)
            n = n + 1
        end
    elseif existing and existing.mode ~= "file" then
        pcall(os.remove, temp)
        cb(nil, "target is not a file")
        return
    end
    -- 覆盖写与删除、改名同样会毁掉配置/凭证，必须和它们一起挡住。
    if isProtected(target) or isSecret(target) then
        pcall(os.remove, temp)
        cb(nil, "protected path")
        return
    end
    local ok, err = os.rename(temp, target)
    if ok then
        cb(true)
        return
    end
    Remote._temp_seq = Remote._temp_seq + 1
    local staging = string.format("%s.moon-upload-%d-%d.part", target, os.time(), Remote._temp_seq)
    runFilesystem("remote-upload-copy", function()
        return copyFile(temp, staging)
    end, function(copy_ok, copy_err)
        if copy_ok then
            copy_ok, copy_err = os.rename(staging, target)
        end
        pcall(os.remove, staging)
        pcall(os.remove, temp)
        if copy_ok then
            cb(true)
        else
            cb(nil, copy_err or err)
        end
    end, function()
        pcall(os.remove, temp)
        pcall(os.remove, staging)
    end)
end

---@param path string
---@return boolean
local function pathExists(path)
    local resolved = existingPath(path)
    return resolved ~= nil and require("libs/libkoreader-lfs").attributes(resolved) ~= nil
end

---@param path string
---@return boolean
local function isDir(path)
    local resolved = existingPath(path)
    return resolved ~= nil
        and require("libs/libkoreader-lfs").attributes(resolved, "mode") == "directory"
end

---@param path string
---@return boolean|nil, any
local function mkdirOne(path)
    local lfs = require("libs/libkoreader-lfs")
    local resolved = newPath(path)
    if not resolved then
        return nil, "path outside managed roots"
    end
    path = resolved
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
    local resolved = existingPath(path)
    if not resolved then
        return nil, "path outside managed roots"
    end
    if isSecret(resolved) then
        return nil, "protected path"
    end
    path = resolved
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
---@param cb fun(ok: boolean|nil, err: any)
local function deleteRecursiveAsync(path, cb)
    runFilesystem("remote-delete", function()
        return deleteRecursive(path)
    end, cb)
end

local MAX_ARCHIVE_ENTRIES = 10000
local MAX_EXTRACT_BYTES = 2 * 1024 * 1024 * 1024

---@param archive string
---@return string|nil output
---@return string|nil err
local function extractZip(archive)
    local lfs = require("libs/libkoreader-lfs")
    local resolved = existingPath(archive)
    if not resolved or lfs.attributes(resolved, "mode") ~= "file" then
        return nil, "not found"
    end
    archive = resolved
    if isSecret(archive) then
        return nil, "protected path"
    end
    local name = archive:match("([^/]+)$") or ""
    if not name:lower():match("%.zip$") then
        return nil, "not a zip archive"
    end
    local target = archive:sub(1, #archive - 4)
    if isProtected(target) then
        return nil, "protected path"
    end
    if lfs.attributes(target) then
        return nil, "target exists"
    end
    local staging = target .. ".moon-extract.part"
    if lfs.attributes(staging) then deleteRecursive(staging) end
    local made, make_err = lfs.mkdir(staging)
    if not made then return nil, make_err end

    local reader = require("ffi/archiver").Reader:new()
    local function fail(err)
        reader:close()
        deleteRecursive(staging)
        return nil, err
    end
    if not reader:open(archive) then
        return fail(reader.err or "cannot open archive")
    end

    local count, total = 0, 0
    for entry in reader:iterate() do
        count = count + 1
        if count > MAX_ARCHIVE_ENTRIES then
            return fail("too many archive entries")
        end
        local path = entry.path
        if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/"
            or path:find("\\", 1, true) or path:match("^%a:")
            or path == ".." or path:match("^%.%./") or path:match("/%.%./")
            or path:match("/%.%.$")
        then
            return fail("unsafe archive path")
        end
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            return fail("unsupported archive entry")
        end
        if entry.mode == "file" then
            total = total + math.max(0, tonumber(entry.size) or 0)
            if total > MAX_EXTRACT_BYTES then
                return fail("archive too large")
            end
        end
        if not reader:extractToPath(path, staging .. "/" .. path) then
            return fail(reader.err or "archive extraction failed")
        end
    end
    local iterate_err = reader.err
    reader:close()
    if iterate_err then
        deleteRecursive(staging)
        return nil, iterate_err
    end
    local moved, move_err = os.rename(staging, target)
    if not moved then
        deleteRecursive(staging)
        return nil, move_err
    end
    return target
end

---@param path string
---@param cb fun(ok: boolean|nil, err: any, output: string|nil)
local function extractZipAsync(path, cb)
    runFilesystem("remote-extract", function()
        return extractZip(path)
    end, function(output, err)
        cb(output ~= nil, err, output)
    end)
end

---@param path string
---@param to string
---@return boolean|nil, any
local function renameTo(path, to)
    local lfs = require("libs/libkoreader-lfs")
    if isProtected(path) or isProtected(to) then
        return nil, "protected path"
    end
    local src, dst = existingPath(path), newPath(to)
    if not src or not dst then
        return nil, "path outside managed roots"
    end
    path, to = src, dst
    -- isProtected 只挡凭证目录本身及其祖先，挡不住目录里的单个文件：
    -- 把 settings/moon.lua 改名搬出去，再 /download 就能拿到 token。
    if isSecret(path) or isSecret(to) then
        logger.warn("book remote reject rename of config file:", path, "→", to)
        return nil, "protected path"
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
-- 链接复制、输入框长按复制、翻译复制……），在这里包一层镜像到 Remote._clip，
-- GET /api/clipboard 读的就是它；setClipboard 写回并同步进激活输入框。
-- 直接读 Device.input.getClipboardText 会穿透到平台层（SDL/Android 系统
-- 剪贴板），拿不到内部复制历史，所以必须自己镜像。

--- 包一层 Device.input.setClipboardText，把设备侧每次复制镜像到 Remote._clip（只装一次）。
--- 无剪贴板能力的设备直接跳过。
local function hookClipboard()
    if Remote._clip_hooked then
        return
    end
    local Device = require("device")
    if not (Device:hasClipboard() and Device.input) then
        return
    end
    local orig = Device.input.setClipboardText
    Device.input.setClipboardText = function(text)
        Remote._clip = text or ""
        return orig(text)
    end
    Remote._clip_hooked = true
end

---@return { text: string }
local function getClipboard()
    return { text = Remote._clip }
end

--- 网页 → 设备：写设备剪贴板 + 同步进激活输入框（无激活框只写剪贴板）。
---@param text string
local function setClipboard(text)
    Remote._clip = text or ""
    local Device = require("device")
    if Device:hasClipboard() and Device.input then
        pcall(Device.input.setClipboardText, text)
    end
    local widget = activeInputWidget()
    if widget then
        widget:setText(text)
        require("ui/uimanager"):setDirty(widget, "ui")
    end
end

---@return table
local function getStatus()
    local Device = require("device")
    local status = {
        charging = false,
        reading = false,
    }
    if Device:hasBattery() and Device.powerd then
        status.battery = Device.powerd:getCapacity()
        status.charging = Device.powerd:isCharging() and true or false
    end
    local DataStorage = require("datastorage")
    local _, _, available = require("ffi/util").df(DataStorage:getDataDir())
    status.storage_available = available

    local session = require("ui.reader.session").current()
    if session then
        status.reading = true
        local identity = session.identity
        status.book = identity and identity.book and identity.book.title
        if not status.book and session.ui and session.ui.document then
            status.book = require("ffi/util").basename(session.ui.document.file)
        end
    end
    return status
end

--- 上传临时落盘路径：缓存目录下 upload-<时间>-<序号>.part，进程内自增保证不撞名。
---@return string
local function tempPath(_name)
    local Paths = require("utils.paths")
    Paths.ensureCacheRoot()
    Remote._temp_seq = Remote._temp_seq + 1
    return string.format(
        "%s/upload-%d-%d.part",
        Paths.cacheDir(),
        os.time(),
        Remote._temp_seq
    )
end

-- ── 启停 ─────────────────────────────────────────────

--- Kindle 防火墙打孔（照 httpinspector 语义：start 打、stop 堵）。
--- 端口必须用打孔时记下的 Remote._punched_port：运行中改了端口的话，读当前配置
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
        port = Remote._punched_port or port
    end
    Remote._punched_port = add and port or nil
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
    Remote._layout = storageLayout()
    local server = require("remote.server").new {
        host = "*",
        port = Remote.port(),
        root = Remote._layout.root,
        roots = Remote._layout.roots,
        home = Remote._layout.home,
        shortcuts = Remote._layout.shortcuts,
        handlers = {
            list_dir = listDirAsync,
            is_dir = isDir,
            resolve_download = resolveDownload,
            save = saveUpload,
            path_exists = pathExists,
            mkdir = function(path, cb)
                cb(mkdirOne(path))
            end,
            delete = deleteRecursiveAsync,
            rename = function(path, to, cb)
                cb(renameTo(path, to))
            end,
            extract = extractZipAsync,
            temp_path = tempPath,
            is_protected = isProtectedDisplay,
            get_input = getInput,
            set_input = setInput,
            get_clipboard = getClipboard,
            set_clipboard = setClipboard,
            get_status = getStatus,
        },
    }
    local started, serr = server:start()
    if not started then
        return false, serr
    end
    hookClipboard()
    kindleHole(true)
    Remote._server = server
    require("ui/uimanager"):insertZMQ(server)
    logger.info("book remote started on port", Remote.port())
    return true
end

--- 停服（幂等）：摘掉 UIManager 轮询、断连接、拆 Kindle 防火墙规则。
function Remote.stop()
    if not Remote.isRunning() then
        return
    end
    require("ui/uimanager"):removeZMQ(Remote._server)
    Remote._server:stop()
    Remote._server = nil
    stopFilesystemJobs()
    kindleHole(false)
    logger.info("book remote stopped")
end

-- ── 生命周期（main.lua 一行转发）───────────────────────

--- 插件 onCreate：挂截图分享入口；autostart 开启时自举（双实例调用幂等）。
function Remote.onCreate()
    -- ButtonDialog 依赖设备后端；离线加载插件时该后端不存在，不能拖垮远程主流程。
    local ok_share, err_share = pcall(function()
        require("remote.screenshot").onCreate()
    end)
    if not ok_share then
        logger.warn("book remote screenshot share onCreate failed:", err_share)
    end
    if Remote.autostartOn() then
        require("ui/uimanager"):nextTick(function()
            local ok, err = Remote.start()
            if not ok then
                logger.warn("book remote autostart failed:", err)
            end
        end)
    end
end

--- 休眠：记下当前是否在跑再停服（睡眠中留着监听既没用又费电）。
function Remote.onPause()
    Remote._resume = Remote.isRunning()
    Remote.stop()
end

--- 唤醒：休眠前在跑、或开了自启，就重新起服。
function Remote.onResume()
    if Remote._resume or Remote.autostartOn() then
        Remote._resume = false
        local ok, err = Remote.start()
        if not ok then
            logger.warn("book remote resume failed:", err)
        end
    end
end

--- 退出 KOReader：停服，避免残留监听与 iptables 规则。
function Remote.onDestroy()
    Remote.stop()
end

-- ── 设置页菜单行 ─────────────────────────────────────

--- 本机局域网 IP：UDP setpeername 只查路由表不发包，getsockname 拿到出口网卡地址。
--- 不能用 dns.toip(gethostname())：多数设备 /etc/hosts 把主机名映射到 127.0.0.1。
---@return string|nil
local function localIP()
    local s = require("socket").udp()
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

--- 启动服务并给受控文件生成局域网下载地址。
---@param path string
---@return string|nil url
---@return string|nil err
function Remote.shareUrl(path)
    -- 截图目录可在服务运行期间被用户修改；分享时以当前配置重建范围，
    -- 否则新目录会被旧 roots 快照误判为越界。
    Remote._layout = storageLayout()
    if Remote._server then
        Remote._server:updateLayout(Remote._layout)
    end
    local real = existingPath(path)
    if not real or require("libs/libkoreader-lfs").attributes(real, "mode") ~= "file" then
        return nil, "file unavailable"
    end
    local ok, err = Remote.start()
    if not ok then
        return nil, err
    end
    local ip = localIP()
    if not ip then
        return nil, "local IP unavailable"
    end
    return string.format("http://%s:%d/download?path=%s", ip, Remote.port(), Text.urlEncode(real))
end

--- 运行状态文案：运行中给可访问地址（IP 尽力而为），否则「未运行」。
---@return string status, boolean running
function Remote.status()
    if not Remote.isRunning() then
        return _("未运行"), false
    end
    return string.format("http://%s:%d/", localIP() or _("本机IP"), Remote.port()), true
end

return Remote
