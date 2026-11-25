--[[-- features.marketplace.page / setting：入口、三区、搜索/分类/生态筛选、README 详情、单包与多包安装确认。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
package.preload["ffi/util"] = function()
    return { template = function(s, a, b, c)
        return (s:gsub("%%1", a or ""):gsub("%%2", b or ""):gsub("%%3", c or ""))
    end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

local shown = {}
local function dialogModule()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            return opts
        end,
    }
end
package.preload["ui.themes.widgets.list"] = dialogModule
package.preload["ui.themes.widgets.input"] = dialogModule
package.preload["ui.themes.widgets.confirm"] = dialogModule
package.preload["ui.themes.widgets.toast"] = dialogModule
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return {
        new = function(_, opts)
            opts.updates = {}
            function opts:show() shown[#shown + 1] = self; return self end
            function opts:showWhile(fn, ...) self:show(); return fn(...) end
            function opts:update(text, done, total)
                self.text = text
                self.updates[#self.updates + 1] = { text = text, done = done, total = total }
            end
            function opts:close()
                if self._closed then return end
                self._closed = true
                if self.close_callback then self.close_callback() end
            end
            return opts
        end,
    }
end
local net_calls = 0
package.preload["http.request"] = function()
    return {
        get = function()
            net_calls = net_calls + 1
            error("page 测试默认不得请求网络")
        end,
    }
end

local Setting = require("features.marketplace.setting")
local Page = require("features.marketplace.page")
local Catalog = require("features.marketplace.catalog")
local Client = require("features.marketplace.client")
local Readme = require("features.marketplace.readme")
local Settings = require("utils.settings")

local desktop = { plugin = { path = "/koreader/plugins/book.koplugin" }, settings_overlay = { updateView = function() end } }

local entries = Setting.entries(desktop)
Assert.eq(#entries, 1)
Assert.eq(entries[1].group, "device")
Assert.eq(entries[1].order, 25)
Assert.eq(entries[1].title, "插件市场")
Assert.eq(entries[1].icon, "inventory_2")
---@type table
local entry_page = entries[1].page
Assert.eq(#entry_page.right_actions, 2)
Assert.eq(entry_page.right_actions[1].icon, "refresh")
Assert.eq(entry_page.right_actions[2].icon, "tune")
Assert.eq(entry_page.searchable, false, "动态插件目录不得展开进设置搜索")

local data = Settings.get("features.marketplace")
data.filter = nil
Settings.save("features.marketplace")
Assert.eq(Setting.defaults.filter.kind, "moon", "默认只筛选月读插件")
Assert.eq(Page.filter().kind, "moon")
Catalog.clear()
Readme.clearCache()
Page.onClose()

-- 空缓存态显示可点击刷新提示
local empty_rows = Page.sections(desktop)[1].rows
local empty_widget = empty_rows[1](100)
Assert.eq(empty_widget.title, "还没有插件列表")
Assert.eq(type(empty_widget.callback), "function")

-- 填充本地缓存测试搜索、分类、生态过滤（全离线，不发网络）
local p_single = {
    uid = "github:Acme/nice-plugin",
    type = "github", host = "https://github.com", owner = "Acme", repo = "nice-plugin",
    kind = "moon", kinds = { "moon" },
    title = "阅读统计", summary = "统计你的阅读时长", version = "1.0.0",
    category = "reader", category_name = "阅读增强",
    release_tag = "v1.0.0", release_asset = "nice.koplugin-1.0.0.zip",
    release_url = "https://github.com/Acme/nice-plugin/releases/download/v1.0.0/nice.koplugin-1.0.0.zip",
    release_assets = {
        { name = "nice.koplugin-1.0.0.zip", url = "https://github.com/Acme/nice-plugin/releases/download/v1.0.0/nice.koplugin-1.0.0.zip" },
    },
}
local p_multi = {
    uid = "github:Acme/bundle-plugin",
    type = "github", host = "https://github.com", owner = "Acme", repo = "bundle-plugin",
    kind = "koreader", kinds = { "koreader" },
    title = "Bundle", summary = "Multi asset plugin", version = "2.0.0",
    category = "util", category_name = "工具",
    release_assets = {
        { name = "a.koplugin.zip", url = "https://github.com/Acme/bundle-plugin/releases/download/v2.0.0/a.koplugin.zip" },
        { name = "b.koplugin.zip", url = "https://github.com/Acme/bundle-plugin/releases/download/v2.0.0/b.koplugin.zip" },
    },
}
Catalog.saveCache({
    updated_at = os.time(),
    categories = {
        { code = "reader", name = "阅读增强" },
        { code = "util", name = "工具" },
    },
    plugins = { p_single, p_multi },
})

local function rowTitles(sections)
    local out = {}
    for _s, section in ipairs(sections) do
        for _r, row in ipairs(section.rows) do
            out[#out + 1] = row(100).title
        end
    end
    return table.concat(out, ",")
end

local before_net = net_calls
-- 默认只显示月读插件
Assert.eq(rowTitles(Page.sections(desktop)), "阅读统计")
Page.setKind("", desktop)
Assert.eq(rowTitles(Page.sections(desktop)), "阅读统计,Bundle")
Page.setQuery("阅读", desktop)
Assert.eq(rowTitles(Page.sections(desktop)), "阅读统计")
Page.setQuery("", desktop)
Page.setCategory("util", desktop)
Assert.eq(rowTitles(Page.sections(desktop)), "Bundle")
Page.setCategory("", desktop)
Page.setKind("moon", desktop)
Assert.eq(rowTitles(Page.sections(desktop)), "阅读统计")
Page.setKind("", desktop)
Assert.eq(rowTitles(Page.sections(desktop)), "阅读统计,Bundle")
Page.clearFilters(desktop)
Assert.eq(Page.filter().kind, "moon", "清除筛选应恢复默认（仅月读插件）")
Assert.eq(rowTitles(Page.sections(desktop)), "阅读统计")
Assert.eq(net_calls, before_net)

-- 设置根页状态走 Catalog.count()，不解码整库 Catalog.plugins()
do
    local real_plugins = Catalog.plugins
    Catalog.plugins = function() error("Setting.entries 不应全量解码 Catalog.plugins") end
    local se = Setting.entries(desktop)
    Catalog.plugins = real_plugins
    Assert.eq(se[1].status, "2 个插件")
end

-- browseSection 返回惰性行：构造 section 时不调 Catalog.get，只在实际渲染行时按 uid 单条解码
do
    local get_calls = 0
    local real_get = Catalog.get
    Catalog.get = function(uid)
        get_calls = get_calls + 1
        return real_get(uid)
    end
    local secs = Page.sections(desktop)
    Assert.eq(get_calls, 0, "列出索引阶段不应解码任何插件 JSON")
    local w1 = secs[1].rows[1](100)
    Assert.eq(w1.title, "阅读统计")
    Assert.eq(get_calls, 1, "只应解码实际渲染的这一行")
    Catalog.get = real_get
end

-- 单包安装：直接弹第三方代码确认框
shown = {}
Page.installPlugin(desktop, p_single)
Assert.eq(shown[1].title, "阅读统计")
Assert.eq(shown[1].ok_text, "安装")
Assert.is_true(shown[1].text:find("第三方代码", 1, true) ~= nil)
Assert.is_true(shown[1].text:find("SHA-256", 1, true) ~= nil)

-- 多包安装：先弹选择安装包列表，选中后再弹确认框
shown = {}
Page.installPlugin(desktop, p_multi)
Assert.eq(shown[1].title, "选择安装包")
Assert.eq(#shown[1].items, 2)
shown[1].on_select(shown[1].items[2].value)
Assert.eq(shown[2].ok_text, "安装")
Assert.is_true(shown[2].text:find("b.koplugin.zip", 1, true) ~= nil)

-- 点击条目打开 README 详情窗，经 Client.getDetail 加载正文
local opened = {}
package.loaded["features.marketplace.viewer"] = {
    open = function(opts)
        function opts:setContent(c) self.content = c end
        function opts:dismiss()
            self.dismissed = true
            if self.on_close then self.on_close() end
        end
        opened[#opened + 1] = opts
        return opts
    end,
    defaultLink = function() end,
}
Client.getDetail = function(uid, cb)
    cb({
        uid = uid, type = "github", owner = "Acme", repo = "nice-plugin",
        default_branch = "main", title = "阅读统计",
        release_assets = p_single.release_assets,
        readme = { name = "README.zh-CN.md", text = "# 阅读统计\n正文" },
    }, nil)
    return { cancel = function() end }
end
local first_widget = Page.sections(desktop)[1].rows[1](100)
first_widget.callback()
Assert.eq(#opened, 1)
Assert.eq(opened[1].title, "阅读统计")
Assert.eq(opened[1].buttons[1].text, "取消")
Assert.eq(opened[1].buttons[2].text, "安装")
Assert.is_true(opened[1].content.html:find("阅读统计", 1, true) ~= nil)

-- 点详情里的安装按钮弹出确认框
shown = {}
opened[1].buttons[2].callback()
Assert.eq(shown[1].ok_text, "安装")

-- 命中 README 缓存时首帧直出 HTML，不再二次 setContent
opened = {}
first_widget.callback()
Assert.eq(#opened, 1)
Assert.is_true(opened[1].html:find("阅读统计", 1, true) ~= nil)
Assert.is_nil(opened[1].content, "命中缓存应直接传给 Viewer.open，不再先出占位再 setContent")

-- 离线回落的旧 README 详情（1.0.0）不得覆盖目录里更新版本（2.0.0）的 release_assets
local p_v2 = {
    uid = p_single.uid,
    type = "github", host = "https://github.com", owner = "Acme", repo = "nice-plugin",
    kind = "moon", kinds = { "moon" },
    title = "阅读统计", summary = "统计你的阅读时长", version = "2.0.0",
    release_assets = {
        { name = "nice.koplugin-2.0.0.zip", url = "https://github.com/Acme/nice-plugin/releases/download/v2.0.0/nice.koplugin-2.0.0.zip" },
    },
}
Client.getDetail = function(_uid, cb)
    cb(nil, "network")
    return { cancel = function() end }
end
opened = {}
shown = {}
Page.showReadme(desktop, p_v2, { kind = "updates" })
Assert.eq(#opened, 1)
opened[1].buttons[2].callback()
Assert.is_true(shown[1].text:find("nice.koplugin-2.0.0.zip", 1, true) ~= nil, "旧 README 缓存不得把安装包回退到旧版本")

-- 切换页签 / 筛选重置页码，且同会话复用 Installed.scan 快照
desktop.settings_overlay.page = 5
Page.setQuery("阅读", desktop)
Assert.eq(desktop.settings_overlay.page, 1)
Page.clearFilters(desktop)

-- 已安装 & 更新页签
local Installed = require("features.marketplace.installed")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local root = Paths.root() .. "/marketplace-page-installed"
local stats = root .. "/nice.koplugin"
local core = root .. "/book.koplugin"
lfs.mkdir(Paths.root())
lfs.mkdir(root)
lfs.mkdir(stats)
lfs.mkdir(core)
local function writeMeta(dir, body)
    local fh = io.open(dir .. "/_meta.lua", "w")
    fh:write(body)
    fh:close()
end
writeMeta(stats, 'return { name = "nice", fullname = _("阅读统计"), version = "0.9.0" }\n')
writeMeta(core, 'return { name = "book", fullname = _("月读"), version = "9.0.0" }\n')
local inst_desktop = { plugin = { path = core }, settings_overlay = desktop.settings_overlay }

local scan_calls = 0
local real_scan = Installed.scan
Installed.scan = function(p)
    scan_calls = scan_calls + 1
    return real_scan(p)
end
Page.setTab("installed", inst_desktop)
local inst_w = Page.sections(inst_desktop)[1].rows[1](100)
Assert.eq(inst_w.title, "阅读统计")
Assert.eq(inst_w.status, "更新")
Assert.eq(scan_calls, 1)

Page.setTab("updates", inst_desktop)
local upd_w = Page.sections(inst_desktop)[1].rows[1](100)
Assert.eq(upd_w.title, "阅读统计")
Assert.eq(upd_w.status, "更新")
Assert.eq(scan_calls, 1, "同会话切页签/翻页复用扫描快照，不重复扫盘")
Page.onClose()
Page.sections(inst_desktop)
Assert.eq(scan_calls, 2, "关闭叠层清快照后再次打开才会重扫")
Installed.scan = real_scan

os.remove(stats .. "/_meta.lua")
os.remove(core .. "/_meta.lua")
lfs.rmdir(stats)
lfs.rmdir(core)
lfs.rmdir(root)
Catalog.clear()
Readme.clearCache()
Page.onClose()
Page.setTab("browse", desktop)
return true
