--[[--
拆出去的书源：用过的才提示从插件市场安装。

认用过只看三处：书库里有这个 source_id（含墓碑）、settings/<id>.lua 里有键、
活跃源就是它。不看 enabled_sources（nil 表示全开，不能当作用过）。
微信读书的旧 id `wechat` 装同一个 weread 插件。

市场目录里还没有的不装、也不记成已处理，目录更新后再问。
关掉弹窗或安装失败记进 source_install_skip，不再问。离线不弹。

@module koplugin.book.features.marketplace.migrate
--]]

require("l10n").apply()

local Catalog = require("features.marketplace.catalog")
local MarketInstall = require("features.marketplace.install")
local Installed = require("features.marketplace.installed")
local Settings = require("utils.settings")
local Paths = require("utils.paths")
local DB = require("utils.db")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Migrate = {}

--- 旧内置源 id → 市场插件目录。also 是改名之前的 id，装同一个插件。
local SOURCES = {
    { id = "weread", plugin = "moonsource-weread.koplugin", name = "微信读书", also = { "wechat" } },
    { id = "qidian", plugin = "moonsource-qidian.koplugin", name = "起点中文网" },
    { id = "qqreader", plugin = "moonsource-qqreader.koplugin", name = "QQ 阅读" },
    { id = "xiaoxiang", plugin = "moonsource-xiaoxiang.koplugin", name = "潇湘书院" },
    { id = "changpei", plugin = "moonsource-changpei.koplugin", name = "长佩文学" },
    { id = "jdread", plugin = "moonsource-jdread.koplugin", name = "京东读书" },
    { id = "jjwxc", plugin = "moonsource-jjwxc.koplugin", name = "晋江文学城" },
    { id = "qimao", plugin = "moonsource-qimao.koplugin", name = "七猫小说" },
    { id = "shuqi", plugin = "moonsource-shuqi.koplugin", name = "书旗小说" },
    { id = "fanqie", plugin = "moonsource-fanqie.koplugin", name = "番茄小说" },
    { id = "dedao", plugin = "moonsource-dedao.koplugin", name = "得到" },
    { id = "ireader", plugin = "moonsource-ireader.koplugin", name = "掌阅" },
    { id = "tadu", plugin = "moonsource-tadu.koplugin", name = "塔读文学" },
    { id = "netease", plugin = "moonsource-netease.koplugin", name = "网易云阅读" },
    { id = "douban", plugin = "moonsource-douban.koplugin", name = "豆瓣读书" },
    { id = "zhihu", plugin = "moonsource-zhihu.koplugin", name = "知乎盐选" },
    { id = "kuaikan", plugin = "moonsource-kuaikan.koplugin", name = "快看漫画" },
    { id = "zymk", plugin = "moonsource-zymk.koplugin", name = "知音漫客" },
    { id = "bilimanga", plugin = "moonsource-bilimanga.koplugin", name = "哔哩哔哩漫画" },
    { id = "copymanga", plugin = "moonsource-copymanga.koplugin", name = "拷贝漫画" },
    { id = "legado", plugin = "moonsource-legado.koplugin", name = "开源阅读" },
    { id = "iread", plugin = "moonsource-iread.koplugin", name = "iRead" },
    { id = "kavita", plugin = "moonsource-kavita.koplugin", name = "Kavita" },
    { id = "bookorbit", plugin = "moonsource-bookorbit.koplugin", name = "BookOrbit" },
    { id = "18ta", plugin = "moonsource-18ta.koplugin", name = "爱看书" },
}

local offered = false

---@param id string
---@return boolean
local function skipped(id)
    local map = Settings.get("features.marketplace").source_install_skip
    return type(map) == "table" and map[id] == true
end

---@param id string
---@return boolean
local function settingsUsed(id)
    local path = Paths.sourcePath(id)
    if lfs.attributes(path, "mode") ~= "file" then return false end
    local data = require("luasettings"):open(path).data
    return type(data) == "table" and next(data) ~= nil
end

---@param id string
---@return boolean
local function booksUsed(id)
    require("book.books_db")
    local hit = DB.rowexec("SELECT 1 FROM books WHERE source_id=? LIMIT 1;", id)
    return hit ~= nil
end

---@param root string|nil
---@param dir string
---@return boolean
local function pluginPresent(root, dir)
    if type(root) ~= "string" or root == "" then return false end
    local parent = root:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return false end
    return lfs.attributes(parent .. "/" .. dir, "mode") == "directory"
end

--- 还没装、也没被用户跳过的旧书源。同一插件只出一行。
---@param root string|nil 月读插件根目录
---@return { ids: string[], plugin: string, name: string }[]
function Migrate.pending(root)
    local Registry = require("source.registry")
    local active = Settings.get("source").active_source
    local out = {}
    for _idx, spec in ipairs(SOURCES) do
        if Registry.meta(spec.id) == nil and not pluginPresent(root, spec.plugin) then
            local ids = { spec.id }
            for _j, extra in ipairs(spec.also or {}) do ids[#ids + 1] = extra end
            local used = {}
            for _k, id in ipairs(ids) do
                if not skipped(id) and (active == id or booksUsed(id) or settingsUsed(id)) then
                    used[#used + 1] = id
                end
            end
            if #used > 0 then
                out[#out + 1] = { ids = used, plugin = spec.plugin, name = spec.name }
            end
        end
    end
    return out
end

--- 目录里有可安装 zip 的进 ready，没有的进 waiting。
---@param pending { ids: string[], plugin: string, name: string }[]
---@return table[] ready
---@return table[] waiting
function Migrate.split(pending)
    local ready, waiting = {}, {}
    for _idx, item in ipairs(pending) do
        local entry = Catalog.byPluginDir(item.plugin)
        local assets = entry and MarketInstall.assets(entry) or {}
        if entry and #assets > 0 then
            item.entry = entry
            item.asset = assets[1]
            ready[#ready + 1] = item
        else
            waiting[#waiting + 1] = item
        end
    end
    return ready, waiting
end

---@param items { ids: string[] }[]
function Migrate.remember(items)
    local saved = Settings.get("features.marketplace")
    local map = saved.source_install_skip
    if type(map) ~= "table" then
        map = {}
        saved.source_install_skip = map
    end
    for _idx, item in ipairs(items) do
        for _j, id in ipairs(item.ids) do map[id] = true end
    end
    Settings.save("features.marketplace")
end

---@param items { name: string }[]
---@return string
local function namesOf(items)
    local names = {}
    for _idx, item in ipairs(items) do names[#names + 1] = item.name end
    return table.concat(names, _("、"))
end

local function askRestart()
    require("ui.themes.widgets.confirm"):new{
        title = _("安装完成"),
        text = _("插件已安装到本地。需要重启 KOReader 后才会加载。现在重启？"),
        ok_text = _("重启"),
        cancel_text = _("稍后"),
        ok_callback = function()
            require("ui/uimanager"):nextTick(require("utils.restart").now)
        end,
    }:show()
end

---@param root string
---@param ready table[]
local function installAll(root, ready)
    local failed = {}
    local installed = 0
    local function step(index)
        local item = ready[index]
        if not item then
            if #failed > 0 then
                require("ui.themes.widgets.toast"):new{
                    text = T(_("安装失败：%1"), table.concat(failed, _("、"))),
                    timeout = 4,
                }:show()
            end
            if installed > 0 then askRestart() end
            return
        end
        local plan, err = MarketInstall.plan(item.entry, item.asset, root)
        if not plan then
            failed[#failed + 1] = item.name
            step(index + 1)
            return
        end
        MarketInstall.perform(plan, {}, function(ok, detail)
            if ok then
                installed = installed + 1
                local dir = type(detail) == "string" and detail or item.plugin
                Installed.remember(item.entry, dir, plan.version ~= "" and plan.version or nil)
            else
                failed[#failed + 1] = item.name .. (detail and (" (" .. tostring(detail) .. ")") or "")
            end
            step(index + 1)
        end)
    end
    step(1)
end

---@param desk table
---@param pending table[]
local function show(desk, pending)
    local ready, waiting = Migrate.split(pending)
    if #ready == 0 then return end
    local text = T(_("这些书源已经拆成独立插件。从插件市场安装后，重启 KOReader 才能继续用：\n%1"), namesOf(ready))
    if #waiting > 0 then
        text = text .. "\n\n" .. T(_("插件市场里还没有：%1。目录更新后会再提示。"), namesOf(waiting))
    end
    local root = desk.plugin.path
    require("ui.themes.widgets.confirm"):new{
        title = _("安装书源插件"),
        text = text,
        ok_text = _("安装"),
        cancel_text = _("以后再说"),
        ok_callback = function()
            Migrate.remember(ready)
            installAll(root, ready)
        end,
        cancel_callback = function()
            Migrate.remember(ready)
        end,
    }:show()
end

--- 桌面回到前台时问一次。离线什么都不记，下次联网再看。
---@param desk table|nil
function Migrate.offer(desk)
    if offered or type(desk) ~= "table" or type(desk.plugin) ~= "table" then return end
    if not require("ui/network/manager"):isConnected() then return end
    local pending = Migrate.pending(desk.plugin.path)
    if #pending == 0 then
        offered = true
        return
    end
    local function present()
        if offered then return end
        local ready = Migrate.split(pending)
        -- 目录刚拉过仍没有可装的包：这次进程不再问。刷新被取消时不会走到这里，下次激活再试。
        if #ready == 0 then
            offered = true
            return
        end
        offered = true
        show(desk, pending)
    end
    local _ready, waiting = Migrate.split(pending)
    if #waiting > 0 and (Catalog.count() == 0 or Catalog.isStale()) then
        Catalog.refresh(function() present() end, { silent = true })
        return
    end
    present()
end

return Migrate
