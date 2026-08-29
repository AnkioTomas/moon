--[[-- 百度百科卡片传输：URL、响应清洗与错误语义。 @module tests.baike.client_spec --]]

local Assert = require("support.assert")

local last_url
local last_options
package.preload["json"] = function()
    return {
        decode = setmetatable({ simple = true }, {
            __call = function(_, content)
                if content == "valid" then
                    return {
                        title = "电子阅读器",
                        abstract = "一种用于阅读&lt;br&gt;电子书的设备。",
                        card = {
                            { name = "别名", value = "电子书阅读器" },
                            { name = "用途", value = { "阅读", "学习" } },
                        },
                    }
                end
                if content == "empty" then
                    return {}
                end
                error("bad json")
            end,
        }),
    }
end
package.preload["logger"] = function()
    return { warn = function() end }
end
package.preload["http.request"] = function()
    return {
        get = function(url, options, callback)
            last_url, last_options = url, options
            callback("valid")
            return { cancel = function() end }
        end,
    }
end

local Client = require("baike.client")

Assert.eq(Client.url("电子 阅读器"),
    "https://baike.baidu.com/api/openapi/BaikeLemmaCardApi?scope=103&format=json&appid=379020&bk_length=600&bk_key=%E7%94%B5%E5%AD%90%20%E9%98%85%E8%AF%BB%E5%99%A8")

local entry = Client.parseResponse({
    title = "词条",
    abstract = "摘要&lt;br&gt;第二行",
    card = { { name = "名称", value = { "甲", "乙" } } },
})
Assert.eq(entry.title, "词条")
Assert.eq(entry.definition, "摘要\n第二行\n\n名称：甲、乙")
Assert.is_nil(Client.parseResponse({ abstract = "missing title" }))

local result, err
local job = Client.lookupAsync("电子阅读器", function(value, failure)
    result, err = value, failure
end)
Assert.eq(last_options.accept, "application/json")
Assert.eq(last_options.connect_timeout, 10)
Assert.eq(last_options.timeout, 20)
Assert.eq(result.title, "电子阅读器")
Assert.eq(result.definition, "一种用于阅读\n电子书的设备。\n\n别名：电子书阅读器\n用途：阅读、学习")
Assert.is_nil(err)
Assert.is_true(type(job.cancel) == "function")

local empty_result, empty_err
Client.lookupAsync("", function(value, failure)
    empty_result, empty_err = value, failure
end)
Assert.is_nil(empty_result)
Assert.eq(empty_err, "empty query")
