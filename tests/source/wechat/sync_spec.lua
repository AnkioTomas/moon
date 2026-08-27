--[[--
source.wechat notes/annotations/mapper 离线用例

@module tests.source.wechat.sync_spec
--]]

local Assert = require("support.assert")

package.loaded["source.wechat.mapper"] = nil
package.loaded["source.wechat.notes"] = nil
package.loaded["source.wechat.annotations"] = nil

local Mapper = require("source.wechat.mapper")
local Notes = require("source.wechat.notes")
local Annotations = require("source.wechat.annotations")
local Report = require("source.wechat.report")

do
    local reporter = Report.new({})
    Assert.not_nil(reporter.pushStatsRows)
    Assert.not_nil(reporter.onPageChanged)
end

do
    local rows = Mapper.shelfProgressRows({
        bookProgress = {
            { bookId = "1", progress = 40, chapterUid = "u1" },
        },
    })
    Assert.eq(#rows, 1)
    Assert.eq(rows[1].stable_id, "1")
    Assert.eq(rows[1].fraction, 0.4)
    Assert.eq(rows[1].chapter_uid, "u1")
end

do
    local anns = Notes.toAnnotations({
        updated = {
            {
                chapterUid = "9",
                markText = "hello",
                range = "0-5",
                createTime = 100,
            },
        },
    }, "9", {
        { range = "0-5", pageReviews = { { review = { content = "想法" } } } },
    })
    Assert.eq(#anns, 1)
    Assert.eq(anns[1].text, "hello")
    Assert.eq(anns[1].note, "想法")
end

do
    local html = "0123456789"
    local out = Annotations.inject(html, { { range = "2-5" } })
    Assert.is_true(out:find("wr%-underline", 1) ~= nil)
    Assert.is_true(out:find("234", 1, true) ~= nil)
end
