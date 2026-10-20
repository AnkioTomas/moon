--[[--
番茄网页榜单解析离线用例：内嵌状态（含裸 undefined）、PUA 书名解码、封面。

@module tests.source.fanqie.rank_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end
package.loaded["source.fanqie.rank"] = nil
local Rank = require("source.fanqie.rank")

local html = '<script>(function(){window.__INITIAL_STATE__={"rank":{"book_list":[{"bookId":"7654593151348247614",'
    .. '"bookName":"\u{E4C2}\u{E3E9}诡异","author":"糕","abstract":"\u{E3E9}简介","pos_category_id":undefined,'
    .. '"thumbUri":"https://p3-reading-sign.fqnovelpic.com/novel-pic/abc~tplv-resize:225:0.image?x=1"}],'
    .. '"rankCategoryTypeList":{"male":[{"id":"1141","name":"西方奇幻"}],"female":[]}}};\n})()\n</script><script>x</script>'

do
    local rank = Rank.state(html)
    Assert.eq(rank.rankCategoryTypeList.male[1].name, "西方奇幻")
    local books = Rank.books(rank, "fanqie")
    Assert.len(books, 1)
    Assert.eq(books[1].stable_id, "7654593151348247614")
    Assert.matches(books[1].title, "在诡异$")
    Assert.eq(books[1].intro, "在简介")
    Assert.matches(books[1].cover, "novel%-pic/abc")
    Assert.is_nil(Rank.state("<html>人机验证</html>"))
end
