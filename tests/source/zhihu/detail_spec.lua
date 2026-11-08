--[[--
知乎详情：作者、完整分段简介、SKU 评分，以及异步链取消。

@module tests.source.zhihu.detail_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Mapper = require("source.zhihu.mapper")
local wire = {
    id = "11", sku_id = "99", title = "作品",
    authors = { { user = { name = "作者甲" } }, { name = "作者乙" } },
    artwork = "https://img/cover.jpg",
    keypoint = "<p>宣传语 &amp; 引言</p>",
    content = "<p>第一段。</p><p>第二段：完整简介结尾。</p>",
    contents = { { title = "第一章", content = "正文试读不是简介" } },
}
local grading = { show_score = true, score = "8.9", grading_count = 902 }
local book = Mapper.detail(wire, "11", grading)
Assert.eq(book.authors, "作者甲、作者乙")
Assert.eq(book.intro, "宣传语 & 引言\n\n第一段。\n第二段：完整简介结尾。")
Assert.eq(book.cover, wire.artwork)
Assert.eq(book.meta.rating.score, 8.9)
Assert.eq(book.meta.rating.by, "zhihu")
Assert.is_nil(Mapper.detail({ error = { code = 1 }, title = "错误" }, "11"))
Assert.is_nil(Mapper.detail(wire, "11", { show_score = false, score = "8.9" }).meta)
Assert.is_nil(Mapper.detail(wire, "11", { show_score = true, score = "11" }).meta)
Assert.eq(Mapper.detail({ title = "无简介", contents = wire.contents }, "11").intro, "",
    "不能把试读内容补成简介")

local pending, sync_detail, cancelled = {}, false, false
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        if sync_detail and url:find("/remix/paid_columns/", 1, true) then
            cb(JSON.encode(wire), nil, { code = 200 })
            return { cancel = function() error("不能取消已完成的详情请求") end }
        end
        pending[#pending + 1] = { url = url, opts = opts, cb = cb }
        return { cancel = function() cancelled = true end }
    end,
}
local Settings = require("utils.settings")
Settings.getSource("zhihu").cookie = "z_c0=fixture"
local Client = require("source.zhihu.client")
local result, err, calls = nil, nil, 0
local function done(value, reason) result, err, calls = value, reason, calls + 1 end
Client.detailAsync("11", done)
Assert.matches(pending[1].url, "/remix/paid_columns/11%?is_new_column=true&is_web=true$")
Assert.eq(pending[1].opts.headers.Cookie, "z_c0=fixture")
pending[1].cb(JSON.encode(wire))
Assert.eq(calls, 0)
Assert.matches(pending[2].url, "/darwin/sku_grading/99$", "评分用 SKU id，不能误用专栏 id")
pending[2].cb(JSON.encode(grading))
Assert.eq(calls, 1)
Assert.is_nil(err)
Assert.eq(result.authors, "作者甲、作者乙")
Assert.eq(result.meta.rating.score, 8.9)

Client.detailAsync("11", done)
pending[#pending].cb(nil, "network down")
Assert.is_nil(result)
Assert.eq(err, "network down")

Client.detailAsync("11", done)
pending[#pending].cb(JSON.encode(wire))
pending[#pending].cb(nil, "rating down")
Assert.eq(result.authors, "作者甲、作者乙", "评分暂时不可用不丢掉已获取的详情")
Assert.is_nil(result.meta)
Assert.is_nil(err)

sync_detail = true
local handle = Client.detailAsync("11", done)
local before = calls
handle.cancel()
Assert.is_true(cancelled, "同步完成详情后，取消仍指向在途的评分请求")
pending[#pending].cb(JSON.encode(grading))
Assert.eq(calls, before, "取消后迟到的评分不能更新详情")

local BookDB = require("book.books_db")
Assert.is_true(BookDB.upsertLocal({ source_id = "zhihu", stable_id = "11", title = "本地书名", category = "本地分类" }))
package.loaded["source.zhihu.client"] = {
    detailAsync = function(id, cb) cb(Mapper.detail(wire, id, grading)); return {} end,
}
local source = require("source.zhihu").new()
source:getDetailAsync({ source_id = "zhihu", stable_id = "11" }, done)
Assert.eq(result.authors, "作者甲、作者乙", "本地上架的脏行也要补缺失作者")
Assert.eq(result.intro, book.intro, "本地上架时没有简介，详情必须补全并落盘")
Assert.eq(result.title, "本地书名")
Assert.eq(result.category, "本地分类")
Assert.eq(result.sync_status, 0)
Assert.is_true(BookDB.upsertLocal({ source_id = "zhihu", stable_id = "11", title = "自定义书名",
    authors = "自定义作者", intro = "自定义简介", category = "本地分类" }))
source:getDetailAsync({ source_id = "zhihu", stable_id = "11" }, done)
Assert.eq(result.authors, "自定义作者")
Assert.eq(result.intro, "自定义简介", "自动补全不能覆盖已编辑的非空字段")
Settings.getSource("zhihu").cookie = nil
