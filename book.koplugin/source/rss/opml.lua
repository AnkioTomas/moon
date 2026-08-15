--[[--
OPML 订阅导入。

@module koplugin.book.source.rss.opml
--]]

local DataStorage = require("datastorage")

local OPML = {
    DEFAULT_IMPORT_PATH = DataStorage:getDataDir() .. "/feeds.opml",
}

local function decode(s)
    return tostring(s or ""):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

local function attr(tag, name)
    local lower = string.lower(tag)
    local start_pos, end_pos = lower:find(string.lower(name) .. "%s*=%s*")
    if not start_pos then return nil end
    local rest = tag:sub(end_pos + 1)
    local quote = rest:match("^%s*([\"'])")
    if not quote then return nil end
    return decode(rest:match("^%s*[\"'](.-)" .. quote) or "")
end

---@param path string|nil
---@return table[]|nil, string|nil
function OPML.read(path)
    path = path or OPML.DEFAULT_IMPORT_PATH
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    local feeds = {}
    for tag in content:gmatch("<[oO][uU][tT][lL][iI][nN][eE]%s+([^>]*)>") do
        local url = attr(tag, "xmlurl")
        if url and url ~= "" then
            feeds[#feeds + 1] = {
                url = url,
                title = attr(tag, "text") or attr(tag, "title"),
            }
        end
    end
    return feeds
end

return OPML
