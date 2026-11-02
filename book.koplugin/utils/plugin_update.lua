--[[--
插件在线更新引擎：查询 GitHub Release、直连与公益镜像竞速下载、校验并替换插件目录。月读与 kamare 共用。

包体唯一信任根是 Release 接口给的资产 digest（sha256），镜像只搬运字节，校验不过回落直连。
没有 digest 的 Release 只走直连。文案和「装到哪」由目标（target）提供，这里只管流程。

target 字段：
  repo           GitHub owner/name，资产地址必须是该仓库本 tag 下的 asset(tag)
  api_urls       Release 接口，按序回落
  asset(tag)     资产文件名
  archive        下载暂存文件名（放在插件数据根目录）
  job            安装子进程名
  digest_required 为真时没有 digest 的 Release 视为无效
  installed()    已装版本，没装返回 nil
  name           包内顶层插件目录名
  parent(ctx)    装到哪个插件目录；已装的同名目录就地换掉
  verify(name, staging) 可选，解压后的额外体检，返回错误串即拒绝（见 utils.plugin_install）
  on_checked()   可选，查询成功后调用
  text           界面文案：checking / downloading / installing / failed(%1) / title /
                 header(release, force) → 弹窗首句 / latest(release) → 已是最新时展示的版本

@module koplugin.book.utils.plugin_update
--]]

local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local Text = require("utils.text")
local Job = require("workers.job")
local Install = require("utils.plugin_install")
local Release = require("http.release")
local _ = require("gettext")
local T = require("ffi/util").template

local MAX_ARCHIVE_BYTES = 100 * 1024 * 1024

---@class PluginUpdater
---@field target table
---@field _offered_version string|nil
---@field _job table|nil 在途请求 / 下载 / 安装子进程，非 nil 即忙
local Updater = {}
Updater.__index = Updater

---@param target table
---@return PluginUpdater
function Updater.new(target)
    return setmetatable({ target = target }, Updater)
end

--- 数字段依次比较；数值相同时，预发布 / 开发版视为比正式版旧；已装版本解析不出一律视为更旧。
---@param candidate string
---@param installed string
---@return boolean
function Updater.newer(candidate, installed)
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
    return installed:find("%-") ~= nil and candidate:find("%-") == nil
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

---@param body string
---@return table|nil release
---@return string|nil err
function Updater:parse(body)
    local target = self.target
    -- body 来自网络，不是 JSON 就当无效响应。
    local ok, release = pcall(JSON.decode, body)
    if not ok or type(release) ~= "table" or release.draft or release.prerelease then
        return nil, "invalid release response"
    end
    local tag = release.tag_name
    local version = type(tag) == "string" and tag:match("^v?(%d+%.%d+%.%d+[%w%.%+%-]*)$")
    if not version then return nil, "invalid release version" end
    local name = target.asset(tag)
    local expected = "https://github.com/" .. target.repo .. "/releases/download/" .. tag .. "/" .. name
    local zip
    for _idx, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
        if type(asset) == "table" and asset.name == name and asset.browser_download_url == expected then
            zip = asset
        end
    end
    if not zip then return nil, "release has no plugin archive" end
    local digest = type(zip.digest) == "string" and zip.digest:match("^sha256:(" .. ("%x"):rep(64) .. ")$")
    if not digest and target.digest_required then return nil, "release has no plugin checksum" end
    local installed = target.installed()
    return {
        version = version,
        url = expected,
        size = tonumber(zip.size),
        sha256 = digest and digest:lower() or nil,
        installed = installed,
        notes = formatNotes(release.body),
        available = not installed or Updater.newer(version, installed),
    }
end

--- 有请求 / 下载 / 安装在途。
---@return boolean
function Updater:busy()
    return self._job ~= nil
end

--- 查询最新稳定版本；接口按序回落。
---@param cb fun(release: table|nil, err: any)
function Updater:check(cb)
    if self._job then return cb(nil, "busy") end
    local urls = self.target.api_urls
    local function fetch(idx)
        self._job = Request.get(urls[idx], {
            timeout = require("http.timeout").net(1),
            headers = {
                Accept = "application/vnd.github+json",
                ["X-GitHub-Api-Version"] = "2022-11-28",
            },
        }, function(body, err)
            self._job = nil
            if err and urls[idx + 1] then
                require("utils.log").warn("plugin.update api failed", urls[idx], err)
                return fetch(idx + 1)
            end
            if err then return cb(nil, err) end
            local release, parse_err = self:parse(body)
            if not release then return cb(nil, parse_err) end
            if self.target.on_checked then self.target.on_checked() end
            cb(release)
        end)
    end
    fetch(1)
end

--- 从 url 下载并在子进程里装包；镜像下载失败或校验不过时回落直连重来一次。
---@param done fun(ok: boolean, err: any) 已负责清 _job
local function installFrom(self, url, release, ctx, done, on_progress, on_installing)
    local target = self.target
    local function fail(err)
        if url == release.url then return done(false, err) end
        require("utils.log").warn("plugin.update mirror failed", url, err)
        installFrom(self, release.url, release, ctx, done, on_progress, on_installing)
    end
    Paths.ensureDir(Paths.root())
    local archive = Paths.root() .. "/" .. target.archive
    -- 换源必须清掉断点：镜像的半个包不能续进直连的字节流。
    os.remove(archive)
    os.remove(archive .. ".part")
    self._job = Request.download({
        url = url,
        timeout = require("http.timeout").net(10),
        allow_redirects = true,
        resume = true,
        max_bytes = MAX_ARCHIVE_BYTES,
        on_progress = on_progress,
    }, archive, function(ok, err)
        if not ok then return fail(err) end
        if on_installing then on_installing() end
        local parent = target.parent(ctx)
        local opts = { name = target.name, verify = target.verify }
        self._job = Job.run(function()
            local installed, detail = Install.run(archive, parent, release.sha256, opts)
            if not installed then error(detail, 0) end
        end, {
            name = target.job,
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

--- 下载、校验并安装已查询到的版本。没有 digest 就不信任镜像，只直连。
---@param release table Updater:check 返回值
---@param ctx any 交给 target.parent
---@param cb fun(ok: boolean, err: any)
---@param on_progress fun(bytes: number)|nil
---@param on_installing fun()|nil 下载完、开始换目录：此后不能再取消
function Updater:install(release, ctx, cb, on_progress, on_installing)
    if self._job then return cb(false, "busy") end
    local function done(ok, err)
        self._job = nil
        cb(ok, err)
    end
    if not release.sha256 then
        return installFrom(self, release.url, release, ctx, done, on_progress, on_installing)
    end
    self._job = Release.pick(release, function(url)
        installFrom(self, url, release, ctx, done, on_progress, on_installing)
    end)
end

--- 安装本地已有的更新包（远程管理上传）。无论成败都删包；装好后由调用方重启。
---@param archive string ZIP 路径，所有权移交本函数
---@param ctx any 交给 target.parent
---@param cb fun(ok: boolean, detail: string|nil) 成功时 detail 是插件目录名；失败时是错误首行，不带子进程堆栈
function Updater:installArchive(archive, ctx, cb)
    if self._job then
        os.remove(archive)
        return cb(false, "busy")
    end
    local settled = false
    local function settle()
        settled = true
        self._job = nil
        os.remove(archive)
    end
    local parent = self.target.parent(ctx)
    local opts = { verify = self.target.verify }
    local job = Job.run(function()
        local installed, detail = Install.run(archive, parent, nil, opts)
        if not installed then error(detail, 0) end
        return detail
    end, {
        name = self.target.job,
        kind = "heavy",
        timeout = require("http.timeout").net(4),
        on_done = function(name)
            settle()
            cb(true, name)
        end,
        on_failed = function(err)
            settle()
            cb(false, tostring(err):match("[^\n]*"))
        end,
        on_cancelled = settle,
    })
    -- fork 失败时 Job.run 同步回调，不能再把已结束的 job 挂回去占着「忙」。
    if not settled then self._job = job end
end

--- 取消在途的检查 / 下载，不回调。换目录的子进程只有退出时才会被杀。
function Updater:cancel()
    if self._job then self._job:cancel() end
    self._job = nil
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
local function startInstall(self, release, ctx)
    local text = self.target.text
    local ProgressDialog = require("ui.themes.widgets.progress_dialog")
    local dialog = ProgressDialog:new{
        title = text.downloading,
        dismissable = false,
        on_cancel = function() self:cancel() end,
    }
    dialog:show()
    self:install(release, ctx, function(ok, err)
        if ok then
            dialog:set(_("更新完成，正在重启 KOReader…"), 100)
            require("ui/uimanager"):nextTick(require("utils.restart").now)
            return
        end
        dialog:close()
        require("ui.themes.widgets.toast"):new{
            text = T(text.failed, errorText(err)),
            timeout = 5,
        }:show()
    end, function(bytes)
        if release.size and release.size > 0 then dialog:bytes(bytes, release.size) end
    end, function()
        dialog:close()
        dialog = ProgressDialog:new{ title = text.installing, dismissable = false }
        dialog:show()
    end)
end

--- 弹更新日志与安装确认。同版本只提示一次，force 跳过这层记忆。
---@param release table
---@param ctx any
---@param force boolean|nil
function Updater:prompt(release, ctx, force)
    if not force and self._offered_version == release.version then return end
    self._offered_version = release.version
    local text = self.target.text
    local header = text.header(release, force)
    local dialog
    dialog = require("ui.themes.widgets.text_viewer"):new{
        title = force and not release.available and _("强制更新") or text.title,
        text = release.notes and (header .. "\n\n" .. release.notes) or header,
        buttons = {
            { text = _("稍后"), callback = function() dialog:close() end },
            {
                text = _("下载并安装"),
                variant = "primary",
                callback = function()
                    dialog:close()
                    startInstall(self, release, ctx)
                end,
            },
        },
    }
    dialog:show()
end

--- 用户主动检查；始终显示结果。force=true：不管有没有新版本都提示安装最新包。
---@param ctx any
---@param force boolean|nil
function Updater:manualCheck(ctx, force)
    local Toast = require("ui.themes.widgets.toast")
    local loading = require("ui.themes.widgets.progress_dialog"):new{
        title = force and _("强制更新") or _("检查更新"),
        text = self.target.text.checking,
        dismissable = false,
    }
    loading:show()
    self:check(function(release, err)
        loading:close()
        if err then
            Toast:new{ text = T(_("检查更新失败：%1"), errorText(err)), timeout = 4 }:show()
        elseif force or release.available then
            self._offered_version = nil
            self:prompt(release, ctx, force)
        else
            Toast:new{ text = T(_("已是最新版本（%1）"), self.target.text.latest(release)), timeout = 3 }:show()
        end
    end)
end

return Updater
