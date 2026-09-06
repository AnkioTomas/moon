--[[-- 连续章节目录的 ReaderToc 适配用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function()
    return { apply = function() end }
end
package.preload["gettext"] = function()
    return function(value) return value end
end

local shown
package.preload["apps/reader/modules/readertoc"] = function()
    return {
        onShowToc = function(self)
            shown = self
            self.ui:handleEvent({ handler = "onGotoPage", args = { 2 } })
        end,
    }
end

package.loaded["ui.reader.chapter_toc"] = nil
local ChapterToc = require("ui.reader.chapter_toc")

local selected, selected_anchor
local adapter = ChapterToc.show({
    {
        idx = 1,
        title = "道经",
        depth = 1,
        anchors = { { title = "第一章", depth = 2 } },
    },
    { idx = 2, title = "第二章", depth = 2 },
}, 2, function(idx, anchor)
    selected = idx
    selected_anchor = anchor
end)

adapter.ui:handleEvent({ handler = "onGotoPage", args = { 2 } })

Assert.eq(adapter, shown)
Assert.eq(shown.pageno, 3)
Assert.eq(shown.toc[1].title, "道经")
Assert.eq(shown.toc[1].page, 1)
Assert.eq(shown.toc[2].title, "第一章")
Assert.eq(shown.toc[2].depth, 2)
Assert.eq(shown.toc[3].title, "第二章")
Assert.eq(shown:getTitle(), "目录")
Assert.eq(selected, 1)
Assert.eq(selected_anchor.title, "第一章")
