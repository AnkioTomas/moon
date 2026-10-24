--[[--
起点正文流程：cES=2 先下字体再解密，cES=0/fEnS=0 直接出文本。

@module tests.source.qidian_content_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")
local Text = require("utils.text")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local cfg = { cookie = "ywguid=123; ywkey=k" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local replies = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            local reply = table.remove(replies, 1)
            cb(reply and reply.body, reply and reply.err, reply and reply.res)
            return { cancel = function() end }
        end,
    }
end

local FONT_BYTES = "\0\1\0\0FONTBYTES"
local fock_calls = {}
package.preload["source.qidian.fock"] = function()
    return {
        chapterAsync = function(info, font, chapter_id, keypool, version, uid, cb)
            fock_calls[#fock_calls + 1] = {
                kind = "chapter", font = font, chapter_id = chapter_id,
                keypool = keypool, version = version, uid = uid,
            }
            cb("RESTORED")
            return { cancel = function() end }
        end,
        restoreAsync = function(html, info, font, cb)
            fock_calls[#fock_calls + 1] = { kind = "restore", font = font, html = html }
            cb("RESTORED")
            return { cancel = function() end }
        end,
        decryptAsync = function(content, chapter_id, keypool, version, uid, cb)
            fock_calls[#fock_calls + 1] = { kind = "decrypt", uid = uid }
            cb("<p>甲</p>")
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.qidian.client"] = nil
package.loaded["source.qidian.mapper"] = nil
local Client = require("source.qidian.client")

local function page(info)
    return '<script id="vite-plugin-ssr_pageContext" type="application/json">'
        .. JSONStub.encode({ pageContext = { pageProps = { pageData = { chapterInfo = info } } } }) .. "</script>"
end

local function fkp()
    return Text.base64Encode('window.onkeyfocus("KEYPOOL", 1635757421)')
end

local function info(extra)
    local out = {
        chapterName = "第一章", chapterId = 9, vipStatus = 1, isBuy = 1,
        content = "CIPHER", fkp = fkp(), cES = 0, fEnS = 0,
    }
    for k, v in pairs(extra or {}) do out[k] = v end
    return out
end

do
    -- 免费 / 普通章：不走 Fock，也不下字体。
    replies = { { body = page(info({ content = "<p>甲</p>" })) } }
    fock_calls = {}
    local text
    Client.contentAsync("1", "2", function(v) text = v end)
    Assert.eq(text, "\n甲\n")
    Assert.len(fock_calls, 0)
end

do
    -- Fock + cES=2：先拉 fixedFontTtf，再把字节交给解密 + 字体还原。
    replies = {
        { body = page(info({ fEnS = 1, cES = 2, fixedFontTtf = "https://font/fixed.ttf", randomFont = "{}", css = "" })) },
        { body = FONT_BYTES },
    }
    fock_calls = {}
    local text
    Client.contentAsync("1", "2", function(v) text = v end)
    Assert.eq(text, "RESTORED")
    Assert.len(fock_calls, 1)
    Assert.eq(fock_calls[1].kind, "chapter")
    Assert.eq(fock_calls[1].font, FONT_BYTES)
    Assert.eq(fock_calls[1].uid, "123")
    Assert.eq(fock_calls[1].keypool, "KEYPOOL")
    Assert.eq(fock_calls[1].version, "1635757421")
end

do
    -- 只有字体层（fEnS=0）：直接还原 HTML，不做 Fock。
    replies = {
        { body = page(info({ fEnS = 0, cES = 2, fixedFontTtf = "https://font/fixed.ttf", randomFont = "{}", css = "" })) },
        { body = FONT_BYTES },
    }
    fock_calls = {}
    local text
    Client.contentAsync("1", "2", function(v) text = v end)
    Assert.eq(text, "RESTORED")
    Assert.len(fock_calls, 1)
    Assert.eq(fock_calls[1].kind, "restore")
    Assert.eq(fock_calls[1].font, FONT_BYTES)
end

do
    -- 未识别的 cES 明确报错，不能把密文当正文。
    replies = { { body = page(info({ fEnS = 0, cES = 1 })) } }
    fock_calls = {}
    local text, err
    Client.contentAsync("1", "2", function(v, e) text, err = v, e end)
    Assert.is_nil(text)
    Assert.is_true(err ~= nil and err:find("不受支持", 1, true) ~= nil)
    Assert.len(fock_calls, 0)
end

do
    -- CDN 返回 HTML 错误页而不是字体：按下载失败处理。
    replies = {
        { body = page(info({ fEnS = 1, cES = 2, fixedFontTtf = "https://font/fixed.ttf", randomFont = "{}", css = "" })) },
        { body = "<html>403</html>" },
    }
    fock_calls = {}
    local text, err
    Client.contentAsync("1", "2", function(v, e) text, err = v, e end)
    Assert.is_nil(text)
    Assert.is_true(err ~= nil and err:find("字体下载失败", 1, true) ~= nil)
    Assert.len(fock_calls, 0)
end

do
    -- cES=2 但没有字体地址：明确报错，不把错字当正文。
    replies = { { body = page(info({ fEnS = 1, cES = 2, randomFont = "{}", css = "" })) } }
    fock_calls = {}
    local text, err
    Client.contentAsync("1", "2", function(v, e) text, err = v, e end)
    Assert.is_nil(text)
    Assert.is_true(err ~= nil and err:find("字体", 1, true) ~= nil)
    Assert.len(fock_calls, 0)
end
