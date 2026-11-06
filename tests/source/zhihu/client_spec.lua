--[[--
知乎盐选：榜单、搜索、折叠判断和章节页正文。

@module tests.source.zhihu.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.zhihu.mapper")
local Page = require("source.zhihu.page")

local story_url = "https://www.zhihu.com/market/paid_column/1580618311758471168/section/1598363011911184384"
local found = Mapper.feed({
    data = { {
        module_data = { data = { {
            content_list = { {
                title = "红包不能抢",
                url = story_url,
                artwork = "https://img/a.jpg",
                description = "预览",
            } },
        } } },
    } },
})
Assert.eq(found[1].stable_id, "1580618311758471168/1598363011911184384")
Assert.eq(found[1].title, "红包不能抢")
Assert.eq(found[1].cover, "https://img/a.jpg")
Assert.eq(found[1].intro, "预览")
Assert.eq(#found, 1)
Assert.eq(#Mapper.feed({ data = {} }), 0)
Assert.is_nil(Mapper.feed({ error = { code = 1 } }))

local searched = Mapper.search({
    data = { {
        type = "knowledge_ad",
        object = {
            url = story_url .. "?km_channel=search",
            body = { title = "<em>红包</em>不能抢", authors = { { name = "向南天" } }, images = { "https://img/b.jpg" }, description = "简介" },
        },
    } },
})
Assert.eq(searched[1].title, "红包不能抢")
Assert.eq(searched[1].authors, "向南天")
Assert.eq(searched[1].cover, "https://img/b.jpg")
Assert.eq(searched[1].intro, "简介")

local simple = {
    is_fold = false,
    section = { id = "1598363011911184384", title = "红包不能抢", head_artwork = "https://img/c.jpg" },
    paid_column = { title = "专栏", artwork = "https://img/d.jpg" },
}
local toc = Mapper.chapters(simple, "1580618311758471168/1598363011911184384")
Assert.eq(toc[1].uid, "1598363011911184384")
Assert.eq(toc[1].vip, false)
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
local folded = Mapper.chapters({ is_fold = true, section = { title = "红包不能抢" } }, "1/2")
Assert.eq(folded[1].vip, true)
local detail = Mapper.detail(simple, "1580618311758471168/1598363011911184384")
Assert.eq(detail.cover, "https://img/c.jpg")
Assert.eq(detail.source_id, "zhihu")

local html = [[<script>window.__={"__connectedAutoFetch":{"manuscript":{"data":{"manuscriptData":{"title":"红包不能抢","is_fold":false,"manuscript":"\u003cp\u003e甲\u003c/p\u003e"}}}}}</script>]]
Assert.eq(Page.manuscript(html), "<p>甲</p>")
local locked_html = html:gsub('"is_fold":false', '"is_fold":true', 1)
Assert.eq(select(2, Page.manuscript(locked_html)), "locked")
Assert.is_nil(Page.manuscript("<html></html>"))

local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, _options, callback)
            requests[#requests + 1] = url
            if url:find("/api/v4/search_v3", 1, true) then
                callback(Json.encode({ data = { { object = { url = story_url, body = { title = "红包不能抢" } } } } }), nil, nil)
            elseif url:find("/vip_tab/svip_story", 1, true) then
                callback(Json.encode({ data = { { url = story_url, title = "红包不能抢" } } }), nil, nil)
            elseif url:find("/manuscript/simple", 1, true) then
                callback(Json.encode(simple), nil, nil)
            elseif url:find("/market/paid_column/", 1, true) then
                callback(html, nil, nil)
            else
                callback(nil, "miss", nil)
            end
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["source.zhihu.client"] = nil

local Client = require("source.zhihu.client")
local books
Client.searchAsync("红包", function(list) books = list end)
Assert.eq(books[1].stable_id, "1580618311758471168/1598363011911184384")
Assert.is_true(requests[#requests]:find("t=km_general", 1, true) ~= nil)

local ranked
Client.browseAsync(function(list) ranked = list end)
Assert.eq(ranked[1].title, "红包不能抢")

local wire
Client.simpleAsync("1580618311758471168/1598363011911184384", function(value) wire = value end)
Assert.eq(wire.section.title, "红包不能抢")

local content
Client.contentAsync("1580618311758471168/1598363011911184384", function(value) content = value end)
Assert.eq(content, "<p>甲</p>")
