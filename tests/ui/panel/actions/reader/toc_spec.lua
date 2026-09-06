--[[-- 阅读页目录快捷动作离线用例。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local state = {
    chapter_mode = false,
    toc = nil,
    goto_idx = nil,
    chapter_toc = nil,
}

package.preload["ui.reader.session"] = function()
    return {
        isChapterMode = function() return state.chapter_mode end,
        toc = function() return state.toc end,
        chapterIndex = function() return 2 end,
        gotoChapter = function(idx) state.goto_idx = idx end,
    }
end

package.preload["ui.reader.chapter_toc"] = function()
    return {
        show = function(toc, current_idx, on_select)
            state.chapter_toc = {
                toc = toc,
                current_idx = current_idx,
                on_select = on_select,
            }
        end,
    }
end

local native_calls = 0
local ui = {
    toc = {
        onShowToc = function() native_calls = native_calls + 1 end,
    },
}

package.loaded["ui.panel.actions.reader.toc"] = nil
local action = require("ui.panel.actions.reader.toc")

action.run({ ui = ui })
Assert.eq(native_calls, 1)
Assert.is_nil(state.chapter_toc)

state.chapter_mode = true
state.toc = {
    { idx = 1, title = "第一章", depth = 1 },
    { idx = 2, title = "第二章", depth = 2 },
}
action.run({ ui = ui })
Assert.eq(native_calls, 1)
Assert.not_nil(state.chapter_toc)
Assert.eq(state.chapter_toc.toc, state.toc)
Assert.eq(state.chapter_toc.current_idx, 2)

state.chapter_toc.on_select(1)
Assert.eq(state.goto_idx, 1)

state.toc = nil
state.chapter_toc = nil
action.run({ ui = ui })
Assert.eq(native_calls, 2)
Assert.is_nil(state.chapter_toc)
