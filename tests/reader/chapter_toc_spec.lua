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

package.loaded["reader.chapter_toc"] = nil
local ChapterToc = require("reader.chapter_toc")

local selected, selected_anchor
local adapter = ChapterToc.show({
    {
        idx = 1,
        title = "道经",
        depth = 1,
        anchors = { { title = "第一章", depth = 2 } },
    },
    { idx = 2, title = "第二章", depth = 2, vip = true, paid = true },
    { idx = 3, title = "第三章", vip = true, paid = false },
    { idx = 4, title = "第四章", vip = true },
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
Assert.eq(shown.toc[3].title, "第二章（已购）")
Assert.eq(shown.toc[4].title, "第三章（未购）")
Assert.eq(shown.toc[5].title, "第四章")
Assert.eq(shown:getTitle(), "目录")
Assert.eq(selected, 1)
Assert.eq(selected_anchor.title, "第一章")

-- pageno 永远是数字：nil / 不在目录 / 空标题章都不能把 nil 传给 ReaderToc。
local toc = {
    { idx = 1, title = "一" },
    { idx = 3, title = "" },
    { idx = 5, title = "五" },
}
Assert.eq(ChapterToc.show(toc, nil, function() end).pageno, 1)
Assert.eq(ChapterToc.show(toc, 3, function() end).pageno, 2, "空标题章仍有页码")
Assert.eq(ChapterToc.show(toc, 3, function() end).toc[2].title, "#3")
Assert.eq(ChapterToc.show(toc, 4, function() end).pageno, 2, "缺章时落到不大于当前 idx 的最近一章")
Assert.eq(ChapterToc.show(toc, 99, function() end).pageno, 3)

-- 卷名不占独立章节序号：切卷时插入 depth=1 的卷标题，点按打开该卷第一章。
do
    local jumped
    local shown = ChapterToc.show({
        { idx = 1, title = "第1章", depth = 2, volume = "第一卷" },
        { idx = 2, title = "第2章", depth = 2, volume = "第一卷" },
        { idx = 3, title = "第3章", depth = 2, volume = "第二卷" },
    }, 1, function(idx, anchor)
        jumped = { idx = idx, anchor = anchor }
    end)
    Assert.eq(shown.toc[1].title, "第一卷")
    Assert.eq(shown.toc[1].depth, 1)
    Assert.eq(shown.toc[2].title, "第1章")
    Assert.eq(shown.toc[2].depth, 2)
    Assert.eq(shown.toc[3].title, "第2章")
    Assert.eq(shown.toc[4].title, "第二卷")
    Assert.eq(shown.toc[5].title, "第3章")
    shown.ui:handleEvent({ handler = "onGotoPage", args = { 1 } })
    Assert.eq(jumped.idx, 1)
    Assert.is_nil(jumped.anchor)
    shown.ui:handleEvent({ handler = "onGotoPage", args = { 4 } })
    Assert.eq(jumped.idx, 3)
end
