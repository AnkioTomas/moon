--[[--
OPML 订阅导入。

@module koplugin.book.source.rss.opml
--]]

local DataStorage = require("datastorage")
local Text = require("utils.text")

local OPML = {
    DEFAULT_IMPORT_PATH = DataStorage:getDataDir() .. "/feeds.opml",
}

local function attr(tag, name)
    local lower = string.lower(tag)
    local start_pos, end_pos = lower:find(string.lower(name) .. "%s*=%s*")
    if not start_pos then return nil end
    local rest = tag:sub(end_pos + 1)
    local quote = rest:match("^%s*([\"'])")
    if not quote then return nil end
    return Text.xmlDecode(rest:match("^%s*[\"'](.-)" .. quote) or "")
end

---@param content string
---@return table[]|nil
function OPML.parse(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end
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

---@param path string|nil
---@return table[]|nil, string|nil
function OPML.read(path)
    path = path or OPML.DEFAULT_IMPORT_PATH
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return OPML.parse(content), nil
end

return OPML
