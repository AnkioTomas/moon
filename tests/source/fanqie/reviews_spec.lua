--[[--
番茄段评：统计 → 热点、评论页 → 展示项（游标翻页）、段落定位到章节 HTML。

@module tests.source.fanqie.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["json"] = function()
    local J = require("support.json_stub")
    return { encode = J.encode, decode = J.decode }
end
package.loaded["json"] = nil

local calls, reply, reply_err = {}, nil, nil
package.preload["source.fanqie.reading.device"] = function()
    return { ensureAsync = function(_, cb) cb({ device_id = "1", install_id = "2" }) return { cancel = function() end } end }
end
package.preload["source.fanqie.reading"] = function()
    return {
        signedAsync = function(_device, name, path, build_query, build_body, cb)
            calls[#calls + 1] = { name = name, path = path, query = build_query({}, 1), body = build_body and build_body() }
            cb(reply, reply_err)
            return { cancel = function() end }
        end,
    }
end
package.preload["source.fanqie.reading.crypto"] = function()
    return { build_common_query = function() return { aid = "1967" } end }
end
package.loaded["source.fanqie.reviews"] = nil
local Reviews = require("source.fanqie.reviews")

-- 统计：只留评论数 > 0 的段，按段序排
do
    reply = { data = { data = { ["12"] = { count = 5 }, ["3"] = { count = 2 }, ["7"] = { count = 0 } } } }
    local hotspots
    Reviews.hotspotsAsync({}, "900", function(list) hotspots = list end)
    Assert.eq(calls[1].path, "/novel/commentapi/idea/list/900/v1/")
    Assert.eq(calls[1].query.compliance_status, "0")
    Assert.is_nil(calls[1].body)
    Assert.len(hotspots, 2)
    Assert.eq(hotspots[1].range, "3")
    Assert.eq(hotspots[2].total, 5)

    reply, reply_err = nil, "comment_stats 空响应"
    local err
    Reviews.hotspotsAsync({}, "900", function(list, e) Assert.is_nil(list) err = e end)
    Assert.eq(err, "comment_stats 空响应")
    reply_err = nil
end

-- 评论页：POST body 带段序与游标；毫秒时间归一成秒；has_more 且游标前进才算还有
do
    reply = { data = {
        data_list = { { comment = {
            comment_id = "c1",
            common = { user_info = { base_info = { user_name = "书友" } }, content = { text = "好看" },
                create_timestamp = 1700000000000 },
            stat = { digg_count = 9 },
        } } },
        common_list_info = { cursor = "20", has_more = true, total = 33 },
    } }
    local page
    Reviews.pageAsync({}, "111", "900", 12, 0, function(p) page = p end)
    local call = calls[#calls]
    Assert.eq(call.path, "/novel/commentapi/comment/list/900/v1/")
    Assert.matches(call.body, '"para_index":12')
    Assert.matches(call.body, '"cursor":""')
    Assert.eq(page.items[1].author, "书友")
    Assert.eq(page.items[1].content, "好看")
    Assert.eq(page.items[1].likes, 9)
    Assert.eq(page.items[1].time, 1700000000)
    Assert.eq(page.total, 33)
    Assert.eq(page.max_idx, 20)
    Assert.is_true(page.more)

    Reviews.pageAsync({}, "111", "900", 12, 20, function(p) page = p end)
    Assert.matches(calls[#calls].body, '"cursor":"20"')

    -- 游标没前进：停，免得无限翻
    Reviews.pageAsync({}, "111", "900", 12, 20, function(p) page = p end)
    Assert.is_false(page.more)

    -- code 为 0 却没有 data_list：风控，报错而不是「0 条」
    reply = { data = { common_list_info = {} } }
    local err
    Reviews.pageAsync({}, "111", "900", 12, 0, function(p, e) Assert.is_nil(p) err = e end)
    Assert.matches(err, "data_list")
end

-- 定位：按段序找 blk p_idx 对应段落，xpointer 覆盖整段；整段原文作引用
do
    local html = '<html><body>'
        .. '<p idx="0" p_idx="40000"><blk p_idx="0">开头一段话。</blk></p>'
        .. '<p idx="1" p_idx="40001"><blk p_idx="1">第二段里有一句被很多人评论的话。</blk></p>'
        .. '</body></html>'
    local spots = Reviews.locate({
        { range = "1", text = "", total = 4 },
        { range = "9", text = "", total = 1 },
    }, html)
    Assert.len(spots, 1)
    Assert.eq(spots[1].range, "1")
    Assert.eq(spots[1].total, 4)
    Assert.eq(spots[1].badge, "4")
    Assert.eq(spots[1].text, "第二段里有一句被很多人评论的话。")
    Assert.matches(spots[1].pos0, "%.%d+$")
    Assert.matches(spots[1].pos1, "%.%d+$")
end

return true
