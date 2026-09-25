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

function FanQie.make_shelf_params()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    }
end

function FanQie.shelf_url()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/"
end

function FanQie.progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/progress"
end

function FanQie.update_progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/update_progress"
end

---@param book_id string
---@return string
function FanQie.book_info_url(book_id)
    return FanQie.BASE_URL .. "/api/book/info?bookId=" .. Text.urlEncode(tostring(book_id))
end

---@param book_id string
---@return string
function FanQie.directory_url(book_id)
    return FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. Text.urlEncode(book_id)
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
