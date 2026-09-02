--[[--
scrape.weread 离线用例：打桩 json（真实 decode）/ http.request / socket.url，经 searchAsync 驱动 mapBook

@module tests.scrape.weread_spec
--]]

local Assert = require("support.assert")

-- ── 最小 JSON decode（够用即可：对象/数组/字符串/数字/true/false/null）──
local function jsonDecode(str)
    local pos = 1
    local len = #str

    local function skipWs()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- 跳过开引号
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(parts)
            end
            if c == "\\" then
                local e = str:sub(pos + 1, pos + 1)
                if e == "n" then
                    parts[#parts + 1] = "\n"
                elseif e == "t" then
                    parts[#parts + 1] = "\t"
                elseif e == "r" then
                    parts[#parts + 1] = "\r"
                elseif e == "u" then
                    local code = tonumber(str:sub(pos + 2, pos + 5), 16) or 0
                    if code < 0x80 then
                        parts[#parts + 1] = string.char(code)
                    elseif code < 0x800 then
                        parts[#parts + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
                    else
                        parts[#parts + 1] = string.char(
                            0xE0 + math.floor(code / 4096),
                            0x80 + math.floor(code / 64) % 64,
                            0x80 + code % 64)
                    end
                    pos = pos + 4
                else
                    parts[#parts + 1] = e
                end
                pos = pos + 2
            else
                parts[#parts + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local function parseNumber()
        local num = str:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
        if not num or num == "" or num == "-" or tonumber(num) == nil then
            error("bad number at " .. pos)
        end
        pos = pos + #num
        return tonumber(num)
    end

    parseValue = function()
        skipWs()
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skipWs()
            if str:sub(pos, pos) == "}" then
                pos = pos + 1
                return obj
            end
            while true do
                skipWs()
                local key = parseString()
                skipWs()
                pos = pos + 1 -- ':'
                obj[key] = parseValue()
                skipWs()
                local d = str:sub(pos, pos)
                if d == "," then
                    pos = pos + 1
                elseif d == "}" then
                    pos = pos + 1
                    return obj
                else
                    error("bad object at " .. pos)
                end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skipWs()
            if str:sub(pos, pos) == "]" then
                pos = pos + 1
                return arr
            end
            while true do
                arr[#arr + 1] = parseValue()
                skipWs()
                local d = str:sub(pos, pos)
                if d == "," then
                    pos = pos + 1
                elseif d == "]" then
                    pos = pos + 1
                    return arr
                else
                    error("bad array at " .. pos)
                end
            end
        elseif c == '"' then
            return parseString()
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        else
            return parseNumber()
        end
    end

    skipWs()
    return parseValue()
end

-- ── 打桩 json / http.request / socket.url ──────────────
local fake = { res = nil, err = nil, url = nil }

package.preload["json"] = function()
    return {
        decode = jsonDecode,
        encode = function() error("json.encode not needed here", 2) end,
    }
end

package.preload["http.request"] = function()
    return {
        randomUA = function() return "TestUA/1.0" end,
        header = function() return nil end,
        request = function(opts, cb)
            fake.url = opts.url
            local res, err = fake.res, fake.err
            cb(res, err)
            return { cancel = function() end }
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
    }
end

-- runner 会跨文件保留 socket.* 的 package.loaded，先清掉再吃自己的 preload
for _, name in ipairs({ "json", "http.request", "socket.url", "scrape.weread" }) do
    package.loaded[name] = nil
end
local Weread = require("scrape.weread")

local function cleanup()
    for _, name in ipairs({ "json", "http.request", "socket.url", "scrape.weread" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- 罐头响应：3 本有效书（其中 1 本待验证字段）+ 1 本售罄 + 1 条空标题
local BODY = [[{
  "books": [
    {
      "bookInfo": {
        "title": "活着",
        "author": "余华",
        "publisher": "作家出版社",
        "publishTime": "2012-08-01",
        "isbn": "9787506365437",
        "intro": "  余华代表作。  ",
        "category": "文学-艺术",
        "newRating": 945,
        "newRatingDetail": { "title": "神作" },
        "cover": "https://wfqqreader-1252317822.image.myqcloud.com/cover/1/1.jpg",
        "bookId": "813451",
        "price": 0,
        "lPushName": "余华作品",
        "soldout": 0
      },
      "newRating": 945
    },
    {
      "bookInfo": {
        "title": "平凡的世界",
        "author": "路遥",
        "publisher": "北京十月文艺出版社",
        "publishTime": "2017年1月",
        "category": "文学／艺术",
        "newRating": 735,
        "newRatingDetail": { "title": "文学" },
        "bookId": "271013",
        "deepLink": "https://weread.qq.com/web/reader/abc123",
        "soldout": 0
      }
    },
    {
      "bookInfo": {
        "title": "无评分书",
        "author": "佚名",
        "publishTime": "",
        "bookId": "555",
        "soldout": 0
      }
    },
    {
      "bookInfo": {
        "title": "绝版书",
        "bookId": "999999",
        "soldout": 1
      }
    },
    {
      "bookInfo": { "title": "" }
    }
  ]
}]]

-- ── 空关键词直接报错，不发请求 ─────────────────────────
do
    fake.res, fake.err, fake.url = nil, nil, nil
    local got_res, got_err
    local job = Weread.searchAsync("  ", nil, function(res, err)
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
    Weread.searchAsync("活着", nil, function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "连接超时")
end

-- ── 非 200 状态码 ─────────────────────────────────────
do
    fake.res, fake.err = { code = 500, body = "{}" }, nil
    local got_res, got_err
    Weread.searchAsync("活着", nil, function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "网络请求失败")
end

-- ── 非法 JSON ─────────────────────────────────────────
do
    fake.res, fake.err = { code = 200, body = "not json at all" }, nil
    local got_res, got_err
    Weread.searchAsync("活着", nil, function(res, err)
        got_res, got_err = res, err
    end)
    Assert.is_nil(got_res)
    Assert.eq(got_err, "响应格式错误")
end

-- ── 无 books 字段：空结果而非报错 ──────────────────────
do
    fake.res, fake.err = { code = 200, body = '{"total":0}' }, nil
    local got_res, got_err
    Weread.searchAsync("活着", nil, function(res, err)
        got_res, got_err = res, err
    end)
    Assert.len(got_res, 0)
    Assert.is_nil(got_err)
end

-- ── 主用例：mapBook 字段映射 ───────────────────────────
do
    fake.res, fake.err = { code = 200, body = BODY }, nil
    local results
    Weread.searchAsync("活着", nil, function(res)
        results = res
    end)

    -- 关键词 urlencode 进地址
    Assert.is_true(fake.url:find("keyword=%E6%B4%BB%E7%9D%80", 1, true) ~= nil)

    -- 售罄 + 空标题被过滤，剩 3 本
    Assert.len(results, 3)

    local a = results[1]
    Assert.eq(a.title, "活着")
    Assert.eq(a.author, "余华")
    Assert.eq(a.publisher, "作家出版社")
    -- 评分：945 / 10 四舍五入取整 → 9.5
    Assert.eq(a.rating, "9.5")
    -- publishTime 抠年份
    Assert.eq(a.year, "2012")
    -- category 按 - 切 tags，newRatingDetail 追加新标签
    Assert.len(a.tags, 3)
    Assert.contains(a.tags, "文学")
    Assert.contains(a.tags, "艺术")
    Assert.contains(a.tags, "神作")
    -- intro 去首尾空白
    Assert.eq(a.intro, "余华代表作。")
    -- 无 deepLink 时按 bookId 兜底拼接
    Assert.eq(a.url, "https://weread.qq.com/web/reader/813451")
    Assert.eq(a.cover_url, "https://wfqqreader-1252317822.image.myqcloud.com/cover/1/1.jpg")
    Assert.eq(a.isbn, "9787506365437")
    Assert.eq(a.series, "余华作品")
    Assert.eq(a.price, "0")
    Assert.eq(a.source, "weread")
    Assert.eq(a.bookId, "813451")

    local b = results[2]
    Assert.eq(b.title, "平凡的世界")
    -- 735 / 10 = 73.5 → +0.5 取整 74 → 7.4
    Assert.eq(b.rating, "7.4")
    -- 非 ISO 日期也能抠出年份
    Assert.eq(b.year, "2017")
    -- 全角分隔符 ／ 也能切；detail 标题与已有 tag 重复不追加
    Assert.len(b.tags, 2)
    Assert.contains(b.tags, "文学")
    Assert.contains(b.tags, "艺术")
    -- deepLink 存在时原样使用
    Assert.eq(b.url, "https://weread.qq.com/web/reader/abc123")

    local c = results[3]
    Assert.eq(c.title, "无评分书")
    -- 无 newRating → 评分为空串
    Assert.eq(c.rating, "")
    -- publishTime 为空 → 年份空串
    Assert.eq(c.year, "")
    Assert.len(c.tags, 0)
    Assert.eq(c.url, "https://weread.qq.com/web/reader/555")
end

-- ── category 多字节分隔符：中文按完整字符切分，不切碎 UTF-8 ──
do
    local body = '{"books":[{"bookInfo":{"title":"字节切分","category":"文学-小说","bookId":"1"}}]}'
    fake.res, fake.err = { code = 200, body = body }, nil
    local results
    Weread.searchAsync("x", nil, function(res)
        results = res
    end)
    Assert.len(results, 1)
    Assert.len(results[1].tags, 2)
    Assert.eq(results[1].tags[1], "文学")
    Assert.eq(results[1].tags[2], "小说")
end

-- ── category 全角分隔符（／、，）与半角等价 ──
do
    local body = '{"books":[{"bookInfo":{"title":"全角分隔","category":"科幻／架空、热血，冒险","bookId":"2"}}]}'
    fake.res, fake.err = { code = 200, body = body }, nil
    local results
    Weread.searchAsync("x", nil, function(res)
        results = res
    end)
    Assert.len(results, 1)
    Assert.len(results[1].tags, 4)
    Assert.eq(results[1].tags[1], "科幻")
    Assert.eq(results[1].tags[2], "架空")
    Assert.eq(results[1].tags[3], "热血")
    Assert.eq(results[1].tags[4], "冒险")
end

-- ── 数字 bookId 归一为字符串；评分标签去空白且不重复 ────
do
    local body = [[{"books":[{"bookInfo":{
        "title":"类型归一","category":"文学","bookId":123,
        "newRatingDetail":{"title":" 文学 "}
    }}]}]]
    fake.res, fake.err = { code = 200, body = body }, nil
    local results
    Weread.searchAsync("x", nil, function(res)
        results = res
    end)
    Assert.len(results, 1)
    Assert.eq(results[1].bookId, "123")
    Assert.eq(results[1].url, "https://weread.qq.com/web/reader/123")
    Assert.len(results[1].tags, 1)
    Assert.eq(results[1].tags[1], "文学")
end

-- ── count 参数钳制：默认 10，<=0 回默认，>20 封顶 20 ──
do
    fake.res, fake.err = { code = 200, body = '{"books":[]}' }, nil

    Weread.searchAsync("活着", nil, function() end)
    Assert.is_true(fake.url:find("count=10", 1, true) ~= nil)

    Weread.searchAsync("活着", -5, function() end)
    Assert.is_true(fake.url:find("count=10", 1, true) ~= nil)

    Weread.searchAsync("活着", 99, function() end)
    Assert.is_true(fake.url:find("count=20", 1, true) ~= nil)

    Weread.searchAsync("活着", 5, function() end)
    Assert.is_true(fake.url:find("count=5", 1, true) ~= nil)
end

cleanup()
