--[[--
book.progress.position 纯计算测试。

@module tests.book.progress_position_spec
--]]

local Assert = require("support.assert")
local Position = require("book.progress.position")

do
    local snapshot = {
        doc_fraction = 0.5,
        identity = { chapter_idx = 2 },
        reading_chapter_idx = 2,
        page = 4,
        total_pages = 10,
        ui = { rolling = { xpointer = "xp" } },
    }
    local toc = { {}, {}, {}, {} }
    local pos = Position.position(snapshot, toc, "第二章")
    Assert.eq(pos.fraction, 0.375)
    Assert.eq(pos.chapter_idx, 2)
    Assert.eq(pos.chapter_title, "第二章")
    Assert.eq(pos.chapter_fraction, 0.5)
    Assert.eq(pos.page, 4)
    Assert.eq(pos.total_pages, 10)
    Assert.eq(pos.locator, "xp")
end

Assert.eq(Position.fraction({ doc_fraction = -1 }, nil), 0)
Assert.eq(Position.fraction({ doc_fraction = 2 }, nil), 1)
