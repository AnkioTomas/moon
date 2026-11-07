--[[--
豆瓣阅读网页响应 → 领域对象。纯函数，不发请求。

搜索和作品查询是持久化 GraphQL：请求里只有 sha256，没有查询文本。
正文是 Base64 后的 AES-256-CBC。末尾 16 字节是 IV，再往前的密文才解密，最后 13 字节丢掉。
密钥是 SHA-256("anonymous")，登录后换成 SHA-256(用户编号)。

@module source.douban.mapper
--]]

local Aes = require("crypto.aes")
local CategorySetting = require("source.category_setting")
local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")

local Mapper = {}

local SOURCE_ID = "douban"

Mapper.TOC_VERSION = 2
Mapper.SEARCH_HASH = "sha256:92911ffc68782f44a56764094edc0068f283c29fb447277f8ed2911af6bbd0a0"
Mapper.ACCESS_HASH = "sha256:bf9257d4f673ee55c4ef0fbf7f495a4cf1fd972048ef4a823d92f40636c36f25"
Mapper.INFO_HASH = "sha256:2ba0b5cafe47036cf931fcf749803c0fed974b448cd479e48fc35edd75e540a7"
--- 书架页先拿编号，再用这条查询补 title / author / cover。
Mapper.SHELF_WORKS_HASH = "sha256:d9cff923ff4ed25849b6dc0d493b027533c4f252647107f2226de11b78f7b831"
Mapper.SHELF_FOLDERS_HASH = "sha256:226417726ce78055a35e7281426637272fdaaef4a001e15a975a41e37a2331cc"
Mapper.READING_TIME_HASH = "sha256:03a310ea89efc4801c0071c4d3c5bcae7ae9227cada95c731e7222a0811e491f"

local SEARCH_VARIABLES = {
    includeRating = false,
    includeBookRating = false,
    includeUpdateTime = false,
    includeSaleInfo = false,
    includePurchase = false,
    includeLibraryCount = false,
    includeFandom = false,
    includeFanfictionTags = false,
}

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(Text.xmlDecode(value))
end

---@param title any
---@param idx integer
---@return string
local function chapterTitle(title, idx)
    local cleaned = clean(title)
    if cleaned ~= "" then return cleaned end
    return require("ffi/util").template(_("第 %1 章"), idx)
end

---@param cover any
---@return string|nil
local function picture(cover)
    if type(cover) ~= "string" or cover == "" then return nil end
    cover = Text.xmlDecode(cover)
    if cover:sub(1, 2) == "//" then return "https:" .. cover end
    return cover
end

---@param author any
---@return string
local function authors(author)
    if type(author) == "string" then return clean(author) end
    if type(author) ~= "table" then return "" end
    if type(author.name) == "string" then return clean(author.name) end
    local names = {}
    for _idx, person in ipairs(author) do
        local name = type(person) == "table" and person.name or person
        if type(name) == "string" and name ~= "" then names[#names + 1] = clean(name) end
    end
    return table.concat(names, " ")
end

---@param id any
---@param title any
---@param author any
---@param intro any
---@param cover any
---@param category any
---@return Book
local function book(id, title, author, intro, cover, category)
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(id),
        title = clean(title),
        authors = authors(author),
        intro = clean(intro),
        cover = picture(cover),
        category = clean(category) ~= "" and clean(category) or nil,
    }
end

---@param works_id any
---@param hash string
---@return table
function Mapper.worksBody(works_id, hash)
    return {
        variables = { worksId = tostring(works_id) },
        extensions = { persistedQuery = { version = 1, sha256Hash = hash } },
    }
end

---@param keyword string
---@return table
function Mapper.searchBody(keyword)
    return {
        sort = "default",
        page = 1,
        q = keyword,
        extensions = { persistedQuery = { version = 1, sha256Hash = Mapper.SEARCH_HASH } },
        variables = SEARCH_VARIABLES,
    }
end

---@param opts table
---@param page integer
---@return table
function Mapper.catalogBody(opts, page)
    local body = {
        kind = tonumber(opts.category),
        sort = opts.sort,
        page = page,
        extensions = { persistedQuery = { version = 1, sha256Hash = Mapper.SEARCH_HASH } },
        variables = SEARCH_VARIABLES,
    }
    if opts.pay == "free" then body.minPrice, body.maxPrice = 0, 0
    elseif opts.pay == "paid" then body.minPrice = 1 end
    if opts.state == "complete" then body.isFinished = true
    elseif opts.state == "serial" then body.isFinished = false end
    return body
end

---@param html string
---@return table<string, { id: string, title: string }[]>|nil
---@return string|nil
function Mapper.categories(html)
    local raw = type(html) == "string" and html:match("Ark%.kindTree%s*=%s*(%b[])")
    local ok, tree = pcall(JSON.decode, raw or "")
    if not ok or type(tree) ~= "table" then return nil, _("响应无效") end
    local categories = { original = {}, publish = {} }
    local function append(rows, out)
        for _idx, row in ipairs(rows) do
            if type(row) ~= "table" or type(row.id) ~= "number" or type(row.name) ~= "string"
                or type(row.children) ~= "table" then return false end
            out[#out + 1] = { id = tostring(row.id), title = clean(row.name) }
            if not append(row.children, out) then return false end
        end
        return true
    end
    for _idx, root in ipairs(tree) do
        if type(root) ~= "table" then return nil, _("响应无效") end
        local channel = root.id == 0 and "original" or root.id == 1 and "publish" or nil
        if channel and (type(root.children) ~= "table" or not append(root.children, categories[channel])) then
            return nil, _("响应无效")
        end
    end
    if #categories.original == 0 or #categories.publish == 0 then return nil, _("响应无效") end
    return categories
end

---@param item table
---@return Book|nil
local function worksBook(item)
    if type(item) ~= "table" or item.isAudio == true or item.isBundle == true then return nil end
    local id = item.id or item.worksId or item.works_id
    local title = item.title or item.name
    if id == nil or title == nil or title == "" then return nil end
    local category = item.category
    if type(item.kinds) == "table" and type(item.kinds[1]) == "table" then
        category = item.kinds[1].shortName or item.kinds[1].name
    end
    return book(id, title, item.author or item.agent, item.abstract or item.intro, item.cover or item.cover_url, category)
end

---@param wire table|nil
---@return Book[]|nil
---@return string|nil
function Mapper.searchBooks(wire)
    if type(wire) ~= "table" or type(wire.list) ~= "table" then
        return nil, type(wire) == "table" and type(wire.error) == "string" and wire.error or _("请求失败")
    end
    local books = {}
    for _idx, item in ipairs(wire.list) do
        local row = worksBook(item)
        if row then books[#books + 1] = row end
    end
    return books
end

---@param url string|nil
---@return { kind: string, column_id: string|nil, aid: string|nil }|nil
function Mapper.reader(url)
    if type(url) ~= "string" then return nil end
    local column_id = url:match("/reader/column/(%d+)/")
    if column_id then return { kind = "column", column_id = column_id } end
    local aid = url:match("/reader/ebook/(%d+)")
    if aid then return { kind = "ebook", aid = aid } end
    return nil
end

---@param wire table|nil
---@return string|nil
function Mapper.readerUrl(wire)
    local data = type(wire) == "table" and wire.data or nil
    local works = type(data) == "table" and data.works or nil
    local url = type(works) == "table" and works.readerUrl or nil
    if type(url) ~= "string" or url == "" then return nil end
    return url
end

---@param works_id string
---@param wire table|nil
---@return Book|nil
function Mapper.columnBook(works_id, wire)
    if type(wire) ~= "table" or wire.type ~= "column" or type(wire.title) ~= "string" then return nil end
    return book(works_id, wire.title, wire.agent, wire.abstract, wire.cover or wire.retina_cover, wire.category)
end

---@param works_id string
---@param wire table|nil
---@return Book|nil
function Mapper.infoBook(works_id, wire)
    local data = type(wire) == "table" and wire.data or nil
    local works = type(data) == "table" and (data.universalWorks or data.works) or nil
    if type(works) ~= "table" or type(works.title) ~= "string" then return nil end
    return book(works_id, works.title, nil, nil, nil, nil)
end

---@param wire table|nil
---@return BookChapter[]|nil
---@return string|nil
function Mapper.columnChapters(wire)
    if type(wire) ~= "table" or type(wire.chapters) ~= "table" then return nil, _("豆瓣阅读目录为空") end
    local chapters = {}
    for idx, item in ipairs(wire.chapters) do
        if type(item) == "table" and item.id ~= nil then
            local free = item.is_free == true or item.is_paid == true or item.is_allowed_to_read == true
            chapters[#chapters + 1] = {
                idx = idx,
                uid = tostring(item.id),
                title = chapterTitle(item.title, idx),
                content_url = tostring(item.id),
                vip = not free,
            }
        end
    end
    if not chapters[1] then return nil, _("豆瓣阅读目录为空") end
    chapters[1].toc_version = Mapper.TOC_VERSION
    return chapters
end

---@param b64 string
---@param user_id string|nil
---@return table|nil
---@return string|nil
function Mapper.decrypt(b64, user_id)
    local raw = Text.base64Decode(b64)
    local cipher_len = #raw - 16 - 13
    if cipher_len < 16 or cipher_len % 16 ~= 0 then return nil, _("正文解密失败") end
    local material = type(user_id) == "string" and user_id ~= "" and user_id or "anonymous"
    local sha2 = require("ffi/sha2")
    local key = sha2.hex_to_bin(sha2.sha256(material))
    local ok, plain = pcall(Aes.cbc_decrypt, raw:sub(1, cipher_len), key, raw:sub(cipher_len + 1, cipher_len + 16))
    if not ok or type(plain) ~= "string" then return nil, _("正文解密失败") end
    local decoded, article = pcall(JSON.decode, plain)
    if not decoded or type(article) ~= "table" then return nil, _("正文解密失败") end
    return article
end

---@param data table|nil
---@return string
local function paragraphText(data)
    local text = data and data.text
    if type(text) == "table" then
        local parts = {}
        for _idx, run in ipairs(text) do
            if run.kind == "plaintext" then parts[#parts + 1] = run.content end
        end
        text = table.concat(parts)
    end
    return type(text) == "string" and Text.trim(text) or ""
end

---@param article table
---@param start_pid number|nil
---@param end_pid number|nil
---@return string
function Mapper.blocksText(article, start_pid, end_pid)
    local lines = {}
    local posts = type(article.posts) == "table" and article.posts or {}
    for _pidx, post in ipairs(posts) do
        local contents = type(post) == "table" and post.contents or nil
        if type(contents) == "table" then
            for _bidx, block in ipairs(contents) do
                local id = type(block) == "table" and tonumber(block.id) or nil
                local in_range = not start_pid or (id and id >= start_pid and (not end_pid or id < end_pid))
                local kind = type(block) == "table" and block.type or nil
                if in_range and (kind == "paragraph" or kind == "headline") then
                    local text = paragraphText(block.data)
                    if text ~= "" then lines[#lines + 1] = text end
                end
            end
        end
    end
    return table.concat(lines, "\n")
end

--- 本章非空段的段落编号，顺序和章节 HTML 里的 <p> 一致。
---@param article table|nil
---@param start_pid number|nil
---@param end_pid number|nil
---@return string[]
function Mapper.paragraphIds(article, start_pid, end_pid)
    local ids = {}
    local posts = type(article) == "table" and article.posts or {}
    for _pidx, post in ipairs(type(posts) == "table" and posts or {}) do
        local contents = type(post) == "table" and post.contents or nil
        if type(contents) == "table" then
            for _bidx, block in ipairs(contents) do
                local id = type(block) == "table" and tonumber(block.id) or nil
                local in_range = not start_pid or (id and id >= start_pid and (not end_pid or id < end_pid))
                local kind = type(block) == "table" and block.type or nil
                if id and in_range and (kind == "paragraph" or kind == "headline") and paragraphText(block.data) ~= "" then
                    ids[#ids + 1] = tostring(block.id)
                end
            end
        end
    end
    return ids
end

--- 批注时间。秒级数字；13 位毫秒收成秒。没有数字就给 0。
---@param value any
---@return integer
local function created(value)
    local n = tonumber(value)
    if n then
        if n > 1e12 then n = math.floor(n / 1000) end
        return math.floor(n)
    end
    if type(value) ~= "string" then return 0 end
    local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not year then return 0 end
    local stamp = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    })
    if not stamp then return 0 end
    local now = os.time()
    return stamp + os.difftime(now, os.time(os.date("!*t", now)))
end

--- 一段上的批注条数。没有 note 的划线不是段评。range 是本章第几个非空段。
---@param rows table|nil
---@param pids string[]
---@return { range: string, text: string, total: integer }[]|nil
function Mapper.reviewHotspots(rows, pids)
    if type(rows) ~= "table" then return nil end
    local index = {}
    for idx, pid in ipairs(pids) do index[tostring(pid)] = tostring(idx) end
    local counts = {}
    for _idx, row in ipairs(rows) do
        local note = type(row) == "table" and type(row.note) == "string" and Text.trim(row.note) or ""
        local pid = type(row) == "table" and row.startContainerId ~= nil and tostring(row.startContainerId) or nil
        local range = pid and index[pid]
        if range and note ~= "" then counts[range] = (counts[range] or 0) + 1 end
    end
    local out = {}
    for range, total in pairs(counts) do
        out[#out + 1] = { range = range, text = "", total = total }
    end
    table.sort(out, function(a, b) return tonumber(a.range) < tonumber(b.range) end)
    return out
end

--- 某一段的批注。作者是 owner.name，赞是 n_favorites。
---@param rows table|nil
---@param pids string[]
---@param range string|number
---@return { items: table[], total: integer, max_idx: integer, more: boolean }|nil
function Mapper.reviewPage(rows, pids, range)
    if type(rows) ~= "table" then return nil end
    local pid = pids[tonumber(range)]
    local items = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and pid and tostring(row.startContainerId) == tostring(pid) then
            local note = type(row.note) == "string" and Text.trim(row.note) or ""
            local owner = type(row.owner) == "table" and row.owner or nil
            local name = owner and type(owner.name) == "string" and owner.name or ""
            if note ~= "" then
                items[#items + 1] = {
                    id = tostring(row.id or ""),
                    author = name,
                    content = note,
                    likes = tonumber(row.n_favorites) or 0,
                    images = {},
                    time = created(row.create_time),
                }
            end
        end
    end
    return { items = items, total = #items, max_idx = 1, more = false }
end

---@param article table
---@param aid string
---@return BookChapter[]|nil
---@return string|nil
function Mapper.ebookChapters(article, aid)
    local toc = type(article.toc) == "table" and article.toc or {}
    local chapters = {}
    for idx, item in ipairs(toc) do
        if type(item) == "table" and item.paragraph_id ~= nil then
            local pid = tonumber(item.paragraph_id)
            local next_item = toc[idx + 1]
            local next_pid = type(next_item) == "table" and tonumber(next_item.paragraph_id) or nil
            chapters[#chapters + 1] = {
                idx = idx,
                uid = tostring(item.paragraph_id),
                title = chapterTitle(item.title, idx),
                content_url = tostring(aid),
                end_pid = next_pid and tostring(next_pid) or nil,
                slice = true,
                vip = Mapper.blocksText(article, pid, next_pid) == "",
                depth = (tonumber(item.level) or 0) + 1,
            }
        end
    end
    if not chapters[1] then
        local text = Mapper.blocksText(article, nil, nil)
        local title = type(article.posts) == "table" and type(article.posts[1]) == "table" and article.posts[1].title or nil
        if text == "" then return nil, _("豆瓣阅读目录为空") end
        chapters[1] = {
            idx = 1,
            uid = tostring(aid),
            title = chapterTitle(title, 1),
            content_url = tostring(aid),
            vip = false,
        }
    end
    chapters[1].toc_version = Mapper.TOC_VERSION
    return chapters
end

--- 首页脚本里的写请求令牌。没有它，登录后的 POST 会被拒。
---@param html string|nil
---@return string|nil
function Mapper.readCsrf(html)
    if type(html) ~= "string" then return nil end
    return html:match("CSRF_TOKEN%s*=%s*'([^']+)'")
        or html:match('CSRF_TOKEN%s*=%s*"([^"]+)"')
end

--- `/j/bookshelf/` 只有编号。书架页 GraphQL 的 `libraryList.list[].worksId` 同形。
---@param wire table|nil
---@return string[]|nil
---@return string|nil
function Mapper.shelfIds(wire)
    if type(wire) ~= "table" or wire.errors then return nil, _("豆瓣阅读书架数据无法识别") end
    local rows = wire.worksIds
    if type(rows) ~= "table" then
        local user = type(wire.data) == "table" and wire.data.user or nil
        local shelf = type(user) == "table" and type(user.bookshelf) == "table" and user.bookshelf or nil
        local library = type(shelf) == "table" and shelf.libraryList or nil
        rows = type(library) == "table" and library.list or nil
    end
    if type(rows) ~= "table" or (next(rows) ~= nil and rows[1] == nil) then
        return nil, _("豆瓣阅读书架数据无法识别")
    end
    local ids = {}
    for _idx, item in ipairs(rows) do
        local id = item
        if type(item) == "table" then id = item.worksId or item.id or item.works_id end
        if type(id) == "number" then id = tostring(id) end
        if type(id) ~= "string" or id == "" then return nil, _("豆瓣阅读书架数据无法识别") end
        ids[#ids + 1] = id
    end

    return ids
end

---@param wire table|nil
---@return (string|number)[]|nil
---@return string|nil
function Mapper.folderIds(wire)
    local ids = type(wire) == "table" and wire.folderIds
    if type(ids) ~= "table" or (next(ids) ~= nil and ids[1] == nil) then return nil, _("响应无效") end
    for _idx, id in ipairs(ids) do
        if (type(id) ~= "string" and type(id) ~= "number") or id == "" then return nil, _("响应无效") end
    end
    return ids
end

--- 与微信相同：多组成员按官网分组顺序取第一个，响应顺序不决定分类。
---@param wire table|nil
---@param ids (string|number)[]
---@return table<string, string>|nil
---@return string|nil
function Mapper.shelfGroups(wire, ids)
    if type(wire) ~= "table" or wire.errors then return nil, _("响应无效") end
    local user = type(wire.data) == "table" and wire.data.user
    local shelf = type(user) == "table" and user.bookshelf
    local folders = type(shelf) == "table" and shelf.folders
    local list = type(folders) == "table" and folders.list
    if type(list) ~= "table" or (next(list) ~= nil and list[1] == nil) then return nil, _("响应无效") end
    local by_id = {}
    for _idx, folder in ipairs(list) do
        if type(folder) ~= "table" or (type(folder.id) ~= "string" and type(folder.id) ~= "number")
            or folder.id == "" or type(folder.name) ~= "string" or folder.name == ""
            or type(folder.libraryList) ~= "table" or by_id[tostring(folder.id)] then
            return nil, _("响应无效")
        end
        local members, err = Mapper.shelfIds({ worksIds = folder.libraryList.list })
        if not members then return nil, err end
        by_id[tostring(folder.id)] = { name = folder.name, members = members }
    end
    local groups = {}
    for _idx, id in ipairs(ids) do
        local folder = by_id[tostring(id)]
        if not folder then return nil, _("响应无效") end
        for _member_idx, works_id in ipairs(folder.members) do
            groups[works_id] = groups[works_id] or folder.name
        end
    end
    return groups
end

---@param ids string[]
---@return table
function Mapper.shelfWorksBody(ids)
    return {
        variables = { worksIds = ids },
        extensions = { persistedQuery = { version = 1, sha256Hash = Mapper.SHELF_WORKS_HASH } },
    }
end

--- 编号查回来的作品。有声书不进书架。
---@param wire table|nil
---@param groups table<string, string>|nil
---@param ids string[]|nil
---@return Book[]|nil
---@return string|nil
function Mapper.shelfWorks(wire, groups, ids)
    if type(wire) ~= "table" or wire.errors then return nil, _("豆瓣阅读书架数据无法识别") end
    local data = type(wire) == "table" and wire.data or nil
    local list = type(data) == "table" and data.worksList or nil
    if type(list) ~= "table" or (next(list) ~= nil and list[1] == nil) then
        return nil, _("豆瓣阅读书架数据无法识别")
    end
    local books, seen = {}, {}
    for _idx, item in ipairs(list) do
        if type(item) ~= "table" or item.id == nil then return nil, _("豆瓣阅读书架数据无法识别") end
        seen[tostring(item.id)] = true
        local row = worksBook(item)
        if row then
            local genre = row.category
            if not genre and type(item.isOrigin) == "boolean" then
                genre = item.isOrigin and _("原创") or _("出版")
            end
            row.category = CategorySetting.apply(SOURCE_ID, genre, groups and groups[row.stable_id])
            row.category_authoritative = true
            books[#books + 1] = row
        elseif item.isAudio ~= true and item.isBundle ~= true then
            return nil, _("豆瓣阅读书架数据无法识别")
        end
    end
    for _idx, id in ipairs(ids or {}) do
        if not seen[id] then return nil, _("豆瓣阅读书架数据无法识别") end
    end
    if #books == 0 and #list > 0 then return nil, _("豆瓣阅读书架数据无法识别") end
    return books
end

---@param wire table|nil
---@return Book[]|nil
---@return string|nil
function Mapper.shelf(wire)
    local rows = wire
    if type(wire) == "table" and wire[1] == nil then
        rows = wire.worksIds or wire.list or wire.works or wire.items
        if rows == nil then
            if wire.error or wire.message or next(wire) ~= nil then
                return nil, _("豆瓣阅读书架数据无法识别")
            end
            rows = {}
        end
    end
    if type(rows) ~= "table" then return nil, _("豆瓣阅读书架数据无法识别") end
    local books = {}
    for _idx, item in ipairs(rows) do
        local row = worksBook(item)
        if row then books[#books + 1] = row end
    end
    if #books == 0 and #rows > 0 then return nil, _("豆瓣阅读书架数据无法识别") end
    return books
end

---@param html string
---@return string|nil
function Mapper.csrf(html)
    if type(html) ~= "string" then return nil end
    return html:match('name="csrf%-token"%s+content="([^"]+)"')
        or html:match('content="([^"]+)"%s+name="csrf%-token"')
end

---@param html string
---@return { id: string, name: string }|nil
function Mapper.user(html)
    if type(html) ~= "string" then return nil end
    local raw = html:match("Ark%.user%s*=%s*(%b{})")
    if not raw then return nil end
    local ok, user = pcall(JSON.decode, raw)
    if not ok or type(user) ~= "table" or user.isAnonymous == true
        or (type(user.id) ~= "string" and type(user.id) ~= "number") or tostring(user.id) == "" then return nil end
    local name = user.name or user.nickname or user.screenName or ""
    return { id = tostring(user.id), name = type(name) == "string" and name or "" }
end

---@param wire table|nil
---@param origin string
---@return { qr: string, code: string, expires_in: number }|nil
function Mapper.qr(wire, origin)
    if type(wire) ~= "table" or type(wire.url) ~= "string" or wire.url == "" then return nil end
    local code = wire.url:match("[?&]code=([^&]+)")
    if not code or code == "" then return nil end
    if wire.url:sub(1, 1) ~= "/" or wire.url:sub(1, 2) == "//" then return nil end
    return { qr = origin .. wire.url, code = code, expires_in = tonumber(wire.expires_in) or 300 }
end

---@param wire table|nil
---@return string|nil
function Mapper.qrStatus(wire)
    if type(wire) ~= "table" or type(wire.confirmed) ~= "boolean" then return nil end
    if wire.confirmed then return "ok" end
    return "wait"
end

--- 进度回包。`r` 为真或没有 progress 是云端无位置，不是请求失败。
---@param wire table|nil
---@return { paragraph_id: string }|nil
---@return boolean empty
function Mapper.progress(wire)
    if type(wire) ~= "table" then return nil, false end
    local item = wire.progress
    -- 网页把 r 当布尔用：0 是成功。Lua 里 0 为真，不能直接 if wire.r。
    local failed = wire.r ~= nil and wire.r ~= false and wire.r ~= 0
    if failed then return nil, false end
    if item == nil or item == JSON.null then return nil, true end
    if type(item) ~= "table" or item.paragraph_id == nil or tostring(item.paragraph_id) == "" then
        return nil, false
    end
    return { paragraph_id = tostring(item.paragraph_id) }, false
end

--- 章节正文里第一个能定位的段落。专栏进度记在这一章的 article 上。
---@param article table|nil
---@return string|nil
function Mapper.firstParagraphId(article)
    local posts = type(article) == "table" and article.posts or nil
    if type(posts) ~= "table" then return nil end
    for _pidx, post in ipairs(posts) do
        local contents = type(post) == "table" and post.contents or nil
        if type(contents) == "table" then
            for _bidx, block in ipairs(contents) do
                local kind = type(block) == "table" and block.type or nil
                if block.id ~= nil and kind == "paragraph" and paragraphText(block.data) ~= "" then
                    return tostring(block.id)
                end

            end
        end
    end
    return nil
end

--- 官网分段索引来自 posts[].contents[]，不是月读章节号。
---@param article table
---@param pid string
---@param end_pid string|nil
---@return table|nil
function Mapper.progressPosition(article, pid, end_pid)
    local reached = false
    for part_idx, post in ipairs(article.posts or {}) do
        for paragraph_idx, block in ipairs(post.contents or {}) do
            local id = block.id ~= nil and tostring(block.id) or nil
            if id == pid then reached = true end
            if reached and end_pid and id == end_pid then return nil end
            if reached and id and block.type == "paragraph" and paragraphText(block.data) ~= "" then
                return {
                    paragraph_id = id,
                    part_sequence = part_idx - 1,
                    part_paragraph_sequence = paragraph_idx - 1,
                }
            end
        end
    end
    return nil
end

---@param wire table
---@param begin_date string
---@param fetched_at number
---@return BookStatsPullResult|nil
---@return string|nil
function Mapper.readingStats(wire, begin_date, fetched_at)
    if type(wire) ~= "table" or wire.errors then return nil, _("响应无效") end
    local user = type(wire) == "table" and type(wire.data) == "table" and wire.data.user
    local total = type(user) == "table" and user.readingTimeTotal
    local history = type(user) == "table" and user.readingTimeHistory
    local function seconds(value)
        return type(value) == "number" and value >= 0 and value < math.huge and value or nil
    end
    if type(total) ~= "table" or not seconds(total.duration) or type(history) ~= "table"
        or (next(history) ~= nil and history[1] == nil) then return nil, _("响应无效") end
    local function midnight(date)
        if type(date) ~= "string" then return nil end
        local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        if not year then return nil end
        local time = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 0 })
        return time and os.date("%Y-%m-%d", time) == date and time or nil
    end
    local from = midnight(begin_date)
    if not from then return nil, _("响应无效") end
    local rows, seen = {}, {}
    local function row(id, kind, start_time, duration)
        if duration > 0 then
            rows[#rows + 1] = {
                source_id = SOURCE_ID, stable_id = id, record_type = kind,
                start_time = start_time, duration = duration, last_time = fetched_at,
                page = 0, total_pages = 0, event_count = 0,
            }
        end
    end
    row("__douban:total", "total", fetched_at, total.duration)
    for _idx, item in ipairs(history) do
        local date = type(item) == "table" and item.date
        local time = midnight(date)
        local reading = type(item) == "table" and item.readingTime
        local duration = type(reading) == "table" and seconds(reading.duration)
        if not time or not duration or time < from or time > fetched_at or seen[date] then
            return nil, _("响应无效")
        end
        seen[date] = true
        row("__douban:day:" .. date, "day", time, duration)
    end
    return {
        rows = rows,
        replace = { mode = "ranges", ranges = {
            { stable_prefix = "__douban:day:", from_ts = from, to_ts = fetched_at },
            { stable_prefix = "__douban:total", from_ts = 0, to_ts = fetched_at },
        } },
    }
end

return Mapper
