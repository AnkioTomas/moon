--[[--
卷列表 / 系列页共用的续读目标：主线 = 最远有进度的卷，回顾旧卷只标「上次翻阅」。

@module tests.source.kavita.continue_point_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")

local CP = dofile(Config.root() .. "/book.koplugin/source/kavita/continue_point.lua")

local function vol(chapter_id, title, pages, pages_read)
    return {
        idx = chapter_id, chapterId = chapter_id, title = title,
        pages = pages, pagesRead = pages_read or 0,
    }
end

local toc = {
    vol(101, "第 1 卷", 100, 100),
    vol(102, "第 2 卷", 100, 40),
    vol(103, "第 3 卷", 100, 0),
    vol(104, "第 4 卷", 100, 0),
}

-- 未开始
local fresh = CP.pick({
    vol(101, "第 1 卷", 100, 0),
    vol(102, "第 2 卷", 100, 0),
}, {})
Assert.eq(fresh.kind, "fresh")
Assert.eq(fresh.entry.chapterId, 101)
Assert.eq(fresh.page, 0)
local fresh_text, fresh_caption = CP.describe(fresh, "系列")
Assert.eq(fresh_text, "开始阅读 · 第 1 卷")
Assert.eq(fresh_caption, "共 100 页")

-- 读到第 2 卷一半：主线是第 2 卷
local mid = CP.pick(toc, {})
Assert.eq(mid.kind, "continue")
Assert.eq(mid.entry.chapterId, 102)
Assert.eq(mid.fraction, 0.4)
Assert.eq(mid.page, 40)
Assert.eq(mid.total_pages, 100)
local mid_text, mid_caption = CP.describe(mid, "系列")
Assert.eq(mid_text, "继续阅读 · 第 2 卷")
Assert.eq(mid_caption, "第 40/100 页 · 40%")
Assert.is_nil(mid.browsed)

-- 第 2 卷读完：顺延第 3 卷
local rolled = CP.pick({
    vol(101, "第 1 卷", 100, 100),
    vol(102, "第 2 卷", 100, 100),
    vol(103, "第 3 卷", 100, 0),
}, {})
Assert.eq(rolled.entry.chapterId, 103)
Assert.eq(rolled.kind, "continue")
Assert.eq(rolled.page, 0)

-- 全部读完：回到第 1 卷，kind = done
local done = CP.pick({
    vol(101, "第 1 卷", 100, 100),
    vol(102, "第 2 卷", 100, 100),
}, {})
Assert.eq(done.kind, "done")
Assert.eq(done.entry.chapterId, 101)

-- 读到第 4 卷、回头翻第 1 卷：主线不动，第 1 卷只作「上次翻阅」
local updated = { [101] = 300, [104] = 200 }
local review = CP.pick({
    vol(101, "第 1 卷", 100, 100),
    vol(102, "第 2 卷", 100, 100),
    vol(103, "第 3 卷", 100, 100),
    vol(104, "第 4 卷", 100, 50),
}, {
    updated_at = function(e) return updated[e.chapterId] end,
})
Assert.eq(review.entry.chapterId, 104, "主线仍是最远的第 4 卷")
Assert.eq(review.browsed.chapterId, 101, "上次翻阅单独返回")

-- 上次翻阅 == 主线：不返回标记
local same = CP.pick(toc, { updated_at = function(e) return e.chapterId == 102 and 500 or 0 end })
Assert.is_nil(same.browsed)

-- 注入 fraction / page（本地 ProgressDB 比 toc 快照新）
local local_better = CP.pick(toc, {
    fraction = function(e) return e.chapterId == 102 and 0.9 or nil end,
    page = function(e)
        if e.chapterId == 102 then return { page = 90, total = 100 } end
    end,
})
Assert.eq(local_better.fraction, 0.9)
Assert.eq(local_better.page, 90)

-- pages == 0 的卷不参与
local zero = CP.pick({
    vol(101, "第 1 卷", 0, 0),
    vol(102, "第 2 卷", 100, 10),
}, {})
Assert.eq(zero.entry.chapterId, 102)

-- 空目录
Assert.is_nil(CP.pick({}, {}))
Assert.is_nil(CP.pick(nil, nil))

-- 服务端已读完、本机重新打开留下 1%：仍按已读完处理，主线顺延下一卷。
local reread = CP.pick({
    vol(101, "第 1 卷", 100, 100),
    vol(102, "第 2 卷", 100, 100),
    vol(103, "第 3 卷", 100, 0),
}, { fraction = function(e) return e.chapterId == 102 and 0.01 or nil end })
Assert.eq(reread.entry.chapterId, 103, "已读完的卷不会被本机低进度拖回主线")
Assert.eq(reread.kind, "continue")


-- 调用方说已读完（kamare 三源）时同样按 fraction 1，不再被本机低进度拖回。
local by_caller = CP.pick({
    vol(101, "第 1 卷", 100, 0),
    vol(102, "第 2 卷", 100, 0),
}, {
    fraction = function(e) return e.chapterId == 101 and 0.01 or nil end,
    complete = function(e) return e.chapterId == 101 end,
})
Assert.eq(by_caller.entry.chapterId, 102, "调用方标记已读完的卷不会成为主线")


-- 卷名：优先标题；空 / 退化成系列名时兜底第 N 卷
Assert.eq(CP.label({ idx = 3, title = "ONE PIECE (3)" }, "航海王"), "ONE PIECE (3)")
Assert.eq(CP.label({ idx = 3, title = "" }, "航海王"), "第 3 卷")
Assert.eq(CP.label({ idx = 3, title = "航海王" }, "航海王"), "第 3 卷")
Assert.eq(CP.label({ idx = 3 }, "航海王"), "第 3 卷")
Assert.eq(CP.label(nil, "航海王"), "?")
