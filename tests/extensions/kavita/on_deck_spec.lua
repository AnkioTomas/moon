--[[--
extensions/moonsource-kavita.koplugin 首页组件 On Deck：在线且已配置才拉，5 分钟内复用；
封面横排按宽度截断，点开走月读开书；失败 / 空列表 / 离线给提示。

@module tests.extensions.kavita.on_deck_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()
local Widget = require("ui/widget/widget")

local covers = {}
package.preload["ui.widgets.book"] = function()
    return {
        cover = function(_plugin, _source, book, cw, ch)
            covers[#covers + 1] = { book = book, w = cw, h = ch }
            return Widget:new{ dimen = { w = cw, h = ch } }
        end,
    }
end
local opened = {}
package.preload["desktop.open"] = function()
    return { book = function(_plugin, book) opened[#opened + 1] = book end }
end

local online, configured = true, true
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
local calls, reply = {}, nil
local source = {
    configured = function() return configured end,
    client = {
        json = function(_self, method, path, query, body, cb)
            calls[#calls + 1] = { method = method, path = path, query = query, body = body }
            reply = cb
            return { cancel = function() reply = nil end }
        end,
    },
}
package.loaded["source.registry"] = { resolve = function(id) return id == "ext.kavita" and source or nil end }

local Deck = dofile(Config.root() .. "/extensions/moonsource-kavita.koplugin/moonsource_kavita/on_deck.lua")
Assert.eq(Deck.id, "ext.kavita.on_deck")

local desktop = { plugin = {} }
local deck = Deck:new{}
deck:build({ desktop = desktop, plugin = desktop.plugin }, { width = 300, height = 200 })
Assert.contains(Kit.texts(deck.slot), "联网后显示 Kavita 上在读的书")

-- 激活拉一次：POST on-deck，进度按 pagesRead / pages。
deck:activate()
Assert.len(calls, 1)
Assert.eq(calls[1].method, "POST")
Assert.eq(calls[1].path, "/api/Series/on-deck")
Assert.eq(calls[1].query.pageSize, 10)
local list = {}
for i = 1, 6 do list[i] = { id = i, name = "S" .. i, pages = 10, pagesRead = i } end
reply(list)
Assert.eq(deck.data[3].stable_id, "3")
Assert.eq(deck.data[3].source_id, "ext.kavita")
Assert.eq(deck.data[3].percent, 30)
Assert.is_true(#covers >= 1 and #covers < 6, "宽度放不下的不画")
Assert.eq(covers[1].book.title, "S1")

-- 5 分钟内重新激活不再请求；过期再拉。
deck:deactivate()
deck:activate()
Assert.len(calls, 1)
deck.loaded_at = os.time() - 301
deck:deactivate()
deck:activate()
Assert.len(calls, 2)

-- 离开首页取消在飞请求；失败显示原因；空列表给提示。
deck:deactivate()
Assert.is_nil(reply)
deck.loaded_at = nil
deck:activate()
reply(nil, "API Key 无效")
Assert.contains(Kit.texts(deck.slot), "S1", "失败保留上次的列表")
deck.data, deck.loaded_at = nil, nil
deck:deactivate()
deck:activate()
reply(nil, "API Key 无效")
Assert.contains(Kit.texts(deck.slot), "API Key 无效")
deck.loaded_at = nil
deck:deactivate()
deck:activate()
reply({})
Assert.contains(Kit.texts(deck.slot), "Kavita 上没有在读的书")

-- 离线 / 未配置不请求。
local before = #calls
deck.loaded_at = nil
deck:deactivate()
online = false
deck:activate()
deck:deactivate()
online, configured = true, false
deck:activate()
Assert.len(calls, before)

-- 点封面走月读开书。
deck.data = { { source_id = "ext.kavita", stable_id = "9", title = "九" } }
deck:refresh()
local taps = Kit.taps(deck.slot)
Assert.len(taps, 1)
taps[1]:onTapThemeArea()
Assert.eq(opened[1].stable_id, "9")
