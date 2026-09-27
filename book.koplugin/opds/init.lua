--[[--
OPDS 书城：浏览导航 feed、搜索、下载，并导入本地书库。
与 zlib 同一套书城门面（listStoreAsync / installAsync），不是 BookSource。

@module koplugin.book.opds
--]]

local Client = require("opds.client")
local Mapper = require("opds.mapper")
local Paths = require("utils.paths")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Opds = {}

-- 顺着 rel="next" 最多拉这么多页凑满一屏结果，防止服务端 next 链成环或过长。
local MAX_PAGES = 10

--- 用当前持久化配置创建一次性客户端。
---@return OpdsClient
local function client()
    return Client.new(require("utils.settings").getSource("opds"))
end

---@param err any
---@param res table|nil
---@return any
local function errText(err, res)
    local code = res and tonumber(res.code)
    if code == 401 or code == 403 then return _("OPDS 认证失败，请检查用户名和密码") end
    return err
end

--- 拉取 feed 条目。opts.feed 缺省为目录根；opts.search 非空时走根目录的搜索模板。
--- 条目是书籍与导航项混排（导航项 { title, feed }，点开把 feed 传回来即下钻）。
---@param opts { feed?: string, search?: string, page_size?: integer }|nil
---@param cb fun(data: { data: table[], count: integer, title: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Opds:listStoreAsync(opts, cb)
    opts = opts or {}
    local api = client()
    if not api:configured() then
        cb(nil, _("未配置 OPDS 目录"))
        return nil
    end
    local limit = tonumber(opts.page_size) or 200
    local cancelled, job = false, nil
    local items, visited, pages, title = {}, {}, 0, nil

    --- 发一个 GET；缓存命中会同步回调，此时不能再把已结束的句柄挂回 job。
    ---@param url string
    ---@param handler fun(body: string)
    local function get(url, handler)
        local settled = false
        local this = api:getAsync(url, function(body, err, res)
            settled = true
            job = nil
            if cancelled then return end
            if not body then
                logger.warn("book.opds request failed", err)
                cb(nil, errText(err, res))
                return
            end
            handler(body)
        end)
        if not settled then job = this end
    end

    ---@param url string
    local function collect(url)
        visited[url] = true
        pages = pages + 1
        get(url, function(body)
            local feed, err = Mapper.feed(body, url)
            if not feed then cb(nil, err); return end
            title = title or feed.title
            for _i, item in ipairs(feed.items) do
                if #items >= limit then break end
                item.cover_headers = api:coverHeaders(item.cover_url)
                items[#items + 1] = item
            end
            local next_url = feed.next
            if #items < limit and next_url and not visited[next_url] and pages < MAX_PAGES then
                collect(next_url)
                return
            end
            cb({ data = items, count = #items, title = title })
        end)
    end

    local query = Text.trim(opts.search)
    if query == "" then
        collect(opts.feed or api:rootUrl())
    else
        local root = api:rootUrl()
        get(root, function(body)
            local feed, err = Mapper.feed(body, root)
            if not feed then cb(nil, err); return end
            if feed.search_template then
                collect(Mapper.searchUrl(feed.search_template, query))
            elseif feed.search_osd then
                get(feed.search_osd, function(osd)
                    local template = Mapper.searchTemplate(osd, feed.search_osd)
                    if not template then cb(nil, _("该 OPDS 目录不支持搜索")); return end
                    collect(Mapper.searchUrl(template, query))
                end)
            else
                cb(nil, _("该 OPDS 目录不支持搜索"))
            end
        end)
    end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 从书籍元数据构造可在所有导入源落盘的文件名。
---@param book Book
---@return string
local function safeFilename(book)
    local title = tostring(book.title or _("未知书名")):gsub("[/\\?%%*:|\"<>%c]", "_")
    local author = tostring(book.authors or ""):gsub("[/\\?%%*:|\"<>%c]", "_")
    local stem = author ~= "" and (title .. " - " .. author) or title
    return stem .. "." .. book.format
end

--- 会话过期的服务端常对下载链接回 200 登录页；书籍格式里没有以 HTML 文档头开始的。
---@param path string
---@return boolean
local function isHtmlPage(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local s = (f:read(64) or ""):lower()
    f:close()
    return s:match("^%s*<!doctype html") ~= nil or s:match("^%s*<html") ~= nil
end

--- 下载书籍到工作目录后导入 source；取消时终止当前任务并删除临时文件。
---@param source BookSource|nil
---@param book Book|nil
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, err: string|nil, filename: string|nil)
---@return { cancel: fun() }|nil
function Opds.installAsync(source, book, on_progress, cb)
    if not (source and type(source.importBookAsync) == "function") then
        cb(nil, _("当前数据源不支持导入书籍"))
        return nil
    end
    if not (book and book.download and book.format) then
        cb(nil, _("没有本地书库支持的下载格式"))
        return nil
    end
    local filename = safeFilename(book)
    Paths.ensureBookWork(book.stable_id, "opds")
    local temp = Paths.bookWorkDir(book.stable_id, "opds") .. "/" .. filename
    local cancelled, job = false, nil
    logger.dbg("book.opds install start", book.stable_id, book.format)
    job = client():downloadAsync(book.download, temp, on_progress, function(ok, err, res)
        if cancelled then return end
        if not ok then
            logger.warn("book.opds install failed", book.stable_id, "download", err)
            cb(nil, errText(err, res))
            return
        end
        if isHtmlPage(temp) then
            os.remove(temp)
            cb(nil, _("下载内容不是书籍文件"))
            return
        end
        job = source:importBookAsync(temp, filename, function(imported, import_err)
            os.remove(temp)
            if cancelled then return end
            if not imported then
                logger.warn("book.opds install failed", book.stable_id, "import", import_err)
            end
            cb(imported, import_err, filename)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
        os.remove(temp)
    end }
end

return Opds
