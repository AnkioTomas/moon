--[[--
快看：签名、话题页目录、搜索和页图。

@module tests.source.kuaikan.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.kuaikan.mapper")
local Page = require("source.kuaikan.page")

local html = [[
<script>window.__NUXT__=(function(z,a,b,c,d,e,f,g,h){z.nickname="翘摇";return {data:[{topicInfo:{id:a,title:b,cover_image_url:c,description:d,first_comic_id:h},comics:[{id:a,title:e,locked:f},{id:11,title:"第二话",locked:g}]}]}}({},9,"错撩","https:\u002F\u002Fc\u002Fa.jpg","简介","序章",false,true,42));</script>
]]
local page = Page.topic(html)
Assert.eq(page.nickname, "翘摇")
Assert.eq(page.info.id, 9)
Assert.eq(page.info.title, "错撩")
Assert.eq(page.info.cover_image_url, "https://c/a.jpg")
Assert.eq(page.info.first_comic_id, 42)
Assert.eq(#page.chapters, 2)
Assert.eq(page.chapters[1].title, "序章")
Assert.eq(page.chapters[1].locked, false)
Assert.eq(page.chapters[2].locked, true)
Assert.is_nil(Page.topic("<html></html>"))

local detail = Mapper.detail(page.info, page.nickname)
Assert.eq(detail.stable_id, "9")
Assert.eq(detail.authors, "翘摇")
Assert.eq(detail.cover, "https://c/a.jpg")
Assert.eq(detail.source_id, "kuaikan")
Assert.eq(detail.intro, "简介")
local toc = Mapper.chapters(page.chapters)
Assert.eq(#toc, 2)
Assert.eq(toc[1].uid, "9")
Assert.eq(toc[1].vip, false)
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[2].vip, true)

local found = Mapper.search({
    code = 200,
    data = { topics = { hit = { { id = 9, title = "错撩", user = { nickname = "翘摇" }, vertical_image_url = "https://img/a.webp" } } } },
})
Assert.eq(found[1].stable_id, "9")
Assert.eq(found[1].authors, "翘摇")
Assert.eq(found[1].cover, "https://img/a.webp")
Assert.is_nil(Mapper.search({ code = 403 }))

local home = Mapper.home({
    code = 200,
    data = { popularity_topics = { { id = 3, title = "榜上", cover_image_url = "https://img/b.webp" } } },
})
Assert.eq(home[1].stable_id, "3")
Assert.eq(home[1].cover, "https://img/b.webp")

local fav = Mapper.fav({
    code = 200,
    data = { total = 1, topics = { { id = 9, title = "错撩", user = { nickname = "翘摇" }, vertical_image_url = "https://img/a.webp" } } },
})
Assert.eq(fav[1].stable_id, "9")
Assert.eq(fav[1].title, "错撩")
Assert.eq(#Mapper.fav({ code = 200, data = { total = 0, topics = {} } }), 0)
Assert.is_nil(Mapper.fav({ code = 200, data = {} }))

local urls = Mapper.images({
    code = 200,
    data = { comic_info = { locked = false, comic_images = { { url = "https://img/1.jpg" }, { url = "https://img/2.jpg" } } } },
})
Assert.eq(#urls, 2)
Assert.eq(urls[1], "https://img/1.jpg")
Assert.eq(select(2, Mapper.images({ code = 200, data = { comic_info = { locked = true, comic_images = {} } } })), "locked")

local Client = require("source.kuaikan.client")
local indexes = {}
for slot = 0, 15 do indexes[#indexes + 1] = slot end
Assert.eq(
    Client.answer("1793924589213", indexes),
    "MjAyMDA4MjBfMEIxdDJNM1Q0VTVsNmU3czhMOVgxMFAxMUkxMkYxM2oxNGYxNWNfMTc5MzkyNDU4OTIxM18zVDRVNWw2ZTdzOEw5WDEwUDExSTEyRjEzajE0ZjE1Yw=="
)

local requests = {}
package.preload["http.request"] = function()
    return {
        header = function(res, name)
            local headers = res and res.headers
            return headers and headers[name]
        end,
        get = function(url, _options, callback)
            requests[#requests + 1] = url
            if url:find("/search/web/complex", 1, true) then
                callback(Json.encode({ code = 200, data = { topics = { hit = { { id = 9, title = "错撩" } } } } }), nil, nil)
            elseif url:find("/v2/pweb/fav/topics", 1, true) then
                callback(Json.encode({ code = 200, data = { total = 1, topics = { { id = 9, title = "错撩" } } } }), nil, nil)
            elseif url:find("/v2/pweb/home", 1, true) then
                callback(Json.encode({ code = 200, data = { popularity_topics = { { id = 3, title = "榜上" } } } }), nil, nil)
            elseif url:find("/web/topic/", 1, true) then
                callback(html, nil, nil)
            elseif url:find("/v1/aegis/", 1, true) then
                callback("ok", nil, { headers = { ["set-cookie"] = "kk_s_t=1793924589213; Path=/" } })
            elseif url:find("/v2/comments/comic/", 1, true) then
                callback(Json.encode({
                    code = 200,
                    data = {
                        total = 80,
                        comments = {
                            { replied_comment_id = 0, content = "好看", likes_count = 3, created_at_info = "2020-01-02 12:00", user = { nickname = "甲" } },
                            { replied_comment_id = 9, content = "回复", user = { nickname = "乙" } },
                        },
                    },
                }), nil, nil)
            elseif url:find("/v2/pweb/comic/", 1, true) then
                callback(Json.encode({ code = 200, data = { comic_info = { comic_images = { { url = "https://img/1.jpg" } } } } }), nil, nil)
            else
                callback(nil, "miss", nil)
            end
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["source.kuaikan.client"] = nil

Client = require("source.kuaikan.client")
local books
Client.searchAsync("错撩", function(list) books = list end)
Assert.eq(books[1].title, "错撩")
Assert.is_true(requests[#requests]:find("q=", 1, true) ~= nil)

local ranked
Client.homeAsync(function(list) ranked = list end)
Assert.eq(ranked[1].stable_id, "3")

local fav_books
Client.favAsync(function(list) fav_books = list end)
Assert.eq(fav_books[1].title, "错撩")
Assert.is_true(requests[#requests]:find("/v2/pweb/fav/topics?since=0&limit=20", 1, true) ~= nil)

local loaded
Client.topicAsync("9", function(value) loaded = value end)
Assert.eq(#loaded.chapters, 2)

local images
Client.imagesAsync("9", function(list) images = list end)
Assert.eq(images[1], "https://img/1.jpg")
Assert.is_true(requests[#requests]:find("answer=", 1, true) ~= nil)

local reviews, total = Mapper.comments({
    code = 200,
    data = {
        total = 1,
        comments = { { replied_comment_id = 0, content = "好看", user = { nickname = "甲" }, created_at_info = "2020-01-02 12:00", likes_count = 3 } },
    },
})
Assert.eq(#reviews, 1)
Assert.eq(reviews[1].author, "甲")
Assert.eq(reviews[1].time, "2020-01-02")
Assert.eq(reviews[1].likes, 3)
Assert.eq(total, 1)
Assert.is_nil(Mapper.comments({ code = 200, data = {} }))

local loaded_reviews, review_err, pages
Client.commentsAsync("9", function(items, err, count) loaded_reviews, review_err, pages = items, err, count end)
Assert.is_nil(review_err)
Assert.eq(#loaded_reviews, 1)
Assert.eq(loaded_reviews[1].text, "好看")
Assert.eq(pages, 2)
Assert.eq(requests[#requests]:find("/v2/comments/comic/42/order/score?offset=0&limit=50&total=true", 1, true) ~= nil, true)
