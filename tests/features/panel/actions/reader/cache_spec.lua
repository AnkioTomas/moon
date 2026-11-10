--[[-- 缓存快捷动作：仅章节源连续阅读可用，复用详情页缓存入口。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local state = {
    chapter_mode = false,
    identity = nil,
    choose = {},
}

package.preload["reader.session"] = function()
    return {
        isChapterMode = function() return state.chapter_mode end,
        current = function()
            return state.identity and { identity = state.identity } or nil
        end,
    }
end

package.preload["desktop.detail.cache"] = function()
    return {
        supported = function(book, source)
            return book ~= nil and source ~= nil and source.type == "chapter"
                and type(source.cacheAllChaptersAsync) == "function"
        end,
        chooseRange = function(book, source, with_reviews)
            state.choose[#state.choose + 1] = {
                book = book, source = source, with_reviews = with_reviews,
            }
        end,
    }
end

package.loaded["features.panel.actions.reader.cache"] = nil
local action = require("features.panel.actions.reader.cache")

Assert.eq(action.id, "cache")
Assert.eq(action.title, "缓存")
Assert.eq(action.icon, "download")
Assert.eq(action.scope, "reader")
Assert.is_true(action.available({}), "设置页无 ui 可勾选")
Assert.is_false(action.available({ ui = {} }), "无会话不显示")

-- 全书模式（无 chapter_idx）
state.chapter_mode = false
state.identity = {
    source_id = "wechat", stable_id = "b1", ephemeral = false,
    book = { source_id = "wechat", stable_id = "b1", title = "书" },
    source = { type = "chapter", cacheAllChaptersAsync = function() end },
}
Assert.is_false(action.available({ ui = {} }), "全书模式不显示")

-- 订阅（ephemeral）即使是章节模式也不显示
state.chapter_mode = true
state.identity.ephemeral = true
Assert.is_false(action.available({ ui = {} }), "订阅不显示")

-- 章节源连续阅读显示
state.identity.ephemeral = false
Assert.is_true(action.available({ ui = {} }), "章节阅读显示")

-- 点击复用详情页 chooseRange
action.run()
Assert.len(state.choose, 1)
Assert.eq(state.choose[1].book.stable_id, "b1")
Assert.eq(state.choose[1].source.type, "chapter")
Assert.is_nil(state.choose[1].with_reviews)

-- 整书源（type=book）即使带 chapter_idx 也不显示
state.identity.source = { type = "book" }
Assert.is_false(action.available({ ui = {} }), "整书源不显示")
