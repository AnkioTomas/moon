--[[--
source.wechat.api 离线用例：stub Auth，测列表归一化 / 进度合并

@module tests.wechat_api_spec
--]]

local Assert = require("support.assert")

-- 必须在 require Api 之前注入 Auth
local auth_state = {
    session = true,
    vid = "10001",
    label = "tester",
    web = {},
    api = {},
}

package.preload["source.wechat.auth"] = function()
    local Auth = {}
    function Auth.hasSession()
        return auth_state.session
    end
    function Auth.userVid()
        return auth_state.vid
    end
    function Auth.userLabel()
        return auth_state.label
    end
    function Auth.webApiGet(path)
        local h = auth_state.web[path]
        if type(h) == "function" then
            return h(path)
        end
        if h ~= nil then
            return h
        end
        -- 前缀匹配（带 query）
        for k, v in pairs(auth_state.web) do
            if path:sub(1, #k) == k then
                if type(v) == "function" then
                    return v(path)
                end
                return v
            end
        end
        return nil, "webApiGet stub miss: " .. tostring(path)
    end
    function Auth.apiGet(path)
        for k, v in pairs(auth_state.api) do
            if path:sub(1, #k) == k then
                if type(v) == "function" then
                    return v(path)
                end
                return v
            end
        end
        return nil, "apiGet stub miss: " .. tostring(path)
    end
    function Auth.apiPost()
        return nil, "apiPost unused"
    end
    function Auth.sessionHeaders()
        return { Cookie = "wr_vid=1" }
    end
    function Auth.webPost()
        return nil, "webPost unused"
    end
    return Auth
end

-- 清掉可能已缓存的模块，确保吃到 stub
package.loaded["source.wechat.auth"] = nil
package.loaded["source.wechat.api"] = nil

local Api = require("source.wechat.api")
local api = Api:new({})

-- configured / ping
Assert.is_true(api:configured())
auth_state.session = false
Assert.is_false(api:configured())
auth_state.session = true

auth_state.web["/api/userInfo"] = { name = "N" }
do
    -- ping 会写 MoonSettings；stub 掉
    package.preload["moon.settings"] = function()
        return {
            getSource = function()
                return {}
            end,
            saveSource = function() end,
        }
    end
    package.loaded["moon.settings"] = nil
    local res, err = api:ping()
    Assert.is_nil(err)
    Assert.eq(res.ok, true)
    Assert.eq(res.user, "tester")
end

-- listShelf：嵌套 book + finishReading + progress 钳制 + albums
auth_state.web["/web/shelf/sync"] = {
    books = {
        {
            book = {
                bookId = "b1",
                title = "书一",
                author = "甲",
                cover = "https://cdn.example/c1.jpg",
                progress = 150, -- 钳到 100
                finishReading = 0,
            },
        },
        {
            bookId = "b2",
            bookName = "书二",
            authors = "乙",
            finishReading = 1,
            progress = 10, -- 读完抬到 100
        },
        {
            -- 无 id → 丢弃
            title = "幽灵",
        },
    },
    albums = {
        { albumInfo = { albumId = "al1", name = "听书一", authorName = "丙" } },
    },
    bookProgress = {
        { bookId = "b1", progress = 33, chapterUid = "c9", chapterIdx = 2 },
    },
}

do
    local res, err = api:listShelf()
    Assert.is_nil(err)
    Assert.eq(res.count, 3)
    Assert.len(res.data, 3)
    Assert.eq(res.data[1].id, "b1")
    Assert.eq(res.data[1].title, "书一")
    Assert.eq(res.data[1].authors, "甲")
    Assert.is_nil(res.data[1].cover)
    -- shelf.bookProgress 覆盖进度
    Assert.eq(res.data[1].percent, 33)
    Assert.is_nil(res.data[1].chapterUid)

    Assert.eq(res.data[2].id, "b2")
    Assert.eq(res.data[2].percent, 100)

    Assert.eq(res.data[3].id, "al1")
    Assert.is_nil(res.data[3].extra)

    -- 封面进 coverRequest 缓存，不进 Book
    local req = api:coverRequest("b1")
    Assert.eq(req.url, "https://cdn.example/c1.jpg")
end

-- listRecent：getRecentBooks 的 finished 是作品完结，不能当用户读完
auth_state.web["/api/storyfeed/getRecentBooks"] = {
    items = {
        {
            bookId = "r1",
            title = "最近",
            finished = 1, -- 作品完结字段，toBook 不读这个
            finishReading = 0,
            progress = 20,
        },
    },
}
-- shelf sync 给进度
auth_state.web["/web/shelf/sync"] = {
    bookProgress = {
        { bookId = "r1", progress = 55 },
    },
}

do
    local res, err = api:listRecent(5)
    Assert.is_nil(err)
    Assert.eq(res.count, 1)
    Assert.eq(res.data[1].id, "r1")
    -- 作品完结 finished=1 不能抬进度；shelf 权威进度 55
    Assert.eq(res.data[1].percent, 55)
    Assert.is_nil(res.data[1].finished)
end

-- search：空关键词 → 空列表
do
    local res, err = api:search("", 10)
    Assert.is_nil(err)
    Assert.eq(res.count, 0)
    Assert.len(res.data, 0)
end

-- coverRequest：list 里记住的 URL
do
    local req, err = api:coverRequest("b1")
    Assert.is_nil(err)
    Assert.eq(req.url, "https://cdn.example/c1.jpg")
end

-- getProgress：web 成功路径（契约字段：percent / chapter_*）
auth_state.web["/web/book/getProgress"] = {
    book = {
        progress = 12,
        chapterUid = "cu",
        chapterIdx = 3,
        chapterOffset = 9,
    },
}
do
    local res, err = api:getProgress("b1")
    Assert.is_nil(err)
    Assert.eq(res.data.percent, 12)
    Assert.eq(res.data.chapter_uid, "cu")
    Assert.eq(res.data.chapter_idx, 3)
    Assert.is_nil(res.data.chapter_offset)
end
