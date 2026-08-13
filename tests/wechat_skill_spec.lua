--[[--
对齐官方 weread-skills / 社区 weread-mcp 能力面（Skill 1.0.4）。

Cursor 当前 mcp.json 未接入 weread MCP；本文件以官方 Agent Gateway 能力清单
做回归锚点，测 cookie 通道已实现子集 + 口径规则。

Skill / MCP 能力矩阵：
  ✅ /store/search          → Api:search(+scope)
  ✅ /shelf/sync            → Api:listShelf（books + albums；mp 计入 shelf_ui_count）
  ✅ /book/info             → Api:bookInfo
  ✅ /book/chapterinfo      → Api:chapterInfo（web chapterInfos）
  ✅ /book/getprogress      → Api:getProgress
  ❌ /user/notebooks 等笔记 → 未实现（需 wrk- Gateway）
  ❌ /readdata/detail       → capabilities.stats=false
  ❌ /review/*              → 未实现
  ❌ discover 推荐          → 未实现

@module tests.wechat_skill_spec
--]]

local Assert = require("support.assert")

local auth_state = {
    session = true,
    vid = "1",
    web = {},
    api = {},
    last_api_get = nil,
}

package.preload["source.wechat.auth"] = function()
    local Auth = {}
    function Auth.hasSession()
        return true
    end
    function Auth.userVid()
        return auth_state.vid
    end
    function Auth.sessionHeaders()
        return {}
    end
    function Auth.webApiGet(path)
        for k, v in pairs(auth_state.web) do
            if path:sub(1, #k) == k then
                return type(v) == "function" and v(path) or v
            end
        end
        return nil, "miss " .. path
    end
    function Auth.webApiPost(path, body)
        for k, v in pairs(auth_state.web) do
            if path:sub(1, #k) == k then
                return type(v) == "function" and v(path, body) or v
            end
        end
        return nil, "miss post " .. path
    end
    function Auth.apiGet(path)
        auth_state.last_api_get = path
        for k, v in pairs(auth_state.api) do
            if path:sub(1, #k) == k then
                return type(v) == "function" and v(path) or v
            end
        end
        return nil, "miss api " .. path
    end
    function Auth.apiPost()
        return nil, "unused"
    end
    return Auth
end

package.loaded["source.wechat.auth"] = nil
package.loaded["source.wechat.api"] = nil

local Api = require("source.wechat.api")

-- shelfUiCount 口径（Skill shelf.md）
Assert.eq(Api.shelfUiCount(10, 3, false), 13)
Assert.eq(Api.shelfUiCount(15, 0, true), 16)
Assert.eq(Api.shelfUiCount(130, 3, true), 134)

local api = Api:new({})

-- /shelf/sync：电子书 + 专辑 + mp
auth_state.web["/web/shelf/sync"] = {
    books = {
        { bookId = "e1", title = "电子书", author = "A" },
    },
    albums = {
        {
            albumInfo = {
                albumId = "a1",
                name = "有声书",
                authorName = "播音",
                cover = "https://cdn.example/a.jpg",
                trackCount = 12,
                finish = 1,
            },
            albumInfoExtra = { isTop = 1 },
        },
    },
    mp = { name = "文章收藏" },
}

do
    local res, err = api:listShelf()
    Assert.is_nil(err)
    Assert.eq(res.count, 2) -- 列表可打开行（不含 mp 入口）
    Assert.len(res.data, 2)
    Assert.eq(Api.shelfUiCount(1, 1, true), 3) -- Skill 口径：ebook+album+mp
    Assert.eq(res.data[1].id, "e1")
    Assert.eq(res.data[2].id, "a1")
    Assert.eq(res.data[2].title, "有声书")
    Assert.is_nil(res.data[2].extra)
    Assert.eq(res.data[2].percent, 100) -- album finish → percent
    Assert.is_true(res.data[2].favorite)
end

-- /store/search：显式 scope + V3 results[].books[].bookInfo
auth_state.api["/store/search"] = function(path)
    Assert.is_true(path:find("scope=10", 1, true) ~= nil or path:find("scope=14", 1, true) ~= nil)
    return {
        results = {
            {
                title = "电子书",
                scope = 17,
                books = {
                    { bookInfo = { bookId = "s1", title = "三体", author = "刘慈欣" } },
                },
            },
        },
    }
end

do
    local res, err = api:search("三体", 10, 10)
    Assert.is_nil(err)
    Assert.eq(res.count, 1)
    Assert.eq(res.data[1].id, "s1")
    Assert.eq(res.data[1].title, "三体")
    Assert.is_true(auth_state.last_api_get:find("scope=10", 1, true) ~= nil)
end

do
    api:search("听书", 5, 14)
    Assert.is_true(auth_state.last_api_get:find("scope=14", 1, true) ~= nil)
end

-- /book/info
auth_state.web["/web/book/info"] = {
    bookId = "820954",
    title = "无上神帝",
    author = "蜗牛狂奔",
    cover = "https://cdn.example/c.jpg",
    intro = "简介",
    newRating = 80,
}
do
    local b, err = api:bookInfo("820954")
    Assert.is_nil(err)
    Assert.eq(b.id, "820954")
    Assert.eq(b.title, "无上神帝")
    Assert.eq(b.authors, "蜗牛狂奔")
    Assert.eq(b.intro, "简介")
    Assert.is_nil(b.description)
    Assert.is_nil(b.newRating)
end

-- /book/chapterInfos：过滤封面与 wordCount=0，idx 重排连续
auth_state.web["/web/book/chapterInfos"] = {
    data = {
        {
            bookId = "820954",
            updated = {
                { chapterUid = "0", chapterIdx = 0, title = "封面", wordCount = 10 },
                { chapterUid = "1", chapterIdx = 1, title = "第一章", wordCount = 100 },
                { chapterUid = "2", chapterIdx = 2, title = "空章", wordCount = 0 },
                { chapterUid = "3", chapterIdx = 5, title = "第五章", wordCount = 200 },
            },
        },
    },
}
do
    local toc, err = api:chapterInfo("820954")
    Assert.is_nil(err)
    Assert.len(toc.chapters, 2)
    Assert.eq(toc.chapters[1].idx, 1)
    Assert.eq(toc.chapters[1].uid, "1")
    Assert.eq(toc.chapters[1].title, "第一章")
    Assert.eq(toc.chapters[2].idx, 2)
    Assert.eq(toc.chapters[2].uid, "3")
    Assert.eq(toc.chapters[2].title, "第五章")
end

-- getprogress：progress 是 0–100 整数（Skill book.md）→ 契约 percent
auth_state.web["/web/book/getProgress"] = {
    book = { progress = 1, chapterUid = "1", chapterIdx = 1 },
}
do
    local res = api:getProgress("820954")
    Assert.eq(res.data.percent, 1)
    Assert.eq(res.data.chapter_uid, "1")
    Assert.eq(res.data.chapter_idx, 1)
end
