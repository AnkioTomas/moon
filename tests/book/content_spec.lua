--[[--
book.content 离线用例

@module tests.book.content_spec
--]]

local Assert = require("support.assert")

local sizes = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            local sz = sizes[path]
            if not sz then
                return nil
            end
            return { mode = "file", size = sz }
        end,
        mkdir = function() return true end,
        dir = function() return function() end end,
    }
end
package.loaded["libs/libkoreader-lfs"] = nil
package.loaded["book.content"] = nil

local Content = require("book.content")

local tmp = os.tmpname()
do
    local f = io.open(tmp, "wb")
    f:write("PK\003\004rest")
    f:close()
    sizes[tmp] = 8
    Assert.is_true(Content.isValidEpub(tmp))
end

do
    local bad = tmp .. ".bad"
    local f = io.open(bad, "wb")
    f:write("XXXX")
    f:close()
    sizes[bad] = 4
    Assert.is_false(Content.isValidEpub(bad))
    os.remove(bad)
end

Assert.is_false(Content.isValidEpub("/no/such/file"))

-- in-flight：finish 延迟，保证第二次订阅合并
do
    local started = 0
    local results = {}
    local finish_fn
    Content.sharedJob("k1", function(finish)
        started = started + 1
        finish_fn = finish
    end, function(ok, path)
        results[#results + 1] = { ok, path }
    end)
    Content.sharedJob("k1", function(_finish)
        started = started + 1
    end, function(ok, path)
        results[#results + 1] = { ok, path }
    end)
    Assert.eq(started, 1)
    finish_fn(true, "/x", nil)
    Assert.eq(#results, 2)
    Assert.eq(results[1][2], "/x")
    Assert.eq(results[2][2], "/x")
end

os.remove(tmp)
package.preload["libs/libkoreader-lfs"] = nil
package.loaded["libs/libkoreader-lfs"] = nil
package.loaded["book.content"] = nil
