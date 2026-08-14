--[[--
Async source APIs must be published while the module loads.  A previous
implementation accidentally defined these methods inside synchronous methods,
making every UI path appear unsupported until a blocking call had run.
--]]

local Assert = require("support.assert")
local original_json_preload = package.preload["json"]
local original_socketutil_preload = package.preload["socketutil"]

local function sourceBase()
    return {}
end

package.preload["utils.settings"] = function()
    return {
        getSource = function() return {} end,
    }
end
package.preload["source.base"] = sourceBase
package.preload["source.contract"] = function()
    return {
        clampFraction = function(n) return n end,
        makeRef = function(source_id, stable_id)
            return { source_id = source_id, stable_id = stable_id }
        end,
    }
end

package.preload["source.moon.client"] = function()
    return { new = function() return {} end }
end
package.preload["source.moon.mapper"] = function() return {} end
package.loaded["source.moon"] = nil
local moon = require("source.moon").new()
for _, name in ipairs({
    "pingAsync", "listLibraryAsync", "recentBooksAsync", "filtersAsync",
    "registerReadingDeviceAsync", "importReadingStatsAsync",
    "readingInsightAsync", "getProgressAsync", "putProgressAsync",
    "materializeWholeAsync",
}) do
    Assert.eq(type(moon[name]), "function")
end

package.preload["source.webdav.client"] = function()
    return { new = function() return {} end }
end
package.preload["source.webdav.mapper"] = function() return {} end
package.loaded["source.webdav"] = nil
local webdav = require("source.webdav").new()
for _, name in ipairs({ "pingAsync", "listLibraryAsync", "materializeWholeAsync" }) do
    Assert.eq(type(webdav[name]), "function")
end

package.preload["source.wechat.client"] = function()
    return { new = function() return {} end, sessionHeaders = function() return {} end }
end
package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return false end,
        userLabel = function() return "" end,
    }
end
package.preload["source.wechat.chapter"] = function() return {} end
package.preload["source.wechat.mapper"] = function() return {} end
package.loaded["source.wechat"] = nil
local wechat = require("source.wechat").new()
for _, name in ipairs({
    "pingAsync", "listLibraryAsync", "listStoreAsync", "recentBooksAsync",
    "getDetailAsync", "getTocAsync", "materializeChapterAsync",
    "getProgressAsync", "putProgressAsync",
}) do
    Assert.eq(type(wechat[name]), "function")
end

for _, name in ipairs({
    "utils.settings",
    "source.base",
    "source.error",
    "source.contract",
    "source.moon.client",
    "source.moon.mapper",
    "source.moon",
    "source.webdav.client",
    "source.webdav.mapper",
    "source.webdav",
    "source.wechat.client",
    "source.wechat.auth",
    "source.wechat.chapter",
    "source.wechat.mapper",
    "source.wechat",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.preload["json"] = original_json_preload

package.preload["json"] = function()
    return {
        encode = function() return "{}" end,
        decode = function() return {} end,
    }
end
package.preload["http.request"] = function()
    return {
        ok = function() return true end,
        header = function() return nil end,
        clearCache = function() end,
        request = function(_, cb)
            cb({ code = 200, body = "{}" })
            return { cancel = function() end }
        end,
        get = function(_, _, cb)
            cb("{}", nil, { code = 200, body = "{}" })
            return { cancel = function() end }
        end,
        post = function(_, _, _, cb)
            cb("{}", nil, { code = 200, body = "{}" })
            return { cancel = function() end }
        end,
    }
end
package.preload["http.header"] = function()
    return {
        merge = function(a, b)
            local out = {}
            for k, v in pairs(a or {}) do out[k] = v end
            for k, v in pairs(b or {}) do out[k] = v end
            return out
        end,
    }
end
package.preload["utils.settings"] = function()
    return { getSource = function() return { wr_vid = "id", wr_skey = "key" } end }
end
for _, name in ipairs({
    "json",
    "http.request",
    "http.header",
    "utils.settings",
}) do
    package.loaded[name] = nil
end
package.loaded["source.wechat.auth"] = nil

local auth_result
require("source.wechat.auth").apiGetAsync("/test", function(data)
    auth_result = data
end)
Assert.eq(type(auth_result), "table")

for _, name in ipairs({
    "json",
    "http.request",
    "http.header",
    "utils.settings",
    "source.wechat.auth",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.preload["socketutil"] = original_socketutil_preload
package.preload["json"] = original_json_preload

package.preload["socket.url"] = function() return { escape = function(s) return s end } end
package.preload["http.request"] = function()
    return {
        ok = function() return true end,
        clearCache = function() end,
        request = function(_, cb)
            cb({ code = 200, body = "{}" })
            return { cancel = function() end }
        end,
        download = function(_, _, cb)
            cb(true)
            return { cancel = function() end }
        end,
    }
end
package.preload["http.cache"] = function()
    return { key = function() return "" end, get = function() end, set = function() end }
end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.loaded["source.moon.client"] = nil

local client = require("source.moon.client"):new{}
for _, name in ipairs({
    "_jsonAsync", "pingAsync", "listBooksAsync", "recentBooksAsync", "filtersAsync",
    "registerReadingDeviceAsync", "importReadingStatsAsync", "readingInsightAsync",
    "getProgressAsync", "updateProgressAsync", "downloadBookAsync",
}) do
    Assert.eq(type(client[name]), "function")
end

for _, name in ipairs({
    "socket.url",
    "http.request",
    "http.cache",
    "ffi/util",
    "source.moon.client",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.preload["socketutil"] = original_socketutil_preload
package.preload["json"] = original_json_preload
