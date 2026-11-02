--[[--
kamare 增强版在线更新：查询 GitHub Release、直连与公益镜像竞速下载、校验包并替换插件目录。

包体唯一信任根是 Release 接口给的资产 digest（sha256）；镜像只搬运字节，校验不过回落直连。
安装复用 utils.plugin_install：解压后顶层恰好一个 .koplugin 目录，装到插件目录（kamare 已装则就地替换）。
装好立即重启 KOReader：旧模块还在内存里，不能继续加载新版文件。

@module source.kavita.kamare_update
--]]

local UIManager = require("ui/uimanager")
local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local Text = require("utils.text")
local Cache = require("source.kavita.cache")
local Release = require("http.release")
local Install = require("utils.plugin_install")
local Job = require("workers.job")
local _ = require("gettext")
local T = require("ffi/util").template

local Update = {
    ---@type table|nil 在途查询 / 下载 / 安装，非 nil 即忙
    _job = nil,
}

-- 第三方仓库不能用 api.ankio.net（只代理 AnkioTomas 的仓库，其它 owner 直接 403）；
-- 直连 GitHub API，连不上再用能转发任意 api.github.com 路径的公益镜像。
local API_URLS = {
    "https://api.github.com/repos/backtracker/kamare.koplugin/releases/latest",
    "https://gh-proxy.com/https://api.github.com/repos/backtracker/kamare.koplugin/releases/latest",
    "https://gh-proxy.org/https://api.github.com/repos/backtracker/kamare.koplugin/releases/latest",
    "https://cdn.gh-proxy.org/https://api.github.com/repos/backtracker/kamare.koplugin/releases/latest",
}
local ASSET_NAME = "kamare.koplugin.zip"
-- 下载地址必须是本仓库、本 tag 下的资产，镜像才能按路径映射；API 镜像也改不了这个前缀。
local RELEASE_BASE = "https://github.com/backtracker/kamare.koplugin/releases/download/"
local MAX_ARCHIVE_BYTES = 100 * 1024 * 1024

--- 有查询 / 下载 / 安装在途。
---@return boolean
function Update.busy()
    return Update._job ~= nil
end

--- 数字段依次比较；数值相同时，预发布 / 开发版视为比正式版旧。
---@param candidate string
---@param installed string
---@return boolean
local function newer(candidate, installed)
    local function parts(version)
        local out = {}
        for n in tostring(version):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local left, right = parts(candidate), parts(installed)
    if #right == 0 then return true end
    for i = 1, 3 do
        local l, r = left[i] or 0, right[i] or 0
        if l ~= r then return l > r end
    end
    -- 0.10.4-dev < 0.10.4
    return tostring(installed):find("%-") ~= nil and tostring(candidate):find("%-") == nil
end

--- Release body → 可读纯文本：去掉 Markdown 标题 / 强调 / 行内代码，保留段落与列表。
---@param body any
---@return string|nil
local function formatNotes(body)
    if type(body) ~= "string" then return nil end
    body = Text.trim(Text.normalizeNewlines(body))
    if body == "" then return nil end
    local out, blank = {}, false
    for line in (body .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("^#+%s*", "")
        line = line:gsub("%*%*([^*]+)%*%*", "%1")
        line = line:gsub("`([^`\n]*)`", "%1")
        line = line:gsub("^%s*[%-%*]%s+", "· ")
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

--- 包体只认 Release 接口给的资产 digest（sha256）；地址必须在本仓库 Release 下。
---@param body string
---@return table|nil release
---@return string|nil err
local function parseRelease(body)
    -- body 来自网络，不是 JSON 就当无效响应。
    local ok, release = pcall(JSON.decode, body)
    if not ok or type(release) ~= "table" or release.draft or release.prerelease then
        return nil, "invalid release response"
    end
    local tag = release.tag_name
    local version = type(tag) == "string" and tag:match("^v?(%d+%.%d+%.%d+[%w%.%+%-]*)$")
    if not version then return nil, "invalid release version" end
    local expected = RELEASE_BASE .. tag .. "/" .. ASSET_NAME
    local zip
    for _idx, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
        local url = type(asset) == "table" and asset.browser_download_url
        if type(asset) == "table" and asset.name == ASSET_NAME and url == expected then
            zip = asset
        end
    end
    if not zip then return nil, "release has no plugin archive" end
    local digest = type(zip.digest) == "string" and zip.digest:match("^sha256:(" .. ("%x"):rep(64) .. ")$") or nil
    local probe = Cache.probe()
    local installed = probe.ok and probe.version or nil
    return {
        version = version,
        url = zip.browser_download_url,
        size = tonumber(zip.size),
        -- 老 Release 可能没有 digest：此时不走镜像，只直连 GitHub 下载。
        sha256 = digest and digest:lower() or nil,
        installed = installed,
        available = not installed or newer(version, installed),
        notes = formatNotes(release.body),
    }
end

--- 查询最新稳定版本：直连与 API 镜像并发查，最先解析出合法 Release 的胜出。
---@param cb fun(release: table|nil, err: any)
function Update.check(cb)
    if Update._job then return cb(nil, "busy") end
    local UIManager = require("ui/uimanager")
    local logger = require("utils.log")
    local jobs, pending, settled, last_err = {}, #API_URLS, false, nil

    local function finish(release, err)
        if settled then return end
        settled = true
        Update._job = nil
        for _idx, job in ipairs(jobs) do job:cancel() end
        cb(release, err)
    end

    local function settle(release, err)
        UIManager:nextTick(require("ui.guard").wrap("kamare update check", function()
            finish(release, err)
        end))
    end

    Update._job = {
        cancel = function()
            settled = true
            Update._job = nil
            for _idx, job in ipairs(jobs) do job:cancel() end
        end,
    }
    for _idx, url in ipairs(API_URLS) do
        if settled then break end
        jobs[#jobs + 1] = Request.get(url, {
            timeout = require("http.timeout").net(1 / 3),
            headers = {
                Accept = "application/vnd.github+json",
                ["X-GitHub-Api-Version"] = "2022-11-28",
            },
        }, function(body, err)
            if settled then return end
            local release, parse_err
            if not err then release, parse_err = parseRelease(body) end
            if release then
                logger.dbg("kamare.update check ok", url)
                return settle(release)
            end
            logger.dbg("kamare.update api failed", url, parse_err or err)
            last_err = parse_err or err or last_err
            pending = pending - 1
            if pending == 0 then
                logger.warn("kamare.update check failed", tostring(last_err))
                settle(nil, last_err)
            end
        end)
    end
end

---@return string
local function archivePath()
    Paths.ensureDir(Paths.root())
    return Paths.root() .. "/kamare-update.zip"
end

--- 从 url 下载并在子进程里装包；镜像下载失败或校验不过时回落直连重来一次。
---@param url string
---@param release table
---@param dir string 插件根目录
---@param done fun(ok: boolean, err: any) 已负责清 _job
---@param on_progress fun(bytes: number)|nil
---@param on_installing fun()|nil 下载完、开始换目录：此后不能再取消
local function installFrom(url, release, dir, done, on_progress, on_installing)
    local archive = archivePath()
    -- 换源必须清掉断点：镜像的半个包不能续进直连的字节流。
    os.remove(archive)
    os.remove(archive .. ".part")
    local function fail(err)
        if url == release.url then return done(false, err) end
        require("utils.log").warn("kamare.update mirror failed", url, err)
        installFrom(release.url, release, dir, done, on_progress, on_installing)
    end
    Update._job = Request.download({
        url = url,
        timeout = require("http.timeout").net(10),
        allow_redirects = true,
        resume = true,
        max_bytes = MAX_ARCHIVE_BYTES,
        on_progress = on_progress,
    }, archive, function(ok, err)
        if not ok then return fail(err) end
        if on_installing then on_installing() end
        Update._job = Job.run(function()
            local installed, detail = Install.run(archive, dir .. "/book.koplugin", release.sha256,
                { name = "kamare.koplugin", parent = dir })
            if not installed then error(detail, 0) end
            return detail
        end, {
            name = "kamare.update",
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

--- 下载、校验并安装 kamare 增强版。
---@param release table Update.check 返回值
---@param plugin table|nil 月读插件实例（取它的目录作为兜底安装位置）
---@param cb fun(ok: boolean, err: any)
---@param on_progress fun(bytes: number)|nil
---@param on_installing fun()|nil
function Update.install(release, plugin, cb, on_progress, on_installing)
    if Update._job then return cb(false, "busy") end
    local dir = Cache.pluginsDir(plugin and plugin.path)
    local function done(ok, err)
        Update._job = nil
        cb(ok, err)
    end
    if not release.sha256 then
        -- 没有校验值就不信任镜像，只从 GitHub 直连下载。
        installFrom(release.url, release, dir, done, on_progress, on_installing)
        return
    end
    Update._job = Release.pick(release, function(url)
        installFrom(url, release, dir, done, on_progress, on_installing)
    end)
end

--- 取消在途的查询 / 下载，不回调。换目录的子进程只有退出时才会被杀。
function Update.cancel()
    if Update._job then Update._job:cancel() end
    Update._job = nil
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

---@param text string
---@param timeout number|nil
local function toast(text, timeout)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = timeout or 3 }:show()
end

--- 下载可取消；进入换目录后换成不可关闭的安装窗。装好立即重启。
---@param plugin table|nil
---@param release table
local function startInstall(plugin, release)
    local ProgressDialog = require("ui.themes.widgets.progress_dialog")
    local dialog = ProgressDialog:new{
        title = _("正在下载 kamare 更新…"),
        dismissable = false,
        on_cancel = Update.cancel,
    }
    dialog:show()
    Update.install(release, plugin, function(ok, err)
        if ok then
            dialog:set(_("更新完成，正在重启 KOReader…"), 100)
            UIManager:nextTick(require("utils.restart").now)
            return
        end
        dialog:close()
        toast(T(_("kamare 更新失败：%1"), errorText(err)), 5)
    end, function(bytes)
        if release.size and release.size > 0 then dialog:bytes(bytes, release.size) end
    end, function()
        dialog:close()
        dialog = ProgressDialog:new{ title = _("正在安装 kamare 更新…"), dismissable = false }
        dialog:show()
    end)
end

---@param plugin table|nil
---@param release table
local function promptInstall(plugin, release)
    local header
    if release.installed then
        header = T(_("发现 kamare %1（当前 %2）。下载并完整替换插件目录？"),
            release.version, release.installed)
    else
        header = T(_("当前未安装可用的 kamare 增强版。安装最新版 %1？"), release.version)
    end
    local text = release.notes and (header .. "\n\n" .. release.notes) or header
    local dialog
    dialog = require("ui.themes.widgets.text_viewer"):new{
        title = _("更新 kamare"),
        text = text,
        buttons = {
            { text = _("稍后"), callback = function() dialog:close() end },
            {
                text = _("下载并安装"),
                variant = "primary",
                callback = function()
                    dialog:close()
                    startInstall(plugin, release)
                end,
            },
        },
    }
    dialog:show()
end

--- 用户主动检查：始终显示结果；有新版本（或当前不是可用的增强版）才弹安装确认。
---@param plugin table|nil
function Update.start(plugin)
    local Toast = require("ui.themes.widgets.toast")
    if Update._job then
        toast(_("正在检查或安装更新，请稍候"))
        return
    end
    if not require("ui/network/manager"):isConnected() then
        toast(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    local loading = require("ui.themes.widgets.progress_dialog"):new{
        title = _("检查更新"),
        text = _("正在检查 kamare 更新…"),
        dismissable = false,
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
                promptInstall(plugin, release)
            else
                Toast:new{
                    text = T(_("已是最新版本（%1）"), "kamare " .. (release.installed or release.version)),
                    timeout = 3,
                }:show()
            end
        end
    end)
end

return Update
