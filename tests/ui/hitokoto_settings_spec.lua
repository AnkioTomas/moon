--[[--
一言设置：类型状态文案、设置弹窗与居中类型多选。
@module tests.ui.hitokoto_settings_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end

local home = {
    home_hitokoto_ttl = 3600,
    home_hitokoto_types = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" },
    home_hitokoto_center = false,
}
local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        save = function(_, data)
            saved[#saved + 1] = data
            if type(data) == "table" then
                for k, v in pairs(data) do home[k] = v end
            end
        end,
    }
end

local ensured = 0
package.preload["online.hitokoto"] = function()
    local TYPES = {
        { id = "a", label = "动画" }, { id = "b", label = "漫画" }, { id = "c", label = "游戏" },
        { id = "d", label = "文学类" }, { id = "e", label = "原创类" }, { id = "f", label = "来自网络" },
        { id = "g", label = "其他" }, { id = "h", label = "影视" }, { id = "i", label = "诗词" },
        { id = "j", label = "网易云" }, { id = "k", label = "哲学类" }, { id = "l", label = "抖机灵" },
    }
    local Hitokoto = { TYPES = TYPES }
    function Hitokoto.allTypeIds()
        local ids = {}
        for i, typ in ipairs(TYPES) do ids[i] = typ.id end
        return ids
    end
    function Hitokoto.selectedTypes()
        return home.home_hitokoto_types or Hitokoto.allTypeIds()
    end
    function Hitokoto.configuredTtl()
        if home.home_hitokoto_ttl == 0 then return 0 end
        return home.home_hitokoto_ttl or 3600
    end
    function Hitokoto:ensureConfigured() ensured = ensured + 1 end
    return Hitokoto
end

local Themed = require("support.theme_stubs")
Themed.install()

local Settings = require("ui.hitokoto_settings")

Assert.eq(Settings.ttl(), 3600)
Assert.eq(#Settings.intervals(), 4)
Assert.eq(Settings.intervals()[1].text, "10 分钟")
Assert.eq(Settings.intervals()[4].value, 0)
Assert.eq(Settings.typesStatus(), "全部")

home.home_hitokoto_types = { "a", "d" }
Assert.eq(Settings.typesStatus(), "动画、文学类")

ensured = 0
Settings.setTtl(0)
Assert.eq(home.home_hitokoto_ttl, 0)
Assert.eq(ensured, 1)
Settings.setTypes({ "i" })
Assert.eq(home.home_hitokoto_types[1], "i")
Assert.eq(Settings.typesStatus(), "诗词")

local changed = 0
Settings.show{
    center_key = "home_hitokoto_center",
    on_change = function() changed = changed + 1 end,
}
local page = Themed.last("settings")
Assert.eq(page.title, "一言")
local items = page.items(page)
Assert.eq(items[1].title, "居中")
Assert.is_false(items[1].checked)
Assert.eq(items[2].title, "联网刷新")
Assert.eq(items[2].current, 0)
Assert.eq(items[3].title, "句子类型")
Assert.eq(items[3].status, "诗词")
items[1].callback()
Assert.is_true(home.home_hitokoto_center)
Assert.eq(changed, 1)
items[2].on_select(600)
Assert.eq(home.home_hitokoto_ttl, 600)
Assert.eq(changed, 2)

items[3].callback()
local list = Themed.last("list")
Assert.eq(list.title, "句子类型")
Assert.is_true(list.multi)
Assert.is_true(list.centered)
Assert.eq(list.items[9].value, "i")
Assert.is_true(list.items[9].checked)
list.items[9].checked = false
list.on_toggle("i", false, list.items[9])
Assert.is_true(list.items[9].checked, "不能取消最后一个")
Assert.eq(Themed.last("toast").text, "至少选择一种类型")
list.items[1].checked = true
list.on_toggle("a", true, list.items[1])
Assert.eq(home.home_hitokoto_types[1], "a")
Assert.eq(changed, 3)

return true
