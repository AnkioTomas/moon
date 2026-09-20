--[[--
番茄 mobileCover / book_info URL。

@module tests.source.fanqie.fanqie_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.fanqie"] = nil
local FanQie = require("source.fanqie.fanqie")

Assert.eq(
    FanQie.mobileCover("novel-pic/p2oa5f36f6d2d249b593383bcfb0000f9eb"),
    "https://p6-novel.byteimg.com/novel-pic/p2oa5f36f6d2d249b593383bcfb0000f9eb~tplv-shrink:320:0.image")

Assert.eq(
    FanQie.mobileCover(
        "https://p9-novel-sign.byteimg.com/novel-pic/p2oa5f36f6d2d249b593383bcfb0000f9eb~tplv-resize:225:300.image?x-expires=1&x-signature=x"),
    "https://p6-novel.byteimg.com/novel-pic/p2oa5f36f6d2d249b593383bcfb0000f9eb~tplv-shrink:320:0.image")

Assert.is_nil(FanQie.mobileCover(nil))
Assert.is_nil(FanQie.mobileCover(""))

Assert.matches(FanQie.book_info_url("7342475219212192830"), "/api/book/info%?bookId=7342475219212192830")
