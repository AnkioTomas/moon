--[[--
online.bing：JSON + 图都落 cache/online；无缓存时图走 302。
@module tests.online.bing_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function()
    return require("support.json_stub")
end

local cache_dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-online-bing-spec"
os.execute("mkdir -p '" .. cache_dir .. "'")
os.execute("rm -f '" .. cache_dir .. "/bing.json' '" .. cache_dir .. "/bing.jpg'")
package.preload["utils.paths"] = function()
    return {
        onlineCacheDir = function() return cache_dir end,
        ensureOnlineCache = function() end,
    }
end

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local PNG = "\137PNG\r\n\26\nxxxx"
local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { kind = "get", url = url, opts = opts, cb = cb }
            return { cancel = function() end }
        end,
        download = function(opts, dest, cb)
            requests[#requests + 1] = { kind = "download", url = opts.url, dest = dest }
            local file = io.open(dest, "wb")
            if file then
                file:write(PNG)
                file:close()
            end
            cb(true)
            return { cancel = function() end }
        end,
    }
end

local by_key = {}
package.preload["workers.tasks"] = function()
    return {
        get = function(key) return by_key[key] end,
        enqueue = function(spec)
            by_key[spec.key] = spec
            spec.state = "running"
            spec.cancel = function()
                if spec.handle then spec.handle.cancel() end
                by_key[spec.key] = nil
            end
            spec.handle = spec.run(function() end, function()
                by_key[spec.key] = nil
            end)
            return spec
        end,
    }
end

local Online = require("online.base")
local Bing = require("online.bing")
Assert.eq(Bing.ttl, Online.untilMidnight)
Assert.eq(Bing.image_ext, "jpg")

do -- 无缓存走 302
    Bing.data, Bing._expire, Bing._cache_key, Bing._image_url = nil, nil, nil, nil
    Assert.eq(Bing:imageUrl(), "https://api.ankio.net/bing")
    Assert.is_nil(Bing:imagePath())
end

do -- JSON 元数据落到午夜；图用当天 link
    requests = {}
    Bing.data, Bing._expire, Bing._cache_key, Bing._image_url = nil, nil, nil, nil
    local got
    Bing:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].kind, "get")
    Assert.eq(requests[1].url, "https://api.ankio.net/bing?type=json")
    Assert.is_true(requests[1].opts.allow_redirects)
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb([[{
        "code":200,
        "data":{
            "link":"https://www.bing.com/th?id=OHR.x.jpg",
            "title":"樱花",
            "copyright":"© Bing"
        }
    }]])
    Assert.eq(got.title, "樱花")
    Assert.eq(got.copyright, "© Bing")
    Assert.eq(got.link, "https://www.bing.com/th?id=OHR.x.jpg")
    Assert.eq(Bing:imageUrl(), "https://www.bing.com/th?id=OHR.x.jpg")
    Assert.is_true(Bing:fresh())
    Assert.is_false(Bing:imageReady(), "fetch 只写 JSON，不下图")
    Assert.eq(#requests, 1)
end

do -- ensure：JSON 已在则只下图
    requests = {}
    Bing:ensure()
    Assert.eq(#requests, 1)
    Assert.eq(requests[1].kind, "download")
    Assert.eq(requests[1].url, "https://www.bing.com/th?id=OHR.x.jpg")
    Assert.eq(requests[1].dest, cache_dir .. "/bing.jpg")
    Assert.is_true(Bing:imageReady())
    Assert.eq(Bing:imagePath(), cache_dir .. "/bing.jpg")
end

do -- 都就绪不再入队
    requests, by_key = {}, {}
    Bing:ensure()
    Assert.eq(#requests, 0)
end

do -- 新 JSON 即使 link 相同也清掉图标记，隔日同 URL 必须重下
    Assert.is_true(Bing:imageReady())
    Bing:store({ link = "https://www.bing.com/th?id=OHR.x.jpg" })
    Assert.is_false(Bing:imageReady())
    Bing._expire = os.time() + 60
    Bing._cache_key = Bing:url()
    Bing._image_url = "https://www.bing.com/th?id=OHR.x.jpg"
    Assert.is_true(Bing:imageReady(), "文件还在且 URL 对上才算图就绪")
end

do -- 图坏了必须重下，JSON 不用重拉
    os.remove(cache_dir .. "/bing.jpg")
    Bing._image_url = nil
    requests, by_key = {}, {}
    Bing:ensure()
    Assert.eq(#requests, 1)
    Assert.eq(requests[1].kind, "download")
    Assert.is_true(Bing:imageReady())
end

do -- ensureImage：下完图回 (path, nil)，不能带错误（锁屏据此判成败）
    os.remove(cache_dir .. "/bing.jpg")
    Bing._image_url = nil
    requests, by_key = {}, {}
    local got_path, got_err, called
    Bing:ensureImage(function(path, err) got_path, got_err, called = path, err, true end)
    Assert.is_true(called)
    Assert.eq(got_path, cache_dir .. "/bing.jpg")
    Assert.is_nil(got_err)
end

do -- 损坏内容不能记成当天图
    local dest = cache_dir .. "/bing.jpg"
    os.remove(dest)
    Bing._image_url = nil
    requests, by_key = {}, {}
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return {
            get = function(url, opts, cb)
                requests[#requests + 1] = { kind = "get", url = url, opts = opts, cb = cb }
                return { cancel = function() end }
            end,
            download = function(opts, path, cb)
                requests[#requests + 1] = { kind = "download", url = opts.url, dest = path }
                local file = io.open(path, "wb")
                file:write("<html>error</html>")
                file:close()
                cb(true)
                return { cancel = function() end }
            end,
        }
    end
    package.loaded["online.base"] = nil
    package.loaded["online.bing"] = nil
    Bing = require("online.bing")
    Bing.data = { link = "https://www.bing.com/th?id=OHR.x.jpg" }
    Bing._expire = os.time() + 60
    Bing._cache_key = Bing:url()
    Bing:ensure()
    Assert.eq(#requests, 1)
    Assert.is_false(Bing:imageReady())
    Assert.is_nil(Bing:imagePath())
    local file = io.open(dest, "rb")
    Assert.is_nil(file, "坏文件必须删掉")
end

os.execute("rm -rf '" .. cache_dir .. "'")
return true
