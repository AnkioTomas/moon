--[[--
长佩文学网数据映射（纯函数）：网页 JSON 接口 → 领域对象。

@module koplugin.book.source.changpei.mapper
--]]

local Aes = require("crypto.aes")
local Text = require("utils.text")
local _ = require("l10n").get("source.changpei")

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
            local process = tonumber(row.novel_process or row.process)
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = tostring(row.novel_id),
                title = Text.trim(row.novel_name),
                authors = Text.trim(row.novel_author),
                category = row.novel_type ~= "" and row.novel_type or nil,
                intro = Text.trim(row.novel_info or row.novel_desc or ""),
                cover = cover(row.novel_cover),
                meta = {
                    words = tonumber(row.novel_wordnumber),
                    status = process == 1 and "连载" or process == 2 and "完结" or nil,
                },
            }
        end

    end
    return out
end

---@param wire table
---@return Book|nil, string|nil
function Mapper.detail(wire)
    local row = wire.data
    if type(row) ~= "table" or not row.novel_id or type(row.novel_name) ~= "string" then
        return nil, _("响应无效")
    end
    local book = Mapper.search({ data = { list = { row } } })[1]
    book.authors = row.author_nickname
    book.category = type(row.type_names) == "table" and table.concat(row.type_names, " · ") or row.type_names
    return book
end

--- 网页 count 在有评论时也可能是 0，以实际页长判断是否还有下一页。
---@param wire table
---@param module string
---@param id string
---@param page integer
---@return table|nil, string|nil
function Mapper.comments(wire, module, id, page)
    local data = wire.data
    if type(data) ~= "table" or type(data.list) ~= "table" then return nil, _("响应无效") end
    local items = {}
    for _idx, row in ipairs(data.list) do
        if type(row) ~= "table" then return nil, _("响应无效") end
        local belongs = module == "chapter" and row.replay_module == "novel_chapter"
            and tostring(row.replay_cid) == tostring(id)
            or module == "novel" and (
                row.replay_module == "novel" and tostring(row.replay_cid) == tostring(id)
                or row.replay_module == "novel_chapter" and tostring(row.novel_id) == tostring(id))
        if not belongs or not row.replay_id or type(row.replay_content) ~= "string" then
            return nil, _("响应无效")
        end
        items[#items + 1] = {
            id = tostring(row.replay_id), author = row.replay_nickname or "",
            content = row.replay_content, text = row.replay_content, time = row.replay_time or "",
            reply_to = module == "novel" and row.replay_module == "novel_chapter" and row.novel_chapter_name or nil,
            replies = tonumber(row.child_comment_number) or 0,
        }
    end
    local count = tonumber(data.count)
    local total = math.max(count or 0, (page - 1) * 10 + #items)
    return { items = items, total = total, max_idx = page,
        more = #items == 10 and (not count or count == 0 or page * 10 < count) }
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
            if row.novel_id and cid and cid > 0 and not out[tostring(row.novel_id)] then
                out[tostring(row.novel_id)] = tostring(cid)
            end
        end
    end
    return out
end

--- 目录缓存格式版本。
Mapper.TOC_VERSION = 1

--- chapterGetList → 目录。只收 type = "item"（还有分页占位 "more"）；price > 0 的是 VIP 章。
---@param wire table
---@return BookChapter[]|nil, string|nil
function Mapper.toc(wire)
    local toc = {}
    local list = type(wire.data) == "table" and wire.data.list
    if type(list) ~= "table" then return nil, _("响应无效") end
    for _idx, row in ipairs(list) do
        if row.type == "item" then
            toc[#toc + 1] = {
                idx = #toc + 1,
                uid = tostring(row.id),
                title = row.name,
                vip = (tonumber(row.price) or 0) > 0 or nil,
                paid = (tonumber(row.price) or 0) > 0 and (row.is_sub == true or tonumber(row.is_sub) == 1
                    or tonumber(row.whole_book_is_bought) == 1 or tonumber(row.is_free_limit) == 1),
            }
        end
    end
    if toc[1] then toc[1].toc_version = Mapper.TOC_VERSION end
    return toc
end

--- chapterGetInfo → 正文纯文本；没买的 VIP 章返回 nil, "unpaid"。
--- data.check > 1 时不解密、不给正文，交给开章入口验证后重取。
---@param wire table
---@return string|nil text
---@return string|nil err
---@return "unpaid"|"verify"|nil kind
function Mapper.content(wire)
    local info = type(wire.data) == "table" and wire.data.chapterInfo
    if type(info) ~= "table" then return nil, wire.msg end
    local check = tonumber(wire.data.check) or 0
    if check > 1 then return nil, nil, "verify" end
    -- isSub 在接口里是 "0" / "1" 字符串（"0" 在 Lua 里是真值）
    local locked = (tonumber(info.chapterPrice) or 0) > 0 and not (info.isSub == true or tonumber(info.isSub) == 1)
    local text
    if type(info.content) == "string" and info.content ~= "" then
        local plain = Aes.cbc_decrypt(Text.base64Decode(info.content), KEY, IV)
        if plain and Text.isValidUtf8(plain) and not plain:find("[%z\1-\8\11\12\14-\31\127]") then
            local lines = {}
            for line in (plain .. "\n"):gmatch("(.-)\r?\n") do
                line = Text.trim(line)
                if line ~= "" then lines[#lines + 1] = line end
            end
            if #lines > 0 then text = table.concat(lines, "\n") end
        elseif not locked then
            return nil, _("长佩章节解密失败")
        end
    end
    if text then return text end
    if locked then return nil, nil, "unpaid" end
    if type(info.content) ~= "string" or info.content == "" then
        return nil, _("长佩章节内容为空")
    end
    return nil, _("长佩章节解密失败")
end

return Mapper
