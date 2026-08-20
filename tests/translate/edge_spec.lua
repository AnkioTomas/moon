--[[--
Edge 翻译适配：语言代码、异步请求和 Translator 注入。
@module tests.translate.edge_spec
--]]

local Assert = require("support.assert")

local encoded
package.preload["json"] = function()
    local decode = setmetatable({ simple = true }, {
        __call = function()
            return {
                { translations = { { text = "你好" } } },
            }
        end,
    })
    return {
        encode = function(value)
            encoded = value
            return '["Hello"]'
        end,
        decode = decode,
    }
end

package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end }
end

local Edge = require("translate.edge")

Assert.eq(Edge.languageCode("auto"), "")
Assert.eq(Edge.languageCode("zh"), "zh-Hans")
Assert.eq(Edge.languageCode("zh_cn"), "zh-Hans")
Assert.eq(Edge.languageCode("zh_TW"), "zh-Hant")
Assert.eq(Edge.languageCode("en"), "en")

local translated, detected_lang = Edge.parseResponse({
    { translations = { { text = "你好" } } },
})
Assert.eq(translated, "你好")
Assert.is_nil(detected_lang)
Assert.is_nil(Edge.parseResponse({}))

local request_url, request_body, request_opts
local request_calls = 0
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, callback)
            request_calls = request_calls + 1
            request_url, request_body, request_opts = url, body, opts
            callback('[{"translations":[{"text":"你好"}]}]')
            return { cancel = function() end }
        end,
    }
end

local result, result_lang, result_err
local job = Edge.translateAsync("Hello", "zh_cn", "en", function(value, lang, err)
    result, result_lang, result_err = value, lang, err
end)
Assert.eq(encoded[1], "Hello")
Assert.eq(request_url,
    "https://edge.microsoft.com/translate/translatetext?from=en&to=zh-Hans&isEnterpriseClient=false")
Assert.eq(request_body, '["Hello"]')
Assert.eq(request_opts.content_type, "application/json")
Assert.eq(request_calls, 1)
Assert.eq(request_opts.connect_timeout, 30)
Assert.eq(request_opts.timeout, 60)
Assert.eq(result, "你好")
Assert.is_nil(result_lang)
Assert.is_nil(result_err)
Assert.is_true(type(job.cancel) == "function")

local translator = {}
package.preload["ui/translator"] = function() return translator end
Edge.install()
Assert.is_true(type(translator.showTranslation) == "function")
local before = translator.showTranslation
Edge.install()
Assert.eq(translator.showTranslation, before)
