--[[--
插件市场页面：浏览 / 已安装 / 更新，基于 moon-store.ankio.net 本地缓存搜索与分类筛选。

@module koplugin.book.features.marketplace.page
--]]

require("l10n").apply()

local _ = require("gettext")
local T = require("ffi/util").template
local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local Catalog = require("features.marketplace.catalog")
local MarketInstall = require("features.marketplace.install")
local Installed = require("features.marketplace.installed")

local Page = {}

--- 详情在途请求（点击安装但列表条目缺资产时补拉详情）。
local detail_job

--- 市场叠层打开期间复用本机插件扫描快照，避免翻页/切页签/点详情反复扫盘。
local scan_cache = { root = nil, list = nil, map = nil }

local function clearScanCache()
    scan_cache.root = nil
    scan_cache.list = nil
    scan_cache.map = nil
end

---@param root string|nil
---@return table[], table<string, table>
local function localScan(root)
    if type(root) ~= "string" or root == "" then return {}, {} end
    if scan_cache.root == root and scan_cache.list and scan_cache.map then
        return scan_cache.list, scan_cache.map
    end
    local list = Installed.scan(root)
    local map = {}
    for _idx, item in ipairs(list) do
        map[item.name] = item
    end
    scan_cache.root = root
    scan_cache.list = list
    scan_cache.map = map
    return list, map
end

local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

local function confirm(opts)
    require("ui.themes.widgets.confirm"):new(opts):show()
end

local function redraw(desktop, reset_page)
    if desktop and not desktop.closed and desktop.settings_overlay then
        if reset_page then desktop.settings_overlay.page = 1 end
        desktop.settings_overlay:updateView()
    end
end

local ERRORS = {
    rate_limit = _("接口请求过于频繁，已保留上次列表。请稍后再刷新。"),
    not_found = _("找不到对应的插件信息。"),
    forbidden = _("插件市场暂时拒绝访问，请稍后再试。"),
    network = _("网络请求失败，已保留上次列表。"),
    not_json = _("插件市场返回了无效数据，请稍后再试。"),
    plugin = _("无法确定插件目录名，不能安装。"),
    reserved = _("不能安装或覆盖月读核心（book.koplugin）。"),
    asset = _("没有可用的 zip 安装包，不能安装。"),
    unsafe_url = _("下载地址无效，已拒绝。"),
    no_release = _("这个插件还没有可安装的 Release 安装包。"),
    busy = _("正在安装另一个插件，请稍候。"),
    download = _("下载失败。"),
    plugin_root = _("无法确定插件安装目录。"),
    write = _("无法写入本地缓存。"),
    record = _("插件已安装，但安装记录未能保存。"),
    delete = _("无法删除这个插件。"),
    settings = _("无法修改插件的停用状态。"),
    missing = _("插件目录已经不在了。"),
    ["not a koplugin archive"] = _("压缩包里没有合法的 .koplugin 目录，不能安装。"),
    ["multiple koplugin directories"] = _("压缩包里包含多个 .koplugin 目录，无法自动安装。"),
}

function Page.errorText(err)
    local code = type(err) == "table" and err.code or err
    local text = ERRORS[code]
    if text then return text end
    if code or err then
        return T(_("操作失败：%1"), tostring(code or err))
    end
    return _("操作失败。")
end

local DEFAULT_KIND = "moon"

local function filterData()
    local data = Settings.get("features.marketplace")
    if type(data.filter) ~= "table" then
        data.filter = { tab = "browse", q = "", category = "", kind = DEFAULT_KIND }
    end
    return data
end

function Page.filter()
    local data = filterData()
    local tab = data.filter.tab
    if tab ~= "installed" and tab ~= "updates" then tab = "browse" end
    local kind = data.filter.kind
    if kind ~= "" and kind ~= "moon" and kind ~= "koreader" then kind = DEFAULT_KIND end
    return {
        tab = tab,
        q = type(data.filter.q) == "string" and data.filter.q or "",
        category = type(data.filter.category) == "string" and data.filter.category or "",
        kind = kind,
    }
end

local function updateFilter(desktop, patch)
    local f = Page.filter()
    for k, v in pairs(patch) do f[k] = v end
    local data = filterData()
    data.filter.tab, data.filter.q, data.filter.category, data.filter.kind = f.tab, f.q, f.category, f.kind
    Settings.save("features.marketplace")
    redraw(desktop, true)
end

function Page.setTab(tab, desktop)
    updateFilter(desktop, { tab = (tab == "installed" or tab == "updates") and tab or "browse" })
end

function Page.setQuery(query, desktop)
    updateFilter(desktop, { q = type(query) == "string" and query or "" })
end

function Page.setCategory(category, desktop)
    updateFilter(desktop, { category = type(category) == "string" and category or "" })
end

function Page.setKind(kind, desktop)
    updateFilter(desktop, { kind = (kind == "" or kind == "moon" or kind == "koreader") and kind or DEFAULT_KIND })
end

function Page.clearFilters(desktop)
    updateFilter(desktop, { q = "", category = "", kind = DEFAULT_KIND })
end

function Page.cancelPending()
    if detail_job and detail_job.cancel then
        detail_job.cancel()
    end
    detail_job = nil
end

function Page.onClose()
    clearScanCache()
end

function Page.refresh(desktop)
    if Catalog.isManualRefreshing() then
        toast(_("正在刷新，请稍候。"))
        return
    end
    require("features.marketplace").cancelAutoRefresh()
    clearScanCache()
    local open, cancelled = true, false
    local dialog
    local function closeProgress()
        if open and dialog and type(dialog.close) == "function" then
            dialog:close()
        end
        open = false
    end
    dialog = require("ui.themes.widgets.progress_dialog"):new{
        title = _("正在刷新"),
        text = _("正在获取插件列表…"),
        on_cancel = function()
            cancelled = true
            Catalog.cancel()
        end,
        close_callback = function()
            open = false
        end,
    }
    dialog:showWhile(function()
        Catalog.refresh(function(err)
            if cancelled then
                redraw(desktop)
                return
            end
            closeProgress()
            if not err then
                toast(_("插件列表已更新。"))
            else
                toast(Page.errorText(err))
            end
            redraw(desktop)
        end, {
            on_progress = function(done, total)
                if not open or not dialog or type(dialog.update) ~= "function" then return end
                dialog:update(_("正在获取插件列表…"), done, total)
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
            local text = type(values) == "table" and values[1] or values
            Page.setQuery(text or "", desktop)
        end,
    }:show()
end

function Page.chooseCategory(desktop)
    local current = Page.filter().category
    local items = { { text = _("全部"), value = "" } }
    for _idx, cat in ipairs(Catalog.categories()) do
        items[#items + 1] = { text = cat.name, value = cat.code }
    end
    require("ui.themes.widgets.list"):new{
        title = _("分类"),
        centered = true,
        items = items,
        current = current,
        on_select = function(value)
            Page.setCategory(value or "", desktop)
        end,
    }:show()
end

function Page.chooseKind(desktop)
    local current = Page.filter().kind
    require("ui.themes.widgets.list"):new{
        title = _("插件生态"),
        centered = true,
        items = {
            { text = _("月读插件"), value = "moon" },
            { text = _("KOReader 常规插件"), value = "koreader" },
            { text = _("全部"), value = "" },
        },
        current = current,
        on_select = function(value)
            Page.setKind(value or "", desktop)
        end,
    }:show()
end

local function pluginRoot(desktop)
    return desktop and desktop.plugin and desktop.plugin.path
end

local function warningText(plan)
    local ver = plan.version ~= "" and (" " .. plan.version) or ""
    return T(
        _("即将安装「%1」%2（%3）。这是第三方代码，不是月读官方插件，请自行确认来源可信后再继续。月读不会覆盖 book.koplugin。"),
        plan.title, ver, plan.asset_name
    ) .. "\n\n" .. _("此安装包没有 SHA-256 校验值，无法校验文件内容或证明包未被篡改。")
end

local function askRestart(title, text)
    confirm{
        title = title,
        text = text,
        ok_text = _("重启"),
        cancel_text = _("稍后"),
        ok_callback = function()
            require("ui/uimanager"):nextTick(require("utils.restart").now)
        end,
    }
end

local function afterInstalled(desktop)
    clearScanCache()
    askRestart(_("安装完成"), _("插件已安装到本地。需要重启 KOReader 后才会加载。现在重启？"))
    redraw(desktop)
end

local function pluginTitle(entry)
    return entry.local_plugin.title or Catalog.displayTitle(entry.plugin) or entry.local_plugin.name
end

local function toggleInstalled(desktop, entry, disabled)
    local ok, err = Installed.setDisabled(entry.local_plugin.name, not disabled)
    if not ok then
        toast(Page.errorText(err))
        return
    end
    clearScanCache()
    redraw(desktop)
    askRestart(pluginTitle(entry), disabled
        and _("插件已启用。需要重启 KOReader 后才会加载。现在重启？")
        or _("插件已停用。需要重启 KOReader 后才会停止加载。现在重启？"))
end

local function removeInstalled(desktop, entry)
    local title = pluginTitle(entry)
    confirm{
        title = title,
        text = T(_("确定删除「%1」？插件目录会被移除。"), title),
        ok_text = _("删除"),
        ok_callback = function()
            local removed, err = Installed.remove(pluginRoot(desktop), entry.local_plugin.name)
            if not removed then
                toast(Page.errorText(err))
                return
            end
            clearScanCache()
            redraw(desktop, true)
            askRestart(title, _("插件已删除。需要重启 KOReader 后才会卸载。现在重启？"))
        end,
    }
end

--- 已安装插件：查看说明、停用 / 启用、删除。有新版本时可以更新。
---@param desktop table
---@param entry table
---@param locals table<string, table>|nil
function Page.manage(desktop, entry, locals)
    local name = entry.local_plugin.name
    local disabled = Installed.isDisabled(name)
    local items = {
        { text = _("查看说明"), value = "readme" },
        { text = disabled and _("启用") or _("停用"), value = "toggle" },
    }
    if Catalog.isNewer(Catalog.catalogVersion(entry.plugin), entry.local_plugin.version) then
        items[#items + 1] = { text = _("更新"), value = "update" }
    end
    items[#items + 1] = { text = _("删除"), value = "delete" }
    require("ui.themes.widgets.list"):new{
        title = pluginTitle(entry),
        centered = true,
        items = items,
        on_select = function(action)
            if action == "readme" then
                Page.openPlugin(desktop, entry.plugin, "installed", locals)
            elseif action == "toggle" then
                toggleInstalled(desktop, entry, disabled)
            elseif action == "update" then
                Page.installPlugin(desktop, entry.plugin)
            elseif action == "delete" then
                removeInstalled(desktop, entry)
            end
        end,
    }:show()
end

local function finishInstall(desktop, plan, plugin, result)
    if not result.ok then
        toast(Page.errorText(result.detail))
        return
    end
    local installed_name = type(result.detail) == "string" and result.detail or Installed.pluginDir(plugin)
    if plugin and installed_name then
        local installed_ver = (plan.version ~= "" and plan.version) or (plan.tag ~= "" and plan.tag) or nil
        local remembered, remember_err = Installed.remember(plugin, installed_name, installed_ver)
        if not remembered then
            toast(Page.errorText(remember_err == "write" and "write" or "record"))
        end
    end
    afterInstalled(desktop)
end

local function startInstall(desktop, plan, plugin)
    local key_id = (type(plan.uid) == "string" and plan.uid ~= "") and plan.uid or plan.archive
    require("workers.ui.task_dialog").start{
        key = "plugin\0" .. key_id,
        kind = "download",
        title = plan.title,
        cancellable = true,
        run = function(report, done)
            return MarketInstall.perform(plan, {
                on_progress = function(bytes, total)
                    report(_("正在下载并安装…"), bytes, total)
                end,
            }, function(ok, detail)
                done({ ok = ok == true, detail = detail })
            end)
        end,
        on_done = function(result) finishInstall(desktop, plan, plugin, result) end,
    }
end

local function confirmAsset(desktop, plugin, asset)
    local plan, plan_err = MarketInstall.plan(plugin, asset, pluginRoot(desktop))
    if not plan then
        confirm{
            title = Catalog.displayTitle(plugin) or _("插件安装"),
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
end

local function chooseAndInstall(desktop, plugin)
    local assets = MarketInstall.assets(plugin)
    if #assets == 0 then
        confirm{
            title = Catalog.displayTitle(plugin) or _("插件安装"),
            text = Page.errorText("no_release"),
        }
        return
    end
    if #assets == 1 then
        confirmAsset(desktop, plugin, assets[1])
        return
    end
    local items = {}
    for _idx, asset in ipairs(assets) do
        items[#items + 1] = { text = asset.name, value = asset }
    end
    require("ui.themes.widgets.list"):new{
        title = _("选择安装包"),
        centered = true,
        items = items,
        on_select = function(asset)
            if asset then confirmAsset(desktop, plugin, asset) end
        end,
    }:show()
end

function Page.installPlugin(desktop, plugin)
    local assets = MarketInstall.assets(plugin)
    if #assets > 0 or not plugin or not plugin.uid then
        chooseAndInstall(desktop, plugin)
        return
    end
    -- 列表项若未带资产，补拉一次详情确认最新 Release。
    toast(_("正在读取插件信息…"))
    Page.cancelPending()
    local job
    job = require("features.marketplace.readme").fetch(plugin, function(item, err)
        if detail_job ~= job then return end
        detail_job = nil
        if item and type(item.detail) == "table" then
            chooseAndInstall(desktop, item.detail)
        else
            toast(Page.errorText(err or "no_release"))
        end
    end, { force = true })
    detail_job = job
end

--- 详情底栏主按钮文案：未安装为安装，已安装为重装，可判断更新时为更新。不自动执行。
---@param plugin table
---@param plugin_root string|nil
---@param tab_kind string|nil
---@param locals table<string, table>|nil
---@return string
function Page.actionLabel(plugin, plugin_root, tab_kind, locals)
    if tab_kind == "updates" then return _("更新") end
    local loc = Installed.findLocal(plugin, plugin_root, locals)
    if not loc then return _("安装") end
    if Catalog.isNewer(Catalog.catalogVersion(plugin), loc.version) then
        return _("更新")
    end
    return _("重装")
end

local function pluginStatus(item, root, locals)
    local loc = Installed.findLocal(item, root, locals)
    if not loc then return nil end
    if Catalog.isNewer(Catalog.catalogVersion(item), loc.version) then
        return _("更新")
    end
    return _("已安装")
end

local function githubLinkBase(plugin)
    if type(plugin) ~= "table" or plugin.type ~= "github" then return nil end
    local owner, repo = plugin.owner, plugin.repo
    if type(owner) ~= "string" or owner == "" or type(repo) ~= "string" or repo == "" then
        return nil
    end
    local ref = type(plugin.default_branch) == "string" and plugin.default_branch ~= "" and plugin.default_branch
        or (type(plugin.ref) == "string" and plugin.ref ~= "" and plugin.ref)
        or "HEAD"
    return "https://github.com/" .. owner .. "/" .. repo .. "/blob/" .. ref .. "/"
end

--- 打开 README 详情：底部固定取消与安装/重装/更新，不直接安装。
function Page.showReadme(desktop, plugin, opts)
    opts = opts or {}
    local active_plugin = plugin
    local title = Catalog.displayTitle(plugin) or plugin.repo or _("插件详情")
    local root = pluginRoot(desktop)
    local locals = opts.locals or (root and select(2, localScan(root)) or nil)
    local action_text = opts.action_text or Page.actionLabel(plugin, root, opts.kind, locals)
    local closed = false
    local job, dialog
    local Readme = require("features.marketplace.readme")
    local Viewer = require("features.marketplace.viewer")
    local Md2Html = require("convert.md2html")
    local function close()
        if closed then return end
        closed = true
        if job and job.cancel then job.cancel() end
    end
    local function contentFor(item, err)
        if item and type(item.detail) == "table" then
            -- 离线回落的旧 README 详情绝不能把目录里更新版本的 release_assets 盖回旧包。
            local catalog_ver = Catalog.catalogVersion(plugin)
            local detail_ver = Catalog.catalogVersion(item.detail)
                or (type(item.version) == "string" and item.version ~= "" and item.version or nil)
            if not Catalog.isNewer(catalog_ver, detail_ver) then
                active_plugin = item.detail
            end
        end
        if item and type(item.text) == "string" and item.text ~= "" then
            return {
                text = item.text,
                html = Md2Html.toHtml(item.text, { link_base = githubLinkBase(active_plugin) }),
                css = Md2Html.CSS,
            }
        end
        local fallback = Catalog.displayDescription(active_plugin)
        if item and type(fallback) == "string" and fallback ~= "" then
            return { text = fallback, html = "", css = "" }
        end
        local message
        if item or err == "missing" or err == "not_found" then
            message = _("这个插件没有可读的 README。")
        else
            message = _("无法加载 README。") .. "\n" .. Page.errorText(err)
        end
        return { text = message, html = "", css = "" }
    end
    local function apply(item, err)
        if closed or not dialog or not dialog.setContent then return end
        dialog:setContent(contentFor(item, err))
    end
    local cached = Readme.get(plugin)
    local initial = cached and contentFor(cached) or { text = _("正在加载 README…"), css = Md2Html.CSS }
    dialog = Viewer.open({
        title = title,
        text = initial.text,
        html = initial.html,
        css = initial.css,
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
                    Page.installPlugin(desktop, active_plugin)
                end,
            },
        },
        on_link = Viewer.defaultLink,
        on_close = close,
    })
    if not cached then
        job = Readme.fetch(plugin, apply)
    end
    return dialog
end

function Page.openPlugin(desktop, plugin, tab_kind, locals)
    local root = pluginRoot(desktop)
    locals = locals or (root and select(2, localScan(root)) or nil)
    return Page.showReadme(desktop, plugin, {
        kind = tab_kind,
        locals = locals,
        action_text = Page.actionLabel(plugin, root, tab_kind, locals),
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
        local cat_label = filter.category ~= "" and Catalog.categoryName(filter.category) or _("分类")
        local category = Tabs.action({
            icon = "category",
            text = cat_label,
            accent = filter.category ~= "",
            on_tap = function() Page.chooseCategory(desktop) end,
        })
        local search = Tabs.action({
            icon = "search",
            text = filter.q ~= "" and filter.q or _("搜索"),
            accent = filter.q ~= "",
            on_tap = function() Page.search(desktop) end,
        })
        trailing = HorizontalGroup:new{ align = "center", category, HorizontalSpan:new{ width = pad }, search }
        if filter.q ~= "" or filter.category ~= "" or filter.kind ~= DEFAULT_KIND then
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

local function rowHeights()
    if type(Row.height) ~= "function" then return nil, nil end
    local Theme = require("ui.themes")
    local divider = Theme.px(Theme.current().row.divider)
    return Row.height(false) + divider, Row.height(true) + divider
end

local function browseSection(desktop)
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
    local prefix = #rows
    if Catalog.count() == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = _("还没有插件列表"),
                subtitle = _("点击此处或右上角刷新按钮，从月读插件市场获取最新目录。"),
                callback = function() Page.refresh(desktop) end,
            }
        end
        return { title = _("浏览"), rows = rows }
    end
    local entries = Catalog.listIndex(filter.q, filter.category, filter.kind)
    if #entries == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = _("没有匹配的插件"),
                subtitle = _("搜索与筛选均在本地缓存中进行，可以清除筛选或手动刷新。"),
            }
        end
        return { title = _("浏览"), rows = rows }
    end
    local root = pluginRoot(desktop)
    local _list, locals = localScan(root)
    for _idx, entry in ipairs(entries) do
        local uid = entry.uid
        rows[#rows + 1] = function(iw)
            local plugin = Catalog.get(uid)
            if not plugin then return Row.widget{ width = iw, title = uid } end
            return Row.widget{
                width = iw,
                title = Catalog.displayTitle(plugin),
                subtitle = Catalog.displayDescription(plugin),
                status = pluginStatus(plugin, root, locals),
                callback = function() Page.openPlugin(desktop, plugin, "browse", locals) end,
            }
        end
    end
    local h_plain, h_sub = rowHeights()
    local row_height = h_plain and function(idx)
        if idx <= prefix then return h_plain end
        return entries[idx - prefix].has_sub and h_sub or h_plain
    end or nil
    return { title = _("浏览"), rows = rows, row_height = row_height }
end

local function installedSection(desktop)
    local rows = {}
    local root = pluginRoot(desktop)
    local locals_list, locals = localScan(root)
    -- 不传全量目录数组：直接由 SQLite 按本机目录/安装记录索引相交，只解码已装插件。
    local matched = Installed.supported(root, nil, locals_list)
    if #matched == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = _("还没有已安装的市场插件"),
                subtitle = _("已安装列表只显示市场支持、并能与本机安装记录或目录条目核对的插件。其他 KOReader 插件不会出现在这里。"),
            }
        end
        return { title = _("已安装"), rows = rows }
    end
    for _idx, entry in ipairs(matched) do
        local current = entry
        local desc = current.local_plugin.description or Catalog.displayDescription(current.plugin)
        local disabled = Installed.isDisabled(current.local_plugin.name)
        local status = disabled and _("已停用")
            or (Catalog.isNewer(Catalog.catalogVersion(current.plugin), current.local_plugin.version)
                and _("更新") or _("已安装"))
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = current.local_plugin.title or Catalog.displayTitle(current.plugin),
                subtitle = desc,
                status = status,
                callback = function() Page.manage(desktop, current, locals) end,
            }
        end
    end
    return { title = _("已安装"), rows = rows }
end

local function updateSection(desktop)
    local rows = {}
    local root = pluginRoot(desktop)
    local locals_list, locals = localScan(root)
    local matched = Installed.supported(root, nil, locals_list)
    local updates = {}
    for _idx, entry in ipairs(matched) do
        if Catalog.isNewer(Catalog.catalogVersion(entry.plugin), entry.local_plugin.version) then
            updates[#updates + 1] = entry.plugin
        end
    end
    if #updates == 0 then
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = _("没有可判断的更新"),
                subtitle = _("只有本地和目录里都能解析出版本、且目录版本更新的插件才会出现在这里。检查更新不会自动安装。"),
            }
        end
        return { title = _("更新"), rows = rows }
    end
    for _idx, plugin in ipairs(updates) do
        local current = plugin
        rows[#rows + 1] = function(iw)
            return Row.widget{
                width = iw,
                title = Catalog.displayTitle(current),
                subtitle = Catalog.displayDescription(current),
                status = _("更新"),
                callback = function() Page.openPlugin(desktop, current, "updates", locals) end,
            }
        end
    end
    return { title = _("更新"), rows = rows }
end

function Page.sections(desktop)
    local filter = Page.filter()
    if filter.tab == "installed" then
        return { installedSection(desktop) }
    end
    if filter.tab == "updates" then
        return { updateSection(desktop) }
    end
    return { browseSection(desktop) }
end

return Page
