--[[--
知乎盐选：榜单、搜索、折叠判断和签名正文接口。

@module tests.source.zhihu.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Mapper = require("source.zhihu.mapper")

local story_url = "https://www.zhihu.com/market/paid_column/1580618311758471168/section/1598363011911184384"
local feed = {
    data = { {
        module_type = "billboard",
        module_data = { data = { data = { {
            head = { type = "recommend", filters = { { key = "0", name = "全部" } } },
            content_list = { {
                title = "红包不能抢",
                url = story_url,
                artwork = "https://img/a.jpg",
                description = "预览",
            } },
        } } } },
    } },
}
local found = Mapper.feed(feed, "recommend")
Assert.eq(found[1].stable_id, "1580618311758471168/1598363011911184384")
Assert.eq(found[1].title, "红包不能抢")
Assert.eq(found[1].cover, "https://img/a.jpg")
Assert.eq(found[1].intro, "预览")
Assert.eq(#found, 1)
Assert.is_nil(Mapper.feed({ data = {} }, "recommend"), "缺少榜单不能当作空榜单")
Assert.is_nil(Mapper.feed({ error = { code = 1 } }, "recommend"))
local ranked_rows = feed.data[1].module_data.data.data
ranked_rows[2] = {
    head = { type = "hot", filters = {} },
    content_list = { { title = "热度榜条目", url = "https://www.zhihu.com/market/paid_column/3/section/4" } },
}
local entries = ranked_rows[1].content_list
entries[2] = { title = "第二名", url = "https://www.zhihu.com/market/paid_column/5/section/6" }
entries[3] = { title = "重复首位", url = story_url }
entries[4] = { title = "长篇", url = "https://www.zhihu.com/xen/market/remix/paid_column/7", description = "正文试读片段" }
feed.data[2] = { module_type = "feed_card", module_data = { data = { content_list = {
    { title = "推荐流", url = "https://www.zhihu.com/market/paid_column/8/section/9" },
} } } }
found = Mapper.feed(feed, "recommend")
Assert.len(found, 3, "只取所选榜单，不混入推荐流或其它榜单")
Assert.eq(found[1].title, "红包不能抢")
Assert.eq(found[2].title, "第二名")
Assert.eq(found[3].stable_id, "7", "长篇不能因没有节 id 被丢掉")
Assert.is_nil(found[3].intro, "长篇榜单给的是正文试读片段，不能存成书籍简介")
Assert.eq(Mapper.feed(feed, "hot")[1].title, "热度榜条目")
ranked_rows[2].content_list = {}
Assert.len(Mapper.feed(feed, "hot"), 0, "合法空榜单保留筛选项")

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

local requests = {}
local request_options = {}
local me_body = Json.encode({ id = "fixture-user", name = "甲" })
local me_error
local response_code = 200
package.preload["http.request"] = function()
    return {
        get = function(url, options, callback)
            requests[#requests + 1] = url
            request_options[#request_options + 1] = options
            if url:find("/api/v4/me", 1, true) then
                callback(me_body, me_error, { code = response_code })
            elseif response_code == 401 then
                callback(nil, "HTTP 401", { code = response_code })
            elseif url:find("/api/v4/search_v3", 1, true) then
                callback(Json.encode({ data = { { object = { url = story_url, body = { title = "红包不能抢" } } } } }), nil, nil)
            elseif url:find("/vip_tab/svip_story", 1, true) then
                callback(Json.encode(feed), nil, nil)
            elseif url:find("/manuscript/simple", 1, true) then
                callback(Json.encode(simple), nil, nil)
            elseif url:find("/manuscript?", 1, true) then
                callback(Json.encode({ is_fold = false, manuscript = "<p>甲</p>" }), nil, nil)
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
Client.browseAsync("recommend", "12", function(list) ranked = list end)
Assert.eq(ranked[1].title, "红包不能抢")
Assert.matches(requests[#requests], "modules=billboard&billboard_type=recommend&billboard_filter=12&offset=0&limit=10$")
Assert.is_nil(requests[#requests]:find("feed_card", 1, true))
Assert.eq(request_options[#request_options].headers.Referer, "https://www.zhihu.com/fiore/h5/vip-web")

local wire
Client.simpleAsync("1580618311758471168/1598363011911184384", function(value) wire = value end)
Assert.eq(wire.section.title, "红包不能抢")
Assert.matches(request_options[#request_options].headers["User-Agent"], "Chrome/")

local content
Client.contentAsync("1580618311758471168/1598363011911184384", function(value) content = value end)
Assert.eq(content, "<p>甲</p>")
Assert.matches(requests[#requests], "/manuscript%?v=1&manuscript_version=0$")
Assert.eq(request_options[#request_options].headers["x-zse-93"], "101_3_3.1")
Assert.matches(request_options[#request_options].headers["x-zse-96"], "^2%.0_.+")

local Settings = require("utils.settings")
local cfg = Settings.getSource("zhihu")
cfg.cookie = "z_c0=saved"
local verified, verify_error
Client.loginCheckAsync("z_c0=candidate", function(ok, err) verified, verify_error = ok, err end)
Assert.is_true(verified)
Assert.is_nil(verify_error)
Assert.eq(request_options[#request_options].headers.Cookie, "z_c0=candidate")
Assert.eq(cfg.cookie, "z_c0=saved", "校验新 Cookie 不能修改已保存的账号")

for _idx, body in ipairs({ "{}", "<html>登录</html>", '{"error":{"code":100}}', '{"id":""}', '{"id":false}' }) do
    me_body = body
    Client.loginCheckAsync("z_c0=invalid", function(ok, err) verified, verify_error = ok, err end)
    Assert.is_false(verified)
    Assert.is_true(verify_error ~= nil)
    Assert.eq(cfg.cookie, "z_c0=saved")
end
me_body, me_error = nil, "network down"
Client.loginCheckAsync("z_c0=candidate", function(ok, err) verified, verify_error = ok, err end)
Assert.is_false(verified)
Assert.eq(verify_error, "network down")

Client.contentAsync("1580618311758471168/1598363011911184384", function(value) content = value end)
Assert.eq(content, "<p>甲</p>")
Assert.eq(request_options[#request_options].headers.Cookie, "z_c0=saved", "已购正文请求必须携带登录态")
Client.searchAsync("红包", function() end)
Assert.eq(request_options[#request_options].headers.Cookie, "z_c0=saved")

local Auth = require("source.auth")
Auth.reset()
response_code = 401
Client.searchAsync("红包", function(_books, err) verify_error = err end)
Assert.is_true(Auth.expired("zhihu"))
Assert.eq(verify_error, "知乎登录已失效，请重新登录")
cfg.cookie = nil
Settings.saveSource("zhihu")
Auth.reset()
