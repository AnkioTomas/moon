--[[--
首页文字组件：一言 / 书摘暂停后才换句；统计按所属源读、数值变了才重建；
历史 / 新闻固定行数、空数据首行占位，恢复时拉日报原地改字。
@module tests.desktop.pages.home.lifecycle_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local quote_text = "old"
package.preload["online.hitokoto"] = function()
    return { random = function() return { text = quote_text, author = "who", title = "work" } end }
end
local excerpt
package.preload["book.highlights"] = function()
    return { random = function() return excerpt end }
end
local seconds, scope = 10, nil
package.preload["book.stats_db"] = function()
    return {
        summaryBySource = function(id) scope = id; return { total_seconds = seconds } end,
        dailyBySource = function() return {} end,
    }
end
package.preload["book.catalog"] = function()
    return {
        formatDuration = function(n) return tostring(n) end,
        libraryScope = function(id) return id end,
    }
end
local daily, fetches, myrl_cb = {}, 0, nil
package.preload["online.myrl"] = function()
    return {
        current = function() return nil end,
        watch = function(_, cb) myrl_cb = cb end,
        ensure = function() fetches = fetches + 1; if myrl_cb then myrl_cb(daily) end end,
        unwatch = function() end,
    }
end
local opened
package.preload["book.books_db"] = function() return { get = function() return nil end } end
package.preload["desktop.open"] = function() return { book = function(_, book) opened = book end } end

--- 树里所有带 text 的控件文案（含 TextBoxWidget）。
local function texts(root)
    local out = {}
    for _, w in ipairs(Kit.find(root, function(w) return type(w.text) == "string" end)) do out[#out + 1] = w.text end
    return table.concat(out, "|")
end

local desktop = {}
local ctx = { desktop = desktop, source = { id = "owner" } }
local opts = { width = 400, height = 120 }

local function mount(name)
    local comp = require("desktop.pages.home." .. name):new()
    local slot = comp:build(ctx, opts)
    comp:activate()
    slot:paintTo(Kit.canvas(), 0, 30)
    return comp, slot
end

do -- 一言：同一可见期重建不换句，暂停后下一次构建才换
    local comp, slot = mount("hitokoto")
    Assert.matches(texts(slot), "old")
    Assert.matches(texts(slot), "—— who · work")
    quote_text = "new"
    comp:refresh()
    Assert.matches(texts(slot), "old", "可见期内重建保持同一句")
    comp:deactivate()
    comp:activate()
    comp:refresh()
    Assert.matches(texts(slot), "new")
    comp:destroy()
end

do -- 书摘：有高亮用高亮，点按开书；空库回退一言
    excerpt = { text = "活着就好", author = "余华", title = "活着", source_id = "local", stable_id = "b1" }
    local plugin = {}
    desktop.plugin = plugin
    local comp, slot = mount("excerpt")
    Assert.matches(texts(slot), "活着就好")
    Kit.taps(slot)[1]:onTapThemeArea(nil, { pos = { x = 1, y = 31 } })
    Assert.eq(opened.stable_id, "b1")
    Assert.eq(opened.authors, "余华")
    comp:destroy()
    excerpt, quote_text = nil, "读书不觉已春深"
    comp, slot = mount("excerpt")
    Assert.matches(texts(slot), "读书不觉已春深")
    Assert.len(Kit.taps(slot), 0, "一言回退没有书可开")
    comp:destroy()
    desktop.plugin = nil
end

do -- 统计：按构建上下文的源读；stats_changed 数值变了才重建
    local comp, slot = mount("stats")
    Assert.eq(scope, "owner")
    Assert.matches(texts(slot), "10|总阅读")
    local dirty = #Kit.dirty
    comp:onEvent("stats_changed")
    Assert.eq(#Kit.dirty, dirty, "数值未变不刷新")
    seconds = 40
    comp:onEvent("stats_changed")
    Assert.matches(texts(slot), "40|总阅读")
    Assert.eq(#Kit.dirty, dirty + 1, "只刷自己的矩形")
    Assert.eq(Kit.dirty[#Kit.dirty].region.y, 30)
    comp:destroy()
    ctx.source = { id = "wechat" }
    comp = mount("stats")
    Assert.eq(scope, "wechat")
    comp:destroy()
    ctx.source = { id = "owner" }
    Assert.is_true(require("desktop.pages.home.stats"):heightRange().height > 0)
end

do -- 历史 / 新闻：固定行数；空数据首行占位；恢复时拉日报，内容变了才原地改字
    for _, case in ipairs({
        { name = "history", lines = 3, data = { history = { { year = "1990", title = "旧事" } } },
          empty = "历史上的今天||--||||", filled = "历史上的今天|1990|旧事||||" },
        { name = "news", lines = 4, data = { news = { "旧闻" } },
          empty = "热点新闻|01|--|02||03||04|", filled = "热点新闻|01|旧闻|02||03||04|" },
    }) do
        daily = {}
        local Comp = require("desktop.pages.home." .. case.name)
        local comp = Comp:new()
        local slot = comp:build(ctx, opts)
        Assert.eq(texts(slot), case.empty, case.name .. " 占位行")
        Assert.len(comp.items, case.lines)
        local before, dirty = fetches, #Kit.dirty
        comp:activate()
        Assert.eq(fetches, before + 1, "恢复才挂日报刷新")
        Assert.eq(#Kit.dirty, dirty, "日报无本字段不刷新")
        comp:deactivate()
        daily = case.data
        slot:paintTo(Kit.canvas(), 0, 0)
        comp:activate()
        Assert.eq(texts(slot), case.filled)
        Assert.eq(#Kit.dirty, dirty + 1)
        comp:deactivate()
        comp:activate()
        Assert.eq(#Kit.dirty, dirty + 1, "缓存命中同一张表不刷新")
        Assert.is_true(Comp:heightRange(nil, opts).height > 0)
        comp:destroy()
        Assert.is_nil(comp.items)
    end
end
