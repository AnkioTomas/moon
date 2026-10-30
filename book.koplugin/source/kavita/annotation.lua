--[[--
Kavita 注解的线上形态与同一性：纯函数、无 IO，pull / push / delete 共用同一条口径。

Kavita 网页端把备注存成 Quill Delta JSON（`comment`）+ Quill HTML（`commentHtml`），
纯文本 `commentPlainText` 是**后端从 HTML 去标签**算出来的（块级标签不插分隔，有损）。
读回、写入、冲突判定三处必须共用这里的归一，否则同一段备注每轮都会被判「改过」→ 无限 update。

@module source.kavita.annotation
--]]

local JSON = require("json")
local Text = require("utils.text")

local Annotation = {}

--- 键分隔符用 US（0x1F）：Kavita 的路径与选中文本里不会出现，天然不可撞。
--- 导出是为了让源侧拼「同坐标」判定键时用同一个字符，不各写一份字面量。
Annotation.KEY_SEP = string.char(31)

--- 排版上不可见、但字节上会破坏比较的字符：ZWSP / ZWNJ / ZWJ / BOM / WORD JOINER。
local ZERO_WIDTH = { "\226\128\139", "\226\128\140", "\226\128\141", "\239\187\191", "\226\129\160" }

--- 写入前的归一：`\r\n` → `\n`、去掉尾部换行；纯空白在调用方判空。
---@param note string|nil
---@return string
local function normalizeNote(note)
    return (Text.normalizeNewlines(note):gsub("\n+$", ""))
end

--- 比较用归一：trim + 内部连续空白压成单空格 + 剔除零宽字符。
--- 只用于「是不是同一段备注」，不能拿它落库（会把用户的换行/缩进抹平）。
---@param s string|nil
---@return string
local function comparisonText(s)
    local text = tostring(s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for _idx, zw in ipairs(ZERO_WIDTH) do text = text:gsub(zw, "") end
    return (text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Delta → 纯文本：`ops[*].insert` 里的字符串拼接，embed（图片等）与 `attributes` 一律忽略。
--- 末尾换行是 Delta 文档的收尾，不是内容；拼完剥掉。
---@param data table
---@return string
local function deltaText(data)
    local ops = data.ops
    if type(ops) ~= "table" then return "" end
    local parts = {}
    for _idx, op in ipairs(ops) do
        if type(op) == "table" and type(op.insert) == "string" then
            parts[#parts + 1] = op.insert
        end
    end
    return (table.concat(parts):gsub("\n+$", ""))
end

--- HTML → 纯文本：块级边界（`</p>` / `</div>` / `<br>`）换行，其余标签丢弃，实体解码。
--- 不能直接用 Text.stripHtml：它会丢弃空行，而备注里的空行是内容。
---@param html string
---@return string
local function htmlText(html)
    local text = tostring(html or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    -- Quill 的空行是 `<p><br></p>`：先整个折成一个换行，否则 <br> 与 </p> 会各补一行。
    text = text:gsub("<p[^>]*>%s*<br%s*/?>%s*</p>", "\n")
    text = text:gsub("<br%s*/?>", "\n"):gsub("</p%s*>", "\n"):gsub("</div%s*>", "\n")
    text = text:gsub("<[^>]*>", "")
    -- Quill 把连续空格写成 &nbsp;，解出来是 NBSP，还原成普通空格才能与本地文本对上。
    text = Text.xmlDecode(text):gsub("\194\160", " ")
    return (text:gsub("\n+$", ""))
end

--- 读回归一。优先级：commentHtml → commentPlainText → comment 的 Delta → comment 原文（legacy 纯文本）。
--- 空值集合（"" / "{}" / {"ops":[]} / {"ops":[{"insert":"\n"}]} / null）一律 ""。
---@param comment string|nil
---@param comment_html string|nil
---@param comment_plain_text string|nil
---@return string
function Annotation.noteText(comment, comment_html, comment_plain_text)
    if type(comment_html) == "string" and Text.trim(comment_html) ~= "" then
        return htmlText(comment_html)
    end
    if type(comment_plain_text) == "string" and Text.trim(comment_plain_text) ~= "" then
        -- 后端 StripHtml 的产物，块间无分隔；这里只需去首尾空白。
        return Text.trim(comment_plain_text)
    end
    local raw = tostring(comment or "")
    if Text.trim(raw) == "" or Text.trim(raw) == "null" then return "" end
    local ok, data = pcall(JSON.decode, raw)
    -- json.decode 失败 = 存量纯文本备注（网页端 JSON.parse 会崩，但设备侧要能读）。
    if not ok then return raw end
    if data == nil then return "" end
    if type(data) ~= "table" then return tostring(data) end
    local text = deltaText(data)
    if text:match("^%s*$") then return "" end
    return text
end

--- 写回归一（create / update 共用）：与 Web 同构，`comment` 为 Quill Delta JSON、`commentHtml` 为对应 HTML。
--- 空备注写 `"{}"` + `""`（Web「新建未输入」的原样），否则网页端 `JSON.parse(comment)` 会崩。
---@param note string|nil
---@return { comment: string, commentHtml: string }
function Annotation.toRemote(note)
    local text = normalizeNote(note)
    if text:match("^%s*$") then
        return { comment = "{}", commentHtml = "" }
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line == "" and "<p><br></p>" or ("<p>" .. Text.xmlEscape(line) .. "</p>")
    end
    return {
        comment = JSON.encode({ ops = { { insert = text .. "\n" } } }),
        commentHtml = table.concat(lines),
    }
end

--- 幂等键（spec §8.2）：`<chapterId>\31<xPath>\31<endingXPath>\31<selectedText>`。
--- `comment` 不进键（备注可改，进键会把「改备注」变成「新建」）；`selectedText` 用比较归一，
--- 否则网页端/设备端的换行差异会让同一条划线认不出来（落库仍存原文）。
--- 字段名两套都要认：线上 DTO 用 `xPath` / `endingXPath` / `selectedText`，落库后的 payload
--- （阅读器快照、远端去重的输入）用 `kavita_xpath` / `kavita_ending_xpath` / `text`。
---@param ann { chapterId: integer|nil, xPath: string|nil, endingXPath: string|nil, selectedText: string|nil, kavita_xpath: string|nil, kavita_ending_xpath: string|nil, text: string|nil }
---@return string
function Annotation.key(ann)
    local selected = ann.selectedText
    if selected == nil then selected = ann.text end
    return table.concat({
        tostring(ann.chapterId or ""),
        tostring(ann.xPath or ann.kavita_xpath or ""),
        tostring(ann.endingXPath or ann.kavita_ending_xpath or ""),
        comparisonText(selected),
    }, Annotation.KEY_SEP)
end

--- 在对账列表里找本地这条注解的远端对应：同键多条取 id 最小（网页端重扫可能留下重复），
--- 没有 id 的条目没法采纳，直接跳过。
---@param remote table[]|nil
---@param ann table
---@return table|nil
function Annotation.match(remote, ann)
    if type(remote) ~= "table" then return nil end
    local wanted = Annotation.key(ann)
    local best, best_id
    for _idx, item in ipairs(remote) do
        local id = type(item) == "table" and tonumber(item.id)
        if id and (not best_id or id < best_id) and Annotation.key(item) == wanted then
            best, best_id = item, id
        end
    end
    return best
end

--- 比较两段备注是不是同一段：trim、内部连续空白压成单空格、剔除零宽字符，两边都空判等。
--- push / pull / 冲突裁决共用；不能拿它落库（换行与缩进会被抹平）。
---@param a string|nil
---@param b string|nil
---@return boolean
function Annotation.sameNote(a, b)
    return comparisonText(a) == comparisonText(b)
end

--- owner 比较：远端 id 是数字，调用方可能拿到字符串（配置/`/api/Users/me` 解析），两边能对上。
---@param a any
---@param b any
---@return boolean
local function sameOwner(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na == nb end
    return tostring(a) == tostring(b)
end

--- 该章全部注解（`GET /api/Annotation/all`，无分页）。`owner_id` 非空时只留自己的：
--- 账号开了「查看他人注解」后接口会混入别人的条目，删改别人的会整批 400。
---@param client KavitaClient
---@param chapter_id integer
---@param owner_id integer|string|nil nil / "" = 拿不到当前用户时的降级：不过滤
---@param cb fun(list: table[]|nil, err: string|nil)
---@return HttpJob|nil
function Annotation.listByChapter(client, chapter_id, owner_id, cb)
    return client:json("GET", "/api/Annotation/all", { chapterId = chapter_id }, nil, function(data, err)
        if not data then return cb(nil, err) end
        local filter = owner_id ~= nil and owner_id ~= ""
        local out = {}
        for _idx, item in ipairs(type(data) == "table" and data or {}) do
            if type(item) == "table" and (not filter or sameOwner(item.ownerUserId, owner_id)) then
                out[#out + 1] = item
            end
        end
        cb(out)
    end)
end

return Annotation
