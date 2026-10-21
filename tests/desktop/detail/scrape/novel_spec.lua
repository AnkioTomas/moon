--[[--
desktop.detail.scrape.novel 离线用例：数据源 Book 映射

@module tests.desktop.detail.scrape.novel_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch

local Assert = require("support.assert")
local Novel = require("desktop.detail.scrape.novel")

do
    local rows = Novel.fromBooks("qimao", { { title = " 书 ", authors = "乙", category = "玄幻", cover = "u" } })
    Assert.eq(rows[1].title, "书")
    Assert.eq(rows[1].author, "乙")
    Assert.eq(rows[1].tags[1], "玄幻")
    Assert.eq(rows[1].source, "qimao")
end
