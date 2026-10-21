--[[--
长佩文学网数据映射（纯函数）：网页 JSON 接口 → 领域对象。

@module koplugin.book.source.changpei.mapper
--]]

local Aes = require("crypto.aes")
local Text = require("utils.text")
local _ = require("gettext")

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

--- rankingNav → 榜单列表 { rid, name, types = { { value, name } } }；带 url 的是跳转活动页的入口、没有子榜的不收。
---@param wire table
---@return table[]
function Mapper.ranks(wire)
    local out = {}
    for _idx, row in ipairs(type(wire.data) == "table" and wire.data or {}) do
        if not row.url and type(row.type) == "table" and #row.type > 0 then
            out[#out + 1] = { rid = row.rank_id, name = row.name, types = row.type }
        end
    end
    return out
end

--- usercoll/getList 的书行 → 书架。
---@param rows table[]
---@return Book[]
function Mapper.shelfList(rows)
    local out = {}
    for _idx, row in ipairs(rows) do
        out[#out + 1] = {
            source_id = SOURCE_ID,
            stable_id = tostring(row.id),
            title = Text.trim(row.name),
            authors = Text.trim(row.author),
            cover = cover(row.cover),
        }
    end
    return out
end

--- getHistory（按日期分组的 list）→ novel_id → 最近读到的章 id。
---@param wire table
---@return table<string, string>
function Mapper.history(wire)
    local out = {}
    local groups = type(wire.data) == "table" and wire.data.list or {}
    for _idx, group in ipairs(groups) do
        for _row, row in ipairs(group.list or {}) do
            local cid = tonumber(row.latest_read_cid)
            if row.novel_id and cid and cid > 0 then out[tostring(row.novel_id)] = tostring(cid) end
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
    -- isSub 在接口里是 "0" / "1" 字符串（"0" 在 Lua 里是真值）
    local locked = (tonumber(info.chapterPrice) or 0) > 0 and not (info.isSub == true or tonumber(info.isSub) == 1)
    if type(info.content) ~= "string" or info.content == "" then
        if locked then return nil, nil, "unpaid" end
        return nil, _("长佩章节内容为空")
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
