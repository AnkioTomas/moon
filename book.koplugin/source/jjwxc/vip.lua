--[[--
晋江 VIP 章网页（m.jjwxc.com/vip/<书>/<章>）正文解密。页面里正文是 #contentvars 的隐藏域，
由官方 jjcontent.js 在浏览器里解开。现行脚本（jsver 不是 20220527 就自己报错）：

1. s1 = md5("<novelid>.<chapterid>.<readerid>.<accessKey>") 的十六进制。按 accessKey 码点和
   对 32 取余左旋，前 16 / 后 16 字符对调后各取 8 字节，DES-CBC 解 cryptInfo 得 JSON{time,key}；
2. s2 = md5(key .. time .. readerid)，同样左旋（仍用 accessKey 的码点和），前 16 / 后 16 直接做
   AES-128-CBC 解 content，这次不对调。

这套解不开再退回旧页面：偶数章 AES 穷举窗口；奇数章（书号 + 章号）用
md5("<accessKey>-<novelid>-<chapterid>-<readerid>") 左旋 33。正文仍是 AES。
结果是 HTML 片段，多数经 encodeURIComponent，也有直接 UTF-8：`<br>` 分段。

@module koplugin.book.source.jjwxc.vip
--]]

local Aes = require("crypto.aes")
local Des = require("crypto.des")
local Text = require("utils.text")
local md5 = require("ffi/sha2").md5

local Vip = {}

local function field(html, name)
    return html:match('name="' .. name .. '"[^>]-value="([^"]*)"')
        or html:match('value="([^"]*)"[^>]-name="' .. name .. '"')
end

--- 明文形状：encodeURIComponent 串，或含中文的合法 UTF-8 文本（有的页面不再编码；纯 ASCII 非 URL 串多半是错 iv 解出来的）。
--- @param text string
--- @param inner boolean|nil 为真时首尾可能切在多字节字符中间
local function looksText(text, inner)
    if text:find("^[%w%%%-_.!~*'()]+$") then return true end
    if not text:find("[\128-\255]") then return false end
    local i, n = 1, #text
    if inner then
        while i <= n and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i + 1 end
    end
    while i <= n do
        local c = text:byte(i)
        local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3
            or (c >= 0xF0 and c < 0xF5) and 4 or 0
        if len == 0 or (c < 0x20 and c ~= 9 and c ~= 10 and c ~= 13) or c == 0x7F then return false end
        if i + len - 1 > n then return inner or false end
        for j = i + 1, i + len - 1 do
            local b = text:byte(j)
            if b < 0x80 or b >= 0xC0 then return false end
        end
        i = i + len
    end
    return true
end

--- @param html string
--- @return string|nil 解出的 HTML 片段；不是加密正文页或解不开返回 nil
--- @return string|nil 失败阶段（写日志用，不含密钥）
function Vip.content(html)
    local vars = html:match('id="contentvars"(.-)</div>')
    if not vars then return nil, "no contentvars" end
    local novel, chapter, reader = field(vars, "novelid"), field(vars, "chapterid"), field(vars, "readerid")
    local access, info, content = field(vars, "accessKey"), field(vars, "cryptInfo"), field(vars, "content")
    if not (novel and chapter and reader and access and info and content) then
        return nil, ("missing fields novel=%s chapter=%s reader=%s access=%s info=%s content=%s"):format(
            tostring(novel ~= nil), tostring(chapter ~= nil), tostring(reader ~= nil), tostring(access ~= nil),
            tostring(info ~= nil), tostring(content ~= nil))
    end

    local function charSum(text)
        local n = 0
        for i = 1, #text do n = n + text:byte(i) end
        return n
    end
    local function finish(text)
        if text:find("^[%w%%%-_.!~*'()]+$") then return Text.urlDecode(text) end
        return text
    end

    --- 现行脚本。cryptInfo 是 DES 解出的 JSON，不是旧页面那种再套一层 base64。
    local function decryptCurrent()
        local function turn(source)
            local hex = md5(source)
            local off = charSum(access) % #hex
            if off ~= 0 then hex = hex:sub(off + 1) .. hex:sub(1, off) end
            return hex
        end
        local spun = turn(novel .. "." .. chapter .. "." .. reader .. "." .. access)
        local meta = Des.decryptBase64(info, spun:sub(-16, -9), spun:sub(1, 8))
        local key, time = meta and meta:match('"key":"([^"]*)"'), meta and meta:match('"time":(%d+)')
        if not (key and time) then return nil end
        spun = turn(key .. time .. reader)
        local ok, text = pcall(Aes.cbc_decrypt, Text.base64Decode(content), spun:sub(1, 16), spun:sub(-16))
        if ok and looksText(text) then return finish(text) end
    end
    local current = decryptCurrent()
    if current then return current end

    --- 奇数章（书号 + 章号）的旧 cryptInfo 密钥。对不上时再走偶数那套搜索。
    local function decryptOdd(data, access_key)
        local digest = md5(access_key .. "-" .. novel .. "-" .. chapter .. "-" .. reader)
        local shift = charSum(access_key) % 33
        if shift ~= 0 then digest = digest:sub(shift + 1) .. digest:sub(1, shift) end
        local ok, plain = pcall(Aes.cbc_decrypt, data, digest:sub(-16), digest:sub(1, 16))
        if ok and plain:find("^[%w+/=]+$") then return plain end
    end

    --- 在摘要的 32 个偏移里找出让密文解成 `shape` 的 key 和 iv，返回去填充后的明文。
    local function decrypt(data, source, shape)
        local digest = md5(source)
        digest = digest .. digest
        local function window(from) return digest:sub(from + 1, from + 16) end
        local probe_len = math.min(#data - 16, 48)
        for key_off = 0, 31 do
            local key = window(key_off)
            local probe = Aes.cbc_decrypt(data:sub(17, 16 + probe_len), key, data:sub(1, 16), false)
            if shape(probe, true) then
                for iv_off = 0, 31 do
                    if shape(Aes.cbc_decrypt(data:sub(1, 16), key, window(iv_off), false), true) then
                        local ok, plain = pcall(Aes.cbc_decrypt, data, key, window(iv_off))
                        if ok then return plain end
                    end
                end
            end
        end
    end

    local info_raw = Text.base64Decode(info)
    local novel_n, chapter_n = tonumber(novel), tonumber(chapter)
    local meta = novel_n and chapter_n and (novel_n + chapter_n) % 2 == 1
        and decryptOdd(info_raw, access) or nil
    if not meta then
        meta = decrypt(info_raw, novel .. "." .. chapter .. "." .. reader .. "." .. access,
            function(text) return text:find("^[%w+/=]+$") end)
    end
    if not meta then return nil, "cryptInfo undecryptable, info_len=" .. #info end
    local params = Text.base64Decode(meta)
    local key, time = params:match('"key":"([^"]*)"'), params:match('"time":(%d+)')
    local ver = params:match('"ver":"([^"]*)"')
    if not (key and time) then return nil, "meta without key/time, ver=" .. tostring(ver) end
    local text = decrypt(Text.base64Decode(content), key .. time .. reader, looksText)
    if not text then return nil, "content undecryptable, ver=" .. tostring(ver) .. " content_len=" .. #content end
    return finish(text)
end

return Vip
