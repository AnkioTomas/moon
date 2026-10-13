--[[--
BookOrbit 书源（整本模式）。走 BookOrbit 给 KOReader 插件开的接口（/api/v1/koreader/...）。

身份：书架一行 = 一本书，stable_id = BookOrbit bookId，分类 = 书库名。
书架：所选书库（未选 = 全部可访问书库）按书名分页拉全量，交书库对账。BookOrbit 没有删书接口，
  本地删除只留墓碑。
开书：详情里按格式偏好挑一个 KOReader 能开的文件，下载原件到工作目录 `<fileId>.<ext>`。
进度：kosync 兼容接口，文档摘要 = 本地文件的 partialMD5（服务端按它认文件，与 KOReader 自带
  kosync、BookOrbit 官方插件同一套）。位置：流式文档是 xpointer，固定版式是页码串。
划线：注解交换接口只做上传（keys 不全、不回 ack）：服务端不据此推断删除，网页上的改动也不落到本地。

@module moonsource_bookorbit.source
--]]

local Client = require("moonsource_bookorbit.client")
local SourceBase = require("source.base")
local _ = require("gettext")
local T = require("ffi/util").template

local ID = "ext.bookorbit"
local PAGE_SIZE = 100
local CHUNK = 50
local PLUGIN_VERSION = "moon-1.0"
-- 服务端已只给 primary / content 文件；按 KOReader 阅读体验排序，有声书等格式不在表里。
local READABLE = { "epub", "azw3", "azw", "mobi", "fb2", "docx", "pdf", "djvu", "cbz", "txt" }
local MAGIC = { epub = "PK\3\4", cbz = "PK\3\4", pdf = "%PDF" }
local DRAWERS = { lighten = true, underscore = true, strikeout = true, invert = true }
local DATETIME = "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"

---@class BookOrbitSource : SourceBase
---@field client BookOrbitClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return BookSourceMeta
local function meta()
    return { id = ID, name = _("BookOrbit"), type = "book" }
end

---@return BookOrbitSource
local function new()
    local self = setmetatable(meta(), Source) --[[@as BookOrbitSource]]
    self.client = Client.new(require("utils.settings").getSource(ID))
    return self
end

function Source:configured()
    return self.client:configured()
end

---@return boolean
local function online()
    return require("ui/network/manager"):isConnected()
end

--- 与 KOReader 自带 kosync / BookOrbit 官方插件共用设备 id，服务端设备列表里是同一台；
--- 没有时（或不合服务端格式）自己生成一个存进源配置。
---@return string
local function deviceId()
    local reader = rawget(_G, "G_reader_settings")
    local id = reader and reader:readSetting("device_id")
    if type(id) == "string" and #id <= 100 and id:match("^[%w%-]+$") then return id end
    local settings = require("utils.settings")
    local cfg = settings.getSource(ID)
    if not cfg.device_id then
        cfg.device_id = require("ffi/sha2").md5(table.concat({ os.time(), math.random(), tostring({}) }, ":"))
        settings.saveSource(ID, cfg)
    end
    return cfg.device_id --[[@as string]]
end

---@return string
local function deviceModel()
    local device = package.loaded["device"]
    local model = type(device) == "table" and type(device.model) == "string" and device.model or "KOReader"
    return model:sub(1, 100)
end

---@param list any
---@return string|nil
local function authorsOf(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    return table.concat(list, " / ")
end

--- 文件头对得上格式才算下载完整；没有魔数的格式只要求非空。
---@param path string|nil
---@return boolean
local function validFile(path)
    local file = path and io.open(path, "rb")
    if not file then return false end
    local head = file:read(4)
    file:close()
    if not head then return false end
    local magic = MAGIC[(path:match("%.(%w+)$") or ""):lower()]
    return magic == nil or head == magic
end

--- 已登记且完整的本地文件。
---@param stable_id string
---@return string|nil
local function downloaded(stable_id)
    local book = require("book.books_db").get(ID, stable_id)
    local path = book and book.path
    if validFile(path) then return path end
    return nil
end

--- 服务端认文件用的摘要；没下载就没有。
---@param stable_id string
---@return string|nil
local function digestOf(stable_id)
    local path = downloaded(stable_id)
    return path and require("util").partialMD5(path) --[[@as string]]
end

---@param files table[]|nil
---@return table|nil
local function pickFile(files)
    for _fidx, format in ipairs(READABLE) do
        for _idx, file in ipairs(files or {}) do
            if type(file.format) == "string" and file.format:lower() == format then return file end
        end
    end
    return nil
end

--- 插件接口要求的设备字段（deviceTime 让服务端按设备时钟生成 datetime）。
---@param body table
---@return table
local function withDevice(body)
    body.deviceId = deviceId()
    body.deviceModel = deviceModel()
    body.pluginVersion = PLUGIN_VERSION
    body.deviceTime = os.date("%Y-%m-%d %H:%M:%S")
    return body
end

--- 书架：书库列表 → 逐库按书名分页拉书 → 对账。没有删书接口，dirty_only 跳过。
---@param opts { dirty_only?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then return SourceBase.skipped(cb, "no remote delete") end
    if not self:configured() then
        return SourceBase.defer(cb, nil, _("请先在设置里填写 BookOrbit 服务器和账号"))
    end
    local chosen = require("utils.settings").getSource(ID).libraries or {}
    local report = opts.on_progress or function() end
    local books, libraries, index, page, cancelled = {}, {}, 1, 1, false
    ---@type HttpJob
    local job

    local function fetch()
        local library = libraries[index]
        report(T(_("正在拉取书架（%1 本）"), #books))
        job = self.client:json("GET", "/koreader/plugin/catalog/books",
            { libraryId = library.id, page = page, size = PAGE_SIZE, sort = "title", order = "asc" }, nil,
            function(data, err)
                if cancelled then return end
                if not data then return cb(nil, err) end
                for _idx, item in ipairs(data.items or {}) do
                    books[#books + 1] = {
                        stable_id = tostring(item.id),
                        title = item.title,
                        authors = authorsOf(item.authors),
                        series = item.seriesName,
                        category = library.title,
                    }
                end
                if data.hasNext == true then
                    page = page + 1
                elseif index < #libraries then
                    index, page = index + 1, 1
                else
                    return cb(require("source.shelf").reconcile(self.id, books))
                end
                fetch()
            end)
    end

    job = self.client:json("GET", "/koreader/plugin/catalog/sections/libraries", nil, nil, function(data, err)
        if cancelled then return end
        if not data then return cb(nil, err) end
        for _idx, entry in ipairs(data.items or {}) do
            if next(chosen) == nil or chosen[tostring(entry.id)] then libraries[#libraries + 1] = entry end
        end
        -- 一个库都没有时不能拿空列表对账：那会把整个书架判成远端已删。
        if #libraries == 0 then return cb(nil, _("BookOrbit 上没有可同步的书库，请检查书库选择")) end
        fetch()
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- KoreaderCatalogBookDetail → 书库行。rating 是用户自己打的分，不是公共评分，不收。
---@param id string 源 id
---@param stable_id string
---@param detail table
---@return Book
local function detailRow(id, stable_id, detail)
    return {
        source_id = id, stable_id = stable_id, title = detail.title,
        authors = authorsOf(detail.authors), intro = detail.description, series = detail.seriesName,
        meta = {
            publisher = detail.publisher, published = detail.publishedDate or detail.publishedYear,
            language = detail.language, isbn = detail.isbn13 or detail.isbn10,
        },
    }
end

--- 详情：写回作者 / 简介 / 系列 / 扩展元数据，回调原始详情（开书要 files）。
---@param stable_id string
---@param cb fun(detail: table|nil, err: string|nil)
---@return HttpJob
function Source:detail(stable_id, cb)
    return self.client:json("GET", "/koreader/plugin/catalog/books/" .. stable_id, { deviceId = deviceId() }, nil,
        function(detail, err)
            if not detail then return cb(nil, err) end
            require("book.store").rememberMany({ detailRow(self.id, stable_id, detail) })
            cb(detail)
        end)
end

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getDetailAsync(identity, cb)
    return self:detail(identity.stable_id, function(detail, err)
        if not detail then return cb(nil, err) end
        cb(detailRow(self.id, identity.stable_id, detail))
    end)
end

--- 下载到 `<工作目录>/<fileId>.<ext>.part`，完整后改名并登记路径：中途断掉不会留下半个文件被当成已下载。
---@param identity BookIdentity
---@param file table KoreaderCatalogFile
---@param title string|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchFile(identity, file, title, cb)
    local Paths = require("utils.paths")
    Paths.ensureBookWork(identity.stable_id, self.id)
    local path = T("%1/%2.%3", Paths.bookWorkDir(identity.stable_id, self.id), file.id, file.format:lower())
    local part = path .. ".part"
    local dialog = require("ui.themes.widgets.progress_dialog"):new{ title = title, dismissable = false }
    dialog:show()
    dialog:set(_("正在下载…"))
    local job = self.client:download(file.id, part, function(bytes, total)
        total = total or tonumber(file.sizeBytes)
        if total and total > 0 then dialog:bytes(bytes, total) end
    end, function(ok, err)
        dialog:close()
        if not ok then
            os.remove(part)
            return cb(nil, err or _("下载失败"))
        end
        if not os.rename(part, path) or not validFile(path) then
            os.remove(part)
            os.remove(path)
            return cb(nil, _("下载文件校验失败"))
        end
        local registered, rerr = require("book.store").touch(path, identity)
        cb(registered and path or nil, rerr)
    end)
    return { cancel = function()
        job:cancel()
        dialog:close()
    end }
end

--- 打开：已下载的直接开（不联网）；否则取详情挑文件下载。
function Source:openBookAsync(identity, _opts, cb)
    local path = downloaded(identity.stable_id)
    if path then return SourceBase.defer(cb, path) end
    if not online() then return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi")) end
    local cancelled = false
    ---@type { cancel: fun() }
    local job
    local function finish(file, err)
        if not cancelled then cb(file, err) end
    end
    job = self:detail(identity.stable_id, function(detail, err)
        if cancelled then return end
        if not detail then return finish(nil, err) end
        local file = pickFile(detail.files)
        if not file then return finish(nil, _("这本书没有 KOReader 能打开的文件")) end
        job = self:fetchFile(identity, file, detail.title, finish)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    if not self:configured() then return nil, _("未配置") end
    return {
        url = self.client:url("/koreader/plugin/catalog/books/" .. identity.stable_id .. "/thumbnail"),
        headers = self.client:headers(),
    }
end

--- kosync 进度 → 月读位置；与本地同一 xpointer / 页时交回本地行（不算冲突）。
---@param stable_id string
---@param remote { percentage: number, progress: string|nil, timestamp: number|nil }
---@return ProgressPosition
local function position(stable_id, remote)
    local progress = type(remote.progress) == "string" and remote.progress or ""
    local page = tonumber(progress)
    local here = require("book.progress_db").get(ID, stable_id)
    if here and ((progress ~= "" and here.locator == progress) or (page and here.page == page)) then
        return here
    end
    return {
        fraction = math.max(0, math.min(1, tonumber(remote.percentage) or 0)),
        locator = progress:sub(1, 1) == "/" and progress or nil,
        page = page and math.floor(page) or nil,
        updated_at = tonumber(remote.timestamp),
    }
end

function Source:getProgressAsync(identity, cb)
    local digest = digestOf(identity.stable_id)
    if not digest then return SourceBase.defer(cb, nil, nil, { empty = true }) end
    return self.client:json("GET", "/koreader/syncs/progress/" .. digest, nil, nil, function(remote, err)
        if not remote then return cb(nil, err) end
        -- 服务端没有这本书或没有进度都回 {}。
        if type(remote.percentage) ~= "number" then return cb(nil, nil, { empty = true }) end
        cb(position(identity.stable_id, remote))
    end)
end

--- 月读位置 → kosync：流式文档推 xpointer，固定版式推页码。timestamp 用进度自己的时间，
--- 服务端会丢弃比已知更旧的推送，离线攒下的旧进度不会盖掉别处更新的位置。
function Source:putProgressAsync(identity, pos, cb)
    local digest = digestOf(identity.stable_id)
    if not digest then return SourceBase.defer(cb, nil, _("这本书还没下载，无法同步")) end
    return self.client:json("PUT", "/koreader/syncs/progress", nil, {
        document = digest,
        percentage = math.max(0, math.min(1, tonumber(pos.fraction) or 0)),
        progress = pos.locator or (pos.page and tostring(pos.page)) or nil,
        device = deviceModel(),
        device_id = deviceId(),
        timestamp = pos.updated_at or os.time(),
    }, function(data, err, code)
        if code == 404 then return cb(nil, _("BookOrbit 不认识本地这个文件，可能服务端的书已更换")) end
        cb(data and true, err)
    end)
end

--- 按 UTF-8 字符边界截断（服务端按字符数限长；截成半个字符整块请求会被拒）。
---@param s any
---@param max integer
---@return string|nil
local function cut(s, max)
    if type(s) ~= "string" then return nil end
    if #s <= max then return s end
    local out = s:sub(1, max)
    local next_byte = s:byte(max + 1)
    if next_byte >= 0x80 and next_byte < 0xC0 then
        out = out:gsub("[\192-\255][\128-\191]*$", "")
    end
    return out
end

--- 位置序列化与官方插件一致：服务端注解键 = md5(datetime|pos0)，写法不同就会重复建。
---@param pos any
---@return string|nil, string|nil
local function serializePos(pos)
    if type(pos) == "string" then return pos, "xpointer" end
    if type(pos) == "table" and type(pos.page) == "number" then
        return string.format('{"page":%d,"x":%.2f,"y":%.2f}', pos.page, tonumber(pos.x) or 0, tonumber(pos.y) or 0), "pdf"
    end
    return nil
end

---@param value any
---@return string|nil
local function datetime(value)
    return type(value) == "string" and value:match(DATETIME) and value or nil
end

--- 月读注解快照 → 服务端 KoreaderAnnotationDto；书签（无 drawer）不传。
---@param annotations table[]
---@return table[]
local function changesOf(annotations)
    local out = {}
    for _idx, ann in ipairs(annotations) do
        local pos0, format = serializePos(ann.pos0)
        if DRAWERS[ann.drawer] and datetime(ann.datetime) and pos0 then
            out[#out + 1] = {
                datetime = ann.datetime,
                datetimeUpdated = datetime(ann.datetime_updated),
                drawer = ann.drawer,
                color = cut(ann.color, 30),
                text = cut(ann.text, 10000),
                note = cut(ann.note, 5000),
                chapter = cut(ann.chapter, 500),
                pageno = type(ann.pageno) == "number" and ann.pageno >= 0 and math.floor(ann.pageno) or nil,
                posFormat = format,
                pos0 = cut(pos0, 4000),
                pos1 = cut((serializePos(ann.pos1)), 4000),
            }
        end
    end
    return out
end

--- 划线整份上传（服务端按 datetime|pos0 去重，重传是空操作），每次 50 条。
--- keysComplete = false：不让服务端拿这份清单推断「设备删了哪些」；服务端回传的改动不 ack，留在服务端。
---@param identity BookIdentity
---@param annotations table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:pushNotesAsync(identity, annotations, cb)
    local digest = digestOf(identity.stable_id)
    if not digest then return SourceBase.defer(cb, nil, _("这本书还没下载，无法同步")) end
    local pending = changesOf(annotations)
    if #pending == 0 then return SourceBase.defer(cb, true) end
    local cursor, cancelled = 1, false
    ---@type HttpJob
    local job
    local function nextChunk()
        if cursor > #pending then return cb(true) end
        local chunk = {}
        for idx = cursor, math.min(cursor + CHUNK - 1, #pending) do chunk[#chunk + 1] = pending[idx] end
        cursor = cursor + #chunk
        job = self.client:json("POST", "/koreader/plugin/annotations/exchange", nil, withDevice({
            -- 空表默认编码成 {}，服务端要数组。
            books = { { hash = digest, keys = require("json").util.InitArray({}), keysComplete = false, changes = chunk } },
        }), function(data, err)
            if cancelled then return end
            if not data then return cb(nil, err) end
            for _idx, hash in ipairs(data.unmatched or {}) do
                if hash == digest then return cb(nil, _("BookOrbit 不认识本地这个文件，可能服务端的书已更换")) end
            end
            nextChunk()
        end)
    end
    nextChunk()
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return { meta = meta, new = new, ID = ID }
