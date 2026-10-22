--[[--
source.wechat.package：App 章节包口令派生与 ZipCrypto 解包。 --]]

local Assert = require("support.assert")
local Package = require("source.wechat.package")

-- 抓包样本：vid 与响应头 encryptKey → 口令。
Assert.eq(Package.password("393727764", "LEyM8AVZMBvMt93WBCFCPw=="), "I1RVbke@p")
Assert.is_nil(Package.password("abc", "LEyM8AVZMBvMt93WBCFCPw=="))

-- zip -P 生成：a.txt 为 deflate、b.txt 为 stored，均带数据描述符。
local hex = "504b0304140009000800e5a2565df9129239220000000902000005001c00612e74787455540900032e00da6a2e00da6a75780b000104f50100000400000000905dd2c021a840192b344394132d37f6762d7d7cf1a02473b117f93084642c384d7f504b0708f91292392200000009020000504b03040a0009000000e5a2565d69111fb6120000000600000005001c00622e74787455540900032e00da6a2e00da6a75780b000104f50100000400000000dfd0647c7666697985230063aeed35d06c94504b070869111fb61200000006000000504b01021e03140009000800e5a2565df91292392200000009020000050018000000000001000000a48100000000612e74787455540500032e00da6a75780b000104f50100000400000000504b01021e030a0009000000e5a2565d69111fb61200000006000000050018000000000001000000a48171000000622e74787455540500032e00da6a75780b000104f50100000400000000504b0506000000000200020096000000d20000000000"
local zip = hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
local files = Package.unzip(zip, "I1RVbke@p")
Assert.eq(files["a.txt"], ("hello 月读 "):rep(40) .. "\n")
Assert.eq(files["b.txt"], "second")

local bad, err = Package.unzip(zip, "wrong")
Assert.is_nil(bad)
Assert.matches(err, "^zip:")
local none, err2 = Package.unzip(zip, nil)
Assert.is_nil(none)
Assert.matches(err2, "password required")

local info = "info"
package.loaded["json"] = {
    decode = function(raw)
        Assert.eq(raw, info)
        return { chapters = { { chapterUid = 27, files = { "Text/S.xhtml", "Text/S_1.xhtml", "Text/S_2.xhtml" } } } }
    end,
}
package.loaded["source.wechat.package"] = nil
local Composed = require("source.wechat.package")
local book = {
    ["info.txt"] = info,
    ["Text/S.xhtml"] = "<html><body><h1>T</h1></body></html>",
    ["Text/S_1.xhtml"] = "<html><body class=x><p>a</p></body></html>",
    ["Text/S_2.xhtml"] = "<html><body><p>b</p></body></html>",
}
Assert.eq(Composed.chapterHtml(book, 27), "<html><body><h1>T</h1><p>a</p><p>b</p></body></html>")
local miss, merr = Composed.chapterHtml(book, 99)
Assert.is_nil(miss)
Assert.matches(merr, "not in package")
