--[[--
数据源选择：6 个书源 + 置顶的混合模式。
@module tests.desktop.pages.setting.source_spec
--]]

local Assert = require("support.assert")

local source_cfg = { library_mixed = false }
local store_cfg = { zlib_enabled = false, opds_enabled = false }
local active = "wechat"
local saved = {}
local set_active
local enabled = {
    { id = "local", name = "本地" },
    { id = "moon", name = "Moon" },
    { id = "wechat", name = "微信读书" },
    { id = "jdread", name = "京东读书" },
    { id = "copymanga", name = "拷贝漫画" },
    { id = "fanqie", name = "番茄小说" },
}
package.preload["utils.settings"] = function()
    return {
        get = function(owner) return owner == "source" and source_cfg or store_cfg end,
        save = function(owner) saved[#saved + 1] = owner end,
        getSource = function() return {} end,
    }
end
local notified = 0
package.preload["source.registry"] = function()
    return {
        activeId = function() return active end,
        listEnabled = function() return enabled end,
        list = function() return enabled end,
        isEnabled = function() return true end,
        setEnabled = function() end,
        setActive = function(id) set_active = id; active = id end,
        meta = function(id) return { id = id, name = id } end,
        external = function(id)
            if id == "ext.demo" then
                return { setting = { rows = function() return { function() return { id = "ext-row" } end } end } }
            end
        end,
        notifyChanged = function() notified = notified + 1 end,
    }
end
for _, id in ipairs({ "moon", "wechat", "jdread", "copymanga", "fanqie" }) do
    package.preload["source." .. id .. ".setting"] = function()
        return { rows = function() return { function() return { id = id .. "-row" } end } end }
    end
end
package.preload["source.local.setting"] = function()
    return {
        rowStatus = function() return "ok", true end,
        rows = function() return { function() return { id = "local-dir" } end } end,
    }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
local broadcasts = {}
package.preload["ui/uimanager"] = function()
    return { show = function() end, broadcastEvent = function(_self, ev) broadcasts[#broadcasts + 1] = ev.name end }
end
package.preload["ui/event"] = function() return { new = function(_self, name) return { name = name } end } end
local Themed = require("support.theme_stubs")
Themed.install()
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a, b) return fmt:gsub("%%1", tostring(a)):gsub("%%2", tostring(b or "")) end }
end
package.preload["store.zlib.setting"] = function() return {} end

package.loaded["desktop.pages.setting.source"] = nil
local Source = require("desktop.pages.setting.source")
local src = Source
local desktop = { updateView = function() end, onEvent = function() end }

Assert.eq(Source.displayName("微信读书"), "微信读书")
source_cfg.library_mixed = true
Assert.eq(Source.displayName("微信读书"), "混合模式")
source_cfg.library_mixed = false

src:pickActive()
local sheet = Themed.last("list")
Assert.eq(sheet.items[1].value, "__mixed__", "混合模式置顶")
Assert.eq(sheet.items[2].value, "local", "本地排第二")
Assert.eq(#sheet.items, 7, "6 源 + 1 混合")
Assert.eq(sheet.items[4].text, "微信读书")
Assert.eq(sheet.current, "wechat")

sheet.on_select("__mixed__")
Assert.eq(saved[#saved], "source")
Assert.is_true(source_cfg.library_mixed)
Assert.eq(notified, 1, "切混合模式广播 SourceChanged")

src:pickActive()
sheet = Themed.last("list")
Assert.eq(sheet.current, "__mixed__", "混合开启时只勾混合")

set_active = nil
sheet.on_select("moon")
Assert.eq(saved[#saved], "source")
Assert.eq(set_active, "moon")
Assert.is_false(source_cfg.library_mixed)

package.loaded["desktop.pages.setting.overlay"] = {
    push = function(d, spec) d.settings_overlay = { spec = spec } end,
}
local config = src:configSections{
    desktop = desktop,
    plugin = nil,
}
-- 账号页：书源一行一个入口（本地书籍在最前），书城后端另成一节；都不展开内容。
Assert.len(config, 2)
Assert.eq(config[1].title, "书籍来源")
Assert.eq(config[1].rows[1]().title, "本地书籍")
Assert.eq(config[2].title, "书城")
local store_rows = config[2].rows
Assert.eq(store_rows[#store_rows - 1]().title, "Z-Library")
Assert.eq(store_rows[#store_rows]().title, "OPDS")
-- OPDS：未开启；二级页面里先只有开关一行，开启后才出现目录配置入口。
Assert.eq(store_rows[#store_rows]().status, "未开启")
store_rows[#store_rows]().callback()
local page = desktop.settings_overlay.spec
Assert.eq(page.title, "OPDS")
local opds_rows = page.sections()[1].rows
Assert.len(opds_rows, 1)
Assert.is_false(opds_rows[1]().toggle)
opds_rows[1]().callback()
Assert.eq(saved[#saved], "store")
Assert.is_true(store_cfg.opds_enabled)
Assert.eq(broadcasts[#broadcasts], "StoreChanged")
opds_rows = page.sections()[1].rows
Assert.len(opds_rows, 2)
Assert.is_true(opds_rows[1]().toggle)
Assert.eq(opds_rows[2]().title, "OPDS 目录")
Assert.eq(opds_rows[2]().status, "未配置")
store_cfg.opds_enabled = false

-- 源设置模块：没有文件即没有；模块自身抛错必须冒出来。
Assert.is_nil(src.loadSetting("nosuch"))
package.preload["source.broken.setting"] = function() error("boom") end
Assert.errors(function() src.loadSetting("broken") end, "boom")

-- 第三方源的设置模块来自描述表，不按 source.<id>.setting 找文件。
Assert.eq(src.loadSetting("ext.demo").rows()[1]().id, "ext-row")
enabled[#enabled + 1] = { id = "ext.demo", name = "Demo" }
local with_ext = src:configSections{ desktop = desktop, plugin = nil }
local found
for _idx, row in ipairs(with_ext[1].rows) do
    if row().title == "Demo" then found = true end
end
Assert.is_true(found)
enabled[#enabled] = nil

return true
