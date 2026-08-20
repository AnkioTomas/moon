--[[--
全局默认书城：Z-Library 浏览、搜索、详情、下载，并导入当前数据源。
不是 BookSource；BookSource 只负责书库持久化目标。

@module koplugin.book.zlib
--]]

local Client = require("zlib.client")
local Mapper = require("zlib.mapper")
local Paths = require("utils.paths")
local _ = require("gettext")

local Zlib = {}

-- KOReader 界面语言代码 -> Z-Library 搜索语言键。
local STORE_LANGUAGES = {
    ar = "arabic", bg = "bulgarian", bn = "bengali", ca = "catalan",
    cs = "czech", da = "danish", de = "german", el = "greek",
    en = "english", eo = "esperanto", es = "spanish", eu = "basque",
    fa = "persian", fi = "finnish", fr = "french", ga = "irish",
    gl = "galician", he = "hebrew", hi = "hindi", hr = "croatian",
    hu = "hungarian", id = "indonesian", it = "italian", ja = "japanese",
    ka = "georgian", kk = "kazakh", ko = "korean", lt = "lithuanian",
    lv = "latvian", ml = "malayalam", nb = "norwegian_bokmal", nl = "dutch",
    pl = "polish", pt = "portuguese", ro = "romanian", ru = "russian",
    sk = "slovak", sl = "slovenian", sr = "serbian", sv = "swedish",
    th = "thai", tr = "turkish", uk = "ukrainian", vi = "vietnamese",
    zh = "chinese",
}

local STORE_LANGUAGE_OVERRIDES = {
    C = "english",
    nb_NO = "norwegian_bokmal",
    pt_BR = "brazilian",
    zh_TW = "traditional chinese",
    ["zh_TW.Big5"] = "traditional chinese",
}

--- 由当前 KOReader 界面语言推导 Z-Library 默认搜索语言。
---@return string|nil
local function storeLanguage()
    local lang = tostring(_.current_lang or "C"):gsub("%.utf8$", ""):gsub("%.UTF%-8$", "")
    return STORE_LANGUAGE_OVERRIDES[lang] or STORE_LANGUAGES[lang:match("^([a-z][a-z])")]
end

--- 用当前持久化配置创建一次性 API 客户端。
---@return table
local function client()
    return Client.new(require("utils.settings").getSource("zlib"))
end

--- 判断当前配置能否发起下载登录。
---@return boolean
function Zlib.hasCredentials()
    return client():hasCredentials()
end

--- 拉取全局书城；无关键词时优先使用界面语言，未知语言才回退热门榜。
---@param opts BookListOpts|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Zlib:listStoreAsync(opts, cb)
    opts = opts or {}
    local api = client()
    local query = opts.search or ""
    local language = query == "" and storeLanguage() or nil
    if query ~= "" or language then
        return api:searchAsync(query, opts.page or 1, opts.page_size or 12, function(wire, err)
            if wire then cb(Mapper.list(wire)) else cb(nil, err) end
        end, language)
    end
    return api:listPopularAsync(function(wire, err)
        if not wire then cb(nil, err); return end
        local all = Mapper.list(wire)
        local page, page_size = tonumber(opts.page) or 1, tonumber(opts.page_size) or 12
        local first, books = (page - 1) * page_size + 1, {}
        for i = first, math.min(#all.data, first + page_size - 1) do books[#books + 1] = all.data[i] end
        cb({ data = books, count = #all.data })
    end)
end

--- 用书城条目的稳定身份拉取并归一化完整详情。
---@param book Book|nil
---@param cb fun(data: Book|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Zlib.getDetailAsync(book, cb)
    local id, hash = Mapper.parse(book and book.stable_id)
    if not id then cb(nil, _("无效书籍身份")); return nil end
    return client():detailAsync(id, hash, function(row, err)
        if not row then cb(nil, err); return end
        local detail = Mapper.book(row)
        if not detail then cb(nil, _("详情为空")); return end
        cb(detail)
    end)
end

--- 从书籍元数据构造可在所有导入源落盘的文件名。
---@param book Book
---@return string
local function safeFilename(book)
    local title = tostring(book.title or _("未知书名")):gsub("[/\\?%%*:|\"<>%c]", "_")
    local author = tostring(book.authors or ""):gsub("[/\\?%%*:|\"<>%c]", "_")
    local ext = tostring(book.format or "epub"):lower():gsub("[^%w]", "")
    if ext == "" or #ext > 8 then ext = "epub" end
    local stem = author ~= "" and (title .. " - " .. author) or title
    return stem .. "." .. ext
end

--- 下载书城书到工作目录后导入当前源；取消时终止当前任务并删除临时文件。
---@param source BookSource|nil
---@param book Book|nil
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, err: string|nil, filename: string|nil)
---@return { cancel: fun() }|nil
function Zlib.installAsync(source, book, on_progress, cb)
    if not source or type(source.importBookAsync) ~= "function" then
        cb(nil, _("当前数据源不支持导入书籍"))
        return nil
    end
    local id, hash = Mapper.parse(book and book.stable_id)
    if not id then cb(nil, _("无效书籍身份")); return nil end
    local api, cancelled, job, temp = client(), false, nil, nil
    local result = {}
    function result.cancel()
        cancelled = true
        if job and job.cancel then job.cancel() end
        if temp then pcall(os.remove, temp) end
    end
    --- 使用完整详情确定扩展名和临时路径，再启动下载。
    ---@param detail Book
    local function run(detail)
        local filename = safeFilename(detail)
        Paths.ensureBookWork(detail.stable_id, "zlib")
        temp = Paths.bookWorkDir(detail.stable_id, "zlib") .. "/" .. filename .. ".part"
        job = api:downloadAsync(id, hash, temp, on_progress, function(ok, err)
            if cancelled then pcall(os.remove, temp); return end
            if not ok then pcall(os.remove, temp); cb(nil, err); return end
            job = source:importBookAsync(temp, filename, function(imported, import_err)
                pcall(os.remove, temp)
                if not cancelled then cb(imported, import_err, filename) end
            end)
        end)
    end
    if book.format and book.format ~= "" then run(book) else
        job = api:detailAsync(id, hash, function(row, err)
            if cancelled then return end
            if not row then cb(nil, err); return end
            local detail = Mapper.book(row)
            if not detail then cb(nil, _("详情为空")); return end
            run(detail)
        end)
    end
    return result
end

return Zlib
