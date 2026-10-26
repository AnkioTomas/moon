--[[--
番茄书架详情：网页端查无此书的用书号占位保留；详情请求本身失败则整次失败（保留本地书架）；
并发有上限；book_shelf_info 上的 group_name 挂到详情行。

@module tests.source.fanqie.client_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    local stub = require("support.json_stub")
    return { decode = stub.decode, encode = stub.encode }
end

local SHELF_IDS = { "1", "2", "3" }
-- book_id → group_name；空表 = 书架项不带分组字段（和没建文件夹的账号一致）。
local SHELF_GROUPS = {}
local fail_ids = {}
local gone_ids = {}
local requests = 0
-- 异步桩：详情请求先挂起，由 drain 逐个回包，才量得出并发。
local held = {}
local no_multi = false
local in_flight, peak = 0, 0
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        header = function() return nil end,
        ok = function(code) return code >= 200 and code < 300 end,
        request = function(opts, cb)
            requests = requests + 1
            if opts.url:find("/bookshelf/info/", 1, true) then
                local list = {}
                for _idx, id in ipairs(SHELF_IDS) do
                    local item = '{"book_id":"' .. id .. '"'
                    if SHELF_GROUPS[id] then
                        item = item .. ',"group_id":"7","group_name":"' .. SHELF_GROUPS[id] .. '"'
                    end
                    list[#list + 1] = item .. "}"
                end
                cb({ code = 200, body = '{"code":0,"data":{"book_shelf_info":[' .. table.concat(list, ",") .. ']}}' })
                return { cancel = function() end }
            end
            if opts.url:find("/multidetail", 1, true) then
                local bid = opts.body:match('"book_id":"(%d+)"')
                cb({ code = 200, body = no_multi and '{"code":0,"data":{"detail_list":[]}}'
                    or '{"code":0,"data":{"detail_list":[{"book_id":"' .. bid .. '","book_name":"架上' .. bid .. '"}]}}' })
                return { cancel = function() end }
            end
            local id = opts.url:match("bookId=(%d+)")
            in_flight = in_flight + 1
            if in_flight > peak then peak = in_flight end
            held[#held + 1] = function()
                in_flight = in_flight - 1
                if fail_ids[id] then
                    cb(nil, "timeout")
                elseif gone_ids[id] then
                    cb({ code = 200, body = '{"code":-1,"message":"book not found"}' })
                else
                    local metadata = id == "1"
                        and ',"author":"年轻熊","abstract":"真正的书籍简介","description":"作者签名"'
                        or ',"author":"","authorName":"兼容作者","abstract":"另一份简介","description":"仍是作者签名"'
                    cb({ code = 200, body = '{"code":0,"data":{"bookName":"书' .. id .. '","thumbUri":"x"' .. metadata .. '}}' })
                end
            end
            return { cancel = function() end }
        end,
    }
end
local function drain()
    while #held > 0 do table.remove(held, 1)() end
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, f) f() end }
end
package.loaded["ui/uimanager"] = nil

package.loaded["source.fanqie.client"] = nil
local Client = require("source.fanqie.client")
local settings = {
    get = function(_, _key, default) return default end,
    set = function() end,
    flush = function() end,
}
local client = Client:new(settings)

-- 一本超时：整次失败，不能把这本书从本地书架藏起来；失败结果不进缓存。
fail_ids["2"] = true
local data, err
client:fetchShelfDetailAsync(false, function(d, e) data, err = d, e end)
drain()
Assert.is_nil(data)
Assert.eq(err, "timeout")

-- 一本查无此书：占位保留，其余照常返回，不报错。
fail_ids["2"] = nil
gone_ids["3"] = true
requests = 0
client:fetchShelfDetailAsync(false, function(d, e) data, err = d, e end)
drain()
Assert.eq(requests, 5, "上次失败没进缓存，这次必须重新请求")
Assert.is_nil(err)
Assert.len(data.data.detail_list, 3)
Assert.eq(data.data.detail_list[1].book_name, "书1")
Assert.eq(data.data.detail_list[2].book_id, "2")
Assert.eq(data.data.detail_list[1].author_name, "年轻熊", "第三方版权书只返回 author")
Assert.eq(data.data.detail_list[1].abstract, "真正的书籍简介", "description 是作者签名，不能当书简介")
Assert.eq(data.data.detail_list[2].author_name, "兼容作者")
Assert.eq(data.data.detail_list[2].abstract, "另一份简介")
Assert.eq(data.data.detail_list[3].book_name, "架上3", "网页查无此书时用书架 multidetail 取书名")

-- 结果进缓存：再拉直接命中，不再发请求。
requests = 0
client:fetchShelfDetailAsync(false, function(d) data = d end)
Assert.eq(requests, 0)
Assert.len(data.data.detail_list, 3)

-- 强制刷新绕过缓存：恢复后按书架顺序拿全。
gone_ids["3"] = nil
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
drain()
Assert.is_nil(err)
Assert.len(data.data.detail_list, 3)
Assert.eq(data.data.detail_list[3].book_id, "3")

-- 全部查无此书且 multidetail 也没有：全部书号占位，不报错。
gone_ids = { ["1"] = true, ["2"] = true, ["3"] = true }
no_multi = true
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
drain()
Assert.is_nil(err)
Assert.len(data.data.detail_list, 3)
Assert.eq(data.data.detail_list[1].book_name, "番茄书籍 1")
no_multi = false

-- 大书架：详情请求并发不超过 4，全部拿到后按书架顺序返回。
gone_ids = {}
SHELF_IDS = {}
for i = 1, 10 do SHELF_IDS[i] = tostring(100 + i) end
peak = 0
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
Assert.eq(in_flight, 4)
drain()
Assert.eq(peak, 4)
Assert.is_nil(err)
Assert.len(data.data.detail_list, 10)
Assert.eq(data.data.detail_list[10].book_id, "110")

do -- 书架分组：book_shelf_info 上的 group_name 挂到详情行（没进组的不写）
    SHELF_IDS = { "1", "2", "3" }
    SHELF_GROUPS = { ["1"] = "追更", ["3"] = "追更" }
    gone_ids = {}
    client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
    drain()
    Assert.is_nil(err)
    Assert.eq(data.data.detail_list[1]._group_name, "追更")
    Assert.is_nil(data.data.detail_list[2]._group_name, "没进组不算分组")
    Assert.eq(data.data.detail_list[3]._group_name, "追更")
    SHELF_GROUPS = {}
end

do
    client:fetchBookDetailAsync("1", function(d, e) data, err = d, e end)
    drain()
    Assert.is_nil(err)
    Assert.eq(data.author_name, "年轻熊")
    Assert.eq(data.abstract, "真正的书籍简介")
    fail_ids["1"] = true
    client:fetchBookDetailAsync("1", function(d, e) data, err = d, e end)
    drain()
    Assert.is_nil(data)
    Assert.eq(err, "timeout")
    fail_ids["1"] = nil
    gone_ids["1"] = true
    client:fetchBookDetailAsync("1", function(d, e) data, err = d, e end)
    drain()
    Assert.is_nil(data)
    Assert.matches(err, "book not found")
    gone_ids["1"] = nil
end

do -- Set-Cookie 值没变不落盘；变了才 flush 一次
    local set_cookie = "ttwid=a; Path=/"
    package.loaded["http.request"] = {
        header = function(_res, name) if name == "Set-Cookie" then return set_cookie end end,
        ok = function(code) return code >= 200 and code < 300 end,
        request = function(_opts, cb)
            cb({ code = 200, body = '{"code":0,"data":{}}' })
            return { cancel = function() end }
        end,
    }
    package.loaded["source.fanqie.client"] = nil
    local C = require("source.fanqie.client")
    local store, flushes = {}, 0
    local s = {
        get = function(_, key, default) return store[key] or default end,
        set = function(_, key, value) store[key] = value end,
        flush = function() flushes = flushes + 1 end,
    }
    local c = C:new(s)
    c:fetchReadProgressAsync(function() end)
    c:fetchReadProgressAsync(function() end)
    Assert.eq(flushes, 1, "同值 Set-Cookie 不重复写设置")
    set_cookie = "ttwid=b; Path=/"
    c:fetchReadProgressAsync(function() end)
    Assert.eq(flushes, 2)
    Assert.eq(store.cookies.ttwid, "b")
    package.loaded["http.request"] = nil
    package.loaded["source.fanqie.client"] = nil
end

do -- 搜索免登录（不带 Cookie、App UA）；书架加 / 删走网页接口并校验业务码
    local seen, reply
    package.loaded["http.request"] = {
        header = function() return nil end,
        ok = function(code) return code >= 200 and code < 300 end,
        request = function(opts, cb)
            seen = opts
            cb({ code = 200, body = reply })
            return { cancel = function() end }
        end,
    }
    package.loaded["source.fanqie.client"] = nil
    local C = require("source.fanqie.client")
    local c = C:new({ get = function(_, _key, default) return default end, set = function() end, flush = function() end })
    local d, e
    reply = '{"code":0,"data":{"ret_data":[]}}'
    c:searchAsync("斗 破", function(r, err) d, e = r, err end)
    Assert.matches(seen.url, "q=%%E6%%96%%97")
    Assert.matches(seen.headers["User-Agent"], "com%.dragon%.read")
    Assert.is_nil(seen.headers["Cookie"])
    Assert.not_nil(d)
    reply = '{"code":1,"message":"bad"}'
    c:searchAsync("x", function(r, err) d, e = r, err end)
    Assert.is_nil(d)
    Assert.matches(e, "番茄搜索失败")

    reply = '{"code":0}'
    c:shelfActionAsync("add", "42", function(r, err) d, e = r, err end)
    Assert.matches(seen.url, "/bookshelf/add/")
    Assert.matches(seen.body, '"book_id":"42"')
    Assert.matches(seen.body, "add_book_source")
    Assert.not_nil(d)
    c:shelfActionAsync("delete", "42", function(r, err) d, e = r, err end)
    Assert.matches(seen.url, "/bookshelf/delete/")
    Assert.is_nil(seen.body:find("add_book_source", 1, true))
    reply = '{"code":101108,"message":"无用户信息"}'
    c:shelfActionAsync("delete", "42", function(r, err) d, e = r, err end)
    Assert.is_nil(d)
    Assert.matches(e, "code=101108")
    package.loaded["http.request"] = nil
    package.loaded["source.fanqie.client"] = nil
end

return true
