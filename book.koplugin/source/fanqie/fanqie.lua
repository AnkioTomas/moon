--[[--
番茄协议常量与 URL。

@module koplugin.book.source.fanqie.fanqie
--]]

local Text = require("utils.text")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"
-- 手机端封面 CDN：相对 thumb_uri 可长期访问；web 签名 thumb_url 会过期。
FanQie.MOBILE_COVER_CDN = "https://p6-novel.byteimg.com"

-- 免登录搜索：免签名、免 Cookie，只要 aid / offset / q；App UA 才不被拒。
FanQie.APP_UA = "com.dragon.read/6.5.3.32 (Linux; U; Android 13; zh_CN; VDE-AL10; Build/TP1A.220624.014;tt-ok/3.10.0.2)"

---@param keyword string
---@return string
function FanQie.searchUrl(keyword)
    return "https://novel.snssdk.com/api/novel/channel/homepage/search/search/v1/?aid=1967&offset=0&q="
        .. Text.urlEncode(keyword)
end

---@param action "add"|"delete"
---@return string
function FanQie.shelfActionUrl(action)
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/" .. action
        .. "/v:version?aid=1967&iid=0&version_code=57700&update_version_code=57700"
end

---@return string
function FanQie.bookshelf_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

---@param book_id string
---@return string
function FanQie.book_info_url(book_id)
    return FanQie.BASE_URL .. "/api/book/info?bookId=" .. Text.urlEncode(tostring(book_id))
end

--- 把 thumb_uri / 签名 URL 收成手机端稳定封面。
---@param thumb string|nil
---@return string|nil
function FanQie.mobileCover(thumb)
    if type(thumb) ~= "string" or thumb == "" then
        return nil
    end
    local path = thumb:match("(novel%-pic/[^~%?#]+)")
        or thumb:match("(novel%-static/[^~%?#]+)")
    if not path then
        if thumb:match("^https?://") then
            return thumb
        end
        path = thumb
    end
    return FanQie.MOBILE_COVER_CDN .. "/" .. path .. "~tplv-shrink:320:0.image"
end

return FanQie
