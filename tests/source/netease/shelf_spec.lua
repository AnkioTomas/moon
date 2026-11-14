--[[--
网易官网 HTML 书架：身份、分页、整批失败与取消，以及本地增删上行。

@module tests.source.netease.shelf_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local CookieOf = require("support.cookie")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Text = require("utils.text")
local Mapper = require("source.netease.mapper")

local function row(id, title, extra)
    return '<li><div class="m-bookshow" prog="0"><div class="m-infos"><h4>书</h4><p>作者甲</p></div>'
        .. '<a data-contentinfo="' .. Text.xmlEscape(JSON.encode({
            sourceUuid = id, sourceTitle = title, imageUrl = "//img/cover.jpg",
            imageDescription = "简介", origin = { "bookshelf", 0 },
        })) .. '"></a>' .. (extra or "") .. '</div></li>'
end
local function page(content, next_page)
    return "<html><title>我的书架--网易云阅读</title>" .. content
        .. (next_page and '<a href="/shelf.do?operation=query_current&amp;style=grid&amp;page='
            .. next_page .. '">下一页</a>' or "") .. "</html>"
end

local books, next_page, err = Mapper.shelfPage(page(row("first_4", "甲 & 乙"), 2), 1)
Assert.eq(books[1].source_id, "netease")
Assert.eq(books[1].stable_id, "first_4")
Assert.eq(books[1].title, "甲 & 乙")
Assert.eq(books[1].authors, "作者甲")
Assert.eq(books[1].cover, "https://img/cover.jpg")
Assert.eq(next_page, 2)
Assert.is_nil(err)
books = Mapper.shelfPage(page(row("first_4", "甲") .. row("first_4", "重复")
    .. row("local_4", "本地上传", '<input data-local="true">')), 1)
Assert.len(books, 1)
books, next_page = Mapper.shelfPage(page("", 1), 1)
Assert.len(books, 0)
Assert.is_nil(next_page, "当前页链接不能造成循环")
books, next_page, err = Mapper.shelfPage("<html><title>登录</title></html>", 1)
Assert.is_nil(books)
Assert.is_true(err ~= nil)
books, next_page, err = Mapper.shelfPage(page('<li><div class="m-bookshow"><a data-contentinfo="broken"></a></div></li>'), 1)
Assert.is_nil(books, "坏行不能被跳过后当作完整快照")
Assert.eq(err, "响应无效")

local cfg = { logged_in = true, cookie = "NTES=fixture", csrf = "csrf" }
package.loaded["utils.settings"] = { getSource = function() return cfg end }
local pending, cancelled = {}, 0
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        pending[#pending + 1] = { url = url, opts = opts, cb = cb }
        return { cancel = function() cancelled = cancelled + 1 end }
    end,
}
local Client = require("source.netease.client")
local result, failure, calls = nil, nil, 0
local function done(value, reason) result, failure, calls = value, reason, calls + 1 end
Client:shelfSyncAsync(done)
Assert.matches(pending[1].url, "https://guofeng%.yuedu%.163%.com/shelf%.do")
Assert.eq(CookieOf(pending[1]), "NTES=fixture")
Assert.eq(pending[1].opts.cache_ttl, 0, "增删后必须拉新鲜书架，不能拿旧缓存对账")
pending[1].cb(page(row("first_4", "第一本"), 2))
Assert.len(pending, 2)
Assert.eq(calls, 0, "没拉完所有页不能对账")
pending[2].cb(page(row("first_4", "重复") .. row("second_4", "第二本")))
Assert.len(result, 2)
Assert.is_nil(failure)
Assert.eq(calls, 1)

Client:shelfSyncAsync(done)
pending[#pending].cb(page(row("first_4", "第一本"), 2))
pending[#pending].cb(nil, "network down")
Assert.is_nil(result, "后一页失败不能把第一页当完整书架")
Assert.eq(failure, "network down")
local handle = Client:shelfSyncAsync(done)
local before = calls
handle:cancel()
pending[#pending].cb(page(row("first_4", "第一本"), 2))
Assert.eq(calls, before)
Assert.eq(cancelled, 1)

local reconciled, deleted, added, marked = {}, { "deleted_4" }, { "added_4" }, {}
package.loaded["book.books_db"] = {
    pendingDeleteIds = function() return deleted end,
    pendingShelfAddIds = function() return added end,
    remove = function(id, stable_id)
        Assert.eq(id, "netease")
        Assert.eq(stable_id, "deleted_4")
        deleted = {}
        return true
    end,
    markSynced = function(_id, stable_id)
        marked[#marked + 1] = stable_id
        added = {}
        return true
    end,
    reconcile = function(id, values, options)
        reconciled = { id = id, books = values, force = options.force }
        return true, 0
    end,
}
package.loaded["source.shelf"] = nil
local posts = {}
package.loaded["http.request"].post = function(url, body, options, cb)
    posts[#posts + 1] = { url = url, body = body, opts = options, cb = cb }
    return { cancel = function() cancelled = cancelled + 1 end }
end
local source = require("source.netease").new()
before = #pending
source:syncBooksAsync({ force = true }, done)
Assert.eq(#pending, before, "先推删除，再拉书架")
Assert.len(deleted, 1, "远端确认前不能撕墓碑")
posts[1].cb(JSON.encode({ resultCode = 0 }))
Assert.len(deleted, 0)
pending[#pending].cb(page(row("first_4", "第一本")))
Assert.len(posts, 2, "拉完书架后推本地独有成员")
Assert.matches(posts[2].body, "id=added_4")
posts[2].cb(JSON.encode({ resultCode = 0 }))
pending[#pending].cb(page(row("first_4", "第一本") .. row("added_4", "新增")))
Assert.eq(reconciled.id, "netease")
Assert.is_true(reconciled.force)
Assert.eq(result.pulled, 2)
Assert.eq(result.pushed, 2)
Assert.eq(marked[1], "added_4")
Assert.is_true(source:capabilities().shelf_push)
before = #pending
added = { "retry_4" }
source:syncBooksAsync({ dirty_only = true }, done)
require("support.stubs").flush()
posts[#posts].cb(JSON.encode({ resultCode = 0 }))
Assert.eq(marked[2], "retry_4")
Assert.eq(result.pushed, 1)
Assert.len(pending, before, "推脏行只上传增删，不拉书架")

deleted, added = { "deleted_4" }, { "added_4" }
before = #marked
source:syncBooksAsync({ dirty_only = true }, done)
posts[#posts].cb(JSON.encode({ resultCode = -1 }))
posts[#posts].cb("")
Assert.len(deleted, 1, "移出失败保留墓碑")
Assert.len(added, 1, "加入失败保留脏行")
Assert.len(marked, before)
Assert.eq(result.pushed, 0)
source:syncBooksAsync({ dirty_only = true }, done)
posts[#posts].cb(JSON.encode({ resultCode = 0 }))
posts[#posts].cb(JSON.encode({ resultCode = 0 }))
Assert.len(deleted, 0)
Assert.len(added, 0)
Assert.eq(result.pushed, 2, "失败后下轮重试增删")

added = { "cancel_4" }
before = cancelled
handle = source:syncBooksAsync({ dirty_only = true }, done)
require("support.stubs").flush()
handle:cancel()
Assert.eq(cancelled, before + 1, "取消同步应取消正在加入书架的请求")
Assert.len(added, 1)

package.loaded["ui/network/manager"] = { isConnected = function() return false end }
package.loaded["book.store"] = {
    markDeleted = function(id, stable_id)
        Assert.eq(id, "netease")
        Assert.eq(stable_id, "deleted_4")
        deleted = { stable_id }
        return true
    end,
}
before = #posts
source:deleteBookAsync({ source_id = "netease", stable_id = "deleted_4" }, done)
require("support.stubs").flush()
Assert.is_true(result)
Assert.len(deleted, 1, "离线删除立即隐藏，墓碑等联网后再推")
Assert.len(posts, before, "删除入口不直接发网络请求")
