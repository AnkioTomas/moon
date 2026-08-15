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

local tmp = os.tmpname() .. ".epub"
do
    local f = io.open(tmp, "wb")
    f:write("PK\003\004rest")
    f:close()
    sizes[tmp] = 8
    Assert.is_true(Content.isValidBook(tmp))
end

do
    local partial = tmp .. ".part"
    local f = io.open(partial, "wb")
    f:write("PK\003\004rest")
    f:close()
    sizes[partial] = 8
    Assert.is_true(Content.isValidBook(partial, tmp))
    os.remove(partial)
end

do
    local bad = tmp .. ".bad"
    local f = io.open(bad, "wb")
    f:write("XXXX")
    f:close()
    sizes[bad] = 4
    Assert.is_false(Content.isValidBook(bad))
    os.remove(bad)
end

do
    local pdf = tmp .. ".pdf"
    local f = io.open(pdf, "wb")
    f:write("%PDF-1.7")
    f:close()
    sizes[pdf] = 8
    Assert.is_true(Content.isValidBook(pdf))
    os.remove(pdf)
end

do
    local html = tmp .. ".html"
    local f = io.open(html, "wb")
    f:write("<!DOCTYPE html><html><body><p>x</p></body></html>")
    f:close()
    sizes[html] = 48
    Assert.is_true(Content.isValidBook(html))
    os.remove(html)
end

Assert.is_false(Content.isValidBook("/no/such/file"))
Assert.is_nil(Content.isValidEpub)

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
