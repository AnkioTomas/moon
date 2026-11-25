--[[-- 插件市场导航：沿用横向下划线页签，接到 Overlay.nav，构造后点击切换。 --]]

local Assert = require("support.assert")
local Config = require("support.config")
if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
package.preload["ffi/util"] = function()
    return { template = function(s, a, b) return (s:gsub("%%1", a or ""):gsub("%%2", b or "")) end }
end
package.preload["http.request"] = function()
    return { get = function() error("nav 测试不得请求网络") end }
end

local Kit = require("support.widget_stubs")
Kit.install("paper")

local shown = {}
package.preload["ui.themes.widgets.input"] = function()
    return { new = function(_, opts) function opts:show() shown[#shown + 1] = self end return opts end }
end
package.preload["ui.themes.widgets.list"] = function()
    return { new = function(_, opts) function opts:show() shown[#shown + 1] = self end return opts end }
end

Kit.sections.marketplace = {
    filter = { tab = "browse", q = "", category = "", kind = "moon" },
}

local Setting = require("features.marketplace.setting")
local Page = require("features.marketplace.page")
local Catalog = require("features.marketplace.catalog")
Catalog.clear()

local desktop = { plugin = { path = "/koreader/plugins/book.koplugin" }, settings_overlay = { updateView = function() end } }
local entry = Setting.entries(desktop)[1]
---@type table
local page = entry.page
Assert.eq(type(page.nav), "function")
Assert.eq(#page.right_actions, 2, "右上角只保留刷新与生态筛选")
Assert.eq(page.right_actions[1].icon, "refresh")
Assert.eq(page.right_actions[2].icon, "tune")

local nav = page.nav(420)
Assert.eq(type(nav.getSize), "function")
Assert.is_true(nav:getSize().h > 0)
local labels = table.concat(Kit.texts(nav), ",")
Assert.is_true(labels:find("浏览", 1, true) ~= nil)
Assert.is_true(labels:find("已安装", 1, true) ~= nil)
Assert.is_true(labels:find("更新", 1, true) ~= nil)
Assert.is_true(labels:find("搜索", 1, true) ~= nil)
Assert.is_true(labels:find("分类", 1, true) ~= nil)
Assert.is_nil(labels:find("清除筛选", 1, true), "默认仅月读插件筛选下不应显示清除筛选")

local taps = Kit.taps(nav)
Assert.is_true(#taps >= 5, "浏览/已安装/更新/分类/搜索都要可点")
taps[2]:onTapThemeArea()
Assert.eq(Page.filter().tab, "installed")
Assert.eq(Page.sections(desktop)[1].title, "已安装")

nav = Page.nav(desktop, 420)
Kit.taps(nav)[3]:onTapThemeArea()
Assert.eq(Page.filter().tab, "updates")
Assert.eq(Page.sections(desktop)[1].title, "更新")

Page.setTab("browse", desktop)
nav = Page.nav(desktop, 420)
shown = {}
local browse_taps = Kit.taps(nav)
browse_taps[#browse_taps]:onTapThemeArea()
Assert.eq(shown[1].title, "搜索")
shown = {}
browse_taps[#browse_taps - 1]:onTapThemeArea()
Assert.eq(shown[1].title, "分类")

shown = {}
page.right_actions[2].callback()
Assert.eq(shown[1].title, "插件生态")
Assert.eq(shown[1].items[1].value, "moon")

Kit.sections.marketplace.filter = { tab = "browse", q = "", category = "", kind = "moon" }
return true
