--[[-- xray.context：当前页 + 前序正文。 --]]

local Assert = require("support.assert")
local current_session = { page = 7 }
package.preload["ui.reader.session"] = function()
    return { current = function() return current_session end }
end
local Context = require("xray.context")

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
