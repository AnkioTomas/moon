--[[--
scrape.douban 离线用例：打桩 http.request / socket.url，经 searchAsync 驱动 HTML 解析

@module tests.scrape.douban_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local function readFixture(name)
    local path = Config.root() .. "/tests/scrape/fixtures/" .. name
    local f = assert(io.open(path, "r"))
    local data = f:read("*a")
    f:close()
    return data
end

-- ── 打桩 http.request / socket.url ─────────────────────
local fake = { res = nil, err = nil, url = nil, cancelled = 0 }

package.preload["http.request"] = function()
    return {
        randomUA = function() return "TestUA/1.0" end,
        randomIP = function() return "203.0.113.1" end,
        header = function(res, name)
            return res and res.headers and res.headers[name] or nil
        end,
        request = function(opts, cb)
            fake.url = opts.url
            local res, err = fake.res, fake.err
            cb(res, err)
            return {
                cancel = function()
                    fake.cancelled = fake.cancelled + 1
                end,
            }
        end,
    }
end

package.preload["socket.url"] = function()
    return {
        escape = function(s)
            return (s:gsub("([^%w%-%._~])", function(c)
                return string.format("%%%02X", string.byte(c))
            end))
        end,
        unescape = function(s)
            return (s:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end))
        end,
    }
end

-- runner 会跨文件保留 socket.* 的 package.loaded，先清掉再吃自己的 preload
for _, name in ipairs({ "http.request", "socket.url", "scrape.douban" }) do
    package.loaded[name] = nil
end
local Douban = require("scrape.douban")

local function cleanup()
    for _, name in ipairs({ "http.request", "socket.url", "scrape.douban" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

--- 按 douban_id 索引结果，便于断言
local function indexById(results)
    local by_id = {}
    for _, r in ipairs(results) do
        by_id[r.douban_id] = r
    end
    return by_id
end

-- ── 空关键词直接报错，不发请求 ─────────────────────────
do
    fake.res, fake.err, fake.url = nil, nil, nil
    local got_res, got_err
    local job = Douban.searchAsync("   ", function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(job)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "搜索关键词为空")
    Assert.is_nil(fake.url)
end

-- ── 传输层错误原样透传 ─────────────────────────────────
do
    fake.res, fake.err = nil, "连接超时"
    local got_res, got_err
    Douban.searchAsync("活着", function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "连接超时")
end

-- ── 非 200 状态码 ─────────────────────────────────────
do
    fake.res, fake.err = { code = 418, body = "teapot" }, nil
    local got_res, got_err
    Douban.searchAsync("活着", function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "网络请求失败 (418)")
end

-- ── 200 但响应体为空 ──────────────────────────────────
do
    fake.res, fake.err = { code = 200, body = "" }, nil
    local got_res, got_err
    Douban.searchAsync("活着", function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "响应为空")
end

-- ── 主用例：fixture HTML 全字段解析 ────────────────────
do
    fake.res, fake.err = { code = 200, body = readFixture("douban_search.html") }, nil
    local results
    Douban.searchAsync("活着", function(res)
        results = res
    end)

    -- 查询词被 urlencode 拼进搜索地址
    Assert.not_nil(fake.url)
    Assert.is_true(fake.url:find("cat=1001&q=", 1, true) ~= nil)
    Assert.is_true(fake.url:find("q=%E6%B4%BB%E7%9D%80", 1, true) ~= nil)

    -- 5 个结果块：1 个低相似度被过滤，剩 4 个
    Assert.len(results, 4)

    -- 按相似度降序：精确匹配的「活着」(1.0) 排第一，即使它在 HTML 中靠后
    Assert.eq(results[1].title, "活着")
    Assert.eq(results[1].similarity, 1.0)
    for i = 2, #results do
        Assert.is_true(results[i - 1].similarity >= results[i].similarity)
    end

    local by_id = indexById(results)

    -- link2 跳转链接（subject%2F 编码）提取 subject id
    local exact = by_id["4913064"]
    Assert.not_nil(exact)
    Assert.eq(exact.url, "https://book.douban.com/subject/4913064/")
    Assert.eq(exact.rating, "9.4")
    Assert.eq(exact.cover_url, "https://img9.doubanio.com/view/subject/s/public/s27279654.jpg")
    Assert.eq(exact.cover_headers["Referer"], "https://book.douban.com/")
    Assert.eq(exact.intro, "《活着》讲述了农村人福贵悲惨的人生遭遇。")
    Assert.eq(exact.source, "douban")
    Assert.eq(exact.author, "余华")
    -- cast 为 4 段（含定价与日期）：出版社取年份前一段，日期段提出年份
    Assert.eq(exact.publisher, "作家出版社")
    Assert.eq(exact.year, "2012")

    -- 直连 /subject/ 链接 + parseCast 三段式正常提取
    local direct = by_id["25862578"]
    Assert.not_nil(direct)
    Assert.eq(direct.title, "活着吧")
    Assert.eq(direct.author, "莫言")
    Assert.eq(direct.publisher, "上海文艺出版社")
    Assert.eq(direct.year, "2020")
    Assert.eq(direct.rating, "8.1")

    -- 全编码链接（unescape 兜底路径）提取 subject id
    local encoded = by_id["36226988"]
    Assert.not_nil(encoded)
    Assert.eq(encoded.title, "活着呀")

    -- 链接里没有 id 时从 onclick 的 sid: 抠 + span 包裹标题的第二种写法
    local sid = by_id["36226843"]
    Assert.not_nil(sid)
    Assert.eq(sid.title, "活着传")
    Assert.eq(sid.author, "李四")

    -- 低相似度（< 0.6）条目已被过滤
    Assert.is_nil(by_id["1000001"])
end

-- ── 结果截断到前 10 条 ─────────────────────────────────
do
    local blocks = {}
    for i = 1, 12 do
        blocks[#blocks + 1] = string.format(
            '<div class="result"><div class="content"><h3>'
                .. '<a href="https://book.douban.com/subject/%d/" class="nbg">活着</a>'
                .. '</h3><span class="subject-cast">余华 / 作家出版社 / 2012</span>'
                .. '</div></div>',
            3000 + i
        )
    end
    fake.res, fake.err = { code = 200, body = table.concat(blocks, "\n") }, nil
    local results
    Douban.searchAsync("活着", function(res)
        results = res
    end)
    Assert.len(results, 10)
    Assert.eq(results[1].similarity, 1.0)
    Assert.eq(results[1].source, "douban")
end

-- ── 返回的 job 带 cancel ───────────────────────────────
do
    fake.res, fake.err = { code = 200, body = "no results here" }, nil
    local job = Douban.searchAsync("活着", function() end)
    Assert.eq(type(job.cancel), "function")
    job.cancel()
    Assert.eq(fake.cancelled > 0, true)
end

cleanup()
