--[[--
extensions/moonsource-kavita.koplugin 首页组件 On Deck：在线且已配置才拉，5 分钟内复用；
两行 × 5 列封面网格（网格尺寸走 CoverCell.denseCoverMetrics / Book.widget，同首页最近阅读），
点开走月读开书；失败 / 空列表 / 离线给提示。

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

local TITLE_EXTRA = 26
local covers = {}
package.preload["ui.widgets.book"] = function()
    return {
        captionExtra = function(show_title) return show_title ~= false and TITLE_EXTRA or 0 end,
        widget = function(_plugin, _source, book, cw, ch, opts)
            local slot_w = (opts and opts.slot_w) or cw
            covers[#covers + 1] = { book = book, w = cw, h = ch, slot_w = slot_w }
            return Widget:new{ dimen = { w = slot_w, h = ch + TITLE_EXTRA } }
        end,
    }
end
package.preload["ui.widgets.cover"] = function()
    return {
        gridCoverMaxH = function() return 320 end,
        denseCoverMetrics = function(w, _budget, opts)
            local cols = opts.min_cols or 5
            local gap, row_gap = 8, 10
            local slot_w = math.max(1, math.floor((w - gap * (cols - 1)) / cols))
            local cw = slot_w
            local ch = math.min(math.floor(cw * 3 / 2), opts.max_h or 320)
            return slot_w, cw, ch, cols, gap, row_gap, ch + opts.title_extra
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
deck:build({ desktop = desktop, plugin = desktop.plugin },
    { width = 300, height = deck:heightRange(nil, { width = 300 }).height })
Assert.contains(Kit.texts(deck.slot), "联网后显示 Kavita 上在读的书")

-- 激活拉一次：POST on-deck，进度按 pagesRead / pages。
deck:activate()
Assert.len(calls, 1)
Assert.eq(calls[1].method, "POST")
Assert.eq(calls[1].path, "/api/Series/on-deck")
Assert.eq(calls[1].query.pageSize, 10)
local list = {}
for i = 1, 12 do list[i] = { id = i, name = "S" .. i, pages = 10, pagesRead = i } end
reply(list)
Assert.eq(deck.data[3].stable_id, "3")
Assert.eq(deck.data[3].source_id, "ext.kavita")
Assert.eq(deck.data[3].percent, 30)
-- 一页 4 本（跟首页最近阅读一样），12 本分 3 页。
Assert.eq(#covers, 4, "一页 4 本")
Assert.eq(covers[1].book.title, "S1")
Assert.contains(Kit.texts(deck.slot), "1 / 3")

-- 一页 4 本、多的分页：翻到后面不该重画前面的书。
covers = {}
deck.page = 2
deck:refresh()
Assert.eq(#covers, 4)
Assert.eq(covers[1].book.title, "S5", "第二页从第 5 本开始")
Assert.contains(Kit.texts(deck.slot), "2 / 3")
deck.page = 3
covers = {}
deck:refresh()
Assert.eq(#covers, 4, "最后一页 4 本")
Assert.eq(covers[1].book.title, "S9")
deck.page = 1
covers = {}
deck:refresh()

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
Assert.eq(covers[1].book.title, "S1", "失败保留上次的列表")
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

-- 一页 4 本，封面按宽度分满，槽宽/封面宽一致，10 本分 3 页。
covers = {}
online, configured = true, true
local wide = Deck:new{}
local nat = wide:heightRange(nil, { width = 568 }).height
wide:build({ desktop = desktop, plugin = desktop.plugin }, { width = 568, height = nat })
wide:activate()
local ten = {}
for i = 1, 10 do ten[i] = { id = i, name = "S" .. i, pages = 10, pagesRead = i } end
reply(ten)
Assert.len(wide.data, 10)
Assert.eq(#covers, 4, "每页 4 本")
Assert.contains(Kit.texts(wide.slot), "1 / 3")
-- 内容高不能超过 heightRange（超了 widget 会掉出槽位）。
Assert.is_true(wide.slot[1]:getSize().h <= nat, "内容高不超过 heightRange")
-- 每格用同一个槽宽（Book.widget 把封面居中到 slot_w），不会有一本看着变小 / 错位。
for _i, c in ipairs(covers) do
    Assert.eq(c.slot_w, covers[1].slot_w, "每格槽宽一致")
    Assert.eq(c.w, covers[1].w, "每格封面宽一致")
end
