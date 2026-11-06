--[[--
知音漫客：封面路径、目录排序、跳转和页图。

@module tests.source.zymk.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.zymk.mapper")
local Page = require("source.zymk.page")

Assert.eq(
    Mapper.cover(4982),
    "https://chapter-cover.yyhao.com/file/cover/000/004/982.jpg-300x400"
)
Assert.is_nil(Mapper.cover("nope"))

local found = Mapper.list({
    status = 0,
    data = { page = { comic_list = {
        { comic_id = 4982, comic_name = "长相思", comic_feature = "简介" },
    } } },
})
Assert.eq(found[1].stable_id, "4982")
Assert.eq(found[1].title, "长相思")
Assert.eq(found[1].intro, "简介")
Assert.eq(found[1].cover, Mapper.cover(4982))
Assert.eq(#Mapper.list({ status = 0, data = { page = { comic_list = {} } } }), 0)
Assert.is_nil(Mapper.list({ status = 1 }))

local html = [[
<meta property="og:novel:book_name" content="长相思">
<meta property="og:novel:author" content="飒飒动漫">
<meta property="og:description" content="简介">
<meta property="og:image" content="https://img/cover.jpg">
<a href="/sort/26.html">少女漫画</a>
<a href="434454.html">202话</a>
]]
local parsed = Page.detail(html)
Assert.eq(parsed.title, "长相思")
Assert.eq(parsed.authors, "飒飒动漫")
Assert.eq(parsed.chapter_file, "434454")
Assert.eq(parsed.cover, "https://img/cover.jpg")
Assert.is_nil(Page.detail("<html></html>"))

local detail = Mapper.detail(parsed, 4982)
Assert.eq(detail.authors, "飒飒动漫")
Assert.eq(detail.cover, "https://img/cover.jpg")
Assert.eq(detail.source_id, "zymk")
Assert.eq(detail.intro, "简介")

local toc = Mapper.chapters(25289, {
    { chapter_name = "后一话", chapter_newid = "hou", order_num = 10, price = 5 },
    { chapter_name = "序章", chapter_newid = "xu", order_num = 3, price = 0 },
})
Assert.eq(#toc, 2)
Assert.eq(toc[1].uid, "25289/xu")
Assert.eq(toc[1].title, "序章")
Assert.eq(toc[1].vip, false)
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[2].vip, true)
Assert.is_nil(Mapper.chapters(25289, {}))

local urls = Mapper.images({
    status = 0,
    data = { current_chapter = { price = 0, is_vip = 0, chapter_img_list = { "https://img/1.jpg", "https://img/2.jpg" } } },
})
Assert.eq(#urls, 2)
Assert.eq(select(2, Mapper.images({
    status = 0,
    data = { current_chapter = { price = 5, is_vip = 0, chapter_img_list = {} } },
})), "locked")
Assert.is_nil(Mapper.images({ status = 1 }))

local requests = {}
package.preload["http.request"] = function()
    return {
        header = function(res, name)
            local headers = res and res.headers
            return headers and headers[name]
        end,
        get = function(url, _options, callback)
            requests[#requests + 1] = url
            if url:find("key=", 1, true) then
                callback(Json.encode({ status = 0, data = { page = { comic_list = { { comic_id = 4982, comic_name = "长相思" } } } } }), nil, nil)
            elseif url:find("/apinew/getsortlist/", 1, true) then
                callback(Json.encode({ status = 0, data = { page = { comic_list = { { comic_id = 101, comic_name = "凤逆天下" } } } } }), nil, nil)
            elseif url:find(".html", 1, true) then
                callback(nil, "HTTP 301", { code = 301, headers = { location = "https://www.kanman.com/25289/di202hua.html" } })
            elseif url:find("/4982/", 1, true) then
                callback(html, nil, nil)
            elseif url:find("/api/getchapterlist", 1, true) then
                callback(Json.encode({ status = 0, data = {
                    { chapter_name = "后一话", chapter_newid = "hou", order_num = 10, price = 0 },
                    { chapter_name = "序章", chapter_newid = "xu", order_num = 3, price = 0 },
                } }), nil, nil)
            elseif url:find("/api/getchapterinfov2", 1, true) then
                callback(Json.encode({ status = 0, data = { current_chapter = { chapter_img_list = { "https://img/1.jpg" } } } }), nil, nil)
            else
                callback(nil, "miss", nil)
            end
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["source.zymk.client"] = nil

local Client = require("source.zymk.client")
local books
Client.searchAsync("长相思", function(list) books = list end)
Assert.eq(books[1].stable_id, "4982")

local ranked
Client.browseAsync(function(list) ranked = list end)
Assert.eq(ranked[1].stable_id, "101")

local loaded
Client.catalogAsync("4982", function(value) loaded = value end)
Assert.eq(loaded.book.title, "长相思")
Assert.eq(loaded.chapters[1].uid, "25289/xu")
Assert.is_true(requests[#requests]:find("comic_id=25289", 1, true) ~= nil)

local images
Client.imagesAsync("25289/xu", function(list) images = list end)
Assert.eq(images[1], "https://img/1.jpg")
Assert.is_true(requests[#requests]:find("isWebp=0", 1, true) ~= nil)
Assert.is_true(requests[#requests]:find("chapter_newid=xu", 1, true) ~= nil)
