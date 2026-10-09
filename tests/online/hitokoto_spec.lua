--[[--
online.hitokoto：成功写 cache/online；失败读文件。
@module tests.online.hitokoto_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function()
    return require("support.json_stub")
end

local cache_dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-online-hitokoto-spec"
os.execute("mkdir -p '" .. cache_dir .. "'")
os.execute("rm -f '" .. cache_dir .. "/hitokoto.json'")
package.preload["utils.paths"] = function()
    return {
        onlineCacheDir = function() return cache_dir end,
        ensureOnlineCache = function() end,
    }
end

local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { url = url, opts = opts, cb = cb }
            return { cancel = function() end }
        end,
    }
end

local Hitokoto = require("online.hitokoto")
Assert.eq(Hitokoto.ttl, 60)

do -- 成功落盘
    requests = {}
    Hitokoto.data, Hitokoto._expire = nil, nil
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/hitokoto")
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb('{"hitokoto":"月亮","from":"博尔赫斯","from_who":"作者"}')
    Assert.eq(got.text, "月亮")
    Assert.eq(got.source, "作者 · 博尔赫斯")
    Hitokoto.data, Hitokoto._expire = nil, nil
    local loaded = Hitokoto:load()
    Assert.eq(loaded.text, "月亮")
    Assert.eq(loaded.source, "作者 · 博尔赫斯")
end

do -- 失败读本地
    requests = {}
    Hitokoto.data, Hitokoto._expire = nil, nil
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    requests[1].cb(nil, "down")
    Assert.eq(got.text, "月亮")
    Assert.eq(got.source, "作者 · 博尔赫斯")
end

do -- 无缓存：current 空；回退句按天取
    os.execute("rm -f '" .. cache_dir .. "/hitokoto.json'")
    Hitokoto.data, Hitokoto._expire, Hitokoto._cache_key = nil, nil, nil
    Assert.is_nil(Hitokoto:current())
    local a = Hitokoto.fallback()
    Assert.is_true(type(a.text) == "string" and a.text ~= "")
    Assert.eq(Hitokoto.fallback().text, a.text)
end

do -- 首页随机：缓存句拆成作者 / 作品
    Hitokoto.data = { text = "月亮", source = "作者 · 博尔赫斯" }
    Hitokoto._expire = os.time() + 60
    Hitokoto._cache_key = Hitokoto:url()
    local found
    for _ = 1, 80 do
        local quote = Hitokoto.random()
        if quote.text == "月亮" then
            found = quote
            break
        end
    end
    Assert.is_true(found ~= nil)
    Assert.eq(found.author, "作者")
    Assert.eq(found.title, "博尔赫斯")
    Hitokoto.data = nil
end

os.execute("rm -rf '" .. cache_dir .. "'")
return true
