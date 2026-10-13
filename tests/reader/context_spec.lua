--[[-- reader.context：选区句子/段落、当前页、前序正文。 --]]

local Assert = require("support.assert")
local current_session = { page = 7 }
package.preload["reader.session"] = function()
    return { current = function() return current_session end }
end
local Context = require("reader.context")

local rolling = {
    rolling = {},
    view = { dimen = { w = 600, h = 800 } },
    getCurrentPage = function() return 7 end,
    document = {
        getTextFromPositions = function(document, from, to, no_draw)
            Assert.eq(from.x, 0)
            Assert.eq(to.y, 800)
            Assert.is_true(no_draw)
            return { text = "  当前页正文  " }
        end,
    },
}
local text, page = Context.visibleText(rolling)
Assert.eq(text, "当前页正文")
Assert.eq(page, 7)

current_session.page = 3
local paging = {
    getCurrentPage = function() return 3 end,
    document = {
        getTextBoxes = function(document, page_num)
            return { { { word = "page" .. tostring(page_num) } } }
        end,
    },
}
text, page = Context.visibleText(paging)
Assert.eq(text, "page3")
Assert.eq(page, 3)

local empty = Context.visibleText({ document = { getTextBoxes = function(document) return {} end } })
Assert.is_nil(empty)

Assert.eq(Context.currentPage(), 3)

local prior = Context.priorText(paging, 3)
Assert.matches(prior, "page1")
Assert.matches(prior, "page2")
Assert.is_false(prior:find("page3", 1, true) ~= nil)

local ctx = Context.forAnalysis(paging)
Assert.eq(ctx.current_page, "page3")
Assert.matches(ctx.prior_text, "page2")
Assert.eq(ctx.page, 3)

-- 分页文档有目录：前文只取本章（第 2 页起）
paging.toc = {
    isChapterStart = function(toc, page_num) return page_num == 2 end,
    getPreviousChapter = function(toc, page_num) return page_num > 2 and 2 or nil end,
}
prior = Context.priorText(paging, 3)
Assert.eq(prior, "page2")
Assert.eq(Context.priorText(paging, 2), "", "章首页没有本章前文")

-- 滚动文档：按章首页与当前页的 xpointer 取区间文本，过长保留末尾
local ranges = {}
local cre = {
    rolling = {},
    toc = paging.toc,
    document = {
        getPageXPointer = function(document, page_num) return "xp" .. page_num end,
        getTextFromXPointers = function(document, from, to)
            ranges[#ranges + 1] = from .. "-" .. to
            return "  本章" .. string.rep("字", 10000) .. "末尾  "
        end,
    },
}
prior = Context.priorText(cre, 5)
Assert.eq(ranges[1], "xp2-xp5")
Assert.is_true(#prior <= 24000)
Assert.matches(prior, "末尾$")
Assert.is_nil(prior:find("本章", 1, true))
Assert.is_true(#Context.priorText(cre, 5, 2000) <= 2000)
cre.document.getTextFromXPointers = function() error("bad xpointer") end
Assert.eq(Context.priorText(cre, 5), "")

-- 段落 xpointer：去掉 text() 与偏移，跳出行内元素，停在块元素
Assert.eq(Context.blockXPointer("/body/DocFragment[3]/body/div/p[12]/text().5"), "/body/DocFragment[3]/body/div/p[12]")
Assert.eq(Context.blockXPointer("/body/DocFragment[3]/body/p[2]/em/span[2]/text()[2].0"), "/body/DocFragment[3]/body/p[2]")
Assert.eq(Context.blockXPointer("/body/DocFragment/body/p[3].0"), "/body/DocFragment/body/p[3]")
Assert.eq(Context.blockXPointer("/body"), "/body")

-- 整句：向前到上一个句末标点，向后到下一个句末标点并带上右引号
local para = "他推开门。“她不在，”老人说，“去镇上了。”他沉默了。"
Assert.eq(Context.sentence(para, "老人"), "“她不在，”老人说，“去镇上了。”")
Assert.eq(Context.sentence(para, "推开"), "他推开门。")
Assert.eq(Context.sentence(para, "沉默"), "他沉默了。")
Assert.eq(Context.sentence("He left. Mary refused to speak to him! Then", "refused"), "Mary refused to speak to him!")
Assert.eq(Context.sentence("没有标点的一段话", "标点"), "没有标点的一段话")
Assert.eq(Context.sentence(para, "不在段落里"), "不在段落里", "段落里找不到就退回选中文字")
Assert.eq(Context.sentence("", "月色"), "月色")

-- 同一个词在段里出现多次：skip 定位到第 skip+1 处；skip 超出时停在最后一处
local repeated = "月色很好。他望着那片月色，久久不语。"
Assert.eq(Context.sentence(repeated, "月色"), "月色很好。")
Assert.eq(Context.sentence(repeated, "月色", 1), "他望着那片月色，久久不语。")
Assert.eq(Context.sentence(repeated, "月色", 5), "他望着那片月色，久久不语。")

-- 选区：滚动文档按 pos0 取所在段落，段首到 pos0 的文字决定是段里第几处；分页文档没有段落
local asked, prefix_range
local cre_sel = {
    rolling = {},
    document = {
        getTextFromXPointer = function(document, xp)
            asked = xp
            return "  月色很好。他望着那片月色，久久不语。后一句。  "
        end,
        getTextFromXPointers = function(document, from, to)
            prefix_range = from .. "-" .. to
            return "月色很好。他望着那片"
        end,
    },
}
local sel = Context.selection(cre_sel, { text = " 月色 ", pos0 = "/body/p[4]/i/text().6" })
Assert.eq(asked, "/body/p[4]")
Assert.eq(prefix_range, "/body/p[4]-/body/p[4]/i/text().6")
Assert.eq(sel.text, "月色")
Assert.eq(sel.sentence, "他望着那片月色，久久不语。", "选的是第二处月色")
Assert.eq(sel.paragraph, "月色很好。他望着那片月色，久久不语。后一句。")

-- 跨行选区：段前文字里是 \r\n，规范后才数得出前面已有一处
cre_sel.document.getTextFromXPointer = function() return "甲\n乙。丙。甲\n乙，后文。" end
cre_sel.document.getTextFromXPointers = function() return "甲\r\n乙。丙。" end
sel = Context.selection(cre_sel, { text = "甲\r\n乙", pos0 = "/body/p[4]/text().9" })
Assert.eq(sel.text, "甲\n乙")
Assert.eq(sel.sentence, "甲\n乙，后文。", "选的是第二处")

sel = Context.selection({ document = {} }, { text = "月色", pos0 = { page = 3 } })
Assert.eq(sel.sentence, "月色")
Assert.eq(sel.paragraph, "")
