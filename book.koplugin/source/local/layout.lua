--[[--
WebDAV 书库布局。流水线只读这张表，不出现风格名字。
再加一种风格：在 order 里登记一条，填书目录、要不要书目文件、进度怎么编码。

@module koplugin.book.source.local.layout
--]]

local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID

--- 书文件目录。book_dir 为空就是 WebDAV 根。
---@param layout table
---@param client LocalClient
---@return string
local function book_root(layout, client)
    if layout.book_dir == "" then return client:webdavPath() end
    return client:webdavPath() .. "/" .. layout.book_dir
end

--- 进度文件 = 进度目录 / 这一本的文件名。
---@param layout table
---@param client LocalClient
---@param rel string
---@return string
local function progress_path(layout, client, rel)
    return layout:progress_dir(client) .. "/" .. layout:progress_file(client, rel)
end

local function bookNameAuthor(rel)
    local row = require("book.books_db").get(SOURCE_ID, Common.remoteStableId(rel))
    local name = (row and Common.field(row.title)) or Common.stem(rel)
    local author = row and type(row.authors) == "string" and row.authors or ""
    local path = row and type(row.path) == "string" and row.path or nil
    return name, author, path
end

--- 阅读 AppWebDav.getProgressFileName：先把 \/:*?"<>| 换成下划线，再按 replaceReservedChar 转义。
---@param name string
---@param author string
---@return string
local function legadoFileName(name, author)
    local base = (name:gsub('[\\/:*?"<>|]', "_")) .. "_" .. (author:gsub('[\\/:*?"<>|]', "_"))
    local reserved = {
        ["%"] = "%25", [" "] = "%20", ['"'] = "%22", ["#"] = "%23",
        ["&"] = "%26", ["("] = "%28", [")"] = "%29", ["+"] = "%2B",
        [","] = "%2C", ["/"] = "%2F", [":"] = "%3A", [";"] = "%3B",
        ["<"] = "%3C", ["="] = "%3D", [">"] = "%3E", ["?"] = "%3F",
        ["@"] = "%40", ["\\"] = "%5C", ["|"] = "%7C",
    }
    return (base:gsub(".", function(ch) return reserved[ch] or ch end)) .. ".json"
end

local function normHref(href)
    href = (href or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    href = href:gsub("#.*", ""):gsub("\\", "/")
    local parts = {}
    for part in href:gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

local function isHtml(href)
    local ext = href:match("%.([^./]+)$")
    ext = ext and ext:lower()
    return ext == "html" or ext == "htm" or ext == "xhtml"
end

--- 阅读 parseFirstPage：第一个目录项之前的 html（封面、扉页）各算一章。
--- spine、first 都是去掉锚点后的路径。对不上目录就返回 0，别把整本书都算成卷首。
---@param spine string[]
---@param first string
---@return integer
local function tocShift(spine, first)
    first = normHref(first)
    if first == "" then return 0 end
    local count = 0
    for _idx, href in ipairs(spine or {}) do
        local path = normHref(href)
        if path == first then return count end
        if isHtml(path) then count = count + 1 end
    end
    return 0
end

--- 打开 epub，数卷首，并按 NCX 顺序取出目录标题。打不开就是没有偏移。
---@param path string|nil
---@return { shift: integer, titles: string[] }
local function epubToc(path)
    local empty = { shift = 0, titles = {} }
    if type(path) ~= "string" or not path:lower():match("%.epub$") then return empty end
    local ok, info = pcall(function()
        local arc = require("ffi/archiver").Reader:new()
        if not arc:open(path) then return empty end
        local read_ok, read = pcall(function()
            for _entry in arc:iterate() do end
            local opf_path = (arc:extractToMemory("META-INF/container.xml") or ""):match('full%-path="([^"]+)"')
            if not opf_path then return empty end
            local opf = arc:extractToMemory(opf_path) or ""
            local manifest = {}
            for tag in opf:gmatch("<item%s[^>]*>") do
                local id, href = tag:match('%sid="([^"]*)"'), tag:match('%shref="([^"]*)"')
                if id and href then manifest[id] = href end
            end
            local opf_dir = opf_path:match("^(.*)/") or ""
            local spine, ncx_href = {}, nil
            for idref in (opf:match("<spine[^>]*>(.-)</spine>") or ""):gmatch('idref="([^"]*)"') do
                local href = manifest[idref]
                if href then spine[#spine + 1] = normHref(opf_dir .. "/" .. href) end
            end
            for tag in opf:gmatch("<item%s[^>]*>") do
                local href, media = tag:match('%shref="([^"]*)"'), tag:match('media%-type="([^"]*)"')
                if href and (media == "application/x-dtbncx+xml" or href:lower():match("%.ncx$")) then
                    ncx_href = href
                    break
                end
            end
            if not ncx_href then return empty end
            local ncx_path = normHref(opf_dir .. "/" .. ncx_href)
            local ncx = arc:extractToMemory(ncx_path) or ""
            local nav = ncx:match("<navMap>(.-)</navMap>") or ""
            local src = nav:match('<content[^>]-src="([^"]+)"')
            local titles = {}
            for text in nav:gmatch("<text>(.-)</text>") do
                titles[#titles + 1] = text:match("^%s*(.-)%s*$")
            end
            local ncx_dir = ncx_path:match("^(.*)/") or ""
            local first = src and normHref(ncx_dir .. "/" .. src) or ""
            return { shift = tocShift(spine, first), titles = titles }
        end)
        arc:close()
        if not read_ok then error(read) end
        return read
    end)
    return ok and info or empty
end

--- BookProgress。阅读的章号 = KOReader 目录序号减 1，再加目录前的卷首页。
--- 没有可靠的章内偏移时位置写 0。卷首只加在真正的目录章上，页码兜底不加。
---@param pos ProgressPosition
---@param name string
---@param author string
---@param shift integer|nil
---@return string
local function legadoEncode(pos, name, author, shift)
    local chapter = tonumber(pos.chapter_idx) or 0
    local indexed = chapter > 0
    local extra = type(pos.extra) == "table" and pos.extra or nil
    local offset = extra and tonumber(extra.offset)
    local anchored = extra and tonumber(extra.at_fraction)
    if offset and offset >= 0 and anchored and math.abs((tonumber(pos.fraction) or 0) - anchored) > 0.001 then
        offset = nil
    end
    if not offset and chapter == 0 then
        local page = tonumber(pos.page)
        if page and page >= 1 then
            chapter = math.floor(page)
            offset = 0
        end
    end
    local add = indexed and math.max(0, math.floor(tonumber(shift) or 0)) or 0
    local body = {
        name = name, author = author,
        durChapterIndex = chapter > 0 and (math.floor(chapter) - 1 + add) or 0,
        durChapterPos = math.floor(offset or 0),
        durChapterTime = math.floor((tonumber(pos.updated_at) or os.time()) * 1000),
    }
    if type(pos.chapter_title) == "string" and pos.chapter_title ~= "" then
        body.durChapterTitle = pos.chapter_title
    end
    return require("json").encode(body)
end

--- 标题在目录里唯一时以标题为准。重名时优先卷首换算对得上的那条。
---@param titles string[]
---@param title string
---@param shifted integer
---@return integer|nil
local function chapterByTitle(titles, title, shifted)
    if title == "" then return nil end
    local hits = {}
    for i, name in ipairs(titles or {}) do
        if name == title then hits[#hits + 1] = i end
    end
    if #hits == 1 then return hits[1] end
    if #hits == 0 then return nil end
    for _idx, i in ipairs(hits) do
        if i == shifted then return i end
    end
    return hits[1]
end

---@param raw string
---@param path string|nil 本地 epub，用来把阅读的章号换回 KOReader 目录
---@return ProgressPosition|nil
local function legadoDecode(raw, path)
    local ok, obj = pcall(require("json").decode, raw)
    if not ok or type(obj) ~= "table" then return nil end
    local index = tonumber(obj.durChapterIndex)
    if not index then return nil end
    local ts = tonumber(obj.durChapterTime) or 0
    if ts > 1e12 then ts = math.floor(ts / 1000) end
    local info = epubToc(path)
    local shift = info.shift
    local chapter = math.floor(index) - shift + 1
    local title = type(obj.durChapterTitle) == "string" and obj.durChapterTitle or ""
    chapter = chapterByTitle(info.titles, title, chapter) or chapter
    if chapter < 1 then chapter = 1 end
    local offset = math.floor(tonumber(obj.durChapterPos) or 0)
    return {
        updated_at = ts,
        chapter_idx = chapter,
        chapter_title = title ~= "" and title or nil,
        fraction = 0,
        extra = { chapter_idx = chapter, volume = 0, offset = offset, at_fraction = 0 },
    }
end

local moon = {
    id = "moon",
    label = "静读天下",
    detail = "书籍在目录中，进度在 .Moon+/Cache",
    blurb = "本地书按静读天下同步，其余数据放进 .moon-koreader",
    book_dir = "",
    -- 书架是书目文件。日常同步不列目录，刷新才列。
    shelf_is_dir = false,
    covers = true,
    book_root = book_root,
    progress_path = progress_path,
    catalog = function(_layout, client)
        return Common.moonPath(client, "books.sync")
    end,
    dirs = function(_layout, client)
        return { Common.moonPath(client, "Cache"), Common.moonPath(client, "Cover") }
    end,
    progress_dir = function(_layout, client)
        return Common.moonPath(client, "Cache")
    end,
    progress_file = function(_layout, _client, rel)
        return Common.sidecarKey(rel) .. ".po"
    end,
    encode = function(_layout, _client, _rel, pos)
        return Common.encodeProgress(pos)
    end,
    decode = function(_layout, raw)
        return Common.decodeProgress(raw)
    end,
    sidecars = function(layout, client, rel)
        local progress = layout:progress_path(client, rel)
        return {
            Common.coverRemotePath(client, rel), progress, progress .. ".json",
            Common.notesRemotePath(client, rel),
        }
    end,
}

local legado = {
    id = "legado",
    label = "Legado",
    detail = "书籍在 books/，进度在 bookProgress/书名_作者.json",
    blurb = "本地书按 Legado 同步：书籍在 books/，进度在 bookProgress，其余数据放进 .moon-koreader",
    book_dir = "books",
    -- 没有书目文件，目录里的书就是书架，每轮都要列。
    shelf_is_dir = true,
    covers = false,
    book_root = book_root,
    progress_path = progress_path,
    catalog = nil,
    -- 纯函数，测试直接拿文件名和 JSON，不经过书库。
    progress_filename = legadoFileName,
    encode_progress = legadoEncode,
    toc_shift = tocShift,
    dirs = function(layout, client)
        return { layout:book_root(client), layout:progress_dir(client) }
    end,
    progress_dir = function(_layout, client)
        return client:webdavPath() .. "/bookProgress"
    end,
    progress_file = function(_layout, _client, rel)
        local name, author = bookNameAuthor(rel)
        return legadoFileName(name, author)
    end,
    encode = function(_layout, _client, rel, pos)
        local name, author, path = bookNameAuthor(rel)
        return legadoEncode(pos, name, author, epubToc(path).shift)
    end,
    decode = function(_layout, raw, path)
        return legadoDecode(raw, path)
    end,
    sidecars = function(layout, client, rel)
        return { layout:progress_path(client, rel), Common.notesRemotePath(client, rel) }
    end,
}

--- 顺序就是设置页的顺序。缺省是第一条。
local order = { moon, legado }

local by_id = {}
for _idx, layout in ipairs(order) do by_id[layout.id] = layout end

local Layout = {
    default_id = order[1].id,
}

---@return table[]
function Layout.all()
    return order
end

---@param id string|nil
---@return table
function Layout.get(id)
    return by_id[id] or order[1]
end

--- 客户端或任意带 cfg 的表。没有配置就读本地源设置。
---@param self LocalClient|nil
---@return table
function Layout.of(self)
    local cfg = type(self) == "table" and self.cfg
    if type(cfg) ~= "table" then cfg = require("utils.settings").getSource(SOURCE_ID) end
    return Layout.get(cfg.webdav_sync_style)
end

return Layout
