--[[--
Home text components refresh on resume and release widget references on pause.
@module tests.ui.desktop.home.views.lifecycle_spec
--]]

local Assert = require("support.assert")
local texts = {}
local function widget()
    return { new = function(_, opts)
        opts.getSize = function() return { w = 100, h = 16 } end
        opts.setText = function(self, text) self.text = text end
        if opts.text then texts[#texts + 1] = opts end
        return opts
    end }
end
for _, name in ipairs({
    "container/centercontainer", "container/framecontainer", "container/leftcontainer",
    "container/rightcontainer", "horizontalgroup", "horizontalspan", "verticalgroup",
    "verticalspan", "textwidget", "textboxwidget", "linewidget",
}) do package.preload["ui/widget/" .. name] = widget end
package.preload["ui/geometry"] = widget
package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = 0, COLOR_GRAY_5 = 5 } end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        fontSize = function(n) return n end,
        line = function() return 1 end,
        face = function(_, size) return { size = size or 15 } end,
        muted = function() return 0 end,
        dim = function() return 0 end,
    }
end
package.preload["ui.components.surface"] = function() return { build = function(opts) return opts.child end } end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end
package.preload["http.request"] = function()
    return { get = function() return { cancel = function() end } end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, value) return (s:gsub("%%1", tostring(value))) end }
end
local paints = 0
package.preload["ui/uimanager"] = function()
    return { setDirty = function() paints = paints + 1 end }
end
local settings = { lock_screen_quote_cache = "old" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, saveSection = function() end }
end
local quote_text = "old"
package.preload["online.hitokoto"] = function()
    return {
        random = function()
            return { text = quote_text, author = "who", title = "work" }
        end,
    }
end
local excerpt_text = "old excerpt"
package.preload["book.highlights"] = function()
    return {
        random = function()
            if excerpt_text == nil then return nil end
            return { text = excerpt_text, author = "余华", title = "活着" }
        end,
    }
end
local seconds = 10
local expected_source = "owner"
package.preload["db.stats"] = function()
    return {
        summaryBySource = function(id) Assert.eq(id, expected_source); return { total_seconds = seconds } end,
        dailyBySource = function() return {} end,
    }
end
package.preload["book.catalog"] = function()
    return {
        formatDuration = function(n) return tostring(n) end,
        libraryScope = function(id) return id end,
    }
end

local daily = {
    history = { { year = "1990", title = "旧事" } },
    news = { "旧闻" },
}
package.preload["online.myrl"] = function()
    return { fetch = function(_, _, cb) cb(daily) return nil end }
end

local ctx = { desktop = {}, source = { id = "owner" } }
local opts = { width = 400, height = 180, y = 30 }
for _, name in ipairs({ "hitokoto", "excerpt", "stats" }) do
    ctx.source = { id = "owner" }
    expected_source = "owner"
    texts = {}
    quote_text = "old"
    excerpt_text = "old excerpt"
    seconds = 10
    local component = require("ui.desktop.home.views." .. name):new()
    component.home = { recent = { source_id = "owner", stable_id = "book" }, daily = {} }
    component:build(ctx, opts)
    quote_text = "new"
    excerpt_text = "new excerpt"
    seconds = 20
    local before = paints
    component:onResume()
    Assert.eq(paints, before + 1)
    local expected = name == "hitokoto" and "new" or name == "excerpt" and "new excerpt" or "20"
    local found = false
    for _, text in ipairs(texts) do if text.text == expected then found = true end end
    Assert.is_true(found, name .. " refreshes its own content")
    if name == "stats" then
        expected_source = "wechat"
        ctx.source = { id = expected_source }
        seconds = 30
        component:onResume()
        local switched = false
        for _, text in ipairs(texts) do if text.text == "30" then switched = true end end
        Assert.is_true(switched, "stats reads the current context source")
    end
    if name == "excerpt" then
        excerpt_text = "third excerpt"
        component:onResume()
        local again = false
        for _, text in ipairs(texts) do if text.text == "third excerpt" then again = true end end
        Assert.is_true(again, "excerpt reshuffles on every resume")
    end
    component:onPause()
    Assert.is_nil(component.refresh)
    before = paints
    component:onResume()
    Assert.eq(paints, before + 1)
    component:onPause()
    component:onDestroy()
    before = paints
    Assert.errors(function() component:onResume() end)
    Assert.eq(paints, before)
end

do -- 历史上的今天 / 热点新闻：固定行数，空数据首行占位，resume 原地更新文字
    local function shown()
        local out = {}
        for _, text in ipairs(texts) do out[#out + 1] = text.text end
        return table.concat(out, "|")
    end
    for _, case in ipairs({
        { name = "history", before = "历史上的今天||--||||", after = "1990|旧事" },
        { name = "news", before = "热点新闻|01|--|02||03||04|", after = "01|旧闻" },
    }) do
        texts = {}
        local component = require("ui.desktop.home.views." .. case.name):new()
        component:build(ctx, opts)
        Assert.eq(shown(), case.before, case.name .. " placeholder rows")
        Assert.eq(#component.items, case.name == "history" and 3 or 4)
        component:onResume()
        Assert.eq(component.marks[1].text .. "|" .. component.items[1].text, case.after)
        Assert.eq(component.items[2].text, "")
        component:onDestroy()
    end
end

do -- 库空时复用一言回退池，不造「暂无书摘」
    texts = {}
    excerpt_text = nil
    quote_text = "读书不觉已春深，一寸光阴一寸金。"
    local component = require("ui.desktop.home.views.excerpt"):new()
    component.home = { daily = {} }
    component:build(ctx, opts)
    local found = false
    for _, text in ipairs(texts) do
        if text.text == quote_text then found = true end
    end
    Assert.is_true(found, "excerpt reuses hitokoto fallback")
    component:onDestroy()
end

do -- 阅读统计槽位按实测文字 + 阴影，不用字号冒充控件高。
    local Stats = require("ui.desktop.home.views.stats")
    local range = Stats:heightRange()
    Assert.eq(range.height, 54)
end
