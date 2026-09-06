--[[--
插件在线更新：查询 GitHub Release、下载校验包并完整替换插件目录。

自动检查只提示可用版本，不会自动下载或安装。

@module koplugin.book.update
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Text = require("utils.text")
local Job = require("workers.job")
local Install = require("update.install")
local _ = require("gettext")
local T = require("ffi/util").template

local Update = {}

local API_URL = "https://api.github.com/repos/AnkioTomas/moon/releases/latest"
local CHECK_INTERVAL = 24 * 60 * 60
local _checking = false
local _installing = false
local _offered_version
local _job

local function currentVersion()
    local ok, version = pcall(require, "bookversion")
    if ok and type(version) == "string" then return version end
    return "0.0.0-dev"
end

local function versionParts(version)
    local major, minor, patch = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function newer(candidate, installed)
    local left, right = versionParts(candidate), versionParts(installed)
    if not left then return false end
    if not right then return true end
    for i = 1, 3 do
        if left[i] ~= right[i] then return left[i] > right[i] end
    end
    return false
end

local function findAsset(assets, name)
    for _, asset in ipairs(type(assets) == "table" and assets or {}) do
        if type(asset) == "table" and asset.name == name
            and type(asset.browser_download_url) == "string"
            and asset.browser_download_url:match("^https://github%.com/AnkioTomas/moon/releases/download/")
        then
            return asset
        end
    end
end

--- 把 GitHub Release body 收成可读纯文本：优先「更新内容」段，丢掉安装说明与对比链接。
---@param body any
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

local function parseRelease(body)
    local ok, release = pcall(JSON.decode, body)
    if not ok or type(release) ~= "table" or release.draft or release.prerelease then
        return nil, "invalid release response"
    end
    local tag = release.tag_name
    local version = type(tag) == "string" and tag:match("^v?(%d+%.%d+%.%d+[%w%.%+%-]*)$")
    if not version then return nil, "invalid release version" end
    local zip_name = "book.koplugin-" .. tag .. ".zip"
    local zip = findAsset(release.assets, zip_name)
    if not zip then return nil, "release has no plugin archive" end
    local digest = type(zip.digest) == "string" and zip.digest:match("^sha256:([%da-fA-F]+)$")
    if digest and #digest ~= 64 then digest = nil end
    local checksum = findAsset(release.assets, zip_name .. ".sha256")
    if not digest and not checksum then return nil, "release has no plugin checksum" end
    return {
        version = version,
        tag = tag,
        url = zip.browser_download_url,
        size = tonumber(zip.size),
        sha256 = digest and digest:lower() or nil,
        checksum_url = checksum and checksum.browser_download_url or nil,
        notes = formatNotes(release.body),
        available = newer(version, currentVersion()),
    }
end

--- 查询最新稳定版本。
---@param cb fun(release: table|nil, err: any)
---@return table|nil
function Update.check(cb)
    if _checking then
        cb(nil, "already checking")
        return nil
    end
    _checking = true
    _job = Request.get(API_URL, {
        timeout = 30,
        headers = {
            Accept = "application/vnd.github+json",
            ["X-GitHub-Api-Version"] = "2022-11-28",
        },
    }, function(body, err)
        _checking = false
        _job = nil
        if err then
            cb(nil, err)
            return
        end
        local release, parse_err = parseRelease(body)
        if not release then
            cb(nil, parse_err)
            return
        end
        MoonSettings.save({ update_last_checked_at = os.time() })
        cb(release)
    end)
    return _job
end

local function installWithChecksum(release, plugin_root, checksum, cb, on_progress)
    Paths.ensureSettings()
    local archive = Paths.root() .. "/plugin-update.zip"
    os.remove(archive)
    _job = Request.download({
        url = release.url,
        method = "GET",
        timeout = 300,
        allow_redirects = true,
        max_bytes = Install.MAX_ARCHIVE_BYTES,
        on_progress = on_progress,
    }, archive, function(ok, err)
        if not ok then
            _installing = false
            _job = nil
            cb(false, err)
            return
        end
        _job = Job.run(function()
            local installed, install_err = Install.run(archive, plugin_root, release.version, checksum)
            if not installed then error(install_err) end
        end, {
            name = "plugin.update",
            timeout = 120,
            on_done = function()
                os.remove(archive)
                _installing = false
                _job = nil
                cb(true)
            end,
            on_failed = function(install_err)
                os.remove(archive)
                _installing = false
                _job = nil
                cb(false, install_err)
            end,
        })
    end)
end

--- 下载、校验并安装已查询到的版本。
---@param release table Update.check 返回值
---@param plugin_root string 当前插件目录
---@param cb fun(ok: boolean, err: any)
---@param on_progress fun(bytes: number)|nil
function Update.install(release, plugin_root, cb, on_progress)
    if _installing then
        cb(false, "already installing")
        return
    end
    _installing = true
    if release.sha256 then
        installWithChecksum(release, plugin_root, release.sha256, cb, on_progress)
        return
    end
    _job = Request.get(release.checksum_url, {
        timeout = 30,
        allow_redirects = true,
    }, function(body, err)
        if err then
            _installing = false
            _job = nil
            cb(false, err)
            return
        end
        local checksum = type(body) == "string" and body:match("^%s*([%da-fA-F]+)")
        if not checksum or #checksum ~= 64 then
            _installing = false
            _job = nil
            cb(false, "invalid update checksum")
            return
        end
        installWithChecksum(release, plugin_root, checksum:lower(), cb, on_progress)
    end)
end

local function promptRestart()
    local dialog
    dialog = ConfirmBox:new{
        text = _("月读已更新，重启 KOReader 后生效。"),
        ok_text = _("立即重启"),
        cancel_text = _("稍后"),
        ok_callback = function()
            UIManager:close(dialog)
            UIManager:restartKOReader()
        end,
    }
    UIManager:show(dialog)
end

local function startInstall(release, plugin_root)
    local size = tonumber(release.size)
    local loading = ProgressbarDialog:new{
        title = _("正在下载月读更新…"),
        subtitle = T(_("版本 %1"), release.version),
        progress_max = size and size > 0 and size or nil,
        refresh_time_seconds = 0.2,
        dismissable = false,
    }
    loading:show()
    Update.install(release, plugin_root, function(ok, err)
        loading:close()
        if ok then
            promptRestart()
        else
            UIManager:show(InfoMessage:new{
                text = T(_("月读更新失败：%1"), tostring(err)),
                timeout = 5,
            })
        end
    end, function(bytes)
        loading:reportProgress(bytes)
    end)
end

local function promptInstall(release, plugin_root)
    if _offered_version == release.version then return end
    _offered_version = release.version
    local header = T(_("发现月读 %1（当前 %2）。下载并完整替换插件目录？"),
        release.version, currentVersion())
    local text = release.notes and (header .. "\n\n" .. release.notes) or header
    local Screen = require("device").screen
    local dialog
    dialog = TextViewer:new{
        title = _("更新日志"),
        text = text,
        height = math.floor(Screen:getHeight() * 0.75),
        buttons_table = {{
            {
                text = _("稍后"),
                callback = function()
                    dialog:onClose()
                end,
            },
            {
                text = _("下载并安装"),
                callback = function()
                    dialog:onClose()
                    startInstall(release, plugin_root)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

--- 用户主动检查；始终显示结果。
---@param plugin_root string
function Update.manualCheck(plugin_root)
    local loading = InfoMessage:new{ text = _("正在检查月读更新…") }
    UIManager:show(loading)
    Update.check(function(release, err)
        UIManager:close(loading)
        if err then
            UIManager:show(InfoMessage:new{
                text = T(_("检查更新失败：%1"), tostring(err)),
                timeout = 4,
            })
        elseif release.available then
            _offered_version = nil
            promptInstall(release, plugin_root)
        else
            UIManager:show(InfoMessage:new{
                text = T(_("已是最新版本（%1）"), currentVersion()),
                timeout = 3,
            })
        end
    end)
end

--- 按 24 小时间隔静默检查；只有发现新版本才弹窗。
---@param plugin_root string
function Update.autoCheck(plugin_root)
    local settings = MoonSettings.get("maintenance")
    if not settings.auto_update_check then return end
    if os.time() - (tonumber(settings.update_last_checked_at) or 0) < CHECK_INTERVAL then return end
    Update.check(function(release)
        if release and release.available then promptInstall(release, plugin_root) end
    end)
end

--- FileManager 插件实例启动后触发一次自动检查。
---@param plugin_root string
function Update.bootstrap(plugin_root)
    UIManager:nextTick(function() Update.autoCheck(plugin_root) end)
end

function Update.cancel()
    if _job and _job.cancel then _job:cancel() end
    _job = nil
    _checking = false
    _installing = false
end

Update._newer = newer
Update._parseRelease = parseRelease
Update._formatNotes = formatNotes

return Update
