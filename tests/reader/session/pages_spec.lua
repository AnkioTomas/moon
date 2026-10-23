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

Assert.is_nil((Pages.estimate({ {}, {} }, 1, 1, 5)))
Assert.is_nil((Pages.estimate(nil, 1, 1, 5)))
