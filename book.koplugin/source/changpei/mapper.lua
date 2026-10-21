--[[--
长佩文学网数据映射（纯函数）：网页 JSON 接口 → 领域对象。

@module koplugin.book.source.changpei.mapper
--]]

local Aes = require("crypto.aes")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "changpei"

-- 网页端正文 AES-128-CBC 的固定密钥与 IV（出自官网 h5 脚本）。
local KEY = "u0LRrbu$Enm84koA"
local IV = "$h$b3!iGzsYnnshj"

--- 封面链接的 ?x-oss-process 只是缩略样式，去掉就是原图。
---@param url string|nil
---@return string|nil
local function cover(url)
    if type(url) ~= "string" or url == "" or url:find("nocover", 1, true) then return nil end
    return (url:gsub("%?.*$", ""))
end

---@param wire table
---@return Book[]
function Mapper.search(wire)
    local out = {}
    local list = type(wire.data) == "table" and wire.data.list or {}
    for _idx, row in ipairs(list) do
        if row.novel_id then
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = tostring(row.novel_id),
                title = Text.trim(row.novel_name),
                authors = Text.trim(row.novel_author),
                category = row.novel_type ~= "" and row.novel_type or nil,
                intro = Text.trim(row.novel_desc or ""),
                cover = cover(row.novel_cover),
                meta = { words = tonumber(row.novel_wordnumber) },
            }
        end
    end
    return out
end

--- 目录缓存格式版本。
Mapper.TOC_VERSION = 1

--- chapterGetList → 目录。只收 type = "item"（还有分页占位 "more"）；price > 0 的是 VIP 章。
---@param wire table
---@return BookChapter[]
function Mapper.toc(wire)
    local toc = {}
    local list = type(wire.data) == "table" and wire.data.list or {}
    for _idx, row in ipairs(list) do
        if row.type == "item" then
            toc[#toc + 1] = {
                idx = #toc + 1,
                uid = tostring(row.id),
                title = row.name,
                vip = (tonumber(row.price) or 0) > 0 or nil,
            }
        end
    end
    if toc[1] then toc[1].toc_version = Mapper.TOC_VERSION end
    return toc
end

--- chapterGetInfo → 正文纯文本；没买的 VIP 章返回 nil, "unpaid"；服务端要求人机验证（data.check > 1）时
--- 正文被换字打乱，返回 nil, "verify"。
---@param wire table
---@return string|nil text
---@return string|nil err
---@return "unpaid"|"verify"|nil kind
function Mapper.content(wire)
    local info = type(wire.data) == "table" and wire.data.chapterInfo
    if type(info) ~= "table" then return nil, wire.msg end
    if (tonumber(wire.data.check) or 0) > 1 then return nil, nil, "verify" end
    local locked = (tonumber(info.chapterPrice) or 0) > 0 and not info.isSub
    if type(info.content) ~= "string" or info.content == "" then
        if locked then return nil, nil, "unpaid" end
        return nil, wire.msg
    end
    local plain = Aes.cbc_decrypt(Text.base64Decode(info.content), KEY, IV)
    if not plain then return nil, nil, locked and "unpaid" or nil end
    local lines = {}
    for line in (plain .. "\n"):gmatch("(.-)\r?\n") do
        line = Text.trim(line)
        if line ~= "" then lines[#lines + 1] = line end
    end
    if #lines == 0 then return nil, nil, locked and "unpaid" or nil end
    return table.concat(lines, "\n")
end

return Mapper
