--[[--
online.hitokoto：一次拉取最多 20 条写入 cache/online；过期后仍可展示；失败读文件。
@module tests.online.hitokoto_spec
--]]

local Assert = require("support.assert")

package.preload["device"] = function() return { model = "KindlePaperWhite5" } end

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

local home = {}
package.preload["utils.settings"] = function()
    return { get = function() return home end, save = function() end }
end

local Hitokoto = require("online.hitokoto")
Assert.eq(Hitokoto.ttl, 3600)
Assert.eq(Hitokoto.batch_size, 20)
Assert.eq(#Hitokoto.TYPES, 12)
Assert.eq(Hitokoto:url(), "https://api.ankio.net/hitokoto?count=20")
Assert.eq(table.concat(Hitokoto.normalizeTypes(nil), ""), "abcdefghijkl")
Assert.eq(table.concat(Hitokoto.normalizeTypes({}), ""), "abcdefghijkl")
Assert.eq(table.concat(Hitokoto.normalizeTypes({ "i", "zzz", "a", "a" }), ","), "a,i")
Assert.eq(table.concat(Hitokoto.selectedTypes(), ""), "abcdefghijkl")

local function clearState()
    Hitokoto.data, Hitokoto._expire, Hitokoto._cache_key = nil, nil, nil
end

local function batchBody(n)
    local parts = {}
    for i = 1, n do
        parts[i] = string.format(
            '{"id":%d,"hitokoto":"句%d","type":"i","from":"出处%d","from_who":"作者%d"}',
            i, i, i, i)
    end
    return '{"code":200,"data":[' .. table.concat(parts, ",") .. ']}'
end

do -- 批量 20 条落盘
    requests = {}
    clearState()
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/hitokoto?count=20")
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb(batchBody(20))
    Assert.eq(#got.items, 20)
    Assert.eq(got.items[1].text, "句1")
    Assert.eq(got.items[1].source, "作者1 · 出处1")
    Assert.eq(got.items[20].text, "句20")
    clearState()
    local loaded = Hitokoto:load()
    Assert.eq(#loaded.items, 20)
    Assert.eq(loaded.items[20].text, "句20")
    Assert.eq(#Hitokoto:quotes(), 20)
end

do -- 不足 20 条：有多少用多少
    requests = {}
    clearState()
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    requests[1].cb(batchBody(3))
    Assert.eq(#got.items, 3)
    Assert.eq(got.items[3].text, "句3")
end

do -- 未升级后端：count 被忽略，仍是单条对象
    requests = {}
    clearState()
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    requests[1].cb('{"code":200,"data":{"hitokoto":"月亮","from":"博尔赫斯","from_who":"作者"}}')
    Assert.eq(#got.items, 1)
    Assert.eq(got.items[1].text, "月亮")
    Assert.eq(got.items[1].source, "作者 · 博尔赫斯")
end

do -- 失败读本地未过期缓存
    requests = {}
    -- 上一用例已写入「月亮」
    Hitokoto.data, Hitokoto._expire = nil, nil
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    requests[1].cb(nil, "down")
    Assert.eq(#got.items, 1)
    Assert.eq(got.items[1].text, "月亮")
    Assert.eq(got.items[1].source, "作者 · 博尔赫斯")
end

do -- 无缓存：current / quotes 空；回退句按天取
    os.execute("rm -f '" .. cache_dir .. "/hitokoto.json'")
    clearState()
    Assert.is_nil(Hitokoto:current())
    Assert.eq(#Hitokoto:quotes(), 0)
    local a = Hitokoto.fallback()
    Assert.is_true(type(a.text) == "string" and a.text ~= "")
    Assert.eq(Hitokoto.fallback().text, a.text)
    Assert.eq(Hitokoto.stable().text, a.text)
end

do -- 旧的单条缓存可展示，且不再混入内置回退句
    clearState()
    Hitokoto.data = { text = "月亮", source = "作者 · 博尔赫斯" }
    Hitokoto._expire = os.time() + 60
    Hitokoto._cache_key = Hitokoto:url()
    Assert.eq(#Hitokoto:quotes(), 1)
    for _ = 1, 20 do
        local quote = Hitokoto.random()
        Assert.eq(quote.text, "月亮")
        Assert.eq(quote.author, "作者")
        Assert.eq(quote.title, "博尔赫斯")
    end
end

do -- 有 20 条缓存时首页只从里面抽，过期后 current 空但 quotes 仍可用
    local items = {}
    local allowed = {}
    for i = 1, 20 do
        items[i] = { text = "缓存" .. i, source = "源" .. i }
        allowed[items[i].text] = true
    end
    clearState()
    Hitokoto.data = { items = items }
    Hitokoto._expire = os.time() - 10
    Hitokoto._cache_key = Hitokoto:url()
    Assert.is_nil(Hitokoto:current())
    Assert.eq(#Hitokoto:quotes(), 20)
    local seen = {}
    for _ = 1, 80 do
        local quote = Hitokoto.random()
        Assert.is_true(allowed[quote.text] == true, "抽到了缓存之外的句子: " .. tostring(quote.text))
        seen[quote.text] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    Assert.is_true(n > 1, "应从多条缓存里抽取")
    local stable = Hitokoto.stable()
    Assert.is_true(allowed[stable.text] == true)
    Assert.eq(Hitokoto.stable().text, stable.text)
end

do -- 避重：有多条时躲开上一句
    clearState()
    Hitokoto.data = { items = {
        { text = "甲", source = "A" },
        { text = "乙", source = "B" },
    } }
    Hitokoto._expire = os.time() + 60
    Hitokoto._cache_key = Hitokoto:url()
    Assert.eq(Hitokoto.random("甲").text, "乙")
    Assert.eq(Hitokoto.random("乙").text, "甲")
end

do -- 勾选子集时 URL 带 c=（官方字母序）；全选或脏数据不加 c
    home.home_hitokoto_types = { "i", "d", "a" }
    Assert.eq(Hitokoto:url(), "https://api.ankio.net/hitokoto?count=20&c=a,d,i")
    home.home_hitokoto_types = { "zzz" }
    Assert.eq(Hitokoto:url(), "https://api.ankio.net/hitokoto?count=20")
    home.home_hitokoto_types = Hitokoto.allTypeIds()
    Assert.eq(Hitokoto:url(), "https://api.ankio.net/hitokoto?count=20")
    home.home_hitokoto_types = nil
end

do -- 类型变了：旧缓存不再进入展示池，新请求走新 URL
    clearState()
    home.home_hitokoto_types = { "i" }
    Hitokoto.data = { items = { { text = "旧诗", source = "李" } } }
    Hitokoto._expire = os.time() + 60
    Hitokoto._cache_key = "https://api.ankio.net/hitokoto?count=20"
    Assert.eq(#Hitokoto:quotes(), 0)
    Assert.is_nil(Hitokoto:current())
    local fallback = Hitokoto.stable()
    Assert.is_true(type(fallback.text) == "string" and fallback.text ~= "旧诗")

    requests = {}
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/hitokoto?count=20&c=i")
    requests[1].cb('{"code":200,"data":[{"hitokoto":"新诗","type":"i","from":"词","from_who":"人"}]}')
    Assert.eq(#got.items, 1)
    Assert.eq(got.items[1].text, "新诗")
    Assert.eq(#Hitokoto:quotes(), 1)
    Assert.eq(Hitokoto.stable().text, "新诗")
    home.home_hitokoto_types = nil
end

do -- 锁屏与首页共用同一批缓存 / 类型
    clearState()
    home.home_hitokoto_types = { "a", "d" }
    Hitokoto.data = { items = {
        { text = "动画句", source = "A" },
        { text = "文学句", source = "D" },
    } }
    Hitokoto._expire = os.time() + 60
    Hitokoto._cache_key = Hitokoto:url()
    Assert.eq(Hitokoto:url(), "https://api.ankio.net/hitokoto?count=20&c=a,d")
    local stable = Hitokoto.stable()
    Assert.is_true(stable.text == "动画句" or stable.text == "文学句")
    for _ = 1, 20 do
        local quote = Hitokoto.random()
        Assert.is_true(quote.text == "动画句" or quote.text == "文学句")
    end
    home.home_hitokoto_types = nil
end

do -- ttl 缺省 1 小时；0 表示不联网，ensureConfigured 不入队
    home.home_hitokoto_ttl = nil
    Assert.eq(Hitokoto.configuredTtl(), 3600)
    home.home_hitokoto_ttl = 0
    Assert.eq(Hitokoto.configuredTtl(), 0)
    home.home_hitokoto_ttl = 600
    Assert.eq(Hitokoto.configuredTtl(), 600)
    home.home_hitokoto_ttl = -1
    Assert.eq(Hitokoto.configuredTtl(), 3600)

    local called = 0
    local orig = Hitokoto.ensure
    function Hitokoto:ensure() called = called + 1 end
    home.home_hitokoto_ttl = 0
    Hitokoto:ensureConfigured()
    Assert.eq(called, 0, "ttl==0 不联网")
    home.home_hitokoto_ttl = 600
    Hitokoto:ensureConfigured()
    Assert.eq(called, 1)
    Assert.eq(Hitokoto.ttl, 600)
    Hitokoto.ensure = orig
    home.home_hitokoto_ttl = nil
    Hitokoto.ttl = 3600
end

os.execute("rm -rf '" .. cache_dir .. "'")
return true
