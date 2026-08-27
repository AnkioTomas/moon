--[[--
ui.reader.bars 离线用例：时间 / 进度文案生成与系统栏可见性。

@module tests.ui.reader.bars_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, n) return n end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
        isTouchDevice = function() return true end,
    }
end
package.preload["ui/event"] = function()
    return {
        new = function(_, name, ...)
            return { name = name, args = { ... } }
        end,
    }
end

package.preload["ui.reader.session"] = function()
    return {
        chapterTitle = function(snapshot)
            if not snapshot then return nil end
            local id = snapshot.identity
            local toc = snapshot.chapter and snapshot.chapter.toc
            if toc and id and id.chapter_idx then
                local entry = toc[tonumber(id.chapter_idx)]
                return entry and entry.title
            end
            return nil
        end,
    }
end

local Bars = require("ui.reader.bars")

-- timeText：HH:MM
Assert.is_true(Bars.timeText(0):match("^%d%d:%d%d$") ~= nil)
Assert.is_true(Bars.timeText():match("^%d%d:%d%d$") ~= nil)

-- chapterTitle：按章书籍取目录 title，整本书无目录为空
local toc = {}
for i = 1, 10 do toc[i] = { idx = i, title = "第 " .. i .. " 章" } end
Assert.eq(Bars.chapterTitle(nil, toc), "")
Assert.eq(Bars.chapterTitle({}, toc), "")
Assert.eq(Bars.chapterTitle({ identity = { chapter_idx = 3 } }, toc), "第 3 章")
Assert.eq(Bars.chapterTitle({ identity = { book = { title = "书名" } } }, toc), "")
Assert.eq(
    Bars.chapterTitle({ identity = { book = { title = "书名" } } }),
    ""
)

-- progressText：空输入
Assert.eq(Bars.progressText(nil), "")
Assert.eq(Bars.progressText({}), "0%")

-- progressText：百分比夹紧
Assert.eq(Bars.progressText({ percent = 42 }), "42%")
Assert.eq(Bars.progressText({ percent = 150 }), "100%")
Assert.eq(Bars.progressText({ percent = -3 }), "0%")

-- progressText：页码 / 章号拼接
Assert.eq(Bars.progressText({ percent = 42, page = 7, total_pages = 100 }), "42% · 第 7/100 页")
Assert.eq(Bars.progressText({ percent = 5, identity = { chapter_idx = 3 } }, toc), "5% · 第 3/10 章")
Assert.eq(
    Bars.progressText({ percent = 5, page = 1, total_pages = 2, identity = { chapter_idx = 3 } }, toc),
    "5% · 第 3/10 章 · 第 1/2 页"
)

-- progressText：页数缺失/为零不拼页码
Assert.eq(Bars.progressText({ percent = 1, page = 3 }), "1%")
Assert.eq(Bars.progressText({ percent = 1, page = 3, total_pages = 0 }), "1%")

-- progressText：剩余阅读时间拼接在末尾
Assert.eq(
    Bars.progressText({ percent = 42, page = 7, total_pages = 100 }, nil, 3600 + 1800),
    "42% · 第 7/100 页 · 约 1 小时 30 分"
)

-- remainingText：不足一分钟为空；分钟 / 小时 + 分钟
Assert.eq(Bars.remainingText(nil), "")
Assert.eq(Bars.remainingText(59), "")
Assert.eq(Bars.remainingText(60), "约 1 分钟")
Assert.eq(Bars.remainingText(5400), "约 1 小时 30 分")

-- systemTopVisible / systemBottomVisible
local events = {}
local ui_top = {
    rolling = true,
    document = {
        getHeaderHeight = function() return 28 end,
        configurable = { status_line = 0, h_page_margins = { 10, 10 } },
    },
    view = {
        view_mode = "page",
        dimen = { w = 600, h = 800 },
        state = { offset = { y = 12 } },
        footer_visible = true,
        footer = {
            getHeight = function() return 32 end,
            onToggleFooterMode = function() end,
            footer_positioner = {
                dimen = { h = 800, y = 0 },
                contentRange = function()
                    return { x = 0, y = 768, w = 600, h = 32 }
                end,
            },
        },
    },
    handleEvent = function(_, event) events[#events + 1] = event end,
}
Assert.is_true(Bars.systemTopVisible(ui_top))
Assert.is_true(Bars.systemBottomVisible(ui_top))
Assert.is_true(Bars.topVisible(ui_top))
Assert.is_true(Bars.bottomVisible(ui_top))
Assert.eq(Bars.topHeight(ui_top), 28)
Assert.eq(Bars.topOffset(ui_top), 12)
Assert.eq(Bars.bottomHeight(ui_top), 32)

ui_top.document.getHeaderHeight = function() return 0 end
Assert.is_false(Bars.systemTopVisible(ui_top))
Assert.eq(Bars.topHeight(ui_top), 0)

ui_top.document.getHeaderHeight = function() return 28 end
ui_top.view.view_mode = "scroll"
Assert.is_false(Bars.systemTopVisible(ui_top))

ui_top.view.view_mode = "page"
ui_top.view.footer_visible = false
Assert.is_false(Bars.systemBottomVisible(ui_top))
Assert.eq(Bars.bottomHeight(ui_top), 0)

-- toggleSystemTop：按实际显隐切换，并同步 ConfigChange
ui_top.document.configurable.status_line = 0
events = {}
Bars.toggleSystemTop(ui_top)
Assert.eq(events[1].name, "ConfigChange")
Assert.eq(events[1].args[1], "status_line")
Assert.eq(events[1].args[2], 1)
Assert.eq(events[2].name, "SetStatusLine")
Assert.eq(events[2].args[1], 1)
ui_top.document.getHeaderHeight = function() return 0 end
events = {}
Bars.toggleSystemTop(ui_top)
Assert.eq(events[1].args[2], 0)
Assert.eq(events[2].args[1], 0)

-- toggleSystemBottom：调 footer:onToggleFooterMode
local toggled = false
ui_top.view.footer.onToggleFooterMode = function() toggled = true end
ui_top.view.footer_visible = true
Bars.toggleSystemBottom(ui_top)
Assert.is_true(toggled)

-- hijackFooter：底栏可见时 TapFooter / onHoldFooter 吞手势
local footer = {
    ui = ui_top,
    TapFooter = function() return false end,
    onHoldFooter = function() return false end,
}
ui_top.view.footer = footer
ui_top._book_bars_installed = nil
Bars.install(ui_top)
Assert.is_true(footer:TapFooter())
Assert.is_true(footer:onHoldFooter())
