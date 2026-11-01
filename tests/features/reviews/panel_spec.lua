--[[-- 阅读快捷面板「显示段评」：写当前页实际用的源开关，不另存一份。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(text) return text end end

local identity
package.loaded["reader.session"] = {
    current = function() return identity and { identity = identity } or nil end,
}
local wechat_on = false
local wechat = { id = "wechat", configured = function() return wechat_on end }
package.loaded["source.registry"] = {
    resolve = function(id)
        if id == "wechat" then return wechat end
        return nil
    end,
}
package.loaded["features.reviews.link"] = {
    available = function(ui) return ui.document ~= nil and ui.document.cre == true end,
}
local store = {}
package.loaded["utils.settings"] = {
    getSource = function(id)
        store[id] = store[id] or {}
        return store[id]
    end,
    saveSource = function(id, values) store[id] = values end,
}
local dirty
package.loaded["ui/uimanager"] = {
    setDirty = function(_self, widget, mode) dirty = { widget, mode } end,
}

local actions = require("features.reviews.panel").actions()
local show
for _idx, action in ipairs(actions) do
    if action.id == "reviews_show" then show = action end
end
Assert.is_true(show ~= nil)
Assert.eq(show.title, "显示段评")
Assert.eq(show.scope, "reader")
Assert.is_true(show.keep_open)
Assert.is_true(show.available({}), "设置页要能勾选")
Assert.is_false(show.active({}))

local fanqie = { id = "fanqie", paragraphHotspotsAsync = function() end }
identity = { source_id = "fanqie", stable_id = "1", chapter_idx = 3, source = fanqie }
local ui = { dialog = {}, document = { cre = true } }
Assert.is_true(show.available({ ui = ui }))
Assert.is_false(show.active({ ui = ui }))
show.run({ ui = ui })
Assert.eq(store.fanqie.show_paragraph_reviews, true)
Assert.is_true(show.active({ ui = ui }))
Assert.eq(dirty[1], ui.dialog)
show.run({ ui = ui })
Assert.eq(store.fanqie.show_paragraph_reviews, false)
Assert.is_nil(store.wechat)

wechat_on = true
identity = { source_id = "local", stable_id = "/a.epub", source = { id = "local" } }
Assert.is_true(show.available({ ui = ui }), "本地书借微信段评")
show.run({ ui = ui })
Assert.eq(store.wechat.show_paragraph_reviews, true)
Assert.is_true(show.active({ ui = ui }))

identity = { source_id = "local", stable_id = "/a.pdf", source = { id = "local" } }
Assert.is_false(show.available({ ui = { dialog = {}, document = {} } }) == true, "PDF 没有段评")

wechat_on = false
identity = { source_id = "jdread", stable_id = "30", chapter_idx = 1, source = { id = "jdread" } }
Assert.is_false(show.available({ ui = ui }) == true, "没登录微信时借段评开关不出现")

identity = { source_id = "subscribe", stable_id = "3", chapter_idx = 1, ephemeral = true,
    source = { id = "subscribe", paragraphHotspotsAsync = function() end } }
Assert.is_false(show.available({ ui = ui }) == true)

for _idx, id in ipairs(require("features.panel.setting").defaults.quick_panel_reader_actions) do
    Assert.is_false(id == "reviews_show", "新开关默认关，不改已有面板")
end
