--[[--
静读天下进度串：百分比只供显示。落地用章内字符偏移或固定版式页码。

@module tests.source.local.progress_po_spec
--]]

local Assert = require("support.assert")
local Common = require("source.local.common")

local full = Common.encodeProgress({
    updated_at = 1700000200, chapter_idx = 4, fraction = 0.456789321,
    extra = { offset = 4826, volume = 0, at_fraction = 0.456789321 },
})
Assert.eq(full, "1700000200000*4@0#4826:45.7%", "偏移和百分比一起写")
local decoded = Common.decodeProgress(full)
Assert.eq(decoded.chapter_idx, 4)
Assert.eq(decoded.fraction, 0.457)
Assert.eq(decoded.extra.offset, 4826)
Assert.eq(decoded.extra.chapter_idx, 4)

Assert.eq(Common.encodeProgress({
    updated_at = 1700000200, chapter_idx = 4, fraction = 0.8,
    extra = { offset = 4826, volume = 0, at_fraction = 0.457 },
}), "1700000200000*4:80.0%", "读过之后旧偏移不能再写回去")

Assert.eq(Common.encodeProgress({
    updated_at = 1700000123, chapter_idx = 4, fraction = 0.4567,
}), "1700000123000*4:45.7%", "没有偏移就不编一个 0")

Assert.eq(Common.encodeProgress({
    updated_at = 1700000200, fraction = 0.2, page = 10,
}), "1700000200000*10@0#0:20.0%", "固定版式把页码和百分比一起写")

local moon = Common.decodeProgress("1590486119266*21@0#4826:11.1%")
Assert.eq(moon.chapter_idx, 21)
Assert.eq(moon.extra.offset, 4826)
Assert.eq(moon.fraction, 0.111)
Assert.is_nil(Common.decodeProgress("1590486119266*9:3.8%").extra)

local flow = {
    rolling = true,
    document = {
        getToc = function()
            return {
                { page = 1, xpointer = "/c1" },
                { page = 10, xpointer = "/c2" },
                { page = 20, xpointer = "/c3" },
            }
        end,
        getPageCount = function() return 30 end,
        getPageXPointer = function(_doc, page) return "/p" .. page end,
        getTextFromXPointers = function(_doc, _start, xp)
            local page = tonumber(xp:match("/p(%d+)"))
            if not page then return "" end
            return string.rep("字", (page - 10) * 100)
        end,
    },
}
local refined = Common.refinePosition({
    fraction = 0.4, chapter_idx = 2, extra = { offset = 250, volume = 0 },
}, flow)
Assert.eq(refined.locator, "/p12", "偏移落在章内那一页，不用全书百分比")

local drifted = Common.refinePosition({
    fraction = 0.05, chapter_idx = 2, extra = { offset = 250, volume = 0 },
}, flow)
Assert.eq(drifted.locator, "/p12", "百分比和章号不一致时仍按字符偏移跳")

local overrun = Common.refinePosition({
    fraction = 0.9, chapter_idx = 2, extra = { offset = 5000, volume = 0 },
}, flow)
Assert.eq(overrun.locator, "/p19", "偏移超出本章文本时停在章末")

local paged = Common.refinePosition({
    stable_id = "webdav://书.pdf", chapter_idx = 40, fraction = 0.11,
}, { document = { getPageCount = function() return 100 end } })
Assert.eq(paged.page, 40)
Assert.eq(paged.total_pages, 100, "PDF 的页码比百分比精确")

local kept = Common.refinePosition({
    locator = "/body/p[1].0", fraction = 0.11, chapter_idx = 40,
    stable_id = "webdav://书.pdf",
}, { document = { getPageCount = function() return 100 end } })
Assert.eq(kept.locator, "/body/p[1].0")
Assert.is_nil(kept.page)
