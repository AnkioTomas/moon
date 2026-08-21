--[[--
Edge 翻译传输：语言码、解析、项目 HTTP 请求。
@module tests.translate.edge_spec
--]]

local Assert = require("support.assert")

local encoded
package.preload["json"] = function()
    local decode = setmetatable({ simple = true }, {
        __call = function(_, content)
            if type(content) == "string" and content:find('"language":"en"') then
                return {
                    {
                        translations = { { text = "你好" } },
                        detectedLanguage = { language = "en" },
                    },
                }
            end
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
Assert.is_nil(Edge.install)
Assert.is_nil(Edge.showTranslation)

Assert.eq(Edge.languageCode("auto"), "")
Assert.eq(Edge.languageCode("zh"), "zh-Hans")
Assert.eq(Edge.languageCode("zh_cn"), "zh-Hans")
Assert.eq(Edge.languageCode("zh-CN"), "zh-Hans")
Assert.eq(Edge.languageCode("zh_TW"), "zh-Hant")
Assert.eq(Edge.languageCode("en"), "en")

local translated, detected_lang = Edge.parseResponse({
    {
        translations = { { text = "你好" } },
        detectedLanguage = { language = "zh-Hans" },
    },
})
Assert.eq(translated, "你好")
Assert.eq(detected_lang, "zh-Hans")
Assert.is_nil(Edge.parseResponse({}))

local request_url, request_body, request_opts
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, callback)
            request_url, request_body, request_opts = url, body, opts
            callback('[{"translations":[{"text":"你好"}],"detectedLanguage":{"language":"en"}}]')
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
Assert.eq(request_opts.connect_timeout, 30)
Assert.eq(request_opts.timeout, 60)
Assert.eq(result, "你好")
Assert.eq(result_lang, "en")
Assert.is_nil(result_err)
Assert.is_true(type(job.cancel) == "function")
