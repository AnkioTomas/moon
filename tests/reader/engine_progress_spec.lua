--[[-- reader.engine_progress：开书 / 重排进度走主题 ProgressDialog；开书弹窗从 0% 起，重排沿用 2 秒延迟与 500ms 节流。 --]]

local Assert = require("support.assert")

local now_ms = 0
package.preload["ui/time"] = function()
    return { s = function(n) return n * 1000 end, ms = function(n) return n end, now = function() return now_ms end }
end
local dialogs, forced, ticks = {}, 0, {}
package.preload["ui/uimanager"] = function()
    return {
        forceRePaint = function() forced = forced + 1 end,
        nextTick = function(_s, fn) ticks[#ticks + 1] = fn end,
    }
end
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return {
        new = function(_s, o)
            o.sets = {}
            o.show = function(self) self.shown = true end
            o.close = function(self) self.closed = true end
            o.set = function(self, text, pct) self.sets[#self.sets + 1] = { text, pct } end
            dialogs[#dialogs + 1] = o
            return o
        end,
    }
end
local ReaderUIStub = {}
package.preload["apps/reader/readerui"] = function() return ReaderUIStub end

local EngineProgress = require("reader.engine_progress")
local rolling = {}
EngineProgress.install(rolling)

-- 没有开书弹窗（阅读中重排）：第一次只起 2 秒倒计时；到点才弹窗，500ms 内不重复刷。
rolling:showEngineProgress(0.1)
Assert.len(dialogs, 0)
now_ms = 1000
rolling:showEngineProgress(0.1)
Assert.len(dialogs, 0)
now_ms = 2000
rolling:showEngineProgress(0.1)
Assert.len(dialogs, 1)
Assert.is_true(dialogs[1].shown)
Assert.eq(dialogs[1].sets[1][1], "正在载入书籍")
now_ms = 2200
rolling:showEngineProgress(0.2)
Assert.len(dialogs[1].sets, 1)
now_ms = 2500
rolling:showEngineProgress(0.7)
Assert.eq(dialogs[1].sets[2][1], "正在排版")
Assert.eq(dialogs[1].sets[2][2], 70)
rolling:showEngineProgress(nil)
Assert.is_true(dialogs[1].closed)
Assert.is_nil(rolling.engine_progress_update_not_before)

-- 原生开关关闭时不弹。
_G.G_reader_settings = { isFalse = function() return true end }
now_ms = 10000
rolling:showEngineProgress(0.5)
now_ms = 20000
rolling:showEngineProgress(0.5)
Assert.len(dialogs, 1)
_G.G_reader_settings = nil

-- 开书：弹「正在打开」，引擎进度无延迟地更新同一个弹窗，开完关窗；seamless 不弹。
EngineProgress.patchOpen()
local patched = ReaderUIStub.showReaderCoroutine
EngineProgress.patchOpen()
Assert.eq(ReaderUIStub.showReaderCoroutine, patched, "重复安装不叠加")
local shown = {}
ReaderUIStub.doShowReader = function(_self, file)
    shown[#shown + 1] = file
    now_ms = 30000
    rolling.engine_progress_update_not_before = nil
    rolling:showEngineProgress(0.25)
end
ReaderUIStub:showReaderCoroutine("a.epub", nil, false)
local open = dialogs[2]
Assert.eq(open.title, "正在打开")
Assert.is_true(open.shown)
ticks[#ticks]()
Assert.eq(shown[1], "a.epub")
Assert.eq(open.sets[1][2], 25, "开书弹窗不等 2 秒延迟")
Assert.is_true(open.closed)
Assert.is_nil(ReaderUIStub._book_open_dialog)
ReaderUIStub:showReaderCoroutine("b.epub", nil, true)
Assert.len(dialogs, 2)
