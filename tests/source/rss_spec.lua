--[[--
source.rss 门面离线用例：configuredFeeds / findFeed / 源侧章节打开。

local 函数经导出入口驱动：configuredFeeds 走 listLibraryAsync/configured，
findFeed 走 getDetailAsync；章节打开验证源自己管理联网与进度 UI。

@module tests.source.rss_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local lfs = require("libs/libkoreader-lfs")

-- 可变配置：RSS.new 每次取同一张表，改 feeds 即可驱动不同用例
local cfg = { feeds = {} }

-- 假客户端：fetchAsync 直接回放 client_state 里的数据
local client_state = { data = nil, err = nil, cleared = 0 }
local chapter_open = {}
local progress_ui = { shown = 0, closed = 0, progress = {} }

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
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function()
            return {
                show = function() progress_ui.shown = progress_ui.shown + 1 end,
                close = function() progress_ui.closed = progress_ui.closed + 1 end,
                reportProgress = function(_, step)
                    progress_ui.progress[#progress_ui.progress + 1] = step
                end,
            }
        end,
    }
end
package.preload["source.chapter"] = function()
    return {
        openWithUi = function(_, _, _, _, ops, cb)
            local dialog = require("ui/widget/progressbardialog"):new{}
            dialog:show()
            ops.progress = function(step) dialog:reportProgress(step) end
            ops.progress(1)
            ops.progress(4)
            dialog:close()
            cb(chapter_open.path, chapter_open.err)
            return { cancel = function() end }
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

-- openBookAsync：RSS 源自己管理联网/进度 UI，回调首参为物理路径。
do
    chapter_open.path = "/cache/rss/feed/1.html"
    local src = RSS.new()
    local path, err, extra
    src:openBookAsync({ source_id = "rss", stable_id = "https://example.com/feed",
        book = { title = "订阅" } }, nil, function(...)
            path, err, extra = ...
        end)
    Assert.eq(path, "/cache/rss/feed/1.html")
    Assert.is_nil(err)
    Assert.is_nil(extra, "源打开回调不得泄露章节上下文")
    Assert.eq(progress_ui.shown, 1)
    Assert.eq(progress_ui.closed, 1)
    Assert.eq(progress_ui.progress[#progress_ui.progress], 4)
end

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
    Assert.eq(books.data[1].stable_id, "https://example.com/feed")
    Assert.eq(books.data[2].title, "乙")
    Assert.eq(books.data[2].stable_id, "https://b.example.com/rss")
end

-- configured：有无有效订阅
do
    cfg.feeds = {}
    local src = RSS.new()
    Assert.is_false(src:configured())

    cfg.feeds = { { url = "https://a.example.com/feed" } }
    Assert.is_true(src:configured())
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
    Assert.eq(detail.stable_id, "https://example.com/feed")

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

-- 清理：删除本 spec 独有的临时目录，还原 preload/loaded
-- 注意先收集再删除：lfs.dir 迭代中途删文件会跳过条目
do
    if lfs.attributes(TMP, "mode") == "directory" then
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
    end
    for _, name in ipairs({
        "utils.settings",
        "source.rss.client",
        "utils.paths",
        "ui/network/manager",
        "ui/widget/progressbardialog",
        "source.chapter",
        "source.rss",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end
