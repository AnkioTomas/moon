--[[--
得到网页响应 → 领域对象。纯函数，不发请求。

正文 SVG 是 AES-256-CBC。密钥和 IV 写在阅读器脚本的 decrypt 里，和网页同一套。

@module source.dedao.mapper
--]]

local Aes = require("crypto.aes")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "dedao"
Mapper.TOC_VERSION = 1

local SVG_KEY = "3e4r06tjkpjcevlbslr3d96gdb5ahbmo"
local SVG_IV = "6fd89a1b3a7f48fb"
local QR_URL = "https://m.igetget.com/oauth/qrcode/v2/authorize?token=%s&source=igetweb&dv="

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(Text.xmlDecode(value:gsub("</?hl>", "")))
end

---@param id string
---@param title string|nil
---@param author string|nil
---@param intro string|nil
---@param cover string|nil
---@return Book
local function book(id, title, author, intro, cover)
    local picture = type(cover) == "string" and cover ~= "" and cover or nil
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = clean(title),
        authors = clean(author),
        intro = clean(intro),
        cover = picture,
    }
end

--- 扫码内容。网页把 qrCodeString 编进这张 URL，得到 App 认的是这张图。
---@param code string|nil
---@return string|nil
function Mapper.qrText(code)
    if type(code) ~= "string" or code == "" then return nil end
    return string.format(QR_URL, code)
end

--- 轮询 data.status：0 继续等，1 成功，2 二维码失效。
---@param wire table|nil
---@return "wait"|"ok"|"fail"
function Mapper.login(wire)
    local data = type(wire) == "table" and wire.data or nil
    local status = type(data) == "table" and tonumber(data.status) or nil
    if status == 0 then return "wait" end
    if status == 1 then return "ok" end
    return "fail"
end

--- 已购电子书。听书、课程、本地上传不在这张书架里。
---@param wire table|nil
---@return Book[]
function Mapper.shelf(wire)
    local out = {}
    local rows = type(wire) == "table" and wire.list or nil
    if type(rows) ~= "table" then return out end
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and tonumber(row.type) == 2 and type(row.enid) == "string" and row.enid ~= "" then
            local item = book(row.enid, row.title, row.author, row.intro, row.icon)
            if item.title ~= "" then out[#out + 1] = item end
        end
    end
    return out
end

--- 搜索 tab 电子书。标题里的高亮标签丢掉。
---@param wire table|nil
---@return Book[]
function Mapper.search(wire)
    local out, seen = {}, {}
    local data = type(wire) == "table" and wire.data or nil
    local modules = type(data) == "table" and data.moduleList or nil
    if type(modules) ~= "table" then return out end
    for _m, mod in ipairs(modules) do
        local rows = type(mod) == "table" and mod.layerDataList or nil
        if type(rows) == "table" then
            for _idx, row in ipairs(rows) do
                local extra = type(row) == "table" and row.extra or nil
                local enid = type(extra) == "table" and extra.enid or nil
                if type(enid) == "string" and enid ~= "" and tonumber(row.type) == 2 and not seen[enid] then
                    seen[enid] = true
                    local item = book(enid, row.Title or row.title, row.author, row.content, row.image)
                    if item.title ~= "" then out[#out + 1] = item end
                end
            end
        end
    end
    return out
end

---@param body table|nil
---@param stable_id string
---@return Book|nil
function Mapper.detail(body, stable_id)
    if type(body) ~= "table" then return nil end
    local id = type(body.enid) == "string" and body.enid ~= "" and body.enid or stable_id
    -- 详情里 title 经常是空字符串，书名在 operating_title。
    local title = type(body.title) == "string" and body.title ~= "" and body.title or body.operating_title
    local item = book(id, title, body.book_author, body.book_intro, body.cover)
    if item.title == "" then return nil end
    return item
end

--- 阅读器目录。href 里 # 前面是 epub 路径，orders 把它换成 get_pages 要的章节号。
---@param info table|nil
---@return BookChapter[]
function Mapper.chapters(info)
    local book_info = type(info) == "table" and info.bookInfo or nil
    if type(book_info) ~= "table" then return {} end
    local by_path = {}
    local orders = type(book_info.orders) == "table" and book_info.orders or {}
    for _idx, row in ipairs(orders) do
        if type(row) == "table" and row.pathInEpub and row.chapterId then
            by_path[row.pathInEpub] = tostring(row.chapterId)
        end
    end
    local rows = {}
    local toc = type(book_info.toc) == "table" and book_info.toc or {}
    for _idx, row in ipairs(toc) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b)
        return (tonumber(a.playOrder) or 0) < (tonumber(b.playOrder) or 0)
    end)
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and type(row.href) == "string" and row.href ~= "" then
            local path = row.href:match("^([^#]+)") or row.href
            local uid = by_path[path] or path
            local level = tonumber(row.level) or 0
            out[#out + 1] = {
                uid = uid,
                title = clean(row.text),
                depth = level + 1,
            }
        end
    end
    for idx, chapter in ipairs(out) do chapter.idx = idx end
    if out[1] then out[1].toc_version = Mapper.TOC_VERSION end
    return out
end

--- 进度 findex 就是章节号。
---@param findex string|nil
---@return string|nil
function Mapper.progressUid(findex)
    if type(findex) ~= "string" or findex == "" then return nil end
    return findex
end

--- 解开一页 SVG，抽出文字；空白页返回空串，解密失败返回 nil。
---@param cipher string|nil
---@return string|nil
function Mapper.pageText(cipher)
    if type(cipher) ~= "string" or cipher == "" then return nil end
    local raw = Text.base64Decode(cipher)
    if #raw == 0 or #raw % 16 ~= 0 then return nil end
    local ok, svg = pcall(Aes.cbc_decrypt, raw, SVG_KEY, SVG_IV)
    if not ok or type(svg) ~= "string" or svg == "" then return nil end
    local parts = {}
    for block in svg:gmatch("<text[^>]*>(.-)</text>") do
        local text = clean(block:gsub("<[^>]+>", ""))
        if text ~= "" then parts[#parts + 1] = text end
    end
    return table.concat(parts, "\n")
end

return Mapper
