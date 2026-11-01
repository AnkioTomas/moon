--[[--
reader.session.pages：全书页码估算（缺字数用平均值）。

@module tests.reader.session.pages_spec
--]]

local Assert = require("support.assert")
local Pages = require("reader.session.pages")

do
    local toc = { { words = 1000 }, { words = 2000 }, { words = 1000 } }
    local p, t = Pages.estimate(toc, 2, 3, 10)
    Assert.eq(p, 8)
    Assert.eq(t, 20)
end

do
    -- 中间章无字数 → 用平均值 1500
    local toc = { { words = 1000 }, {}, { words = 2000 } }
    local p, t = Pages.estimate(toc, 2, 5, 10)
    Assert.not_nil(p)
    Assert.not_nil(t)
    Assert.is_true(t >= 10)
end

-- 多章但没字数：按本章页数外推，不能退回和章内页码相同的文档页码
do
    local p, t = Pages.estimate({ {}, {} }, 1, 1, 5)
    Assert.eq(p, 1)
    Assert.eq(t, 10)
end
do
    local p, t = Pages.estimate({ {}, {}, {} }, 2, 3, 10)
    Assert.eq(p, 13)
    Assert.eq(t, 30)
end
Assert.is_nil((Pages.estimate({ {} }, 1, 1, 5)), "只有一章，文档页码就是全书页码")
Assert.is_nil((Pages.estimate(nil, 1, 1, 5)))

-- 整本书：页码标签和隐藏流，跟章内页码同一套序号
do
    local p, t = Pages.document({
        pagemap = {
            wantsPageLabels = function() return true end,
            getCurrentPageLabel = function() return "iv", 4, 20 end,
        },
        document = {
            hasHiddenFlows = function() return true end,
            getPageFlow = function() return 0 end,
            getPageNumberInFlow = function() return 9 end,
            getTotalPagesInFlow = function() return 100 end,
        },
    }, 30, 80)
    Assert.eq(p, 4, "有页码标签时用标签序号，不用屏幕页")
    Assert.eq(t, 20)
end
do
    local p, t = Pages.document({
        document = {
            hasHiddenFlows = function() return true end,
            getPageFlow = function() return 0 end,
            getPageNumberInFlow = function() return 9 end,
            getTotalPagesInFlow = function() return 40 end,
        },
    }, 30, 80)
    Assert.eq(p, 9)
    Assert.eq(t, 40)
end
do
    local p, t = Pages.document(nil, 3, 10)
    Assert.eq(p, 3)
    Assert.eq(t, 10)
end
