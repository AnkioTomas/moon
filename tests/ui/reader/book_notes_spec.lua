--[[--
ui.reader.book_notes 离线用例：全书笔记汇总（按章排序、当前章用内存注解）、
章节模式接管原生书签列表、点击跳转（本章定位 / 他章切章带 xpointer）。

@module tests.ui.reader.book_notes_spec
--]]

local Assert = require("support.assert")

local state = { rows = {}, snapshot = nil, goto_calls = {}, shown = nil, closed = 0 }

package.preload["json"] = function()
    local JsonStub = require("support.json_stub")
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["db.note"] = function()
    return { all = function() return state.rows end }
end
package.preload["ui.reader.session"] = function()
    return {
        current = function() return state.snapshot end,
        gotoChapter = function(idx, opts)
            state.goto_calls[#state.goto_calls + 1] = { idx = idx, opts = opts }
            return true
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) state.shown = w end,
        close = function() state.closed = state.closed + 1 end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, a) return { name = name, arg = a } end }
end
package.preload["ui/widget/menu"] = function()
    return { new = function(_, o) return o end }
end
for _, name in ipairs({ "json", "l10n", "gettext", "db.note", "ui.reader.session", "ui/uimanager",
    "ui/event", "ui/widget/menu", "ui.reader.book_notes" }) do
    package.loaded[name] = nil
end

local BookNotes = require("ui.reader.book_notes")

state.rows = {
    { source_id = "wechat", stable_id = "b1", chapter_idx = 5,
      payload = '[{"text":"五章划线","page":"/body/p[3]/text().0","note":"想法五"}]' },
    { source_id = "wechat", stable_id = "b1", chapter_idx = 2,
      payload = '{"authoritative":true,"items":[{"text":"二章远端","wr_range":"1-2"},{"text":""}]}' },
    { source_id = "wechat", stable_id = "b1", chapter_idx = 3,
      payload = '[{"text":"三章库里旧快照"}]' },
    { source_id = "wechat", stable_id = "other", chapter_idx = 1, payload = '[{"text":"别的书"}]' },
}

-- 汇总：按章序排列，当前章（3）用内存注解替换库里旧快照，空文本与别的书丢掉。
do
    local live = { { text = "三章新划线", pos0 = "/body/p[1]/text().4" } }
    local out = BookNotes.collect("wechat", "b1", 3, live, { [2] = "第二章", [3] = "第三章" })
    Assert.eq(#out, 3)
    Assert.eq(out[1].chapter_idx, 2)
    Assert.eq(out[1].chapter, "第二章")
    Assert.is_nil(out[1].xpointer, "远端未开过章的条目没有位置")
    Assert.eq(out[2].text, "三章新划线")
    Assert.eq(out[2].xpointer, "/body/p[1]/text().4")
    Assert.eq(out[3].chapter_idx, 5)
    Assert.eq(out[3].note, "想法五")
    Assert.eq(out[3].xpointer, "/body/p[3]/text().0")
end

-- 当前章没有库行也照样出现。
do
    local out = BookNotes.collect("wechat", "b1", 9, { { text = "九章" } }, {})
    Assert.eq(out[#out].chapter_idx, 9)
    Assert.eq(out[#out].text, "九章")
end

local function fakeUi(live)
    local ui = { events = {}, annotation = { annotations = live } }
    function ui:handleEvent(ev) self.events[#self.events + 1] = ev end
    local native_calls = 0
    ui.bookmark = { onShowBookmark = function() native_calls = native_calls + 1 end }
    return ui, function() return native_calls end
end

-- 非章节模式：原样走 KOReader 原生列表。
do
    local ui, native = fakeUi({})
    BookNotes.install(ui)
    state.snapshot = { identity = { source_id = "wechat", stable_id = "b1" } }
    ui.bookmark:onShowBookmark()
    Assert.eq(native(), 1)
    BookNotes.install(ui)
    ui.bookmark:onShowBookmark()
    Assert.eq(native(), 2, "重复 install 不会套两层")
end

-- 章节模式：弹全书列表；本章条目直接定位，他章条目切章并带 xpointer，左键回原生列表。
do
    local ui, native = fakeUi({ { text = "三章新划线", pos0 = "/body/p[1]/text().4" } })
    BookNotes.install(ui)
    state.snapshot = {
        identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 3 },
        chapter = { toc = { { idx = 2, title = "第二章" }, { idx = 3, title = "第三章" }, { idx = 5, title = "第五章" } } },
    }
    state.goto_calls = {}
    ui.bookmark:onShowBookmark()
    Assert.eq(native(), 0)
    local menu = state.shown
    Assert.eq(#menu.item_table, 3)
    Assert.matches(menu.title, "3")
    Assert.eq(menu.item_table[2].mandatory, "第三章")
    Assert.is_true(menu.item_table[2].bold)
    Assert.eq(menu.item_table[3].text, "五章划线\n✎ 想法五")

    menu.item_table[2].callback()
    Assert.eq(ui.events[1].name, "GotoXPointer")
    Assert.eq(ui.events[1].arg, "/body/p[1]/text().4")
    Assert.eq(#state.goto_calls, 0)

    menu.item_table[3].callback()
    Assert.eq(state.goto_calls[1].idx, 5)
    Assert.eq(state.goto_calls[1].opts.xpointer, "/body/p[3]/text().0")

    menu.item_table[1].callback()
    Assert.eq(state.goto_calls[2].idx, 2)
    Assert.is_nil(state.goto_calls[2].opts.xpointer, "没有位置时落到章首")

    menu:onLeftButtonTap()
    Assert.eq(native(), 1)
end
