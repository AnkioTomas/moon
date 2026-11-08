--[[--
知乎源进度映射：整篇 EPUB 与源章节身份分开，长篇支持最近章节及目录刷新。

@module tests.source.zhihu.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local read, posts = {}, {}
package.loaded["source.zhihu.client"] = {
    progressAsync = function(id, cb)
        read[#read + 1] = { id = id, cb = cb }
        return { cancel = function() read[#read].cancelled = true end }
    end,
    putProgressAsync = function(section, fraction, cb)
        local post = { section = section, fraction = fraction, cb = cb }
        posts[#posts + 1] = post
        return { cancel = function() post.cancelled = true end }
    end,
}
local Source = require("source.zhihu").new()
local toc_requests = {}
function Source:loadTocAsync(_identity, cb, force)
    local item = { cb = cb, force = force }
    toc_requests[#toc_requests + 1] = item
    return { cancel = function() item.cancelled = true end }
end
local short = { source_id = "zhihu", stable_id = "1/2" }
local long = { source_id = "zhihu", stable_id = "1" }
local toc = { { idx = 1, uid = "2", title = "甲" }, { idx = 2, uid = "3", title = "乙" } }
local result, err, calls = nil, nil, 0
local function done(value, reason) result, err, calls = value, reason, calls + 1 end
Source:getProgressAsync(short, done)
read[#read].cb({ section_id = "2", fraction = .6, updated_at = 12 })
Assert.eq(result.fraction, .6)
Assert.is_nil(result.chapter_idx, "整篇 EPUB 应按整书比例定位，不能跳到内部第 1 小节")
Assert.eq(result.updated_at, 12)
short.chapter_idx = 1
Source:getProgressAsync(short, done)
read[#read].cb({ section_id = "2", fraction = .6 })
Assert.eq(result.chapter_idx, 1)
Assert.eq(result.chapter_fraction, .6)
short.chapter_idx = nil
Source:putProgressAsync(short, { fraction = .6, chapter_idx = 8, chapter_fraction = .2 }, done)
Assert.eq(posts[#posts].section, "2")
Assert.eq(posts[#posts].fraction, .6, "内部 EPUB 章内比例不能当作整篇进度")
posts[#posts].cb(true)
Assert.is_true(result)

Source:getProgressAsync(long, done)
read[#read].cb({ section_id = "3", fraction = .4 })
toc_requests[#toc_requests].cb(toc)
Assert.eq(result.chapter_idx, 2)
Assert.eq(result.chapter_fraction, .4)
Assert.eq(result.fraction, .7)
Source:getProgressAsync(long, done)
read[#read].cb({ section_id = "5", fraction = .4 })
toc_requests[#toc_requests].cb(toc)
Assert.is_true(toc_requests[#toc_requests].force, "云端读到新章时须刷新旧目录")
toc_requests[#toc_requests].cb({ toc[1], toc[2], { idx = 3, uid = "5", title = "丙" } })
Assert.eq(result.chapter_idx, 3)
Assert.is_true(math.abs(result.fraction - .8) < 1e-10)

local job = Source:getProgressAsync(long, done)
read[#read].cb({ section_id = "3", fraction = .4 })
local before = calls
job.cancel()
Assert.is_true(toc_requests[#toc_requests].cancelled)
toc_requests[#toc_requests].cb(toc)
Assert.eq(calls, before)

Source:putProgressAsync(long, { fraction = .8, chapter_idx = 2, chapter_fraction = .6 }, done)
toc_requests[#toc_requests].cb(toc)
Assert.eq(posts[#posts].section, "3")
Assert.eq(posts[#posts].fraction, .6)
posts[#posts].cb(true)
Assert.is_true(result)
Source:putProgressAsync(long, { fraction = 1 }, done)
toc_requests[#toc_requests].cb(toc)
Assert.eq(posts[#posts].section, "3")
Assert.eq(posts[#posts].fraction, 1, "手动已读要推末章读完")
local count = #posts
job = Source:putProgressAsync(long, { fraction = .1 }, done)
job.cancel()
toc_requests[#toc_requests].cb(toc)
Assert.eq(#posts, count)
