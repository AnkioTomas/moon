--[[--
插件在线更新：查询 GitHub Release、直连与公益镜像竞速下载、校验包并完整替换插件目录。

自动检查只提示可用版本，不会自动下载或安装。

包体唯一信任根是 Release 接口给的资产 digest，镜像只搬运字节，校验不过回落直连。
先解压到同级暂存目录，换位失败回滚，不留半替换的 book.koplugin/。版本文件必须叫 bookversion.lua（version.lua 与 KOReader 冲突）。

@module koplugin.book.features.update
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Text = require("utils.text")
local Job = require("workers.job")
local Install = require("features.update.install")
local _ = require("gettext")
local T = require("ffi/util").template

local Update = {
    _offered_version = nil,
    ---@type table|nil 在途请求 / 探测 / 下载 / 安装子进程，非 nil 即忙
    _job = nil,
}

local API_URL = "https://api.ankio.net/gh/repos/AnkioTomas/moon/releases/latest"
local CHECK_INTERVAL = 24 * 60 * 60
local GITHUB = "https://github.com"
local ASSET_PREFIX = "^https://github%.com/AnkioTomas/moon/releases/download/"
local MAX_ARCHIVE_BYTES = 100 * 1024 * 1024

--- 镜像不可信：包体只靠 Release 接口（api.ankio.net 转发的 GitHub API）给的 sha256 把关，校验值绝不走镜像。
local MIRRORS = require("http.mirror").RELEASE_PROXIES
local PROBE_MIRRORS = 5
local PROBE_TIMEOUT_RATIO = 1 / 3 -- × 「网络超时」，缺省 10 秒

--- candidate 是 parseRelease 验过的 x.y.z；installed 解析不出（开发版）一律视为更旧。
local function newer(candidate, installed)
    local left = { candidate:match("^(%d+)%.(%d+)%.(%d+)") }
    local right = { installed:match("^(%d+)%.(%d+)%.(%d+)") }
    if #right == 0 then return true end
    for i = 1, 3 do
        local l, r = tonumber(left[i]), tonumber(right[i])
        if l ~= r then return l > r end
    end
    return false
end

--- 把 GitHub Release body 收成可读纯文本：优先「更新内容」段，丢掉安装说明与对比链接。
---@return string|nil
local function formatNotes(body)
    if type(body) ~= "string" then return nil end
    body = Text.normalizeNewlines(Text.trim(body))
    if body == "" then return nil end
    local section = body:match("###%s*更新内容%s*\n+(.*)$") or body
    section = section:gsub("\n###%s*完整对比[%s%S]*$", "")
    section = section:gsub(":[%w_+-]+:%s*", "")
    section = section:gsub("`([^`\n]*)`", "%1")
    local out, blank = {}, false
    for line in (section .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("^#+%s*", "")
        line = line:gsub("%*%*([^*]+)%*%*", "%1")
        line = Text.rtrim(line)
        if line == "" then
            if not blank and #out > 0 then
                out[#out + 1] = ""
                blank = true
            end
        else
            out[#out + 1] = line
            blank = false
        end
    end
    local notes = Text.trim(table.concat(out, "\n"))
    return notes ~= "" and notes or nil
end

--- 包体只认 Release 接口给的资产 digest（sha256）；下载地址必须在本仓库 Release 下，镜像才能按路径映射。
local function parseRelease(body)
    -- body 来自网络，不是 JSON 就当无效响应。
    local ok, release = pcall(JSON.decode, body)
    if not ok or type(release) ~= "table" or release.draft or release.prerelease then
        return nil, "invalid release response"
    end
    local tag = release.tag_name
    local version = type(tag) == "string" and tag:match("^v?(%d+%.%d+%.%d+[%w%.%+%-]*)$")
    if not version then return nil, "invalid release version" end
    local zip_name = "book.koplugin-" .. tag .. ".zip"
    local zip
    for _idx, asset in ipairs(release.assets or {}) do
        local url = asset.browser_download_url
        if asset.name == zip_name and type(url) == "string" and url:match(ASSET_PREFIX) then zip = asset end
    end
    if not zip then return nil, "release has no plugin archive" end
    local digest = (zip.digest or ""):match("^sha256:(" .. ("%x"):rep(64) .. ")$")
    if not digest then return nil, "release has no plugin checksum" end
    return {
        version = version,
        url = zip.browser_download_url,
        size = tonumber(zip.size),
        sha256 = digest:lower(),
        notes = formatNotes(release.body),
        available = newer(version, require("bookversion")),
    }
end

--- 查询最新稳定版本。
---@param cb fun(release: table|nil, err: any)
function Update.check(cb)
    if Update._job then return cb(nil, "busy") end
    Update._job = Request.get(API_URL, {
        timeout = require("http.timeout").net(1),
        headers = {
            Accept = "application/vnd.github+json",
            ["X-GitHub-Api-Version"] = "2022-11-28",
        },
    }, function(body, err)
        Update._job = nil
        if err then return cb(nil, err) end
        local release, parse_err = parseRelease(body)
        if not release then return cb(nil, parse_err) end
        local settings = MoonSettings.get("features.update")
        settings.update_last_checked_at = os.time()
        MoonSettings.save("features.update", settings)
        cb(release)
    end)
end

--- 并发探测直连与随机几个镜像：最先回 200 且长度对得上的胜出，全部失败回落直连。
--- 选中结果一律 nextTick 回调，不在 turbo 回调栈里取消自己那条流。
---@param release table
---@param cb fun(url: string)
---@return table handle { cancel }
local function pickDownloadUrl(release, cb)
    local path = release.url:sub(#GITHUB + 1)
    local Mirror = require("http.mirror")
    local pool = {}
    for _idx, prefix in ipairs(MIRRORS) do
        if not Mirror.isDead(prefix) then pool[#pool + 1] = prefix end
    end
    local prefixes = { GITHUB }
    for i = 1, math.min(PROBE_MIRRORS, #pool) do
        local j = math.random(i, #pool)
        pool[i], pool[j] = pool[j], pool[i]
        prefixes[#prefixes + 1] = pool[i]
    end
    local jobs, pending, settled = {}, #prefixes, false
    local bad, flagged = {}, {}
    local function flag(i)
        if i > 1 and not settled and not flagged[i] then
            flagged[i] = true
            bad[#bad + 1] = prefixes[i]
        end
    end
    local function cancelAll()
        settled = true
        for _idx, job in ipairs(jobs) do job:cancel() end
    end
    local function settle(url)
        if settled then return end
        cancelAll()
        -- 有源胜出说明网络通：同场已确定失败的镜像（不含直连）落盘拉黑
        if url ~= release.url then Mirror.markDead(bad) end
        logger.dbg("book.update download from", url)
        cb(url)
    end
    for i, prefix in ipairs(prefixes) do
        local url = prefix .. path
        jobs[i] = Request.stream({ url = url, timeout = require("http.timeout").net(PROBE_TIMEOUT_RATIO), allow_redirects = true }, {
            on_headers = function(code, headers)
                local function reject() flag(i) end
                if code ~= 200 then return reject() end
                local length = tonumber((headers:get("Content-Length", true)))
                if length and release.size and length ~= release.size then return reject() end
                -- 死镜像常回 200 + 自家首页且不带长度，只凭长度拦不住。
                local mime = headers:get("Content-Type", true)
                if mime and mime:lower():find("text/html", 1, true) then return reject() end
                UIManager:nextTick(require("ui.guard").wrap("update settle", function() settle(url) end))
            end,
            on_done = function(err)
                if err then flag(i) end
                pending = pending - 1
                if pending == 0 then UIManager:nextTick(require("ui.guard").wrap("update settle", function() settle(release.url) end)) end
            end,
        })
    end
    return { cancel = cancelAll }
end

--- 从 url 下载并在子进程里装包；镜像下载失败或校验不过时回落直连重来一次。
---@param done fun(ok: boolean, err: any) 已负责清 _job
---@param on_installing fun()|nil 下载完、开始换目录：此后不能再取消
local function installFrom(url, release, plugin_root, done, on_progress, on_installing)
    local function fail(err)
        if url == release.url then return done(false, err) end
        logger.warn("book.update mirror failed", url, err)
        installFrom(release.url, release, plugin_root, done, on_progress, on_installing)
    end
    Paths.ensureDir(Paths.root())
    local archive = Paths.root() .. "/plugin-update.zip"
    os.remove(archive)
    Update._job = Request.download({
        url = url,
        timeout = require("http.timeout").net(10),
        allow_redirects = true,
        max_bytes = MAX_ARCHIVE_BYTES,
        on_progress = on_progress,
    }, archive, function(ok, err)
        if not ok then return fail(err) end
        if on_installing then on_installing() end
        Update._job = Job.run(function()
            local installed, install_err = Install.run(archive, plugin_root, release.sha256)
            if not installed then error(install_err, 0) end
        end, {
            name = "plugin.update",
            kind = "heavy",
            timeout = 120,
            on_done = function()
                os.remove(archive)
                done(true)
            end,
            on_failed = function(install_err)
                os.remove(archive)
                if tostring(install_err):find("update checksum mismatch", 1, true) then
                    fail(install_err)
                else
                    done(false, install_err)
                end
            end,
        })
    end)
end

--- 下载、校验并安装已查询到的版本。
---@param release table Update.check 返回值
---@param plugin_root string 当前插件目录
---@param cb fun(ok: boolean, err: any)
---@param on_progress fun(bytes: number)|nil
---@param on_installing fun()|nil 下载完、开始换目录：此后不能再取消
function Update.install(release, plugin_root, cb, on_progress, on_installing)
    if Update._job then return cb(false, "busy") end
    local function done(ok, err)
        Update._job = nil
        cb(ok, err)
    end
    Update._job = pickDownloadUrl(release, function(url)
        installFrom(url, release, plugin_root, done, on_progress, on_installing)
    end)
end

--- 安装本地已有的更新包（远程管理上传）。无论成败都删包；装好后由调用方重启。
---@param archive string ZIP 路径，所有权移交本函数
---@param plugin_root string 当前插件目录
---@param cb fun(ok: boolean, err: string|nil) err 只取首行，不带子进程堆栈
function Update.installArchive(archive, plugin_root, cb)
    if Update._job then
        os.remove(archive)
        return cb(false, "busy")
    end
    local settled = false
    local function settle()
        settled = true
        Update._job = nil
        os.remove(archive)
    end
    local job = Job.run(function()
        local installed, install_err = Install.run(archive, plugin_root)
        if not installed then error(install_err, 0) end
    end, {
        name = "plugin.update",
        kind = "heavy",
        timeout = require("http.timeout").net(4),
        on_done = function()
            settle()
            cb(true)
        end,
        on_failed = function(err)
            settle()
            cb(false, tostring(err):match("[^\n]*"))
        end,
        on_cancelled = settle,
    })
    -- fork 失败时 Job.run 同步回调，不能再把已结束的 job 挂回去占着「忙」。
    if not settled then Update._job = job end
end

--- 取消在途的检查 / 下载，不回调。换目录的子进程只有退出时才会被杀。
function Update.cancel()
    if Update._job then Update._job:cancel() end
    Update._job = nil
end

Update.onExit = Update.cancel

--- 装好后重启 KOReader：走 KOReader 自己的重启动作（广播 Restart → DeviceListener → exitOrRestart），
--- 阅读器 / 文件管理器先 onClose（sidecar、阅读会话、各 onExit 落盘）再退出；禁止直接 restartKOReader。
function Update.restart()
    UIManager:broadcastEvent(require("ui/event"):new("Restart"))
end

--- 已知错误码 → 用户文案；子进程错误带堆栈，只取首行。
---@param err any
---@return string
local function errorText(err)
    local text = tostring(err)
    local known = {
        { "^busy$", _("正在检查或安装更新，请稍候") },
        { "^invalid release", _("更新信息无效，请稍后再试") },
        { "^release has no", _("新版本缺少插件包，请稍后再试") },
        { "update checksum mismatch", _("更新包校验失败，请稍后再试") },
        { "download too large", _("更新包过大，已中止下载") },
    }
    for _idx, entry in ipairs(known) do
        if text:find(entry[1]) then return entry[2] end
    end
    return text:match("[^\n]*")
end

--- 下载可取消；进入换目录后换成不可关闭的安装窗。装好立即重启：
--- 新文件已就位，旧模块还在内存里，再跑插件代码就会延迟加载到新版文件、新旧混跑。
local function startInstall(release, plugin_root)
    local ProgressDialog = require("ui.themes.widgets.progress_dialog")
    local size = release.size
    local dialog = ProgressDialog:new{
        title = _("正在下载月读更新…"),
        dismissable = false,
        on_cancel = Update.cancel,
    }
    dialog:show()
    Update.install(release, plugin_root, function(ok, err)
        if ok then
            dialog:set(_("更新完成，正在重启 KOReader…"), 100)
            UIManager:nextTick(Update.restart)
            return
        end
        dialog:close()
        require("ui.themes.widgets.toast"):new{
            text = T(_("月读更新失败：%1"), errorText(err)),
            timeout = 5,
        }:show()
    end, function(bytes)
        if size and size > 0 then dialog:bytes(bytes, size) end
    end, function()
        dialog:close()
        dialog = ProgressDialog:new{ title = _("正在安装月读更新…"), dismissable = false }
        dialog:show()
    end)
end

local function promptInstall(release, plugin_root)
    if Update._offered_version == release.version then return end
    Update._offered_version = release.version
    local header = T(_("发现月读 %1（当前 %2）。下载并完整替换插件目录？"),
        release.version, require("bookversion"))
    local text = release.notes and (header .. "\n\n" .. release.notes) or header
    local dialog
    dialog = require("ui.themes.widgets.text_viewer"):new{
        title = _("更新日志"),
        text = text,
        buttons = {
            { text = _("稍后"), callback = function() dialog:close() end },
            {
                text = _("下载并安装"),
                variant = "primary",
                callback = function()
                    dialog:close()
                    startInstall(release, plugin_root)
                end,
            },
        },
    }
    dialog:show()
end

--- 用户主动检查；始终显示结果。
---@param plugin_root string
function Update.manualCheck(plugin_root)
    local Toast = require("ui.themes.widgets.toast")
    local loading = require("ui.themes.widgets.progress_dialog"):new{
        title = _("检查更新"), text = _("正在检查月读更新…"), dismissable = false,
    }
    loading:show()
    Update.check(function(release, err)
        loading:close()
        if err then
            Toast:new{
                text = T(_("检查更新失败：%1"), errorText(err)),
                timeout = 4,
            }:show()
        elseif release then
            if release.available then
                Update._offered_version = nil
                promptInstall(release, plugin_root)
            else
                Toast:new{
                    text = T(_("已是最新版本（%1）"), require("bookversion")),
                    timeout = 3,
                }:show()
            end
        end
    end)
end

--- 按 24 小时间隔静默检查；只有发现新版本才弹窗。没连网不发请求，等下次唤醒。
---@param plugin_root string
function Update.autoCheck(plugin_root)
    local settings = MoonSettings.get("features.update")
    if not settings.auto_update_check then return end
    if os.time() - settings.update_last_checked_at < CHECK_INTERVAL then return end
    if not require("ui/network/manager"):isConnected() then return end
    Update.check(function(release)
        if not release then return end
        if release.available then promptInstall(release, plugin_root) end
    end)
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
-- 插件更新检查走桌面回到前台，不在插件 init / 网络回调里抢跑。
require("utils.extension").add("desktop.activated", function(desk)
    local root = desk.plugin and desk.plugin.path
    if root then Update.autoCheck(root) end
end)

return Update
