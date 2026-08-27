--[[-- xray.context：当前页 + 前序正文。 --]]

local Assert = require("support.assert")
local Context = require("xray.context")

local rolling = {
    rolling = {},
    view = { dimen = { w = 600, h = 800 } },
    getCurrentPage = function() return 7 end,
    document = {
        getTextFromPositions = function(_, from, to, no_draw)
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

local paging = {
    getCurrentPage = function() return 3 end,
    document = {
        getTextBoxes = function(_, page_num)
            return { { { word = "page" .. tostring(page_num) } } }
        end,
    },
}
text, page = Context.visibleText(paging)
Assert.eq(text, "page3")
Assert.eq(page, 3)

local empty = Context.visibleText({ document = { getTextBoxes = function() return {} end } })
Assert.is_nil(empty)

Assert.eq(Context.currentPage({ getCurrentPage = function() return 5 end }), 5)

local prior = Context.priorText(paging, 3, 2000)
Assert.matches(prior, "page1")
Assert.matches(prior, "page2")
Assert.is_false(prior:find("page3", 1, true) ~= nil)

local ctx = Context.forAnalysis(paging)
Assert.eq(ctx.current_page, "page3")
Assert.matches(ctx.prior_text, "page2")
Assert.eq(ctx.page, 3)
