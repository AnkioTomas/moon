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

local function client()
    return Client.new(require("utils.settings").getSource("zlib"))
end

function Zlib.configured()
    return true
end

function Zlib.hasCredentials()
    local cfg = require("utils.settings").getSource("zlib")
    return (cfg.email or "") ~= "" and (cfg.password or "") ~= ""
end

function Zlib.pingAsync(cb)
    return client():pingAsync(cb)
end

function Zlib:listStoreAsync(opts, cb)
    opts = opts or {}
    local api = client()
    local query = opts.search or ""
    if query ~= "" then
        return api:searchAsync(query, opts.page or 1, opts.page_size or 12, function(wire, err)
            if wire then cb(Mapper.list(wire)) else cb(nil, err) end
        end)
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

function Zlib.getDetailAsync(book, cb)
    local ref = book and book.ref
    local id, hash = Mapper.parse(ref and ref.stable_id)
    if not id then cb(nil, _("无效书籍身份")); return nil end
    return client():detailAsync(id, hash, function(row, err)
        if not row then cb(nil, err); return end
        local detail = Mapper.book(row)
        if not detail then cb(nil, _("详情为空")); return end
        detail.ref = ref
        cb(detail)
    end)
end

local function safeFilename(book)
    local title = tostring(book.title or _("未知书名")):gsub("[/\\?%%*:|\"<>%c]", "_")
    local author = tostring(book.authors or ""):gsub("[/\\?%%*:|\"<>%c]", "_")
    local ext = tostring(book.format or "epub"):lower():gsub("[^%w]", "")
    if ext == "" or #ext > 8 then ext = "epub" end
    local stem = author ~= "" and (title .. " - " .. author) or title
    return stem .. "." .. ext
end

function Zlib.installAsync(source, book, on_progress, cb)
    if not source or type(source.importBookAsync) ~= "function" then
        cb(nil, _("当前数据源不支持导入书籍"))
        return nil
    end
    local id, hash = Mapper.parse(book and book.ref and book.ref.stable_id)
    if not id then cb(nil, _("无效书籍身份")); return nil end
    local api, cancelled, job = client(), false, nil
    local result = {}
    function result.cancel()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end
    local function run(detail)
        local filename = safeFilename(detail)
        Paths.ensureBookWork(detail.ref.stable_id, "zlib")
        local temp = Paths.bookWorkDir(detail.ref.stable_id, "zlib") .. "/" .. filename .. ".part"
        job = api:downloadAsync(id, hash, temp, on_progress, function(ok, err)
            if cancelled then pcall(os.remove, temp); return end
            if not ok then cb(nil, err); return end
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
            detail.ref = book.ref
            run(detail)
        end)
    end
    return result
end

return Zlib
