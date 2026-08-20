--[[-- ai.context：滚动/分页文档当前页文本采集。 --]]

local Assert = require("support.assert")
local Context = require("ai.context")

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
local text, page = Context.currentPage(rolling)
Assert.eq(text, "当前页正文")
Assert.eq(page, 7)

local paging = {
    getCurrentPage = function() return 3 end,
    document = {
        getTextBoxes = function()
            return { { { word = "Hello" }, { word = "world" } }, { { word = "中文" } } }
        end,
    },
}
text, page = Context.currentPage(paging)
Assert.eq(text, "Hello world 中文")
Assert.eq(page, 3)

local empty = Context.currentPage({ document = { getTextBoxes = function() return {} end } })
Assert.is_nil(empty)
