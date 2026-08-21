--[[--
WebDAV entry → Book

@module koplugin.book.source.webdav.mapper
--]]

local BookListResult = require("types.book_list")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "webdav"

local BOOK_EXT = {
    epub = true,
    pdf = true,
    cbz = true,
    cbr = true,
    mobi = true,
    azw3 = true,
    txt = true,
}

--- 按扩展名判断是否为可打开的书籍文件。
---@param name string|nil
---@return boolean
local function isBookFile(name)
    if type(name) ~= "string" then
        return false
    end
    local ext = name:match("%.([^.]+)$")
    if not ext then
        return false
    end
    return BOOK_EXT[string.lower(ext)] == true
end

--- 规范化路径：去首尾斜杠。
---@param path string|nil
---@return string
local normalizePath = Text.trimSlashes

--- WebDAV 目录项 → BookListResult。
---@param entries table[]
---@param base_path string|nil
---@return BookListResult
function Mapper.list(entries, base_path)
    local books = {}
    base_path = normalizePath(base_path)
    for _, e in ipairs(entries or {}) do
        if not e.is_dir and isBookFile(e.name or e.path) then
            local path = normalizePath(e.path or e.href or e.name)
            if path ~= "" then
                local title = e.name or path:match("([^/]+)$") or path
                local parent = path:match("^(.*)/[^/]+$") or ""
                local category, series = parent:match("^([^/]+)/?([^/]*)")
                if series == "" then series = nil end
                books[#books + 1] = {
                    source_id = SOURCE_ID, stable_id = path,
                    title = title,
                    authors = nil,
                    percent = 0,
                    category = category,
                    series = series,
                }
            end
        end
    end
    return BookListResult.new(books)
end

--- 由 BookIdentity 构造最小详情。
---@param identity BookIdentity
---@return BookDetail
function Mapper.detailFromIdentity(identity)
    local title = identity.stable_id:match("([^/]+)$") or identity.stable_id
    return {
        source_id = identity.source_id, stable_id = identity.stable_id,
        title = title,
        percent = 0,
    }
end

return Mapper
