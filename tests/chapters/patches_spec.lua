--[[--
chapters patches 离线用例：ReaderUI rolling/paging 边界包装

@module tests.chapters.patches_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Fakes = require("support.chapter_fakes")
Stubs.install()
Stubs.reset()
-- patches 只需要 ui/event 替身，不碰 readerui / book.store
Fakes.install({ readerui = false, store = false })

for _, name in ipairs({ "chapters.patches", "chapters.session", "ui/event" }) do
    package.loaded[name] = nil
end

local Patches = require("chapters.patches")
local Session = require("chapters.session")

--- 造假 ReaderUI：rolling/paging 的 onGotoViewRel 模拟引擎翻页（越界时原地不动），
--- handleEvent 把事件收进返回的 events 表。
local function makeUi(opts)
    opts = opts or {}
    local ui = { name = "ReaderUI" }
    local events = {}
    function ui:handleEvent(ev)
        events[#events + 1] = ev
    end
    local max_page = opts.max_page or 1
    ui.rolling = {
        ui = ui,
        current_page = opts.page or 1,
        onGotoViewRel = function(self, diff)
            local target = self.current_page + diff
            if target >= 1 and target <= max_page then
                self.current_page = target
            end
            return "rolled"
        end,
    }
    ui.paging = {
        ui = ui,
        _top = opts.top or 1,
        getTopPage = function(self)
            return self._top
        end,
        onGotoViewRel = function(self, diff)
            local target = self._top + diff
            if target >= 1 and target <= max_page then
                self._top = target
            end
            return "paged"
        end,
    }
    return ui, events
end

local function bindSession()
    Session.bind({ ref = { source_id = "wechat", stable_id = "b1" } })
end

-- 未 enable：完全透传（返回值原样、不触发事件），即使会话 active
do
    local ui, events = makeUi({ page = 1, max_page = 5 })
    Patches.wrapReaderUi(ui)
    Patches.disable()
    bindSession()
    local ret = ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.eq(ret, "rolled")
    Assert.len(events, 0)
    Assert.eq(ui.rolling.current_page, 1)
    local ret2 = ui.paging.onGotoViewRel(ui.paging, -1)
    Assert.eq(ret2, "paged")
    Assert.len(events, 0)
end

-- enable 但会话不 active：同样透传不触发
do
    local ui, events = makeUi({ page = 1, max_page = 5 })
    Patches.wrapReaderUi(ui)
    Patches.enable()
    Session.clear()
    ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.len(events, 0)
    Patches.disable()
end

-- 翻到顶再向前翻：触发 StartOfBook
do
    local ui, events = makeUi({ page = 1, max_page = 5 })
    Patches.wrapReaderUi(ui)
    Patches.enable()
    bindSession()
    ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.len(events, 1)
    Assert.eq(events[1].name, "StartOfBook")
    Patches.disable()
end

-- 中间页向前翻（页码确实变了）：不触发
do
    local ui, events = makeUi({ page = 3, max_page = 5 })
    Patches.wrapReaderUi(ui)
    Patches.enable()
    bindSession()
    ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.eq(ui.rolling.current_page, 2)
    Assert.len(events, 0)
    Patches.disable()
end

-- 向后翻（diff > 0）即使原地不动也不触发
do
    local ui, events = makeUi({ page = 1, max_page = 1 })
    Patches.wrapReaderUi(ui)
    Patches.enable()
    bindSession()
    ui.rolling.onGotoViewRel(ui.rolling, 1)
    Assert.eq(ui.rolling.current_page, 1)
    Assert.len(events, 0)
    Patches.disable()
end

-- scroll 模式：看 current_pos 而非 current_page
do
    local ui, events = makeUi({ page = 1, max_page = 5 })
    ui.rolling.view = { view_mode = "scroll" }
    ui.rolling.current_pos = 0
    Patches.wrapReaderUi(ui)
    Patches.enable()
    bindSession()
    -- 引擎在 scroll 模式到顶时 current_pos 不变
    ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.len(events, 1)
    Assert.eq(events[1].name, "StartOfBook")
    Patches.disable()
end

-- paging：到顶（getTopPage == 1）再向前翻触发；页码变了不触发
do
    local ui, events = makeUi({ top = 1, max_page = 5 })
    Patches.wrapReaderUi(ui)
    Patches.enable()
    bindSession()
    local ret = ui.paging.onGotoViewRel(ui.paging, -1)
    Assert.eq(ret, "paged")
    Assert.len(events, 1)
    Assert.eq(events[1].name, "StartOfBook")
    -- 第 2 页向前翻到第 1 页：位置变了，不触发
    ui.paging._top = 2
    ui.paging.onGotoViewRel(ui.paging, -1)
    Assert.eq(ui.paging._top, 1)
    Assert.len(events, 1)
    Patches.disable()
end

-- enable/disable 开关：disable 后不再触发
do
    local ui, events = makeUi({ page = 1, max_page = 5 })
    Patches.wrapReaderUi(ui)
    bindSession()
    Patches.enable()
    ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.len(events, 1)
    Patches.disable()
    ui.rolling.onGotoViewRel(ui.rolling, -1)
    Assert.len(events, 1)
end

-- 重复 wrap 幂等：_wrapped 标记挡第二次，包装函数不换
do
    local ui = makeUi({ page = 1 })
    Patches.wrapReaderUi(ui)
    Assert.is_true(ui._ref_book_chapters_wrapped)
    local wrapped_rolling = ui.rolling.onGotoViewRel
    local wrapped_paging = ui.paging.onGotoViewRel
    Patches.wrapReaderUi(ui)
    Assert.eq(ui.rolling.onGotoViewRel, wrapped_rolling)
    Assert.eq(ui.paging.onGotoViewRel, wrapped_paging)
end

-- 非 ReaderUI / nil：不包装
do
    Patches.wrapReaderUi(nil)
    local fake = { name = "SomethingElse" }
    Patches.wrapReaderUi(fake)
    Assert.is_nil(fake._ref_book_chapters_wrapped)
    -- 传入外层对象：经 read_ui.ui 找到真 ReaderUI
    local inner = makeUi({ page = 1 })
    Patches.wrapReaderUi({ name = "wrapper", ui = inner })
    Assert.is_true(inner._ref_book_chapters_wrapped)
end

Session.clear()
