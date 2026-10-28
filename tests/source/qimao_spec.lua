--[[--
七猫登录 token、书架分页 / 增删上行与映射离线用例。

@module tests.source.qimao_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local cfg = { token = "tk-1" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local expired
package.preload["source.auth"] = function()
    return { expire = function(_, msg) expired = msg; return msg end, ok = function() end }
end

local requests, replies = {}, {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { url = url, opts = opts }
            cb(table.remove(replies, 1))
            return { cancel = function() end }
        end,
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { url = url, body = body, opts = opts }
            cb(table.remove(replies, 1))
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.qimao.client"] = nil
package.loaded["source.qimao.mapper"] = nil
package.loaded["source.qimao.setting"] = nil
local Client = require("source.qimao.client")
local Mapper = require("source.qimao.mapper")
local Setting = require("source.qimao.setting")

-- 书架分页：按 meta.total_pages 翻完，请求带 Authorization。
do
    replies = {
        '{"data":{"books":[{"book_id":"1"}],"meta":{"total_pages":"2"}}}',
        '{"data":{"books":[{"book_id":"2"}],"meta":{"total_pages":"2"}}}',
    }
    local rows, err
    Client.shelfSyncAsync(function(v, e) rows, err = v, e end)
    Assert.is_nil(err)
    Assert.len(rows, 2)
    Assert.eq(rows[2].book_id, "2")
    Assert.len(requests, 2)
    Assert.eq(requests[1].opts.headers.Authorization, "tk-1")
    Assert.matches(requests[1].url, "api%-bs%.wtzw%.com/pcapi/v1/user/local$")
    Assert.matches(requests[2].body, "page=2")
end

-- 书库列表：分页字段决定是否还有下一页，书取书库行字段。
do
    requests, replies = {}, { '{"data":{"book_list":[{"book_id":"9","title":"甲","author":"乙","image_link":"http://c/x.jpg"}],'
        .. '"page_data":{"count":"31","page":"2","page_size":"15"}}}' }
    local wire
    Client.classifyAsync({ channel = "0", category1 = "202", category2 = "a", order = "click", page = 2 },
        function(v) wire = v end)
    Assert.matches(requests[1].url, "^https://www%.qimao%.com/api/classify/book%-list%?")
    Assert.matches(requests[1].url, "category1=202")
    local books, more = Mapper.classify(wire)
    Assert.eq(books[1].stable_id, "9")
    Assert.eq(books[1].authors, "乙")
    Assert.is_true(more)
    wire.data.page_data.page = "3"
    Assert.is_true(not select(2, Mapper.classify(wire)))
end

-- 登录态被拒：标失效；弹窗用人话，不原样塞服务端 title。
do
    requests, expired = {}, nil
    replies = { '{"errors":{"code":"40001002","title":"请先登录"}}' }
    local wire, err
    Client.shelfPushAsync({ { book_id = "1" } }, function(v, e) wire, err = v, e end)
    Assert.is_nil(wire)
    Assert.eq(err, "七猫登录已失效，请重新登录")
    Assert.eq(expired, "七猫登录已失效，请重新登录")
end

-- 没 token 不发请求。
do
    requests, cfg.token = {}, nil
    local queue = {}
    package.preload["ui/uimanager"] = function() return { nextTick = function(_, f) queue[#queue + 1] = f end } end
    package.loaded["source.base"] = nil
    package.loaded["ui.guard"] = nil
    package.preload["ui.guard"] = function() return { call = function(_, f, ...) return f(...) end } end
    local err
    Client.shelfPushAsync({}, function(_, e) err = e end)
    for _idx, f in ipairs(queue) do f() end
    Assert.eq(err, "未登录七猫")
    Assert.len(requests, 0)
    cfg.token = "tk-1"
end

-- 校验新 token 的失败不能把已有登录态标失效。
do
    expired = nil
    replies = { '{"errors":{"code":"40001002","title":"请先登录"}}' }
    local user, err
    Client.userInfoAsync("other-token", function(v, e) user, err = v, e end)
    Assert.is_nil(user)
    Assert.eq(err, "请先登录")
    Assert.is_nil(expired)
end

-- 映射：书架行用 book_*，封面补 CDN；上行条目只留 /bookimg/ 路径。
do
    local books = Mapper.shelfList({ { book_id = 7, book_title = "书", author = "作者", image_link = "/bookimg/a.jpg" } })
    Assert.eq(books[1].stable_id, "7")
    Assert.eq(books[1].title, "书")
    Assert.eq(books[1].cover, "https://cdn.wtzw.com/bookimg/a.jpg")
    local item = Mapper.shelfItem("7", books[1], "1")
    Assert.eq(item.image_link, "/bookimg/a.jpg")
    Assert.eq(item.push_type, "1")
    Assert.is_nil(Mapper.readChapter({ latest_read_chapter_id = "" }))
    local row = {
        book_id = "7", book_title = "书", group_name = "在读",
        latest_read_chapter_id = "19", latest_read_chapter_name = "第19章",
        page_offset = "12", paragraph_index = "3",
    }
    Assert.eq(Mapper.readChapter(row).uid, "19")
    local same = Mapper.progressItem(row, { uid = "19", title = "第19章", idx = 19 })
    Assert.eq(same.book_title, "书")
    Assert.eq(same.group_name, "在读")
    Assert.eq(same.page_offset, "12")
    Assert.eq(same.paragraph_index, "3")
    Assert.eq(same.push_type, "1")
    local moved = Mapper.progressItem(row, { uid = "20", title = "第20章", idx = 20 })
    Assert.eq(moved.latest_read_chapter_id, "20")
    Assert.eq(moved.latest_read_chapter_index, "20")
    Assert.eq(moved.page_offset, "")
    Assert.eq(moved.paragraph_index, "0")
    Assert.eq(moved.book_title, "书")
end

-- 登录输入：裸 token、Bearer 前缀、浏览器 userinfo JSON。
do
    Assert.eq(Setting.parseToken("  abc "), "abc")
    Assert.eq(Setting.parseToken("Bearer abc"), "abc")
    Assert.eq(Setting.parseToken('{"token":"xyz","is_vip":"0"}'), "xyz")
    Assert.eq(Setting.parseToken("{坏"), "")
end

-- 书城浏览：默认节点是「频道:分类:子分类:排序」四段；三段正则会让 cat2/order 为 nil 拼崩。
do
    local classify_q
    package.loaded["source.qimao.client"] = nil
    package.preload["source.qimao.client"] = function()
        return {
            classifyOptionsAsync = function(cb)
                cb({
                    data = {
                        filters = {
                            order = { { value = "click", label = "点击" }, { value = "a", label = "全部" } },
                            channel = { { value = "0", label = "男生" }, { value = "a", label = "全部" } },
                        },
                        category = {},
                    },
                })
                return { cancel = function() end }
            end,
            classifyAsync = function(q, cb)
                classify_q = q
                cb({ data = { book_list = {}, page_data = { page = "1", page_size = "15", count = "0" } } })
                return { cancel = function() end }
            end,
        }
    end
    package.loaded["source.browse"] = nil
    package.preload["source.browse"] = function()
        return {
            group = function(items, selected) return { items = items, selected = selected } end,
            pages = function(fetch, _limit, groups, cb)
                fetch(1, function(books, err, more)
                    cb({ data = books or {}, groups = groups, more = more }, err)
                end)
                return { cancel = function() end }
            end,
        }
    end
    package.loaded["source.qimao"] = nil
    package.loaded["source.qimao.init"] = nil
    local Source = require("source.qimao").new()
    local res, err
    Source:browseAsync({}, function(r, e) res, err = r, e end)
    Assert.is_nil(err)
    Assert.is_true(res ~= nil)
    Assert.eq(classify_q.channel, "0")
    Assert.eq(classify_q.category1, "a")
    Assert.eq(classify_q.category2, "a")
    Assert.eq(classify_q.order, "click")
    Assert.eq(res.groups[1].selected, "0:a:a:click")
end
