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

    for _idx, data in ipairs({ {}, { data = { ["1"] = {} } } }) do
        reply = { data = data }
        Reviews.hotspotsAsync({}, "900", function(list, e) Assert.is_nil(list); err = e end)
        Assert.matches(err, "统计", "坏响应不能覆盖缓存成空热点")
    end
end

-- 评论页：POST body 带段序与游标；毫秒时间归一成秒；has_more 且游标前进才算还有
do
    reply = { data = {
        data_list = { { comment = {
            comment_id = "c1",
            common = { user_info = { base_info = { user_name = "书友" } }, content = { text = "好看", image_data_list = { image_data = {
                    { web_url = "https://p3-novel.byteimg.com/tos-cn-i-abc/xyz~tplv-q:300:0.awebp?sig=1" },
                    { web_url = "https://p3-novel.byteimg.com/tos-cn-i-abc/up123~tplv-q-jpeg.heic?sig=2" },
                } } },
                create_timestamp = 1700000000000 },
            stat = { digg_count = 9, reply_count = 4 },
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
    Assert.eq(page.items[1].replies, 4)
    Assert.len(page.items[1].images, 2)
    Assert.matches(page.items[1].images[1].url, "awebp%?sig=1")
    Assert.eq(page.items[1].images[2].url,
        "https://p3-novel.byteimg.com/tos-cn-i-abc/up123~tplv-1yzifmftcy-expand:800:0:0.webp")
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

    reply = { data = { data_list = {}, common_list_info = { total = 3 } } }
    Reviews.pageAsync({}, "111", "900", 12, 0, function(p, e) Assert.is_nil(p); err = e end)
    Assert.matches(err, "为空", "风控空成功不删除已有热点")
    reply.data.common_list_info.total = 0
    Reviews.pageAsync({}, "111", "900", 12, 0, function(p) page = p end)
    Assert.len(page.items, 0, "真正空列表正常返回")
    Assert.is_false(page.more)

    reply = { data = { data_list = { { comment = { common = {
        content = { text = "甲[笑]乙[哭][笑][因果]😀" },
    } } } }, common_list_info = { total = 1 } } }
    Reviews.pageAsync({}, "111", "900", 12, 0, function(p) page = p end)
    Assert.eq(page.items[1].content, "甲[笑]乙[哭][笑][因果]😀", "原文供引用、复制与缓存，不做破坏性替换")
    Assert.matches(page.items[1].inline_images["[笑]"].url, "/1f604%.png$")
    Assert.matches(page.items[1].inline_images["[哭]"].url, "/1f622%.png$")
    Assert.is_nil(page.items[1].inline_images["[因果]"], "书中术语不是表情")
end

-- 回复：comment_source 必须是 5；楼中楼记被回复者；空列表且 total>0 不当成功
do
    reply = { data = {
        reply_list = { {
            reply_id = "rp1",
            reply_to_user_info = { base_info = { user_name = "楼主" } },
            Common = { user_info = { base_info = { user_name = "路人" } },
                content = { text = "确实[吃瓜]" }, create_timestamp = 1700000000 },
            stat = { digg_count = 2, reply_count = 9 },
        } },
        comment_list_info = { cursor = "20", has_more = true, total = 6 },
    } }
    local page
    Reviews.repliesAsync({}, "c1", 0, function(p) page = p end)
    local call = calls[#calls]
    Assert.eq(call.name, "reply_list")
    Assert.eq(call.path, "/novel/commentapi/reply/list/c1/v1/")
    Assert.matches(call.body, '"comment_source":5')
    Assert.matches(call.body, '"cursor":""')
    Assert.eq(page.items[1].author, "路人")
    Assert.eq(page.items[1].content, "确实[吃瓜]")
    Assert.matches(page.items[1].inline_images["[吃瓜]"].url, "/1f349%.png$", "回复与主评论共用表情映射")
    Assert.eq(page.items[1].reply_to, "楼主")
    Assert.eq(page.items[1].replies, 0, "回复页不再往下开")
    Assert.eq(page.items[1].likes, 2)
    Assert.eq(page.total, 6)
    Assert.eq(page.max_idx, "20")
    Assert.is_true(page.more)

    Reviews.repliesAsync({}, "c1", "20", function(p) page = p end)
    Assert.matches(calls[#calls].body, '"cursor":"20"')
    Assert.is_false(page.more, "游标停住就不再翻")

    reply = { data = { reply_list = {}, comment_list_info = { total = 3, has_more = false, cursor = "" } } }
    local err
    Reviews.repliesAsync({}, "c1", 0, function(p, e) Assert.is_nil(p) err = e end)
    Assert.matches(err, "为空")

    reply = { data = {} }
    Reviews.repliesAsync({}, "c1", 0, function(p, e) Assert.is_nil(p) err = e end)
    Assert.matches(err, "reply_list")
end

do -- 同步设备桩不能把正在请求的句柄覆盖掉；关闭后忽略迟到回包。
    local Device = require("source.fanqie.reading.device")
    local Reading = require("source.fanqie.reading")
    local ensure, signed = Device.ensureAsync, Reading.signedAsync
    local pending_device, pending_response
    local registration_cancelled, request_cancelled, received = false, false, false
    local signed_calls = 0
    Reading.signedAsync = function(_device, _name, _path, _query, _body, cb)
        signed_calls = signed_calls + 1
        pending_response = cb
        return { cancel = function() request_cancelled = true end }
    end
    local job = Reviews.hotspotsAsync({}, "900", function() received = true end)
    job.cancel()
    Assert.is_true(request_cancelled, "同步注册回调后取消实际段评请求")
    pending_response({ data = { data = {} } })
    Assert.is_false(received, "窗口关闭后不接受迟到响应")

    Device.ensureAsync = function(_settings, cb)
        pending_device = cb
        return { cancel = function() registration_cancelled = true end }
    end
    request_cancelled = false
    job = Reviews.hotspotsAsync({}, "900", function() received = true end)
    job.cancel()
    Assert.is_true(registration_cancelled)
    pending_device({})
    Assert.is_false(request_cancelled)
    Assert.eq(signed_calls, 1, "取消注册后迟到回调不得启动段评请求")
    Assert.is_false(received)

    job = Reviews.hotspotsAsync({}, "900", function() received = true end)
    pending_device({})
    Assert.eq(signed_calls, 2, "异步注册正常进入段评请求")
    job.cancel()
    Assert.is_true(request_cancelled, "异步注册完成后取消当前请求")
    pending_response({ data = { data = {} } })
    Assert.is_false(received)
    Device.ensureAsync, Reading.signedAsync = ensure, signed
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
