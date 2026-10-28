--[[--
远程管理服务：生命周期 + 文件系统 IO + 截图分享入口。

模块级单例（FM / Reader 两个插件实例共享一份 server）；
KOReader UI 依赖全部函数内延迟加载（离线测试只碰 server.lua）。

范围 = KOReader 数据目录的上级目录；书籍根目录若在范围外则作为独立入口。
KOReader 根、字体、插件、设置、Book 数据及书籍根目录不可删除或移动。
下载和单次元数据查询直接落 lfs/os；目录扫描、递归删除、跨设备复制串行跑 worker。
上传先落临时文件再移入目标目录（重名加 " (n)"，跨设备退化为后台流式复制）。

受管根全部 realpath，堵软链逃逸。Kindle 防火墙打孔端口记 _punched_port，stop 必须用它拆规则（改端口先拆旧孔）。
suspend 停服、resume 按标记恢复；停服时释放静态资源缓存。

@module koplugin.book.features.remote.init
--]]

local logger = require("utils.log")
local Settings = require("utils.settings")
local Text = require("utils.text")
local Guard = require("ui.guard")
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
--- roots/快捷入口落 realpath，避免快捷入口和真实目录各显示一份。
local function storageLayout()
    local DataStorage = require("datastorage")
    local ffiUtil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")
    local Paths = require("utils.paths")
    local data = assert(ffiUtil.realpath(DataStorage:getFullDataDir()), "KOReader data dir unavailable")
    local root = ffiUtil.dirname(data)
    ---@cast root string
    local local_cfg = Settings.getSource("local")
    local home_dir = G_reader_settings:readSetting("home_dir")
    local book = ffiUtil.realpath(local_cfg.path or "")
        or ffiUtil.realpath(type(home_dir) == "string" and home_dir or "")
        or root
    --- realpath 取不到（路径尚不存在等）时退回原串，保证 roots 里没有 nil。
    ---@param p string
    ---@return string
    local function real(p)
        local path = ffiUtil.realpath(p)
        if type(path) ~= "string" or path == "" then return p end
        return path
    end
    local fonts = real(data .. "/fonts")
    local plugins = real(data .. "/plugins")
    local plugin_self = real(plugins .. "/book.koplugin")
    local shot = G_reader_settings:readSetting("screenshot_dir")
    local screenshot_dir = real(type(shot) == "string" and shot or (data .. "/screenshots"))
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
    for _idx, r in ipairs({ root, book, fonts, plugins, plugin_self, screenshot_dir }) do
        local dup = false
        for _idx, existing in ipairs(roots) do
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
        -- 配置所在：protected 只挡重要路径本身及其祖先，目录内的单个配置文件
        -- 还要另挡删除/改名/解压，否则误操作会弄坏登录态和设置。
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

--- 已存在路径解析成真实路径。不存在返回 nil。软链解析到目标，用来读内容。
---@param path string
---@return string|nil 真实绝对路径
local function existingPath(path)
    return require("ffi/util").realpath(path)
end

--- 新建、删除、改名用真实父目录 + 原基名。软链接本身才是被操作对象，不能解析成它指向的文件。
---@param path string
---@return string|nil 真实父目录 + 原基名
---@return string|nil err
local function newPath(path)
    local ffiUtil = require("ffi/util")
    path = path:gsub("/+$", "")
    local name = ffiUtil.basename(path)
    if name == "" or name == "." or name == ".." then
        logger.warn("book remote reject name:", path)
        return nil, "bad path"
    end
    local parent = ffiUtil.realpath(ffiUtil.dirname(path))
    if not parent then
        logger.warn("book remote reject new:", path)
        return nil, "not found"
    end
    return parent .. "/" .. ffiUtil.basename(path)
end


--- 配置/凭证文件本身或其目录内：一律不许读出去。
---@param path string
---@return boolean
local function isSecret(path)
    if layout().public_files[path] then return false end
    for _idx, public_dir in ipairs(layout().public_dirs) do
        if Text.pathContains(public_dir, path) then
            return false
        end
    end
    for _idx, secret in ipairs(layout().secret) do
        if path == secret or Text.pathContains(secret, path) then
            return true
        end
    end
    return false
end

--- 展示级 protected 判定：命中重要路径本身或其祖先（删除/移动祖先同样会带走重要路径）。
--- 免 realpath：目录列表每个 entry 都调一次，realpath 是一趟 FFI syscall，大目录下会卡 UI。
---@param path string
---@return boolean
local function isProtectedDisplay(path)
    for _idx, protected in ipairs(layout().protected) do
        if path == protected or Text.pathContains(path, protected) then
            return true
        end
    end
    return false
end

--- 变更操作的全量保护判定：先 realpath（堵软链绕过），删除/改名一律走这里。
---@param path string
---@return boolean
local function isProtected(path)
    return isProtectedDisplay(require("ffi/util").realpath(path) or path)
end

---@return number
function Remote.port()
    return tonumber(Settings.get("features.remote").remote_port)
end

---@return boolean
function Remote.autostartOn()
    return Settings.get("features.remote").remote_autostart
end

---@param on boolean
function Remote.setAutostart(on)
    local c = Settings.get("features.remote")
    c.remote_autostart = on and true or false
    Settings.save("features.remote", c)
end

---@return boolean
function Remote.deleteAfterShareOn()
    return Settings.get("features.remote").remote_delete_after_share
end

---@param on boolean
function Remote.setDeleteAfterShare(on)
    local c = Settings.get("features.remote")
    c.remote_delete_after_share = on and true or false
    Settings.save("features.remote", c)
end

--- 空闲自动关闭的时长（秒）：无任何网页/客户端连接持续这么久就停服。
Remote.IDLE_STOP = 5 * 60

---@return boolean
function Remote.idleStopOn()
    return Settings.get("features.remote").remote_idle_stop
end

---@param on boolean
function Remote.setIdleStop(on)
    local c = Settings.get("features.remote")
    c.remote_idle_stop = on and true or false
    Settings.save("features.remote", c)
    if Remote._server then
        Remote._server:setIdleTimeout(on and Remote.IDLE_STOP or nil)
    end
end

---@param port number
function Remote.setPort(port)
    local c = Settings.get("features.remote")
    c.remote_port = port
    Settings.save("features.remote", c)
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
        kind = "light",
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
    for _idx, item in ipairs(Remote._io_queue) do
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
        return nil, "not found"
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

--- 下载解析：存在且是普通文件。
---@param path string
---@return string|nil
local function resolveDownload(path)
    local resolved = existingPath(path)
    if not resolved or require("libs/libkoreader-lfs").attributes(resolved, "mode") ~= "file" then
        return nil
    end
    return resolved
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
        cb(nil, "not found")
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
        os.remove(temp)
        cb(true)
        return
    end
    if conflict == "rename" then
        while lfs.attributes(target) do
            target = string.format("%s/%s (%d)%s", dir, stem, n, ext)
            n = n + 1
        end
    elseif existing and existing.mode ~= "file" then
        os.remove(temp)
        cb(nil, "target is not a file")
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
        os.remove(staging)
        os.remove(temp)
        if copy_ok then
            cb(true)
        else
            cb(nil, copy_err or err)
        end
    end, function()
        os.remove(temp)
        os.remove(staging)
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
    local resolved, reason = newPath(path)
    if not resolved then
        return nil, reason
    end
    path = resolved
    if lfs.attributes(path) then
        return nil, "already exists"
    end
    return lfs.mkdir(path)
end

--- 递归删除，不跟随软链接：链接只删链接本身。
---@param path string 已校验范围的条目路径
---@return boolean|nil, any
local function purge(path)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.symlinkattributes(path)
    if not attr then
        return nil, "not found"
    end
    if attr.mode ~= "directory" then
        return os.remove(path)
    end
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok or not iter then
        return nil, "cannot open"
    end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local d_ok, d_err = purge(path .. "/" .. name)
            if not d_ok then
                return nil, d_err
            end
        end
    end
    return lfs.rmdir(path)
end

---@param path string
---@return boolean|nil, any
local function deleteRecursive(path)
    if isProtected(path) then
        return nil, "protected path"
    end
    local entry, reason = newPath(path)
    if not entry then
        return nil, reason
    end
    if isSecret(entry) then
        return nil, "protected path"
    end
    return purge(entry)
end

--- 删除后按 KOReader 文件管理器的规则清 KOReader 记的状态（文件：.sdr、阅读历史、收藏；
--- 目录：其下书籍的历史、收藏与不在书旁的 .sdr）。文件列表隐藏了 .sdr，这里不清就成了删不掉的孤儿。
--- 类型要在删之前取：删完就分不出是文件还是目录。阅读历史只在主进程，不能放进子进程。
---@param path string
---@param cb fun(ok: boolean|nil, err: any)
local function deleteRecursiveAsync(path, cb)
    local entry = newPath(path)
    local mode = entry and require("libs/libkoreader-lfs").symlinkattributes(entry, "mode")
    runFilesystem("remote-delete", function()
        return deleteRecursive(path)
    end, function(ok, err)
        if ok and mode == "file" then
            require("book.sidecar").remove(entry)
        elseif ok and mode == "directory" then
            require("readhistory"):folderDeleted(entry)
            require("readcollection"):removeItemsByPath(entry)
        end
        cb(ok, err)
    end)
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
    purge(staging)
    local made, make_err = lfs.mkdir(staging)
    if not made then return nil, make_err end

    local reader = require("ffi/archiver").Reader:new()
    local function fail(err)
        reader:close()
        purge(staging)
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
        purge(staging)
        return nil, iterate_err
    end
    local moved, move_err = os.rename(staging, target)
    if not moved then
        purge(staging)
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
    local src, src_err = newPath(path)
    local dst, dst_err = newPath(to)
    if not src or not dst then
        return nil, src_err or dst_err
    end
    path, to = src, dst
    -- isProtected 只挡配置目录本身及其祖先，挡不住目录里的单个文件。
    if isSecret(path) or isSecret(to) then
        logger.warn("book remote reject rename of config file:", path, "→", to)
        return nil, "protected path"
    end
    if not lfs.symlinkattributes(path) then
        return nil, "not found"
    end
    if lfs.symlinkattributes(to) then
        return nil, "target exists"
    end
    return os.rename(path, to)
end

--- 当前激活的输入框：窗口栈自上而下找第一个带输入框的窗口。
--- 主题 Input 面板（.inputs 数组 + .focus_idx 焦点字段）和原生 InputDialog（._input_widget）两种都认。
--- 不能只查栈顶——用户正在输入时栈顶是 VirtualKeyboard（独立 widget）。
--- 调试模式下 KOReader dbg:guard 把方法包成 __call 表，type 检查会误杀，
--- 必须用可调用判定而不是 type=="function"。
---@return table|nil InputText 实例
local function activeInputWidget()
    local UIManager = require("ui/uimanager")
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w and not w.invisible then
            local iw = type(w.inputs) == "table" and w.inputs[w.focus_idx or 1] or w._input_widget
            if type(iw) == "table" then
                local f = iw.addChars
                local mt = type(f) == "table" and getmetatable(f)
                if type(f) == "function" or (mt and mt.__call) then
                    return iw
                end
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
    return { active = true, text = widget:getText() }
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
    if not Device:hasClipboard() then
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
    Remote._clip = text
    local Device = require("device")
    if Device:hasClipboard() then
        Device.input.setClipboardText(text)
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
    -- 旧版 KOReader 的 df 只返回 total, free，没有第三个 available
    local _total, free, available = require("ffi/util").df(DataStorage:getDataDir())
    status.storage_available = available or free

    local session = require("reader.session").current()
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

--- 本插件根目录，与 PluginLoader 给的 plugin.path 同一字符串（同 source/registry）。
local PLUGIN_ROOT = debug.getinfo(1, "S").source:match("^@(.*)/features/remote/init%.lua$")

--- 装上传的插件包；装好在设备上提示并稍后重启：留一秒让「成功」响应发回浏览器，
--- 不能久等（旧模块还在内存里，延迟加载会混进新版文件）。重启走 Update.restart，开着书也先落盘。
---@param temp string
---@param cb fun(ok: boolean, err: string|nil)
local function installUpdate(temp, cb)
    local Update = require("features.update")
    Update.installArchive(temp, PLUGIN_ROOT, function(ok, err)
        cb(ok, err)
        if not ok then return end
        require("ui.themes.widgets.toast"):new{
            text = _("月读已通过远程管理更新，正在重启 KOReader…"),
        }:show()
        require("ui/uimanager"):scheduleIn(1, Update.restart)
    end)
end

--- 上传临时落盘路径：缓存目录下 upload-<时间>-<序号>.part，进程内自增保证不撞名。
---@return string
local function tempPath()
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

-- ── 复制 / 移动 / 属性 / 文本写入 / 打包（远程文件管理扩展）──────────

local MAX_TREE_ENTRIES = 20000
local MAX_TEXT_BYTES = 4 * 1024 * 1024

--- 同目录下不撞名的新路径：name (2).ext、name (3).ext …（目录不拆扩展名）。
---@param path string
---@param is_dir boolean
---@return string
local function uniquePath(path, is_dir)
    local lfs = require("libs/libkoreader-lfs")
    local dir, name = path:match("^(.*)/([^/]+)$")
    local stem, ext = name, ""
    if not is_dir then
        local s, e = name:match("^(.+)(%.[^.]+)$")
        if s then stem, ext = s, e end
    end
    local n, target = 2, path
    while lfs.symlinkattributes(target) do
        target = string.format("%s/%s (%d)%s", dir, stem, n, ext)
        n = n + 1
    end
    return target
end

--- 递归复制：不跟随软链接（链接跳过，免得把范围外的内容拷进来）；凭证文件跳过。
---@param src string
---@param dst string
---@param budget table { left: number }
---@return boolean|nil, any
local function copyTree(src, dst, budget)
    local lfs = require("libs/libkoreader-lfs")
    budget.left = budget.left - 1
    if budget.left < 0 then
        return nil, "too many entries"
    end
    local attr = lfs.symlinkattributes(src)
    if not attr then
        return nil, "not found"
    end
    if attr.mode == "link" or isSecret(src) then
        return true
    end
    if attr.mode == "file" then
        return copyFile(src, dst)
    end
    if attr.mode ~= "directory" then
        return true
    end
    local made, err = lfs.mkdir(dst)
    if not made then
        return nil, err
    end
    local ok, iter, state = pcall(lfs.dir, src)
    if not ok or not iter then
        return nil, "cannot open"
    end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local c_ok, c_err = copyTree(src .. "/" .. name, dst .. "/" .. name, budget)
            if not c_ok then
                return nil, c_err
            end
        end
    end
    return true
end

--- 复制 / 移动一个条目到 to（完整目标路径）。
--- conflict：ask（默认，目标存在报 target exists）/ skip / rename（保留两份）/ overwrite（替换）。
--- 移动先 os.rename，跨设备失败再复制后删源。
---@param op "copy"|"move"
---@param path string
---@param to string
---@param conflict string|nil
---@return string|nil output 实际目标路径
---@return any err
local function transfer(op, path, to, conflict)
    local lfs = require("libs/libkoreader-lfs")
    if (op == "move" and isProtected(path)) or isProtected(to) then
        return nil, "protected path"
    end
    local src, src_err = newPath(path)
    local dst, dst_err = newPath(to)
    if not src or not dst then
        return nil, src_err or dst_err
    end
    if isSecret(src) or isSecret(dst) then
        return nil, "protected path"
    end
    local attr = lfs.symlinkattributes(src)
    if not attr then
        return nil, "not found"
    end
    if dst == src or Text.pathContains(src, dst) then
        return nil, "target inside source"
    end
    if lfs.symlinkattributes(dst) then
        if conflict == "skip" then
            return dst
        elseif conflict == "rename" then
            dst = uniquePath(dst, attr.mode == "directory")
        elseif conflict == "overwrite" then
            if isProtected(dst) then
                return nil, "protected path"
            end
            local purged, p_err = purge(dst)
            if not purged then
                return nil, p_err
            end
        else
            return nil, "target exists"
        end
    end
    if op == "move" and os.rename(src, dst) then
        return dst
    end
    local copied, c_err = copyTree(src, dst, { left = MAX_TREE_ENTRIES })
    if not copied then
        purge(dst)
        return nil, c_err
    end
    if op == "move" then
        local purged, p_err = purge(src)
        if not purged then
            return nil, p_err
        end
    end
    return dst
end

---@param op "copy"|"move"
---@param path string
---@param to string
---@param conflict string|nil
---@param cb fun(ok: boolean|nil, err: any, output: string|nil)
local function transferAsync(op, path, to, conflict, cb)
    runFilesystem("remote-" .. op, function()
        return transfer(op, path, to, conflict)
    end, function(output, err)
        cb(output ~= nil, err, output)
    end)
end

--- 条目属性：类型、大小、时间、权限、属主、链接目标；目录另统计文件数 / 文件夹数 / 总大小。
---@param path string
---@return table|nil, any
local function statPath(path)
    local lfs = require("libs/libkoreader-lfs")
    local entry, reason = newPath(path)
    if not entry then
        return nil, reason
    end
    local attr = lfs.symlinkattributes(entry)
    if not attr then
        return nil, "not found"
    end
    local info = {
        path = entry,
        name = entry:match("([^/]+)$") or entry,
        type = attr.mode,
        size = attr.size,
        mtime = attr.modification,
        atime = attr.access,
        ctime = attr.change,
        permissions = attr.permissions,
        uid = attr.uid,
        gid = attr.gid,
        blocks = attr.blocks,
        protected = isProtectedDisplay(entry),
    }
    if attr.mode == "link" then
        info.target = attr.target or require("ffi/util").realpath(entry)
    end
    if attr.mode == "directory" then
        local files, dirs, bytes, blocks, left = 0, 0, 0, 0, MAX_TREE_ENTRIES
        local function walk(dir)
            local ok, iter, state = pcall(lfs.dir, dir)
            if not ok or not iter then return end
            for name in iter, state do
                if name ~= "." and name ~= ".." then
                    left = left - 1
                    if left < 0 then
                        info.truncated = true
                        return
                    end
                    local child = dir .. "/" .. name
                    local a = lfs.symlinkattributes(child)
                    if a and a.mode == "directory" then
                        dirs = dirs + 1
                        walk(child)
                    elseif a then
                        files = files + 1
                        bytes = bytes + (a.mode == "file" and (a.size or 0) or 0)
                        blocks = blocks + (a.blocks or 0)
                    end
                    if info.truncated then return end
                end
            end
        end
        walk(entry)
        info.files, info.dirs, info.size, info.blocks = files, dirs, bytes, blocks + (attr.blocks or 0)
    end
    return info
end

---@param path string
---@param cb fun(info: table|nil, err: any)
local function statAsync(path, cb)
    runFilesystem("remote-stat", function()
        return statPath(path)
    end, cb)
end

--- 写文本文件（文本编辑器保存 / 新建文件）：先写同目录临时文件再 rename，断电不留半截。
---@param path string
---@param text string
---@param create boolean 为 true 时目标已存在即失败
---@return boolean|nil, any
local function writeText(path, text, create)
    local lfs = require("libs/libkoreader-lfs")
    if #text > MAX_TEXT_BYTES then
        return nil, "file too large"
    end
    if isProtected(path) then
        return nil, "protected path"
    end
    local target, reason = newPath(path)
    if not target then
        return nil, reason
    end
    if isSecret(target) then
        return nil, "protected path"
    end
    local attr = lfs.attributes(target)
    if attr and create then
        return nil, "already exists"
    end
    if attr and attr.mode ~= "file" then
        return nil, "target is not a file"
    end
    local staging = target .. ".moon-write.part"
    local file, err = io.open(staging, "wb")
    if not file then
        return nil, err
    end
    local ok, w_err = file:write(text)
    local closed, c_err = file:close()
    if not ok or not closed then
        os.remove(staging)
        return nil, w_err or c_err or "write failed"
    end
    local moved, m_err = os.rename(staging, target)
    if not moved then
        os.remove(staging)
        return nil, m_err
    end
    return true
end

--- 打包下载：把若干条目（目录递归）写成不压缩的 ZIP 临时文件。不跟随软链接，凭证文件跳过。
---@param paths string[]
---@return string|nil output 临时 zip 路径
---@return any err
local function zipPaths(paths)
    local lfs = require("libs/libkoreader-lfs")
    local entries = {}
    local left, total = MAX_ARCHIVE_ENTRIES, 0
    local function collect(real, name)
        local attr = lfs.symlinkattributes(real)
        if not attr or attr.mode == "link" or isSecret(real) then
            return true
        end
        left = left - 1
        if left < 0 then
            return nil, "too many archive entries"
        end
        if attr.mode == "file" then
            total = total + (attr.size or 0)
            if total > MAX_EXTRACT_BYTES then
                return nil, "archive too large"
            end
            entries[#entries + 1] = { name, real }
            return true
        end
        if attr.mode ~= "directory" then
            return true
        end
        entries[#entries + 1] = { name, real }
        local ok, iter, state = pcall(lfs.dir, real)
        if not ok or not iter then
            return nil, "cannot open"
        end
        for child in iter, state do
            if child ~= "." and child ~= ".." then
                local c_ok, c_err = collect(real .. "/" .. child, name .. "/" .. child)
                if not c_ok then
                    return nil, c_err
                end
            end
        end
        return true
    end
    for _idx, path in ipairs(paths) do
        local real, reason = newPath(path)
        if not real then
            return nil, reason
        end
        if not lfs.symlinkattributes(real) then
            return nil, "not found"
        end
        local ok, err = collect(real, real:match("([^/]+)$"))
        if not ok then
            return nil, err
        end
    end
    local output = tempPath() .. ".zip"
    local writer = require("ffi/archiver").Writer:new()
    if not writer:open(output, "zip") then
        return nil, writer.err or "cannot create archive"
    end
    writer:setZipCompression("store")
    for _idx, item in ipairs(entries) do
        if not writer:addPath(item[1], item[2], false) and writer.err then
            local err = writer.err
            writer:close()
            os.remove(output)
            return nil, err or "archive write failed"
        end
    end
    writer:close()
    return output
end

--- 一键日志包：插件日志（含轮转件）+ KOReader crash.log 等，内容脱敏，附 info.txt
--- 与 diag/* 诊断快照（插件列表、脱敏设置、源登录态、书库规模、采样 sdr）。
--- 只按文件名白名单收日志；源凭证文件只记登录态，不进包。
--- 跑在 fork 子进程里：诊断快照（碰库、建源实例）由主进程先算好传进来。
---@param diag { name: string, text: string }[] Logs.gatherExtras 的结果
---@param diag_notes string[]
---@return string|nil output 临时 zip 路径
---@return any err
local function buildLogsZip(diag, diag_notes)
    local Logs = require("features.remote.logs")
    local DataStorage = require("datastorage")
    local Paths = require("utils.paths")
    local lfs = require("libs/libkoreader-lfs")
    local Device = require("device")
    local notes = {}
    local function is(name)
        local f = Device[name]
        local ok, v = pcall(function() return f and f(Device) end)
        if not ok then notes[#notes + 1] = "Device." .. name .. " failed: " .. tostring(v) end
        return ok and v
    end
    local KO = { "^crash.*%.log$", "^crash%.log%.old$", "^crash%.log%.%d+$", "^reader%.log$", "^koreader.*%.log$" }
    local data = DataStorage:getFullDataDir()
    local install = lfs.currentdir() or "."
    local spec = {
        { dir = Paths.root(), prefix = "moon/", patterns = { "^book%.log" } },
        { dir = data, prefix = "koreader-data/", patterns = KO },
        { dir = install, prefix = "koreader-install/", patterns = KO },
        { dir = "/tmp", prefix = "tmp/", patterns = { "^koreader.*%.log$", "^crash.*%.log$" } },
    }
    if install ~= data and DataStorage.getDataDir and DataStorage:getDataDir() ~= data then
        spec[#spec + 1] = { dir = DataStorage:getDataDir(), prefix = "koreader-datadir/", patterns = KO }
    end
    if is("isKobo") then
        spec[#spec + 1] = { dir = "/mnt/onboard/.kobo", prefix = "kobo/", patterns = { "%.log$" } }
        spec[#spec + 1] = { dir = "/mnt/onboard/.adds/koreader", prefix = "kobo-koreader/", patterns = KO }
    elseif is("isKindle") then
        spec[#spec + 1] = { dir = "/mnt/us/koreader", prefix = "kindle-koreader/", patterns = KO }
    elseif is("isPocketBook") then
        spec[#spec + 1] = { dir = "/mnt/ext1/applications/koreader", prefix = "pocketbook-koreader/", patterns = KO }
        spec[#spec + 1] = { dir = "/mnt/ext1/system/logs", prefix = "pocketbook/", patterns = { "%.log$" } }
    end
    local files, missing = Logs.collect(lfs, spec)
    for _idx, dir in ipairs(missing) do notes[#notes + 1] = "skipped (not found): " .. dir end

    local extras = {}
    for _idx, e in ipairs(diag) do extras[#extras + 1] = e end
    for _idx, n in ipairs(diag_notes) do notes[#notes + 1] = n end
    if is("isAndroid") then
        -- 应用只能读到自己进程的 logcat；取不到就记 skipped
        local ok_l, text = pcall(function()
            local h = io.popen("logcat -d -t 5000 2>/dev/null")
            if not h then return "" end
            local t = h:read("*a") or ""
            h:close()
            return t
        end)
        extras[#extras + 1] = { name = "android-logcat.txt", text = ok_l and text or ("error: " .. tostring(text)) }
    end

    local ok_v, Version = pcall(require, "version")
    local info = {
        plugin_version = require("bookversion"),
        koreader_version = ok_v and Version:getCurrentRevision() or ("? (" .. tostring(Version) .. ")"),
        device = tostring(Device.model or "?"),
        language = require("gettext").current_lang or G_reader_settings:readSetting("language") or "C",
    }
    return Logs.build(tempPath() .. ".zip", files, info, require("ffi/archiver").Writer, extras, notes)
end

--- 打包 .moon（不含日志与缓存）。先把 WAL 并回主库、日志刷盘，子进程只做文件打包。
---@param cb fun(output: string|nil, err: any)
local function backupZip(cb)
    require("utils.db").exec("PRAGMA wal_checkpoint(TRUNCATE);")
    require("utils.log").flush()
    local output = tempPath() .. ".zip"
    runFilesystem("remote-backup", function()
        return require("features.remote.backup").build(
            output, require("utils.paths").root(), require("ffi/archiver").Writer, require("libs/libkoreader-lfs"))
    end, cb)
end

--- 用上传的备份包替换 .moon：先关库（子进程换文件时不许有连接握着旧库），换完重载配置，
--- 提示后重启，让各模块按新数据重新加载（留一秒把响应发回浏览器）。
---@param temp string
---@param cb fun(ok: boolean, err: string|nil)
local function restoreBackup(temp, cb)
    local DB = require("utils.db")
    DB.close()
    runFilesystem("remote-restore", function()
        return require("features.remote.backup").restore(
            temp, require("utils.paths").root(), require("ffi/archiver").Reader, require("libs/libkoreader-lfs"))
    end, function(names, err)
        os.remove(temp)
        if not names then return cb(false, err) end
        DB.close() -- 恢复期间若被重新打开，握的是被换掉的旧文件
        require("utils.settings").reload()
        cb(true)
        require("ui.themes.widgets.toast"):new{
            text = _("备份已通过远程管理恢复，正在重启 KOReader…"),
        }:show()
        require("ui/uimanager"):scheduleIn(1, require("features.update").restart)
    end)
end

--- 清除全部配置（.moon/settings 与 crash.log）：与恢复备份同一收尾——重载配置、提示、重启。
---@param cb fun(ok: boolean, err: string|nil)
local function resetConfig(cb)
    local crash = require("datastorage"):getFullDataDir() .. "/crash.log"
    runFilesystem("remote-reset", function()
        return require("features.remote.backup").clearConfig(
            require("libs/libkoreader-lfs"), require("utils.paths").settingsDir(), { crash, crash .. ".old" })
    end, function(done, err)
        if not done then return cb(false, err) end
        require("utils.settings").reload()
        cb(true)
        require("ui.themes.widgets.toast"):new{
            text = _("配置已通过远程管理清除，正在重启 KOReader…"),
        }:show()
        require("ui/uimanager"):scheduleIn(1, require("features.update").restart)
    end)
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

local RESCAN_DELAY = 3

--- 文件有变：停手 3 秒后让桌面重扫本地书籍（批量上传只扫一次）。
local function libraryChanged()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(Remote._rescan)
    UIManager:scheduleIn(RESCAN_DELAY, Remote._rescan)
end

function Remote._rescan()
    local UIManager = require("ui/uimanager")
    for _idx, entry in ipairs(UIManager._window_stack) do
        if entry.widget.name == "book_desktop" then require("desktop.sync").rescan(entry.widget) end
    end
end

--- 变更类 handler 成功后通知书架重扫。
---@param handler function
---@param at integer cb 是第几个参数
---@return function
local function watched(handler, at)
    return function(...)
        local args, n = { ... }, math.max(select("#", ...), at)
        local cb = args[at]
        args[at] = function(ok, ...)
            if ok then libraryChanged() end
            return cb(ok, ...)
        end
        return handler(unpack(args, 1, n))
    end
end

--- 启动服务（幂等）。
---@return boolean ok, string|nil err
function Remote.start()
    if Remote.isRunning() then
        return true
    end
    Remote._layout = storageLayout()
    local server = require("features.remote.server").new {
        host = "*",
        port = Remote.port(),
        root = Remote._layout.root,
        roots = Remote._layout.roots,
        home = Remote._layout.home,
        shortcuts = Remote._layout.shortcuts,
        idle_timeout = Remote.idleStopOn() and Remote.IDLE_STOP or nil,
        on_idle = Remote.stop,
        handlers = {
            list_dir = listDirAsync,
            is_dir = isDir,
            resolve_download = resolveDownload,
            downloaded = function(real)
                if Remote._once[real] then
                    Remote._once[real] = nil
                    deleteRecursiveAsync(real, function(ok, err)
                        logger.info("book remote delete shared file", real, ok, err)
                    end)
                end
            end,
            save = watched(saveUpload, 4),
            path_exists = pathExists,
            mkdir = function(path, cb)
                cb(mkdirOne(path))
            end,
            delete = watched(deleteRecursiveAsync, 2),
            rename = watched(function(path, to, cb)
                cb(renameTo(path, to))
            end, 3),
            extract = watched(extractZipAsync, 2),
            transfer = watched(transferAsync, 5),
            stat = statAsync,
            write_text = function(path, text, create, cb)
                runFilesystem("remote-write", function()
                    return writeText(path, text, create)
                end, cb)
            end,
            zip = function(paths, cb)
                runFilesystem("remote-zip", function()
                    return zipPaths(paths)
                end, cb)
            end,
            logs_zip = function(cb)
                -- 先把缓冲里的插件日志刷盘，打包才完整
                pcall(require("utils.log").flush)
                -- 诊断快照要查 sqlite、建源实例：子进程禁止碰库，主进程先算
                local diag, diag_notes = require("features.remote.logs").gatherExtras()
                runFilesystem("remote-logs", function() return buildLogsZip(diag, diag_notes) end, cb)
            end,
            temp_path = tempPath,
            is_protected = isProtectedDisplay,
            get_input = getInput,
            set_input = setInput,
            get_clipboard = getClipboard,
            set_clipboard = setClipboard,
            get_status = getStatus,
            install_update = installUpdate,
            backup_zip = backupZip,
            restore_backup = restoreBackup,
            reset_config = resetConfig,
        },
    }
    local started, serr = server:start()
    if not started then
        return false, serr
    end
    hookClipboard()
    kindleHole(true)
    Remote._server = server
    -- UIManager:processZMQs 不 pcall，这里抛错会带崩 KOReader。
    -- 出错即停服：每轮都抛的 bug 否则每 50ms 刷一次日志，用户重开远程管理即可。
    local wait = server.waitEvent
    local function step(self)
        wait(self)
        return true
    end
    function server:waitEvent()
        if not Guard.call("remote server", step, self) then
            Guard.call("remote stop", Remote.stop)
        end
    end
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

-- ── 生命周期（features 钩子）───────────────────────────

--- 插件 onCreate：挂截图分享入口；autostart 开启时自举（双实例调用幂等）。
function Remote.onCreate()
    require("features.remote.screenshot").onCreate()
    if Remote.autostartOn() then
        require("features.passcode").afterUnlock("remote", function()
            require("ui/uimanager"):nextTick(Guard.wrap("remote autostart", function()
                local ok, err = Remote.start()
                if not ok then
                    logger.warn("book remote autostart failed:", err)
                end
            end))
        end)
    end
end

--- 休眠：记下当前是否在跑再停服（睡眠中留着监听既没用又费电）。
--- 锁着没解开时服务没起，但上次唤醒欠下的恢复还在，不能被 false 覆盖。
function Remote.onSuspend()
    Remote._resume = Remote._resume or Remote.isRunning()
    Remote.stop()
end

--- 唤醒：休眠前在跑、或开了自启，就在解锁后重新起服（锁屏密码锁着时局域网不能绕过它看文件）。
function Remote.onResume()
    if not (Remote._resume or Remote.autostartOn()) then return end
    require("features.passcode").afterUnlock("remote", function()
        Remote._resume = false
        local ok, err = Remote.start()
        if not ok then
            logger.warn("book remote resume failed:", err)
        end
    end)
end

--- 退出 KOReader：停服，避免残留监听与 iptables 规则。
function Remote.onExit()
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

--- 分享链接下载完整后要删掉的文件（开关「分享后自动删除」开启时登记）。
Remote._once = {}

--- 启动服务并给受控文件生成局域网下载地址。
---@param path string
---@return string|nil url
---@return string|nil err
function Remote.shareUrl(path)
    -- 截图目录和保护路径可在服务运行期间被改；分享时重建布局，快捷入口和保护名单跟着走。
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
    if Remote.deleteAfterShareOn() then
        Remote._once[real] = true
    end
    return string.format("http://%s:%d/download?path=%s", ip, Remote.port(), Text.urlEncode(real))
end

--- 浏览器访问地址；拿不到局域网 IP 时没有可扫、可输的地址。
---@return string|nil
local function accessUrl()
    local ip = localIP()
    if not ip then return nil end
    return string.format("http://%s:%d/", ip, Remote.port())
end

--- 运行状态文案：运行中给可访问地址（IP 尽力而为），否则「未运行」。
---@return string status, boolean running
function Remote.status()
    if not Remote.isRunning() then
        return _("未运行"), false
    end
    return accessUrl() or string.format("http://%s:%d/", _("本机IP"), Remote.port()), true
end

--- 打开远程管理时弹访问二维码：内容就是地址，底部（caption）再明文写一遍，
--- 扫不了码时照着输。拿不到局域网 IP 就不弹扫了也打不开的码，退回文字提示。
--- 只供用户主动打开时调用（面板 / 设置页启动成功后）；自启、唤醒续跑不弹窗。
---@return boolean 是否弹出了二维码
function Remote.showAccess()
    local url = accessUrl()
    if not url then
        require("ui.themes.widgets.toast"):new{
            text = require("ffi/util").template(_("服务已启动：%1"), Remote.status()), timeout = 4,
        }:show()
        return false
    end
    require("ui.themes.widgets.qr"):new{ title = _("远程管理"), text = url, caption = url }:show()
    return true
end

return Remote
