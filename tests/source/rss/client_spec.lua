local Assert = require("support.assert")

local original_preload = package.preload["http.request"]
local original_loaded = package.loaded["http.request"]
local requests = 0
local pending
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests = requests + 1
            pending = { url = url, opts = opts, cb = cb, cancelled = false }
            return { cancel = function() pending.cancelled = true end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["source.rss.client"] = nil

local Client = require("source.rss.client")
local client = Client.new()
local xml = [[
<rss><channel><title>T</title>
<item><title>A</title><link>https://example.com/a</link>
<description>Body</description></item>
</channel></rss>
]]

local first, second
client:fetchAsync("example.com/feed", nil, function(data) first = data end)
client:fetchAsync("https://example.com/feed", nil, function(data) second = data end)
Assert.eq(requests, 1)
pending.cb(xml)
Assert.eq(first.title, "T")
Assert.eq(second.title, "T")

local cached
client:fetchAsync("https://example.com/feed", nil, function(data) cached = data end)
Assert.eq(requests, 1)
Assert.eq(cached.items[1].title, "A")

client:fetchAsync("https://example.com/feed", { force = true }, function() end)
Assert.eq(requests, 2)
client:clear()
Assert.is_true(pending.cancelled)

package.preload["http.request"] = original_preload
package.loaded["http.request"] = original_loaded
package.loaded["source.rss.client"] = nil
