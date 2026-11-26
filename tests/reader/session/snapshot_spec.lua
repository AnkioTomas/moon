--[[-- reader.session.snapshot.refresh：每翻一页只问一次当前章（CRE getTocIndexByPage 很贵）。 --]]

local Assert = require("support.assert")

local current_calls = 0
package.preload["reader.session.chapter"] = function()
    return { chapterTitle = function() end, toc = function() end }
end
package.preload["reader.session.document_toc"] = function()
    return {
        list = function() return { { idx = 1, title = "一" }, { idx = 2, title = "二" }, { idx = 3, title = "三" } } end,
        current = function()
            current_calls = current_calls + 1
            return { idx = 3, title = "三" }
        end,
        chapterPages = function() end,
        chapterFraction = function() return 0.4 end,
    }
end
package.loaded["reader.session.toc"] = nil
package.loaded["reader.session.snapshot"] = nil
local Snapshot = require("reader.session.snapshot")

local session = {
    identity = { source_id = "local", stable_id = "/a.epub" },
    ui = { document = { getPageCount = function() return 200 end } },
    page = 0, total_pages = 0,
}
Snapshot.refresh(session, 50)
Assert.eq(current_calls, 1, "当前章只算一次")
Assert.eq(session.page, 50)
Assert.eq(session.total_pages, 200)
Assert.eq(session.reading_chapter_idx, 3)
Assert.eq(session.position.chapter_title, "三")
Assert.eq(session.position.chapter_idx, 3)
Assert.eq(session.chapter_fraction, 0.4, "章内比例取文档目录")
Assert.eq(session.fraction, 0.25)
Assert.eq(session.percent, 25)

for _idx, name in ipairs({ "reader.session.chapter", "reader.session.document_toc",
    "reader.session.toc", "reader.session.snapshot" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end

return true
