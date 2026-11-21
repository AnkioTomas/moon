--[[--
插件市场页面：浏览 / 已安装 / 更新，缓存搜索与分类，平台来源与可选令牌管理。

@module koplugin.book.features.marketplace.page
--]]

require("l10n").apply()

local _ = require("gettext")
local T = require("ffi/util").template
local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local Sources = require("features.marketplace.sources")
local Catalog = require("features.marketplace.catalog")
local Credentials = require("features.marketplace.credentials")
local MarketInstall = require("features.marketplace.install")
local Installed = require("features.marketplace.installed")
local Adapters = require("features.marketplace.adapters")

local Page = {}

--- 浏览页在途 listReleases；离开/退出时取消，避免回调再弹窗。
local release_job

local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

local function confirm(opts)
    require("ui.themes.widgets.confirm"):new(opts):show()
end

local function redraw(desktop)
    if desktop and not desktop.closed and desktop.settings_overlay then
        desktop.settings_overlay:updateView()
    end
end

local ERRORS = {
    rate_limit = _("接口请求过于频繁，已保留上次列表。请稍后再刷新。"),
    not_found = _("找不到对应的项目或文件。请检查来源地址。"),
    forbidden = _("来源拒绝了访问。请检查令牌是否有效、是否仍有权限。"),
    network = _("网络请求失败，已保留上次列表。"),
    bad_instance = _("无法识别这个平台实例。请检查地址是否正确。"),
    host_mismatch = _("请求没有发到来源主机，已中止。"),
    type = _("不支持的来源类型。"),
    duplicate = _("这个来源已经添加过了。"),
    host = _("请填写有效的平台地址，例如 git.example.com 或 gitlab.com。"),
    scheme = _("平台地址只支持 http 或 https。"),
    userinfo = _("地址里不能包含用户名或密码。"),
    query = _("地址里不能包含查询参数。"),
    path = _("请只填写实例主机名，不要带路径。"),
    github_as_gitea = _("GitHub 请使用 GitHub 类型，不要当作 Gitea 实例。"),
    github_as_gitlab = _("GitHub 请使用 GitHub 类型，不要当作 GitLab 实例。"),
    gitlab_as_gitea = _("GitLab.com 请使用 GitLab 类型，不要当作 Gitea 实例。"),
    missing = _("找不到这个来源。"),
    no_manifest = _("仓库没有可用的安装信息，不能安装。"),
    plugin = _("无法确定插件目录名，不能安装。"),
    reserved = _("不能安装或覆盖月读核心（book.koplugin）。"),
    asset = _("没有可用的官方 zip 资产，不能安装。"),
    asset_mismatch = _("Release 资产与清单声明不一致，不能安装。"),
    version_mismatch = _("清单版本与 Release 标签不一致，不能安装。"),
    unsafe_url = _("下载地址不是该仓库的官方 Release 资产，已拒绝。"),
    unsafe_path = _("目标路径不安全，已拒绝安装。"),
    min_moon = _("当前月读版本低于清单要求，不能安装。"),
    no_release = _("找不到可安装的官方 Release 资产，不能安装。"),
    ambiguous = _("这个 Release 有多个 zip，无法自动选择，不能安装。"),
    busy = _("正在安装另一个插件，请稍候。"),
    download = _("下载失败。"),
    plugin_root = _("无法确定插件安装目录。"),
    id = _("无法保存令牌。"),
    corrupt = _("凭据文件已损坏，已拒绝覆盖，以免抹掉其它来源的令牌。请删除 secrets/marketplace.json 后重试。"),
    write = _("无法写入本地缓存。"),
    record = _("插件已安装，但安装记录未能保存。"),
}

function Page.errorText(err)
    local code, retry_at, source_id
    if type(err) == "table" then
        code = err.code
        retry_at = err.retry_at
        source_id = err.source_id
    else
        code = err
    end
    local text = ERRORS[code]
    if not text then
        if code or err then
            text = T(_("操作失败：%1"), tostring(code or err))
        else
            text = _("操作失败。")
        end
    elseif code == "rate_limit" and type(retry_at) == "number" and retry_at > 0 then
        text = T(_("接口请求过于频繁，已保留上次列表。请在 %1 后再刷新。"), os.date("%Y-%m-%d %H:%M", retry_at))
    end
    if type(source_id) == "string" and source_id ~= "" then
        local source = Sources.get(source_id)
        local label = source and Sources.label(source) or source_id
        text = T(_("%1：%2"), label, text)
    end
    return text
end

local function reasonText(item)
    if item.has_topic then
        if Installed.pluginDir(item) then return nil end
        return _("有 moon-plugin 标记，但无法确定插件目录名，还不能安装。")
    end
    return _("不是带 moon-plugin 标记的月读扩展，不能安装。请给仓库加上 topic「moon-plugin」。不会把普通 koreader-plugin 或仅凭 ko-* 名字的仓库当成月读插件。")
end

local function markHint()
    return _("给仓库加上 GitHub / Gitea / GitLab topic「moon-plugin」。标题和简介优先读取仓库里的 _meta.lua（只解析字面量，不会执行远程代码）。moon-plugin.json 是可选兼容项，不是安装前提。不会把普通 koreader-plugin 或仅凭 ko-* 名字的仓库当成月读插件。月读本体请继续用「我的设备 → 版本」更新。")
end

local function filterData()
    local data = Settings.get("features.marketplace")
    if type(data.filter) ~= "table" then data.filter = { tab = "browse", q = "", topic = "" } end
    return data
end

function Page.filter()
    local data = filterData()
    local tab = data.filter.tab
    if tab ~= "installed" and tab ~= "updates" then tab = "browse" end
    return {
        tab = tab,
        q = type(data.filter.q) == "string" and data.filter.q or "",
        topic = type(data.filter.topic) == "string" and data.filter.topic or "",
    }
end

local function saveFilter(next_filter)
    local data = filterData()
    data.filter.tab = next_filter.tab
    data.filter.q = next_filter.q
    data.filter.topic = next_filter.topic
    Settings.save("features.marketplace")
end

function Page.setTab(tab, desktop)
    local filter = Page.filter()
    filter.tab = (tab == "installed" or tab == "updates") and tab or "browse"
    saveFilter(filter)
    redraw(desktop)
end

function Page.setQuery(query, desktop)
    local filter = Page.filter()
    filter.q = type(query) == "string" and query or ""
    saveFilter(filter)
    redraw(desktop)
end

function Page.setTopic(topic, desktop)
    local filter = Page.filter()
    filter.topic = type(topic) == "string" and topic or ""
    saveFilter(filter)
    redraw(desktop)
end

function Page.clearFilters(desktop)
    local filter = Page.filter()
    filter.q = ""
    filter.topic = ""
    saveFilter(filter)
    redraw(desktop)
end

--- 限流可重试时间：只有响应头给出 retry_at 才格式化，否则如实说明没有时间。
---@param err any
---@return string
function Page.retryHint(err)
    if type(err) == "table" and type(err.retry_at) == "number" and err.retry_at > 0 then
        return T(_("请在 %1 后再刷新。"), os.date("%Y-%m-%d %H:%M", err.retry_at))
    end
    return _("接口没有返回可重试时间。")
end

---@param err any
---@return string
local function errorBody(err)
    if type(err) == "table" then
        return Page.errorText({ code = err.code, retry_at = err.retry_at })
    end
    return Page.errorText(err)
end

--- 进度条文案。不编造百分比；有真实完成数时由调用方传给进度条。
---@param info table
---@return string
function Page.progressText(info)
    info = info or {}
    local label = info.source and Sources.label(info.source) or _("来源")
    local text
    if info.stage == "enrich" then
        text = T(_("正在读取 %1 的说明"), label)
    elseif info.stage == "source_done" then
        text = T(_("%1 已完成"), label)
    else
        text = T(_("正在搜索 %1"), label)
    end
    if type(info.index) == "number" and type(info.sources) == "number" and info.sources > 0 then
        text = T(_("%1（第 %2 / %3 个来源）"), text, tostring(info.index), tostring(info.sources))
    end
    return text
end

--- 刷新汇总。未刷到的来源不算成功。
---@param report table|nil
---@param sources table[]|nil
---@return string text
---@return boolean all_ok
function Page.summaryText(report, sources)
    sources = sources or Sources.list()
    local by_id = {}
    for _idx, row in ipairs(report and report.sources or {}) do
        if type(row) == "table" and type(row.id) == "string" then
            by_id[row.id] = row
        end
    end
    local function fallbackNote(row, source)
        if type(row) ~= "table" then return "" end
        if row.fallback_failed then
            return " " .. _("公开后备接口未能完成。")
        end
        if row.via_fallback ~= true then return "" end
        local note = _("已改用公开后备接口。")
        local Credentials = require("features.marketplace.credentials")
        if source and Credentials.has(source.id) then
            note = note .. " " .. _("私有仓库可能未包含。")
        end
        return " " .. note
    end
    local lines, all_ok = {}, #sources > 0
    for _idx, source in ipairs(sources) do
        local row = by_id[source.id]
        local label = Sources.label(source)
        if not row then
            all_ok = false
            lines[#lines + 1] = T(_("%1：未刷新，已保留上次列表。"), label)
        elseif row.status == "ok" then
            lines[#lines + 1] = T(_("%1：已更新。"), label) .. fallbackNote(row, source)
        elseif row.status == "rate_limit" then
            all_ok = false
            local kept = row.kept_cache and _("已保留上次列表。") or _("已保存当前已搜到的条目。")
            lines[#lines + 1] = T(_("%1：接口请求过于频繁。"), label)
                .. " " .. Page.retryHint(row.err) .. " " .. kept .. fallbackNote(row, source)
        else
            all_ok = false
            local kept = row.kept_cache and _("已保留上次列表。") or _("已保存当前已搜到的条目。")
            lines[#lines + 1] = T(_("%1：%2"), label, errorBody(row.err)) .. " " .. kept .. fallbackNote(row, source)
        end
    end
    if report and report.persist_error then
        all_ok = false
        lines[#lines + 1] = _("列表已拉取，但未能写入本地缓存。")
    end
    if #sources == 0 then
        return _("没有可刷新的来源。"), false
    end
    return table.concat(lines, "\n"), all_ok
end

function Page.cancelPending()
    if release_job and release_job.cancel then
        release_job.cancel()
    end
    release_job = nil
end

function Page.refresh(desktop)
    if #Sources.list() == 0 then
        toast(_("请先添加来源。"))
        return
    end
    if Catalog.isRefreshing() then
        toast(_("正在刷新，请稍候。"))
        return
    end
    local sources = Sources.list()
    local open, cancelled = true, false
    local dialog
    local function safeUpdate(text, done, total)
        if not open or not dialog or type(dialog.update) ~= "function" then return end
        dialog:update(text, done, total)
    end
    local function closeProgress()
        if open and dialog and type(dialog.close) == "function" then
            dialog:close()
        end
        open = false
    end
    dialog = require("ui.themes.widgets.progress_dialog"):new{
        title = _("正在刷新"),
        text = _("正在准备…"),
        on_cancel = function()
            cancelled = true
            Catalog.cancel()
        end,
        close_callback = function()
            open = false
        end,
    }
    dialog:showWhile(function()
        Catalog.refresh(function(cache, err, report)
            if cancelled then
                redraw(desktop)
                return
            end
            closeProgress()
            local text, all_ok = Page.summaryText(report, sources)
            if all_ok then
                toast(_("已按来源更新列表。"))
            else
                require("ui.themes.widgets.confirm"):new{
                    title = _("刷新结果"),
                    text = (text and text ~= "" and text) or Page.errorText(err),
                    ok_text = _("知道了"),
                }:show()
            end
            redraw(desktop)
        end, {
            on_progress = function(info)
                if not open then return end
                local text = Page.progressText(info)
                if info and info.stage == "enrich" and type(info.total) == "number" and info.total > 0 then
                    safeUpdate(text, info.done or 0, info.total)
                else
                    safeUpdate(text)
                end
            end,
        })
    end)
    redraw(desktop)
end

function Page.search(desktop)
    local filter = Page.filter()
    require("ui.themes.widgets.input"):new{
        title = _("搜索"),
        fields = {
            { text = filter.q, hint = _("插件名、仓库名、标题或简介") },
        },
        callback = function(values)
            local text = values
            if type(values) == "table" then text = values[1] end
            Page.setQuery(text or "", desktop)
        end,
    }:show()
end

function Page.chooseTopic(desktop)
    local current = Page.filter().topic
    local items = { { text = _("全部"), value = "" } }
    for _idx, topic in ipairs(Catalog.topics()) do
        items[#items + 1] = { text = topic, value = topic }
    end
    require("ui.themes.widgets.list"):new{
        title = _("分类"),
        centered = true,
        items = items,
        selected = current,
        on_select = function(value)
            Page.setTopic(value or "", desktop)
        end,
    }:show()
end

local function addPlatform(desktop, type_name, host)
    local item, err = Sources.add({ type = type_name, host = host })
    if not item then
        toast(Page.errorText(err))
        return
    end
    toast(_("已添加来源"))
    Page.refresh(desktop)
end

local function askHost(desktop, type_name)
    if type_name == "github" then
        addPlatform(desktop, "github", Sources.GITHUB_HOST)
        return
    end
    local title = type_name == "gitlab" and _("GitLab 地址") or _("Gitea 地址")
    local hint = type_name == "gitlab" and "gitlab.com" or "git.example.com"
    local default = type_name == "gitlab" and "gitlab.com" or ""
    require("ui.themes.widgets.input"):new{
        title = title,
        fields = {
            { label = _("平台地址"), hint = hint, text = default },
        },
        callback = function(host)
            addPlatform(desktop, type_name, host)
        end,
    }:show()
end

function Page.addSource(desktop)
    require("ui.themes.widgets.list"):new{
        title = _("添加来源"),
        centered = true,
        items = {
            { text = _("GitHub"), value = "github" },
            { text = _("Gitea"), value = "gitea" },
            { text = _("GitLab"), value = "gitlab" },
        },
        on_select = function(value)
            askHost(desktop, value)
        end,
    }:show()
end

function Page.removeSource(desktop, source)
    confirm{
        title = _("删除来源"),
        text = T(_("删除来源「%1」？之后不会再扫描它。已安装的插件不会被卸载。"), Sources.label(source)),
        ok_text = _("删除"),
        ok_callback = function()
            Sources.remove(source.id)
            Credentials.clear(source.id)
            Catalog.onAuthChange(source.id)
            Catalog.dropSource(source.id)
            redraw(desktop)
        end,
    }
end

function Page.setToken(desktop, source)
    require("ui.themes.widgets.input"):new{
        title = _("访问令牌"),
        fields = {
            {
                label = _("令牌"),
                hint = Credentials.has(source.id) and _("已保存（输入新令牌将替换）") or _("可选，用于检索私有仓库"),
                text = "",
                text_type = "password",
            },
        },
        callback = function(values)
            local token = values
            if type(values) == "table" then token = values[1] end
            if type(token) ~= "string" or token:match("^%s*$") then
                return
            end
            local ok, err = Credentials.set(source.id, token)
            if not ok then
                toast(Page.errorText(err or "id"))
                return
            end
            -- 替换令牌必须丢掉上一份身份的私有缓存，并作废在途回写。
            require("features.marketplace.catalog").onAuthChange(source.id)
            toast(_("已保存令牌。私有仓库会在下次刷新后出现。"))
            redraw(desktop)
        end,
    }:show()
end

function Page.clearToken(desktop, source)
    confirm{
        title = _("清除令牌"),
        text = _("清除此来源的令牌？之后将按匿名方式检索，已缓存的私有条目会被移除。"),
        ok_text = _("清除"),
        ok_callback = function()
            Credentials.clear(source.id)
            Catalog.onAuthChange(source.id)
            redraw(desktop)
        end,
    }
end

function Page.manageSources(desktop)
    require("desktop.pages.setting.overlay").push(desktop, {
        title = _("来源"),
        right_icon = "add",
        right_callback = function() Page.addSource(desktop) end,
        sections = function()
            return Page.sourceSections(desktop)
        end,
    })
end

local function pluginRoot(desktop)
    return desktop and desktop.plugin and desktop.plugin.path
end

local function warningText(plan)
    local text = T(_("即将安装「%1」%2。这是第三方代码，不是月读官方插件。请自行确认来源可信后再继续。月读只会安装到声明的插件目录，不会覆盖 book.koplugin。"), plan.title, plan.version)
    if plan.digest_missing then
        text = text .. "\n\n" .. _("此 Release 没有 SHA-256 校验值。安装时只会直连官方下载地址并核对文件名，不能校验文件内容。这不是数字签名，也无法证明包没被篡改。")
    end
    return text
end

local function afterInstalled(desktop)
    confirm{
        title = _("安装完成"),
        text = _("插件已安装到本地。需要重启 KOReader 后才会加载。现在重启？"),
        ok_text = _("重启"),
        cancel_text = _("稍后"),
        ok_callback = function()
            require("ui/uimanager"):nextTick(require("utils.restart").now)
        end,
    }
    redraw(desktop)
end

local function startInstall(desktop, plan, plugin)
    toast(_("正在下载并安装…"))
    local opts = {}
    if plan.source_id then
        opts.token = Credentials.get(plan.source_id)
        opts.auth_origin = plan.auth_origin
        opts.auth_scheme = plan.auth_scheme
        opts.auth_id = plan.source_id
    end
    MarketInstall.perform(plan, opts, function(ok, err)
        if ok then
            if plugin and plan.name then
                local remembered, remember_err = Installed.remember(plugin, plan.name)
                if not remembered then
                    toast(Page.errorText(remember_err == "write" and "write" or "record"))
                end
            end
            afterInstalled(desktop)
            return
        end
        toast(Page.errorText(err))
    end)
end

function Page.installPlugin(desktop, plugin)
    if not plugin.has_topic then
        confirm{
            title = plugin.repo,
            text = reasonText(plugin) .. "\n\n" .. markHint(),
        }
        return
    end
    local root = pluginRoot(desktop)
    local mod = Adapters.forPlugin(plugin)
    if not mod then
        toast(Page.errorText("type"))
        return
    end
    toast(_("正在读取 Release…"))
    local source = {
        type = plugin.type, host = plugin.host, owner = plugin.owner, repo = plugin.repo,
        kind = "repo", id = plugin.source_id, token = Credentials.get(plugin.source_id),
    }
    Page.cancelPending()
    local job
    job = mod.listReleases(source, function(releases, err)
        if release_job ~= job then return end
        release_job = nil
        if err then
            toast(Page.errorText(err))
            return
        end
        local release, asset = MarketInstall.match(plugin, releases)
        if not release then
            confirm{
                title = Catalog.displayTitle(plugin),
                text = Page.errorText("no_release"),
            }
            return
        end
        local plan, plan_err = MarketInstall.plan(plugin, release, asset, root)
        if not plan then
            confirm{
                title = Catalog.displayTitle(plugin),
                text = Page.errorText(plan_err),
            }
            return
        end
        confirm{
            title = plan.title,
            text = warningText(plan),
            ok_text = _("安装"),
            ok_callback = function() startInstall(desktop, plan, plugin) end,
        }
    end)
    release_job = job
end

--- 详情底栏主按钮文案：未安装为安装，已安装为重装，可判断更新时为更新。不自动执行。
---@param plugin table
---@param plugin_root string|nil
---@param kind string|nil
---@return string
function Page.actionLabel(plugin, plugin_root, kind)
    if kind == "updates" then return _("更新") end
    local name = Installed.pluginDir(plugin)
    local loc = name and plugin_root and Installed.index(plugin_root)[name]
    if not loc or loc.reserved then return _("安装") end
    if Catalog.isNewer(Catalog.catalogVersion(plugin), loc.version) then
        return _("更新")
    end
    return _("重装")
end

local function pluginStatus(item, locals)
    local name = Installed.pluginDir(item)
    local loc = name and locals[name]
    if not loc or loc.reserved then return nil end
    if Catalog.isNewer(Catalog.catalogVersion(item), loc.version) then
        return _("更新")
    end
    return _("已安装")
end

--- 打开 README 详情：底部固定取消与安装/重装/更新，不直接安装。
function Page.showReadme(desktop, plugin, opts)
    opts = opts or {}
    local title = Catalog.displayTitle(plugin) or plugin.repo
    local action_text = opts.action_text or Page.actionLabel(plugin, pluginRoot(desktop), opts.kind)
    local closed = false
    local job, unwatch, dialog
    local Readme = require("features.marketplace.readme")
    local Viewer = require("features.marketplace.viewer")
    local Markdown = require("features.marketplace.markdown")
    local function close()
        if closed then return end
        closed = true
        if unwatch then unwatch() end
        if job and job.cancel then job.cancel() end
    end
    local function apply(item, err)
        if closed or not dialog or not dialog.setContent then return end
        if item and type(item.text) == "string" then
            dialog:setContent({
                text = item.text,
                html = Markdown.toHtml(item.text, { link_base = Markdown.linkBase(plugin) }),
                css = Markdown.CSS,
            })
            return
        end
        local message
        if err == "missing" or err == "not_found" then
            message = _("这个仓库没有可读的 README。")
        elseif err == "forbidden" then
            message = _("无权查看这份 README。这份内容已从缓存中移除。")
        else
            message = _("无法加载 README。") .. "\n" .. Page.errorText(err)
        end
        dialog:setContent({ text = message, html = "", css = "" })
    end
    dialog = Viewer.open({
        title = title,
        text = _("正在加载 README…"),
        css = Markdown.CSS,
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    if dialog and dialog.dismiss then dialog:dismiss() end
                end,
            },
            {
                text = action_text,
                variant = "primary",
                callback = function()
                    Page.installPlugin(desktop, plugin)
                end,
            },
        },
        on_link = Viewer.defaultLink,
        on_close = close,
    })
    unwatch = Readme.watch(function(event)
        if closed then return end
        if event and event.source_id == plugin.source_id and plugin.private then
            apply(nil, "forbidden")
        end
    end)
    local cached = Readme.get(plugin)
    if cached then
        apply(cached)
        return dialog
    end
    job = Readme.fetch(plugin, apply)
    return dialog
end

function Page.openPlugin(desktop, plugin, kind)
    return Page.showReadme(desktop, plugin, {
        kind = kind,
        action_text = Page.actionLabel(plugin, pluginRoot(desktop), kind),
    })
end

function Page.nav(desktop, width)
    local Tabs = require("ui.themes.widgets.tabs")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Theme = require("ui.themes")
    local filter = Page.filter()
    local trailing
    if filter.tab == "browse" then
        local pad = Theme.px(Theme.current().space.lg)
        local category = Tabs.action({
            icon = "category",
            text = filter.topic ~= "" and filter.topic or _("分类"),
            accent = filter.topic ~= "",
            on_tap = function() Page.chooseTopic(desktop) end,
        })
        local search = Tabs.action({
            icon = "search",
            text = filter.q ~= "" and filter.q or _("搜索"),
            accent = filter.q ~= "",
            on_tap = function() Page.search(desktop) end,
        })
        trailing = HorizontalGroup:new{ align = "center", category, HorizontalSpan:new{ width = pad }, search }
        if filter.q ~= "" or filter.topic ~= "" then
            trailing[#trailing + 1] = HorizontalSpan:new{ width = pad }
            trailing[#trailing + 1] = Tabs.action({
                text = _("清除筛选"),
                on_tap = function() Page.clearFilters(desktop) end,
            })
        end
    end
    return Tabs.row({
        width = width,
        tabs = {
            { id = "browse", text = _("浏览") },
            { id = "installed", text = _("已安装") },
            { id = "updates", text = _("更新") },
        },
        active = filter.tab,
        on_tab = function(id) Page.setTab(id, desktop) end,
        trailing = trailing,
    })
end


function Page.sourceSections(desktop)
    local sources = Sources.list()
    if #sources == 0 then
        return {{
            title = _("来源"),
            rows = {
                function(iw)
                    return Row.widget{
                        width = iw, title = _("还没有来源"),
                        subtitle = _("点右上角添加 GitHub、Gitea 或 GitLab 平台。默认站点只在首次安装时写入一次。"),
                    }
                end,
            },
        }}
    end
    local sections = {}
    for _idx, source in ipairs(sources) do
        local current = source
        local rows = {}
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = Sources.hostLabel(current),
                subtitle = Sources.typeLabel(current.type) or current.type,
                status = Credentials.has(current.id) and _("已配置令牌") or _("匿名"),
            }
        end
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = Credentials.has(current.id) and _("更换令牌") or _("设置令牌"),
                subtitle = _("令牌只发给对应主机，不会写入目录缓存或日志。"),
                callback = function() Page.setToken(desktop, current) end,
            }
        end
        if Credentials.has(current.id) then
            rows[#rows + 1] = function(iw)
                return Row.widget{
                    width = iw, title = _("清除令牌"),
                    callback = function() Page.clearToken(desktop, current) end,
                }
            end
        end
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw, title = _("删除来源"),
                callback = function() Page.removeSource(desktop, current) end,
            }
        end
        sections[#sections + 1] = { title = Sources.label(current), rows = rows }
    end
    return sections
end

local function browseRows(desktop)
    local filter = Page.filter()
    local rows = {}
    if Catalog.isRefreshing() then
        rows[#rows + 1] = function(iw)
            return Row.widget{ width = iw, title = _("正在刷新…") }
        end
    elseif Catalog.lastError() then
        rows[#rows + 1] = function(iw)
            return Row.widget{ width = iw, title = Page.errorText(Catalog.lastError()) }
        end
    end
    local listed = {}
    for _idx, item in ipairs(Catalog.filter(Catalog.plugins(), filter.q, filter.topic)) do
        if Catalog.isListed(item) then listed[#listed + 1] = item end
    end
    if #Sources.list() == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw, title = _("还没有来源"),
                subtitle = _("点右上角添加来源，或使用内置站点刷新。"),
            }
        end
        return rows
    end
    if #listed == 0 then
        local empty_title = (filter.q ~= "" or filter.topic ~= "") and _("没有匹配的插件") or _("还没有可浏览的扩展")
        local empty_sub = (filter.q ~= "" or filter.topic ~= "")
            and _("搜索只在已缓存的索引里进行，不会在每次输入时访问网络。可以清除筛选或手动刷新。")
            or (markHint() .. " " .. _("列表来自上次刷新的本地缓存，打开页面不会自动全网重扫。"))
        rows[#rows + 1] = function(iw)
            return Row.widget{ width = iw, title = empty_title, subtitle = empty_sub }
        end
        return rows
    end
    local locals = Installed.index(pluginRoot(desktop))
    for _idx, item in ipairs(listed) do
        local plugin = item
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = Catalog.displayTitle(plugin),
                subtitle = Catalog.displayDescription(plugin),
                status = pluginStatus(plugin, locals),
                callback = function() Page.openPlugin(desktop, plugin, "browse") end,
            }
        end
    end
    return rows
end

local function installedRows(desktop)
    local rows = {}
    local root = pluginRoot(desktop)
    local matched = Installed.supported(root, Catalog.plugins())
    if #matched == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw, title = _("还没有已安装的市场插件"),
                subtitle = _("已安装列表只显示市场支持、并能与本机安装记录或目录条目核对的插件。其他 KOReader 插件不会出现在这里。"),
            }
        end
        return rows
    end
    for _idx, entry in ipairs(matched) do
        local current = entry
        local desc = current.local_plugin.description or Catalog.displayDescription(current.plugin)
        local status = _("已安装")
        if Catalog.isNewer(Catalog.catalogVersion(current.plugin), current.local_plugin.version) then
            status = _("更新")
        end
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = current.local_plugin.title or Catalog.displayTitle(current.plugin),
                subtitle = desc,
                status = status,
                callback = function() Page.openPlugin(desktop, current.plugin, "installed") end,
            }
        end
    end
    return rows
end

local function updateRows(desktop)
    local rows = {}
    local root = pluginRoot(desktop)
    local local_index = Installed.index(root)
    local updates = {}
    for _idx, item in ipairs(Catalog.plugins()) do
        if item.has_topic == true then
            local name = Installed.pluginDir(item)
            local local_plugin = name and local_index[name]
            local remote = Catalog.catalogVersion(item)
            local installed = local_plugin and local_plugin.version
            if local_plugin and not local_plugin.reserved and Catalog.isNewer(remote, installed) then
                updates[#updates + 1] = {
                    plugin = item,
                    installed = installed,
                    remote = remote,
                }
            end
        end
    end
    if #updates == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw, title = _("没有可判断的更新"),
                subtitle = _("只有本地和目录里都能解析出版本、且目录版本更新的插件才会出现在这里。检查更新不会自动安装。"),
            }
        end
        return rows
    end
    for _idx, entry in ipairs(updates) do
        local current = entry
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = Catalog.displayTitle(current.plugin),
                subtitle = Catalog.displayDescription(current.plugin),
                status = _("更新"),
                callback = function() Page.openPlugin(desktop, current.plugin, "updates") end,
            }
        end
    end
    return rows
end

function Page.sections(desktop)
    local filter = Page.filter()
    local sections = {}
    if filter.tab == "installed" then
        sections[#sections + 1] = { title = _("已安装"), rows = installedRows(desktop) }
    elseif filter.tab == "updates" then
        sections[#sections + 1] = { title = _("更新"), rows = updateRows(desktop) }
    else
        sections[#sections + 1] = { title = _("浏览"), rows = browseRows(desktop) }
    end
    return sections
end

return Page
