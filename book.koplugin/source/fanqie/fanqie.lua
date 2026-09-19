--[[--
番茄协议常量与 URL。

@module koplugin.book.source.fanqie.fanqie
--]]

local Text = require("utils.text")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"

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

function FanQie.bookshelf_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

function FanQie.progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/progress"
end

function FanQie.update_progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/update_progress"
end

---@param book_id string
---@return string
function FanQie.directory_url(book_id)
    return FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. Text.urlEncode(book_id)
end

return FanQie
