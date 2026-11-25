--[[-- features.marketplace.client：moon-store.ankio.net 插件列表分页、分类、详情与错误分类。 --]]

local Assert = require("support.assert")

package.preload["json"] = function() return require("support.json_stub") end

local seen = {}
local responder
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            seen[#seen + 1] = { url = url, opts = opts }
            return responder(url, opts, cb)
        end,
    }
end

local Client = require("features.marketplace.client")
Assert.eq(Client.BASE_URL, "https://moon-store.ankio.net")

-- 分页拉取与去重 + 进度回调
local saved_size = Client.PAGE_SIZE
Client.PAGE_SIZE = 2
local progress = {}
responder = function(url, _opts, cb)
    if url:find("page=1", 1, true) then
        cb('{"data":[{"uid":"u1","title":"A"},{"uid":"u2","title":"B"}],"count":3,"page":1,"pageSize":2}', nil, { code = 200 })
    else
        cb('{"data":[{"uid":"u2","title":"B"},{"uid":"u3","title":"C"}],"count":3,"page":2,"pageSize":2}', nil, { code = 200 })
    end
    return { cancel = function() end }
end
local got, got_err
Client.listPlugins(function(items, err)
    got, got_err = items, err
end, function(done, total)
    progress[#progress + 1] = { done = done, total = total }
end)
Assert.is_nil(got_err)
Assert.eq(#got, 3)
Assert.eq(got[1].uid, "u1")
Assert.eq(got[3].uid, "u3")
Assert.eq(#seen, 2)
Assert.eq(seen[1].url, "https://moon-store.ankio.net/api/v1/store/plugins?page=1&pageSize=2")
Assert.eq(seen[2].url, "https://moon-store.ankio.net/api/v1/store/plugins?page=2&pageSize=2")
Assert.eq(#progress, 2)
Assert.eq(progress[2].done, 3)
Assert.eq(progress[2].total, 3)
Client.PAGE_SIZE = saved_size

-- 分类列表
seen = {}
responder = function(_url, _opts, cb)
    cb('{"data":[{"code":"reader","name":"阅读增强","hint":"翻页"}]}', nil, { code = 200 })
    return { cancel = function() end }
end
local cats, cat_err
Client.listCategories(function(items, err) cats, cat_err = items, err end)
Assert.is_nil(cat_err)
Assert.eq(seen[1].url, "https://moon-store.ankio.net/api/v1/store/categories")
Assert.eq(cats[1].code, "reader")
Assert.eq(cats[1].name, "阅读增强")

-- 详情接口：uid URL 编码
seen = {}
responder = function(_url, _opts, cb)
    cb('{"data":{"uid":"github:Acme/demo","title":"Demo","readme":{"name":"README.md","text":"# Hi"}}}', nil, { code = 200 })
    return { cancel = function() end }
end
local detail, detail_err
Client.getDetail("github:Acme/demo", function(d, err) detail, detail_err = d, err end)
Assert.is_nil(detail_err)
Assert.eq(seen[1].url, "https://moon-store.ankio.net/api/v1/store/plugins/github%3AAcme%2Fdemo")
Assert.eq(detail.readme.text, "# Hi")

-- 错误分类
Assert.eq(Client.classify("HTTP 429", { code = 429 }), "rate_limit")
Assert.eq(Client.classify("HTTP 404", { code = 404 }), "not_found")
Assert.eq(Client.classify("HTTP 403", { code = 403 }), "forbidden")
Assert.eq(Client.classify("timeout", { code = 0 }), "network")

responder = function(_url, _opts, cb)
    cb("<html>bad gateway</html>", nil, { code = 200 })
    return { cancel = function() end }
end
Client.listCategories(function(items, err) cats, cat_err = items, err end)
Assert.is_nil(cats)
Assert.eq(cat_err, "not_json")

return true
