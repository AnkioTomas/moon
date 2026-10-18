--[[--
番茄漫画章节（book_type=1）：正文不是 HTML，而是 {"picInfos":[{"picUrl":…}],"encrypt":true,"encrypt_key":"<hex>"}；
每张图就是一页，CDN 给的是 AES-256-GCM 密文 [12B IV][密文][16B 标签]。

@module koplugin.book.source.fanqie.comic
--]]

local Aes = require("crypto.aes")
local Gcm = require("crypto.gcm")
local Text = require("utils.text")

local Comic = {}

--- 章节正文是漫画 JSON 则返回每页的 <img> XHTML 与解密密钥（未加密为 nil）；否则返回 nil。
---@param raw string
---@return string|nil html, string|nil key
function Comic.parse(raw)
    local s = raw:match("^%s*(.-)%s*$")
    if s:sub(1, 1) ~= "{" then return nil end
    local ok, data = pcall(require("json").decode, s)
    if not ok or type(data) ~= "table" or type(data.picInfos) ~= "table" then return nil end
    local pages = {}
    for _idx, pic in ipairs(data.picInfos) do
        if type(pic.picUrl) == "string" then
            pages[#pages + 1] = string.format('<div class="comic-page"><img src="%s" alt="" /></div>',
                Text.xmlEscape(pic.picUrl))
        end
    end
    if #pages == 0 then return nil end
    local key = data.encrypt == true and type(data.encrypt_key) == "string" and Aes.from_hex(data.encrypt_key) or nil
    return table.concat(pages, "\n"), key
end

---@param data string 下载到的页图
---@param key string|nil
---@return string|nil
function Comic.decrypt(data, key)
    if not key then return data end
    if #data <= 28 then return nil end
    return Gcm.ctr(key, data:sub(1, 12), data:sub(13, -17))
end

return Comic
