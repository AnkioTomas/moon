--[[--
番茄书架详情：部分 book_info 失败必须整体失败且不写缓存。

@module tests.source.fanqie.client_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local fail_ids = {}
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
                body = '{"code":0,"data":{"book_shelf_info":[{"book_id":"1"},{"book_id":"2"}]}}'
            else
                local id = opts.url:match("bookId=(%d+)")
                if fail_ids[id] then
                    cb(nil, "timeout")
                    return { cancel = function() end }
                end
                body = '{"code":0,"data":{"bookName":"书' .. id .. '","thumbUri":"x"}}'
            end
            cb({ code = 200, body = body })
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.fanqie.client"] = nil
local Client = require("source.fanqie.client")
local settings = {
    get = function(_, _key, default) return default end,
    set = function() end,
    flush = function() end,
}
local client = Client:new(settings)

-- 两本里一本详情失败：整体失败，不能把残缺书架交出去。
fail_ids["2"] = true
local data, err
client:fetchShelfDetailAsync(false, function(d, e) data, err = d, e end)
Assert.is_nil(data)
Assert.matches(err, "不完整")

-- 残缺结果不得进缓存：恢复后再拉必须重新请求并拿到完整书架。
fail_ids["2"] = nil
requests = 0
client:fetchShelfDetailAsync(false, function(d, e) data, err = d, e end)
Assert.eq(requests, 3)
Assert.is_nil(err)
Assert.len(data.data.detail_list, 2)

-- 完整结果才缓存：再拉直接命中，不再发请求。
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, f) f() end }
end
package.loaded["ui/uimanager"] = nil
requests = 0
client:fetchShelfDetailAsync(false, function(d) data = d end)
Assert.eq(requests, 0)
Assert.len(data.data.detail_list, 2)

return true
