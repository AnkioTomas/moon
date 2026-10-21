--[[--
晋江 VIP 章网页（m.jjwxc.com/vip/<书>/<章>）正文解密。页面里正文是 #contentvars 的隐藏域，
由官方 jjcontent 脚本在浏览器里解开；这里按脚本流程还原（jsver 20250926）：

1. s1 = md5("<novelid>.<chapterid>.<readerid>.<accessKey>")，AES-128-CBC 解 cryptInfo 得 base64(JSON{time,key})；
2. s2 = md5(key .. time .. readerid)，同样解 content；
   key / iv 都是摘要重复两遍（64 字符）里某个偏移起的 16 个字符；脚本里的偏移规则随请求变（只看到过
   「accessKey 码点和 % 16」「+16」「key / iv 互换」等不同取法），所以不推规则，直接按解出内容的形状找：
   CBC 第二块只依赖 key 和第一块密文，先逐偏移找 key，再逐偏移找 iv；
3. 结果是 HTML 片段，多数页面经 encodeURIComponent，也有直接 UTF-8 的：`<br>` 分段，反爬字符写成 `&#xXXXX`（常缺分号）后跟 `&zwnj;`。

脚本版本变了（jsver 不是 20250926）解不出来时返回 nil，调用方报错。

@module koplugin.book.source.jjwxc.vip
--]]

local Aes = require("crypto.aes")
local Md5 = require("crypto.md5")
local Text = require("utils.text")

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
function Vip.content(html)
    local vars = html:match('id="contentvars"(.-)</div>')
    if not vars then return nil end
    local novel, chapter, reader = field(vars, "novelid"), field(vars, "chapterid"), field(vars, "readerid")
    local access, info, content = field(vars, "accessKey"), field(vars, "cryptInfo"), field(vars, "content")
    if not (novel and chapter and reader and access and info and content) then return nil end

    --- 在摘要的 32 个偏移里找出让密文解成 `shape` 的 key 和 iv，返回去填充后的明文。
    local function decrypt(data, source, shape)
        local digest = Md5.hex(source)
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

    local meta = decrypt(Text.base64Decode(info), novel .. "." .. chapter .. "." .. reader .. "." .. access,
        function(text) return text:find("^[%w+/=]+$") end)
    if not meta then return nil end
    local params = Text.base64Decode(meta)
    local key, time = params:match('"key":"([^"]*)"'), params:match('"time":(%d+)')
    if not (key and time) then return nil end
    local text = decrypt(Text.base64Decode(content), key .. time .. reader, looksText)
    if not text then return nil end
    if text:find("^[%w%%%-_.!~*'()]+$") then return Text.urlDecode(text) end
    return text
end

return Vip
