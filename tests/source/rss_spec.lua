--[[--
source.rss 门面离线用例：configuredFeeds / findFeed / reconcileChapterCache。

local 函数经导出入口驱动：configuredFeeds 走 listLibraryAsync/configured，
findFeed 走 getDetailAsync，reconcileChapterCache 走 getTocAsync（观察文件系统副作用）。

@module tests.source.rss_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local lfs = require("libs/libkoreader-lfs")

-- 可变配置：RSS.new 每次取同一张表，改 feeds 即可驱动不同用例
local cfg = { feeds = {} }

-- 假客户端：fetchAsync 直接回放 client_state 里的数据
local client_state = { data = nil, err = nil, cleared = 0 }

package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
    }
end

package.preload["source.rss.client"] = function()
    return {
        new = function()
            return {
                clear = function()
                    client_state.cleared = client_state.cleared + 1
                end,
                peek = function() return nil end,
                fetchAsync = function(_, _url, _opts, cb)
                    cb(client_state.data, client_state.err)
                    return { cancel = function() end }
                end,
            }
        end,
    }
end

-- reconcileChapterCache 写章节缓存目录；指到带本区域前缀的临时目录，结束清理
local TMP = Config.dir() .. "/.moon/cache/test_rss_spec"
local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("(.+)/[^/]+$")
    if parent and parent ~= path then ensureDir(parent) end
    lfs.mkdir(path)
end

package.preload["utils.paths"] = function()
    return {
        ensureBookWork = function() ensureDir(TMP) end,
        bookWorkDir = function() return TMP end,
    }
end

local RSS = require("source.rss")

local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

-- configuredFeeds：按规范化 URL 去重（保留首条）、跳过空 URL（经 listLibraryAsync 观察）
do
    cfg.feeds = {
        { url = "Example.COM/feed/", title = "甲" },
        { url = "https://example.com/feed", title = "甲副本" },
        { url = "   ", title = "空" },
        { url = "https://b.example.com/rss", title = "乙" },
    }
    local src = RSS.new()
    local books
    src:listLibraryAsync({}, function(result) books = result end)
    Assert.len(books.data, 2)
    Assert.eq(books.data[1].title, "甲")
    Assert.eq(books.data[1].ref.stable_id, "https://example.com/feed")
    Assert.eq(books.data[2].title, "乙")
    Assert.eq(books.data[2].ref.stable_id, "https://b.example.com/rss")
end

-- configured / configurationState：有无有效订阅
do
    cfg.feeds = {}
    local src = RSS.new()
    Assert.is_false(src:configured())
    Assert.eq(src:configurationState(), "needs_config")

    cfg.feeds = { { url = "https://a.example.com/feed" } }
    Assert.is_true(src:configured())
    Assert.eq(src:configurationState(), "ready")
end

-- findFeed：stable_id 双侧规范化匹配；未命中报「订阅不存在」（经 getDetailAsync 观察）
do
    cfg.feeds = { { url = "example.com/feed", title = "甲" } }
    client_state.data = { title = "远程标题", intro = "i", items = {} }
    client_state.err = nil
    local src = RSS.new()

    local detail, detail_err
    src:getDetailAsync({ stable_id = "https://example.com/feed" }, function(d, e)
        detail, detail_err = d, e
    end)
    Assert.is_nil(detail_err)
    Assert.eq(detail.title, "甲")
    Assert.eq(detail.ref.stable_id, "https://example.com/feed")

    -- 未规范化的 stable_id 同样命中
    local detail2
    src:getDetailAsync({ stable_id = "example.com/feed" }, function(d) detail2 = d end)
    Assert.not_nil(detail2)

    local missing, missing_err
    src:getDetailAsync({ stable_id = "https://elsewhere.example.com/x" }, function(d, e)
        missing, missing_err = d, e
    end)
    Assert.is_nil(missing)
    Assert.eq(missing_err, "订阅不存在")
end

-- getTocAsync 拉取失败：错误透传
do
    cfg.feeds = { { url = "https://a.example.com/feed" } }
    client_state.data = nil
    client_state.err = "网络故障"
    local src = RSS.new()
    local chapters, err
    src:getTocAsync({ stable_id = "https://a.example.com/feed" }, function(c, e)
        chapters, err = c, e
    end)
    Assert.is_nil(chapters)
    Assert.eq(err, "网络故障")
end

-- reconcileChapterCache：目录身份序列（uid 列表）变化才清 N.html 章节缓存
do
    cfg.feeds = { { url = "https://a.example.com/feed" } }
    client_state.err = nil
    local src = RSS.new()
    local ref = { stable_id = "https://a.example.com/feed", source_id = "rss" }
    local fingerprint_path = TMP .. "/rss-catalog"

    local function setItems(uids)
        local items = {}
        for _, uid in ipairs(uids) do
            items[#items + 1] = { uid = uid, link = "https://a.example.com/" .. uid, title = uid }
        end
        client_state.data = { title = "f", items = items }
    end

    local function getToc()
        local chapters, err
        src:getTocAsync(ref, function(c, e) chapters, err = c, e end)
        return chapters, err
    end

    -- 首次对账：无旧指纹，只写指纹不清缓存
    setItems({ "u1", "u2" })
    local chapters = getToc()
    Assert.len(chapters, 2)
    Assert.eq(readFile(fingerprint_path), "u1\nu2")

    -- 目录变化：删除 N.html / N.html.part，保留其它文件，更新指纹
    writeFile(TMP .. "/1.html", "a")
    writeFile(TMP .. "/2.html", "b")
    writeFile(TMP .. "/3.html.part", "c")
    writeFile(TMP .. "/keep.txt", "d")
    setItems({ "u2", "u3" })
    getToc()
    Assert.is_false(fileExists(TMP .. "/1.html"))
    Assert.is_false(fileExists(TMP .. "/2.html"))
    Assert.is_false(fileExists(TMP .. "/3.html.part"))
    Assert.is_true(fileExists(TMP .. "/keep.txt"))
    Assert.eq(readFile(fingerprint_path), "u2\nu3")

    -- 目录不变：缓存保留
    writeFile(TMP .. "/1.html", "a")
    getToc()
    Assert.is_true(fileExists(TMP .. "/1.html"))

    -- 空目录：报错且不动指纹
    setItems({})
    local empty_chapters, empty_err = getToc()
    Assert.is_nil(empty_chapters)
    Assert.eq(empty_err, "RSS 暂无文章")
    Assert.eq(readFile(fingerprint_path), "u2\nu3")
end

-- 清理：删除本 spec 独有的临时目录，还原 preload/loaded
-- 注意先收集再删除：lfs.dir 迭代中途删文件会跳过条目
do
    local names = {}
    for name in lfs.dir(TMP) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(names) do
        os.remove(TMP .. "/" .. name)
    end
    lfs.rmdir(TMP)
    for _, name in ipairs({
        "utils.settings",
        "source.rss.client",
        "utils.paths",
        "source.rss",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end
