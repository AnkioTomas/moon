--[[--
Kavita 源设置：服务器地址、API Key、书库选择、测试连接。
配置经月读 utils.settings.getSource / saveSource("ext.kavita") 落盘。

@module moonsource_kavita.setting
--]]

local Text = require("utils.text")
local Cache = require("moonsource_kavita.cache")
local _ = require("gettext")
local T = require("ffi/util").template

local ID = "ext.kavita"

local Setting = {}

---@return table
local function config()
    return require("utils.settings").getSource(ID)
end

---@param text string
local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

--- 落盘并重建源实例，让新地址 / Key / 书库立即生效，设置页随之刷新。
--- 保存后把配置镜像给 kamare（02 A5 第二处）；kamare 侧失败只提示，不阻断 moon 自己的保存。
---@param cfg table
local function save(cfg)
    require("utils.settings").saveSource(ID, cfg)
    local configured = (cfg.base_url or "") ~= "" and (cfg.api_key or "") ~= ""
    if configured and Cache.probe().ok then
        local server_key, code = Cache.registerServer(cfg.base_url, cfg.api_key)
        if not server_key or code then toast(_("无法同步配置到 kamare")) end
    end
    require("source.registry").reload()
end

--- 未配置 / 断网当场提示；否则带忙碌提示调 fn(client, done)，fn 结束时必须调 done()。
---@param fn fun(client: KavitaClient, done: fun())
local function withServer(fn)
    local client = require("moonsource_kavita.client").new(config())
    if not client:configured() then
        toast(_("请先填写服务器地址和 API Key"))
        return
    end
    if not require("ui/network/manager"):isConnected() then
        toast(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    local busy = require("ui.themes.widgets.toast"):new{ text = _("正在连接 Kavita…"), dismissable = false }
    busy:show()
    fn(client, function() busy:close() end)
end

---@param key string
---@param title string
---@param hint string
---@param password boolean
---@param normalize fun(value: string|nil): string
---@param icon string
---@return fun(iw: number): table
local function field(key, title, hint, password, normalize, icon)
    return function(iw)
        local value = config()[key] or ""
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = icon, title = title,
            status = value ~= "" and (password and "******" or value) or _("未设置"),
            status_on = value ~= "",
            callback = function()
                local cfg = config()
                require("ui.themes.widgets.input"):new{
                    title = title,
                    fields = { { text = cfg[key] or "", hint = hint, text_type = password and "password" or nil } },
                    ok_text = _("保存"),
                    callback = function(input)
                        cfg[key] = normalize(input)
                        save(cfg)
                    end,
                }:show()
            end,
        })
    end
end

--- 多选书库：只同步选中的库，书架分类即库名。
local function pickLibraries()
    withServer(function(client, done)
        client:json("GET", "/api/Library/libraries", nil, nil, function(libraries, err)
            done()
            if not libraries then
                toast(err)
                return
            end
            local cfg = config()
            local chosen = cfg.libraries or {}
            local items = {}
            for _idx, lib in ipairs(libraries) do
                local id = tostring(lib.id)
                items[#items + 1] = { text = lib.name or id, value = id, checked = chosen[id] == true }
            end
            require("ui.themes.widgets.list"):new{
                title = _("选择书库"),
                multi = true,
                items = items,
                close_callback = function()
                    local picked = {}
                    for _idx, item in ipairs(items) do
                        if item.checked then picked[item.value] = true end
                    end
                    cfg.libraries = picked
                    save(cfg)
                end,
            }:show()
        end)
    end)
end

--- 请求超时（秒）：全量书架（all-v2）在慢设备 / 慢服务器上一次要几十秒，
--- 硬上限会让整轮同步中断、书架永远加载不出来。留个设置行按设备调大。
---@return fun(iw: number): table
local function timeoutRow()
    return function(iw)
        local client = require("moonsource_kavita.client")
        local value = tonumber(config().timeout) or client.DEFAULT_TIMEOUT
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "hourglass_top", title = _("请求超时"),
            status = T(_("%1 秒"), value),
            status_on = value ~= client.DEFAULT_TIMEOUT,
            callback = function()
                local cfg = config()
                require("ui.themes.widgets.input"):new{
                    title = _("请求超时"),
                    fields = { {
                        text = tostring(tonumber(cfg.timeout) or client.DEFAULT_TIMEOUT),
                        hint = _("秒，慢设备 / 慢服务器调大"),
                        input_type = "number",
                    } },
                    ok_text = _("保存"),
                    callback = function(input)
                        local seconds = math.floor(tonumber(input) or 0)
                        -- 空 / 非正数回默认值；正数交给 Client 收敛到合法区间（5–600）。
                        cfg.timeout = seconds > 0 and seconds or nil
                        save(cfg)
                    end,
                }:show()
            end,
        })
    end
end

--- 进度心跳间隔（秒）：Kavita 的阅读会话时长 = 相邻两次进度写入的间隔，只在关书推一次会是
--- 0 秒会话；阅读期按这个间隔补推当前位置。0 = 关闭（关书 / 切章 / 休眠的推送不受影响）。
---@return fun(iw: number): table
local function heartbeatRow()
    return function(iw)
        local Source = require("moonsource_kavita.source")
        local default = Source.DEFAULT_HEARTBEAT_INTERVAL
        local value = tonumber(config().heartbeat_interval) or default
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "favorite", title = _("进度心跳间隔"),
            -- 行副标题是单行截断的（TextWidget 带 max_width 不换行），这行还有状态与箭头，
            -- 右边留给文字的位置很窄：副标题必须短，长解释放不进来。
            subtitle = _("阅读时补推进度，0 关闭"),
            status = value > 0 and T(_("%1 秒"), value) or _("已关闭"),
            status_on = value > 0,
            callback = function()
                local cfg = config()
                require("ui.themes.widgets.input"):new{
                    title = _("进度心跳间隔"),
                    fields = { {
                        text = tostring(tonumber(cfg.heartbeat_interval) or default),
                        hint = _("秒，0 = 关闭；Kavita 按写入间隔算阅读时长"),
                        input_type = "number",
                    } },
                    ok_text = _("保存"),
                    callback = function(input)
                        local seconds = tonumber(input)
                        -- 空 / 非数字回默认值；0（或负数）交给源当成关闭。
                        if not seconds or seconds < 0 then
                            cfg.heartbeat_interval = nil
                        else
                            cfg.heartbeat_interval = math.floor(seconds)
                        end
                        save(cfg)
                    end,
                }:show()
            end,
        })
    end
end

--- 增强版是否带清理接口（03 A）：只有 chapters + delete 才能按章删除。
--- 缺任一项就是「旧接口」，设置行与详情页都据此降级。
---@param probe table
---@return boolean
local function cleanupReady(probe)
    local caps = probe.capabilities or {}
    return caps.chapters == true and caps.delete == true
end

--- 五态文案（02 A8）：镜像失败优先于「增强版」，其余按探测态。
--- 增强版再分「能力齐 / 旧接口」两态（03 A 七态矩阵）；旧接口不高亮。
--- 行副标题只留结论，API 版本 / 能力清单不再展示（用户不需要，也会误导）。
---@param probe table
---@return string, boolean
local function cacheStatus(probe)
    if probe.state == "enhanced" then
        if Cache.mirrorFailed() then return _("配置同步失败"), false end
        local ready = cleanupReady(probe)
        if probe.version then
            return ready and T(_("增强版 v%1"), probe.version)
                or T(_("增强版 v%1（旧接口）"), probe.version), ready
        end
        return ready and _("增强版") or _("增强版（旧接口）"), ready
    elseif probe.state == "incompatible" then
        return _("版本不兼容"), false
    elseif probe.state == "official" then
        return _("官方版（无缓存接口）"), false
    end
    return _("未安装 / 未启用"), false
end

--- 测试连接结果：结论一行 + 明细一行或多行（Toast 用 TextBoxWidget，换行生效）。
---@param headline string
---@param detail string|nil
---@return string
local function connectResult(headline, detail)
    return detail and (headline .. "\n" .. detail) or headline
end

local function testConnection()
    withServer(function(client, done)
        client:request("GET", "/api/Plugin/version", { apiKey = client.api_key }, nil, function(version, err)
            done()
            local major, minor = (version or ""):match("^(%d+)%.(%d+)")
            if not major then
                toast(connectResult(err and _("连接失败") or _("连接正常"),
                    err or _("无法识别 Kavita 版本")))
            elseif tonumber(major) == 0 and tonumber(minor) < 9 then
                toast(connectResult(_("连接正常"),
                    T(_("Kavita %1 过旧，需要 0.9 及以上"), Text.trim(version))))
            else
                -- 连上服务器不等于缓存能用：kamare 才是缓存的执行者，顺手报它的状态。
                local status = cacheStatus(Cache.probe())
                toast(table.concat({
                    _("连接正常"),
                    T(_("Kavita %1"), Text.trim(version)),
                    T(_("kamare %1"), status),
                }, "\n"))
            end
        end)
    end)
end

---@return fun(iw: number): table
local function libraryRow()
    return function(iw)
        local count = 0
        for _id in pairs(config().libraries or {}) do count = count + 1 end
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "library_books", title = _("书库"),
            status = count > 0 and T(_("%1 个"), count) or _("未选择"),
            status_on = count > 0,
            callback = pickLibraries,
        })
    end
end

---@return fun(iw: number): table
local function testRow()
    return function(iw)
        return require("ui.themes.widgets.row").widget({
            width = iw,
            kind = "action", icon = "network_check", title = _("测试连接"),
            subtitle = _("同时检查漫画缓存插件"),
            callback = testConnection,
        })
    end
end

--- 路径展示归一：KOReader 的 data 目录插件路径常带 `//`（`plugins//x.koplugin`），
--- 文件系统不介意，但显示给人看要干净（安装说明里的目录也会被复制去用）。
---@param path string
---@return string
local function tidyPath(path)
    return (path:gsub("/+", "/"))
end

--- 插件安装目录（09）：kamare 已装用它当前所在目录（就地替换），否则用 moon 自己的。
---@param plugin table|nil
---@return string
local function pluginsDir(plugin)
    local path = Cache.probe().path
    local installed = type(path) == "string" and tidyPath(path):match("^(.*)/[^/]+%.koplugin/")
    if installed then return installed end
    local own = plugin and plugin.path
    if type(own) == "string" and own ~= "" then
        own = tidyPath(own):gsub("/+$", "")
        return own:match("^(.*)/[^/]+$") or own
    end
    local source = debug.getinfo(1, "S").source
    if type(source) == "string" and source:sub(1, 1) == "@" then source = source:sub(2) end
    local module_dir = source:match("^(.*)/[^/]+$")
    local root = module_dir and module_dir:match("^(.*)/[^/]+$")
    if root then return root:match("^(.*)/[^/]+$") or root end
    return module_dir or "plugins"
end

--- 只读占用：summary / summaryAll；能力缺失或读失败返回 nil。
local function usageFor(configured)
    if not Cache.available("summary") then return nil end
    local usage = configured and Cache.summary() or Cache.summaryAll()
    return type(usage) == "table" and usage or nil
end

--- 多行说明段（安装说明）：设置行的 rows 是构建函数，这里返回一个带内边距的文本块。
local function textRow(text)
    return function(iw)
        local Theme = require("ui.themes")
        local Geom = require("ui/geometry")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local TextBlock = require("ui/themes/widgets/text")
        local t = Theme.current()
        local pad = Theme.px(t.space.md)
        local box = TextBlock.box("caption", text, iw - pad * 2,
            { color = t.color.muted, bg = t.color.page })
        return CenterContainer:new{
            dimen = Geom:new{ w = iw, h = box:getSize().h },
            box,
            text = text,
        }
    end
end

--- 设置行的构建函数（sections 每次重绘都按新宽度重建）。
local function mk(opts)
    return function(iw)
        opts.width = iw
        return require("ui.themes.widgets.row").widget(opts)
    end
end

local function installText(plugin)
    local dir = pluginsDir(plugin)
    return table.concat({
        _("获取增强版"),
        _("  发布页：github.com/backtracker/kamare.koplugin/releases/latest"),
        T(_("  下载 kamare.koplugin.zip，解压后把 kamare.koplugin/ 放进：%1"), dir),
        _("  重启 KOReader。包里要有 kamarecache.lua（没有就是官方版）；"),
        _("  增强版与官方版目录同名，不能共存；替换前先删掉旧的 kamare.koplugin/。"),
        T(_("  如该目录不可写，可改用：%1"),
            tidyPath(require("datastorage"):getDataDir() .. "/plugins")),
        "",
        _("增强版提供：缓存（离线阅读与清理）、双页拆分、裁切边框。"),
    }, "\n")
end

local function refreshOverlay(plugin)
    local desktop = plugin and plugin.desktop
    if desktop and desktop.settings_overlay then desktop.settings_overlay:updateView() end
end

--- 删除后复查：请求里属于「删除前已缓存」的章如果还在，就是没删掉。
local function leftoverCount(entries, ids)
    local wanted = {}
    for __, id in ipairs(ids or {}) do wanted[tostring(id)] = true end
    local left = 0
    for __, entry in ipairs(type(entries) == "table" and entries or {}) do
        if wanted[tostring(entry.chapterId)] then left = left + 1 end
    end
    return left
end

--- 同步删除期间的忙碌窗（05 A）：kamare 直接写盘，主线程会停住；
--- 先画出来再动手，否则用户看不到任何反馈（与维护页导入统计同一套做法）。
---@param title string
---@param fn fun(): boolean|nil, string|nil, string|nil, any
---@return boolean|nil, string|nil, string|nil, any
local function runBusy(title, fn)
    local UIManager = require("ui/uimanager")
    local busy = require("ui.themes.widgets.progress_dialog"):new{
        title = title,
        text = _("正在清理…"),
        dismissable = false,
    }
    local result, code, message, detail = busy:showWhile(function()
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        return fn()
    end)
    busy:close()
    return result, code, message, detail
end

local function runCleanup(plugin, filter, title)
    local entries, code = Cache.chapters()
    if not entries then
        toast(Cache.message(code) or _("缓存操作失败"))
        return
    end
    local plan = Cache.plan(entries, filter)
    if plan.chapters == 0 then
        toast(filter == "read" and _("没有已读完的缓存") or _("没有可清理的缓存"))
        return
    end
    local first = filter == "read"
        and T(_("将删除 %1 章已读完的缓存（约 %2）。"), plan.chapters, Cache.sizeText(plan.bytes))
        or T(_("将删除本服务器的 %1 章（约 %2）。"), plan.chapters, Cache.sizeText(plan.bytes))
    local lines = { first }
    if plan.queued > 0 then
        lines[#lines + 1] = T(_("会中止正在下载的 %1 章，已下载的部分会被删除。"), plan.queued)
    end
    lines[#lines + 1] = _("阅读进度与 kamare journal 保留。")

    require("ui.themes.widgets.confirm"):new{
        title = title,
        text = table.concat(lines, "\n"),
        ok_text = _("清理"),
        cancel_text = _("取消"),
        ok_callback = function()
            local ok, err, message = runBusy(title, function() return Cache.delete(plan.ids) end)
            if not ok then
                toast(Cache.message(err, message))
                return
            end
            local left = leftoverCount(Cache.chapters(), plan.ids)
            if left > 0 then
                toast(T(_("已清理 %1 章，%2 章未能删除"), plan.chapters - left, left), 3)
            else
                toast(T(_("已清理 %1 章，释放约 %2"), plan.chapters, Cache.sizeText(plan.bytes)), 3)
            end
            refreshOverlay(plugin)
            if plugin and plugin.desktop then plugin.desktop:onEvent("shelf_changed") end
        end,
    }:show()
end

local function runCleanupAll(plugin)
    local usage = usageFor((config().base_url or "") ~= "")
    local chapters = usage and tonumber(usage.chapters) or 0
    local bytes = usage and tonumber(usage.used) or 0
    require("ui.themes.widgets.confirm"):new{
        title = _("清理全部缓存"),
        text = table.concat({
            T(_("将删除所有服务器（含未关联服务器）共 %1 章（约 %2）。"),
                chapters, Cache.sizeText(bytes)),
            _("此操作不可撤销，之后阅读需要重新下载。"),
            _("阅读进度与 kamare journal 保留。"),
        }, "\n"),
        ok_text = _("清理"),
        cancel_text = _("取消"),
        ok_callback = function()
            local ok, err, message, detail = runBusy(_("清理全部缓存"),
                function() return Cache.deleteAll() end)
            if not ok then
                toast(Cache.message(err, message))
                return
            end
            local freed = detail and tonumber(detail.bytes) or bytes
            toast(T(_("已清理全部缓存，释放约 %1"), Cache.sizeText(freed)), 3)
            refreshOverlay(plugin)
            if plugin and plugin.desktop then plugin.desktop:onEvent("shelf_changed") end
        end,
    }:show()
end

--- 详情页：状态 → 清理 → 维护（+ 非增强态的安装说明）。
---@param plugin table|nil
---@return BookThemeSection[]
local function cacheSections(plugin)
    local probe = Cache.probe()
    local caps = probe.capabilities or {}
    local configured = (config().base_url or "") ~= ""
    local can_plan = probe.ok and cleanupReady(probe)
    local can_all = probe.ok and caps.delete_all == true
    local usage = usageFor(configured)
    local out = {}

    local status = {
        mk({ icon = "info", title = _("版本"),
            status = probe.version or _("未知"), status_on = probe.version ~= nil, chevron = false }),
    }
    if probe.ok then
        status[#status + 1] = mk({ icon = "book", title = _("增强版功能"),
            subtitle = _("缓存（离线阅读与清理） · 双页拆分 · 裁切边框"), chevron = false })
    end
    status[#status + 1] = mk({ icon = "info", title = _("加载路径"),
        subtitle = probe.path and tidyPath(probe.path) or _("未加载"), chevron = false })
    if usage then
        local scope = configured and "" or _("（含未关联服务器）")
        status[#status + 1] = mk({
            icon = "storage", title = _("缓存占用"),
            subtitle = T(_("已用 %1%2，可用 %3"),
                Cache.sizeText(usage.used), scope, Cache.sizeText(usage.available)),
            status = T(_("%1 章"), tostring(usage.chapters or 0)),
            status_on = true, chevron = false,
        })
    end
    if probe.ok and Cache.mirrorFailed() then
        status[#status + 1] = mk({
            icon = "warning", title = _("配置同步失败"),
            subtitle = _("服务器配置没能写入 kamare，缓存操作可能找不到服务器"),
            status = _("重试同步"), chevron = false,
            callback = function()
                local cfg = config()
                local server_key, code = Cache.registerServer(cfg.base_url, cfg.api_key)
                toast(server_key and _("已重新同步配置") or Cache.message(code) or _("同步失败"))
                refreshOverlay(plugin)
            end,
        })
    end
    out[#out + 1] = { title = _("状态"), rows = status }

    --- 「清理全部」一行：跨服务器（含未关联）。统计得到 0 章时置灰（03 待确认 3）；
    --- 拿不到 summary 时不猜，保持可点（删除时以 kamare 的事实为准）。
    local function cleanupAllRow()
        local count = usage and tonumber(usage.chapters) or nil
        local empty = count ~= nil and count <= 0
        return mk({
            icon = "delete", title = _("清理全部"),
            subtitle = usage
                and T(_("含未关联服务器 · %1 章 · 约 %2"), tostring(usage.chapters or 0),
                    Cache.sizeText(usage.used))
                or _("含未关联服务器"),
            enabled = not empty,
            chevron = not empty,
            callback = function() runCleanupAll(plugin) end,
        })
    end

    if can_plan and configured then
        local entries = Cache.chapters() or {}
        local read_plan = Cache.plan(entries, "read")
        local all_plan = Cache.plan(entries, "all")
        local cleanup = {
            mk({
                icon = "delete", title = _("清理已读"),
                subtitle = read_plan.chapters > 0
                    and T(_("%1 章 · 约 %2"), read_plan.chapters, Cache.sizeText(read_plan.bytes))
                    or _("没有可清理的缓存"),
                enabled = read_plan.chapters > 0,
                chevron = read_plan.chapters > 0,
                callback = function() runCleanup(plugin, "read", _("清理已读")) end,
            }),
            mk({
                icon = "delete", title = _("清理本服务器"),
                subtitle = all_plan.chapters > 0
                    and T(_("%1 章 · 约 %2"), all_plan.chapters, Cache.sizeText(all_plan.bytes))
                    or _("没有可清理的缓存"),
                enabled = all_plan.chapters > 0,
                chevron = all_plan.chapters > 0,
                callback = function() runCleanup(plugin, "all", _("清理本服务器")) end,
            }),
        }
        if can_all then
            cleanup[#cleanup + 1] = cleanupAllRow()
        end
        out[#out + 1] = { title = _("清理"), rows = cleanup }
    elseif can_all and not configured then
        out[#out + 1] = { title = _("清理"), rows = {
            mk({ icon = "info", title = _("未配置服务器"),
                subtitle = _("填写服务器地址与 API Key 后，可按服务器清理已读或全部缓存"),
                chevron = false }),
            cleanupAllRow(),
        } }
    elseif probe.ok and not can_plan then
        out[#out + 1] = { title = _("清理"), rows = {
            mk({ icon = "info", title = _("当前 kamare 没有清理接口"),
                subtitle = _("升级到带 chapters / delete_all 的版本后才能清理"),
                chevron = false }),
        } }
    end

    out[#out + 1] = { title = _("维护"), rows = {
        mk({
            icon = "refresh", title = _("重新检测"),
            subtitle = _("重新探测 kamare 的版本与能力"),
            chevron = false,
            callback = function()
                Cache.reprobe()
                refreshOverlay(plugin)
            end,
        }),
    } }

    if not probe.ok then
        local rows = {}
        if probe.state == "incompatible" and probe.api_version then
            rows[#rows + 1] = mk({
                icon = "warning", title = _("版本不兼容"),
                subtitle = T(_("kamare API v%1 与当前支持的 v1 不兼容"), tostring(probe.api_version)),
                chevron = false,
            })
        end
        rows[#rows + 1] = textRow(installText(plugin))
        out[#out + 1] = { title = _("获取增强版"), rows = rows }
    end
    return out
end

---@param plugin table|nil
local function showCachePage(plugin)
    local desktop = plugin and plugin.desktop
    if not desktop then
        toast(_("请先打开月读桌面"))
        return
    end
    require("desktop.pages.setting.overlay").push(desktop, {
        title = _("漫画缓存"),
        sections = function() return cacheSections(plugin) end,
    })
end

---@param plugin table|nil
---@return fun(iw: number): table
local function cacheRow(plugin)
    return function(iw)
        local status, on = cacheStatus(Cache.probe())
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "download_done", title = _("漫画缓存"),
            subtitle = Cache.probe().ok
                and _("清理已读、按系列或全部清理")
                or _("状态与获取增强版"),
            status = status, status_on = on,
            callback = function() showCachePage(plugin) end,
        })
    end
end

---@param value string|nil
---@return string
local function normalizeUrl(value)
    return Text.rtrimSlashes(Text.stripWhitespace(value))
end

---@param plugin table|nil 月读插件实例（取 plugin.path 定位实际安装目录）
---@return table[]
function Setting.rows(plugin)
    return {
        field("base_url", _("服务器地址"), "https://kavita.example.com", false, normalizeUrl, "dns"),
        field("api_key", _("API Key"), _("Kavita 用户设置 → API Key"), true, Text.stripWhitespace, "key"),
        libraryRow(),
        cacheRow(plugin),
        heartbeatRow(),
        timeoutRow(),
        testRow(),
    }
end

--- 远程管理「连接配置」网页上的表单；书库要连服务器挑，仍在设备上选。
Setting.remote = {
    { key = "base_url", label = _("服务器地址"), type = "url", placeholder = "https://kavita.example.com",
        normalize = normalizeUrl },
    { key = "api_key", label = _("API Key"), secret = true, normalize = Text.stripWhitespace },
}

return Setting
