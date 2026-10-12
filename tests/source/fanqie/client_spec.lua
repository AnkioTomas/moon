--[[--
番茄书架详情：下架的书剔除；详情请求本身失败则整次失败（保留本地书架）；并发有上限。

@module tests.source.fanqie.client_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local SHELF_IDS = { "1", "2", "3" }
local fail_ids = {}
local gone_ids = {}
local requests = 0
-- 异步桩：详情请求先挂起，由 drain 逐个回包，才量得出并发。
local held = {}
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
                    list[#list + 1] = '{"book_id":"' .. id .. '"}'
                end
                cb({ code = 200, body = '{"code":0,"data":{"book_shelf_info":[' .. table.concat(list, ",") .. ']}}' })
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
                    cb({ code = 200, body = '{"code":0,"data":{"bookName":"书' .. id .. '","thumbUri":"x"}}' })
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

-- 一本下架：剔除，其余照常返回，不报错。
fail_ids["2"] = nil
gone_ids["3"] = true
requests = 0
client:fetchShelfDetailAsync(false, function(d, e) data, err = d, e end)
drain()
Assert.eq(requests, 4, "上次失败没进缓存，这次必须重新请求")
Assert.is_nil(err)
Assert.len(data.data.detail_list, 2)
Assert.eq(data.data.detail_list[1].book_name, "书1")
Assert.eq(data.data.detail_list[2].book_id, "2")

-- 结果进缓存：再拉直接命中，不再发请求。
requests = 0
client:fetchShelfDetailAsync(false, function(d) data = d end)
Assert.eq(requests, 0)
Assert.len(data.data.detail_list, 2)

-- 强制刷新绕过缓存：恢复后按书架顺序拿全。
gone_ids["3"] = nil
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
drain()
Assert.is_nil(err)
Assert.len(data.data.detail_list, 3)
Assert.eq(data.data.detail_list[3].book_id, "3")

-- 全部下架：空书架，不报错。
gone_ids = { ["1"] = true, ["2"] = true, ["3"] = true }
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
drain()
Assert.is_nil(err)
Assert.len(data.data.detail_list, 0)

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

return true
