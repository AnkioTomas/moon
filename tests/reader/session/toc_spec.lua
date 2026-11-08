--[[-- 连续章节 Toc.current：空标题不能把当前章判没。 --]]

local Assert = require("support.assert")

local title
package.preload["reader.session.chapter"] = function()
    return {
        chapterTitle = function() return title end,
        toc = function() return nil end,
    }
end
package.preload["reader.session.document_toc"] = function()
    return {
        list = function() return nil end,
        current = function() return { idx = 9, title = "文档" } end,
        chapterPages = function() end,
        chapterFraction = function() end,
    }
end

package.loaded["reader.session.toc"] = nil
local Toc = require("reader.session.toc")

local session = { identity = { chapter_idx = 2 } }

title = "正文"
local cur = Toc.current(session)
Assert.eq(cur.idx, 2)
Assert.eq(cur.title, "正文")

-- 空标题：仍返回当前章，显示回落成 #idx（PR #106 崩溃根因）。
title = nil
cur = Toc.current(session)
Assert.eq(cur.idx, 2)
Assert.eq(cur.title, "#2")

Assert.is_nil(Toc.current(nil))
Assert.is_nil(Toc.current({ identity = { chapter_idx = "x" } }))

-- 非整书章节会话：走文档 TOC。
cur = Toc.current({ identity = {}, ui = {} })
Assert.eq(cur.idx, 9)
Assert.eq(cur.title, "文档")

return true
