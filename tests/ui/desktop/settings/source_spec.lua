--[[--
数据源选择：6 个书源 + 置顶的混合模式。
@module tests.ui.desktop.settings.source_spec
--]]

local Assert = require("support.assert")

local mixed = false
local active = "wechat"
local saved
local set_active
local sheet
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
        libraryMixed = function() return mixed end,
        zlibEnabled = function() return false end,
        save = function(patch)
            saved = patch
            if patch.library_mixed ~= nil then mixed = patch.library_mixed end
        end,
        activeSourceId = function() return active end,
        getSource = function() return {} end,
    }
end
package.preload["source.registry"] = function()
    return {
        listEnabled = function() return enabled end,
        list = function() return enabled end,
        isEnabled = function() return true end,
        setEnabled = function() end,
        setActive = function(id) set_active = id; active = id end,
        meta = function(id) return { id = id, name = id } end,
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
package.preload["ui/uimanager"] = function() return { show = function() end } end
package.preload["ui.views.popup"] = function()
    return {
        sheet = function(opts) sheet = opts end,
        list = function() end,
    }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a, b) return fmt:gsub("%%1", tostring(a)):gsub("%%2", tostring(b or "")) end }
end
package.preload["zlib.setting"] = function() return {} end

package.loaded["ui.desktop.settings.source"] = nil
local Source = require("ui.desktop.settings.source")
local src = Source.new()
local desktop = { updateView = function() end, onEvent = function() end }

Assert.eq(Source.displayName("微信读书"), "微信读书")
mixed = true
Assert.eq(Source.displayName("微信读书"), "混合模式")
mixed = false

src:pickActive(desktop, nil)
Assert.not_nil(sheet)
Assert.eq(sheet.items[1].value, "__mixed__", "混合模式置顶")
Assert.eq(sheet.items[2].value, "local", "本地排第二")
Assert.eq(#sheet.items, 7, "6 源 + 1 混合")
Assert.eq(sheet.items[4].text, "✓ 微信读书")

sheet.on_select("__mixed__")
Assert.eq(saved.library_mixed, true)
Assert.is_true(mixed)

sheet = nil
src:pickActive(desktop, nil)
Assert.eq(sheet.items[1].text, "✓ 混合模式")
Assert.eq(sheet.items[4].text, "微信读书", "混合开启时真实源不打勾")

set_active = nil
sheet.on_select("moon")
Assert.eq(saved.library_mixed, false)
Assert.eq(set_active, "moon")
Assert.is_false(mixed)

local scope = src:scopeSections{
    desktop = desktop,
    plugin = nil,
    active_id = "wechat",
    active_name = "微信读书",
}
Assert.eq(#scope, 1)
Assert.eq(scope[1].title, "书籍来源")
Assert.eq(scope[1].rows[1]().status, "微信读书")
Assert.eq(scope[1].rows[1]().title, "当前数据源")
Assert.eq(scope[1].rows[2]().title, "已启用的数据源")

local config = src:configSections{
    desktop = desktop,
    plugin = nil,
}
Assert.is_true(#config >= 2)
Assert.eq(config[1].title, "Moon")
Assert.eq(config[#config].title, "Z-Library")
for i = 1, #config do
    local first = config[i].rows[1]
    if first then
        Assert.is_true(first().title ~= "混合模式", config[i].title)
    end
end

return true
