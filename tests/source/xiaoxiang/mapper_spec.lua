--[[--
潇湘新站结构、长整数身份及旧目录兼容。

@module tests.source.xiaoxiang.mapper_spec
--]]

local A = require("support.assert")
package.loaded["json"] = require("support.json_stub")
local M = require("source.xiaoxiang.mapper")

---@type {cbId: string, ccid: string, ratio: number, exp: number, text: string}|nil
local decoded = M.decode('{"cbId" : 27760376302677004, "ccid":35554414603847008,"ratio":1.5,"exp":12345678901234567e2,'
    .. '"text":"{\\"cbId\\":27760376302677004}"}')
A.eq(decoded.cbId, "27760376302677004")
A.eq(decoded.ccid, "35554414603847008")
A.eq(decoded.ratio, 1.5)
A.eq(decoded.exp, 12345678901234567e2)
A.eq(decoded.text, '{"cbId":27760376302677004}')
A.is_nil(M.decode("not JSON"))

local function page(data)
    return '<script id="vite-plugin-ssr_pageContext" type="application/json">'
        .. '{"pageContext":{"pageProps":{"pageData":' .. data .. '}}}</script>'
end
local book = M.detail(page('{"detailData":{"cbid":"27760376302677004","title":" 灯花笑 ","author":"千山茶客",'
    .. '"intro":"简介","categoryShortName":"古代言情","totalWords":1200}}'))
A.eq(book.stable_id, "27760376302677004")
A.eq(book.title, "灯花笑")
A.eq(book.category, "古代言情")
A.eq(book.words, 1200)
A.is_nil(M.detail("<html>维护</html>"))
A.is_nil(M.books({ { title = "缺身份" } }))
A.len(M.books({}), 0)
local books = M.books({ { cbId = "123", bookName = "书", authorName = "作者", cate2Name = "分类" } })
A.eq(books[1].authors, "作者")

local toc = M.toc(page('{"chapters":[{"type":0,"title":"正文卷"},'
    .. '{"type":1,"ccid":35554414603847008,"title":"第1章","price":0},'
    .. '{"type":1,"ccid":"35554414603847009","title":"第2章","price":25}]}'))
A.len(toc, 2)
A.eq(toc[1].uid, "35554414603847008")
A.eq(toc[2].idx, 2)
A.is_nil(toc[1].vip)
A.is_true(toc[2].vip)
A.eq(toc[1].toc_version, 1)
A.is_nil(M.toc(page('{"chapters":[{"type":1,"title":"缺身份"}]}')))
local legacy = M.toc('x"chapters":[{"type":0},{"type":1,"ccid":"42","title":"旧章","price":0}]')
A.eq(legacy[1].uid, "42")
A.len(M.toc(page('{"chapters":[]}')), 0)
local ranks = page('[{"columnInfo":{"name":"潇湘票榜"},"bookList":[]},'
    .. '{"columnInfo":{"name":"收藏榜"},"bookList":[{"cbid":"123","title":"收藏书"}]}]')
A.len(M.rank(ranks, "潇湘票榜"), 0, "真实空榜单与坏页面分别处理")
A.eq(M.rank(ranks, "收藏榜")[1].title, "收藏书")
A.is_nil(M.rank(ranks, "不存在的榜单"))
