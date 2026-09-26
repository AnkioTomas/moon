--[[--
番茄书架详情：拿不到详情的书（网络失败/下架）直接剔除，其余照常返回。

@module tests.source.fanqie.client_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local fail_ids = {}
local gone_ids = {}
local requests = 0
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        header = function() return nil end,
        ok = function(code) return code >= 200 and code < 300 end,
        request = function(opts, cb)
            requests = requests + 1
            local body
            if opts.url:find("/bookshelf/info/", 1, true) then
                body = '{"code":0,"data":{"book_shelf_info":[{"book_id":"1"},{"book_id":"2"},{"book_id":"3"}]}}'
            else
                local id = opts.url:match("bookId=(%d+)")
                if fail_ids[id] then
                    cb(nil, "timeout")
                    return { cancel = function() end }
                end
                if gone_ids[id] then
                    body = '{"code":-1,"message":"book not found"}'
                else
                    body = '{"code":0,"data":{"bookName":"书' .. id .. '","thumbUri":"x"}}'
                end
            end
            cb({ code = 200, body = body })
            return { cancel = function() end }
        end,
    }
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

-- 一本超时、一本下架：剔除两本，剩下的照常返回，不报错。
fail_ids["2"] = true
gone_ids["3"] = true
local data, err
client:fetchShelfDetailAsync(false, function(d, e) data, err = d, e end)
Assert.is_nil(err)
Assert.len(data.data.detail_list, 1)
Assert.eq(data.data.detail_list[1].book_id, "1")
Assert.eq(data.data.detail_list[1].book_name, "书1")

-- 结果进缓存：再拉直接命中，不再发请求。
requests = 0
client:fetchShelfDetailAsync(false, function(d) data = d end)
Assert.eq(requests, 0)
Assert.len(data.data.detail_list, 1)

-- 强制刷新绕过缓存：恢复后按书架顺序拿全。
fail_ids["2"] = nil
gone_ids["3"] = nil
requests = 0
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
Assert.eq(requests, 4)
Assert.is_nil(err)
Assert.len(data.data.detail_list, 3)
Assert.eq(data.data.detail_list[2].book_id, "2")
Assert.eq(data.data.detail_list[3].book_id, "3")

-- 全部失效：空书架，不报错。
fail_ids = { ["1"] = true, ["2"] = true, ["3"] = true }
client:fetchShelfDetailAsync(true, function(d, e) data, err = d, e end)
Assert.is_nil(err)
Assert.len(data.data.detail_list, 0)

return true
