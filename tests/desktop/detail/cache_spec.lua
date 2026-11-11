--[[--
缓存章节弹窗：段评开关、范围单选、底部取消/开始；范围含全本、到结尾和往后固定档。
@module tests.desktop.detail.cache_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(s) return s end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end

local Themed = require("support.theme_stubs")
Themed.install()

package.preload["ui.themes.widgets.toast"] = package.preload["ui.themes.widgets.toast"]
package.preload["book.progress_db"] = function()
    return { get = function() return { chapter_idx = 3, fraction = 0.5 } end }
end
local supported = true
package.preload["book.review_prefetch"] = function()
    return { supported = function() return supported end }
end
package.preload["desktop.detail.common"] = function()
    return { bookOwnerSource = function()
        return { type = "chapter", cacheAllChaptersAsync = function() end }
    end }
end

local Cache = require("desktop.detail.cache")
local queued = {}
function Cache.cacheAll(book, _source, range, reviews)
    queued[#queued + 1] = { book = book, range = range, reviews = reviews }
end

local pos = { chapter_idx = 3, fraction = 0.5 }
Assert.is_nil(Cache.rangeOf("all", pos))
local to_end = Cache.rangeOf("end", pos)
Assert.eq(to_end.chapter_idx, 3)
Assert.eq(to_end.fraction, 0.5)
Assert.is_nil(to_end.count)
local next10 = Cache.rangeOf("10", pos)
Assert.eq(next10.chapter_idx, 3)
Assert.eq(next10.count, 10, "往后 N 章直接带 count，不按目标章反算")
Assert.is_nil(Cache.rangeOf("5", nil).chapter_idx, "无进度：不带起始章，由底层从第 1 章起")
Assert.eq(Cache.rangeOf("5", nil).count, 5)

local book = { source_id = "wechat", stable_id = "b1", title = "书" }
Cache.chooseRange(book, nil, false)
local page = Themed.last("settings")
Assert.eq(page.title, "缓存章节")
local items = page.items(page)
Assert.eq(items[1].title, "缓存段评")
Assert.is_true(items[1].toggle)
Assert.is_false(items[1].checked)
Assert.eq(items[2].title, "缓存范围")
Assert.eq(items[2].current, "all")
local expected = {
    { "all", "全本" },
    { "end", "到结尾" },
    { "5", "往后 5 章" },
    { "10", "往后 10 章" },
    { "50", "往后 50 章" },
    { "100", "往后 100 章" },
    { "200", "往后 200 章" },
}
Assert.eq(#items[2].items, #expected)
for i, want in ipairs(expected) do
    Assert.eq(items[2].items[i].value, want[1])
    Assert.eq(items[2].items[i].text, want[2])
end
Assert.eq(#items, 2, "范围都在同一组单选里，没有目标章节行")

items[1].callback()
items = page.items(page)
Assert.is_true(items[1].checked)
Assert.eq(items[2].note, "每句只缓存前 10 条。请求频繁可能被风控封号，请谨慎。")
Assert.eq(items[3].title, "缓存范围")

items[3].on_select("50")
items = page.items(page)
Assert.eq(items[3].current, "50")
Assert.eq(#items, 3, "选往后 N 章也不多出行")

local buttons = page.buttons(page)
Assert.eq(buttons[1].text, "取消")
Assert.eq(buttons[2].text, "开始")
Assert.eq(buttons[2].variant, "primary")
buttons[2].callback()
Assert.is_true(page.closed)
Assert.len(queued, 1)
Assert.is_true(queued[1].reviews)
Assert.eq(queued[1].range.chapter_idx, 3)
Assert.eq(queued[1].range.count, 50)

queued = {}
Cache.chooseRange(book, nil, true)
page = Themed.last("settings")
items = page.items(page)
Assert.is_true(items[1].checked)
Assert.eq(items[3].title, "缓存范围")
items[3].on_select("end")
page.buttons(page)[2].callback()
Assert.eq(queued[1].range.chapter_idx, 3)
Assert.is_nil(queued[1].range.count)
Assert.is_true(queued[1].reviews)

queued = {}
supported = false
Cache.chooseRange(book, nil)
page = Themed.last("settings")
items = page.items(page)
Assert.eq(items[1].title, "缓存范围")
page.buttons(page)[2].callback()
Assert.is_nil(queued[1].range, "默认全本")
Assert.is_false(queued[1].reviews)

queued = {}
Cache.chooseRange(book, nil)
page = Themed.last("settings")
items = page.items(page)
items[1].on_select("10")
Assert.len(queued, 0, "选范围不入队")
page.buttons(page)[1].callback()
Assert.is_true(page.closed)
Assert.len(queued, 0, "取消不入队")

return true
