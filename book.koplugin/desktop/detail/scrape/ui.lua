--[[--
刮削 UI 流程

书名行 + 候选数据来源列表 -> 点来源搜索 -> 选择结果 -> 修改预览（逐行可取消）-> 写 books 表 + 下封面 -> 通知属主源上行 -> 通知调用方刷新

入口先过 SourceCapabilities.supportsScrape(source)，不支持就不显示按钮。封面先写 .part 再 rename。
写库用 upsertLocal，不走远端 upsert，免得盖掉本地脏元数据语义。

@module koplugin.book.desktop.detail.scrape.ui
--]]

local UIManager = require("ui/uimanager")
local Results = require("desktop.detail.scrape.results")
local Search = require("desktop.detail.scrape.search")
local Image = require("ui.themes.widgets.image")
local BookDB = require("book.books_db")
local Paths = require("utils.paths")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template
local Input = require("ui.themes.widgets.input")
local Toast = require("ui.themes.widgets.toast")
local List = require("ui.themes.widgets.list")

local ScrapeUI = {}

--- 换封面：先删旧封面，新图下载后移入本源封面缓存；books 表不存链接，UI 只认本地文件。
--- 结果没有封面时保留旧封面；下载失败则无封面，local 下次扫盘会从书内重新提取。
---@param identity BookIdentity
---@param url string
---@param headers table|nil 源站防盗链头（豆瓣必须带 Referer）
---@param done fun()
local function saveCover(identity, url, headers, done)
    if url == "" then
        done()
        return
    end
    local target = Paths.coverPath(identity.stable_id, identity.source_id)
    os.remove(target)
    Image.invalidate(target)
    Image.fetchAsync(url, headers, function(path, err)
        if not path then
            logger.warn("scrape cover download failed:", url, err)
            done()
            return
        end
        Paths.ensureLayout(identity.source_id)
        local ok, merr = os.rename(path, target)
        if not ok then
            logger.warn("scrape cover save failed:", path, merr)
        end
        done()
    end)
end

--- 刮削能改的字段（顺序即预览顺序）。old 取库里现值，new 取结果；same 判「实质没变」。
local function digits(v) return (v:gsub("[^%dXx]", "")):upper() end
local function year(v) return v:match("^%d%d%d%d") or v end
local FIELDS = {
    { key = "title", label = _("书名"), old = function(b) return b.title end, new = function(r) return r.title end },
    { key = "author", label = _("作者"), old = function(b) return b.authors end, new = function(r) return r.author end },
    { key = "intro", label = _("简介"), old = function(b) return b.intro end, new = function(r) return r.intro end },
    { key = "series", label = _("系列"), old = function(b) return b.series end, new = function(r) return r.series end },
    { key = "publisher", label = _("出版社"), old = function(b) return b.meta.publisher end,
        new = function(r) return r.publisher end },
    { key = "year", label = _("出版年份"), old = function(b) return b.meta.published end,
        new = function(r) return r.year end, norm = year },
    { key = "isbn", label = "ISBN", old = function(b) return b.meta.isbn end,
        new = function(r) return r.isbn end, norm = digits },
    { key = "rating", label = _("评分"),
        old = function(b) return b.meta.rating and string.format("%.1f", b.meta.rating.score) or "" end,
        new = function(r) return r.rating end },
}

--- 超长文本截成前 max 个字符加省略号（按 UTF-8 字符数）。
---@param s string
---@param max integer
---@return string
local function clip(s, max)
    s = s:gsub("%s+", " ")
    local n, pos = 0, 1
    for p in s:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > max then return s:sub(1, p - 1) .. "…" end
        pos = p --[[@as integer]]
    end
    return s
end

--- 对比库里现值与刮削结果，列出会变的字段（结果为空或与现值相同的不列）。
---@param existing table|nil
---@param result table
---@return { key: string, label: string, old: string, new: string }[]
local function diff(existing, result)
    local book = existing or {}
    book.meta = book.meta or {}
    local out = {}
    for _idx, f in ipairs(FIELDS) do
        local old, new = Text.trim(tostring(f.old(book) or "")), Text.trim(tostring(f.new(result) or ""))
        local norm = f.norm or function(v) return v end
        if new ~= "" and norm(old) ~= norm(new) then
            out[#out + 1] = { key = f.key, label = f.label, old = old, new = new }
        end
    end
    if result.cover_url ~= "" then
        out[#out + 1] = { key = "cover", label = _("封面"), old = "", new = _("更换为新封面") }
    end
    return out
end

--- 写 books 表 + 拉封面，两件事都落地后回调。只落 pick 里勾选的字段，其余保持库里现值。
---@param identity BookIdentity
---@param result table
---@param pick table<string, boolean>
---@param done fun(err: string|nil)
local function applyResult(identity, result, pick, done)
    -- 分类归本地目录/用户，刮削只补元数据，不覆盖
    local existing = BookDB.get(identity.source_id, identity.stable_id) or {}
    local function chosen(key, new, old)
        if pick[key] then return new end
        return old
    end
    local ok = BookDB.upsertLocal({
        source_id = identity.source_id,
        stable_id = identity.stable_id,
        title = chosen("title", result.title, existing.title or result.title),
        authors = chosen("author", result.author, existing.authors),
        intro = chosen("intro", result.intro, existing.intro),
        category = existing.category,
        series = chosen("series", result.series, existing.series),
        md5 = existing.md5,
        meta = {
            publisher = chosen("publisher", result.publisher),
            published = chosen("year", result.year),
            isbn = chosen("isbn", result.isbn),
            rating = pick.rating and { score = tonumber(result.rating), by = result.source } or nil,
        },
    })
    if not ok then
        done(_("元数据更新失败"))
        return
    end
    local function finish()
        require("source.registry").resolve(identity.source_id):onEvent("book_meta_changed", {
            identity = identity,
            cover = pick.cover == true,
        })
        done()
    end
    if pick.cover then
        saveCover(identity, result.cover_url, result.cover_headers, finish)
    else
        finish()
    end
end

--- 修改预览：逐行列出「字段：旧 → 新」，点行首 × 取消该项（再点恢复），首行「应用所选修改」落库，点面板外放弃。
---@param identity BookIdentity
---@param result table
---@param done fun()
local function showPreview(identity, result, done)
    local changes = diff(BookDB.get(identity.source_id, identity.stable_id), result)
    if #changes == 0 then
        Toast:new{ text = _("元数据已是最新，无需修改"), timeout = 2 }:show()
        return
    end
    local off = {}
    local preview

    local function apply()
        local pick, count = {}, 0
        for _idx, c in ipairs(changes) do
            if not off[c.key] then
                pick[c.key] = true
                count = count + 1
            end
        end
        if count == 0 then
            Toast:new{ text = _("没有选中任何修改"), timeout = 2 }:show()
            return
        end
        preview:close()
        applyResult(identity, result, pick, function(err)
            Toast:new{ text = err or _("元数据已更新"), timeout = 1.5 }:show()
            done()
        end)
    end

    local function build()
        local items = { { text = _("应用所选修改"), icon = "check", keep_open = true, callback = apply } }
        for _idx, c in ipairs(changes) do
            local line = c.old == "" and c.new or (clip(c.old, 12) .. " → " .. clip(c.new, 12))
            items[#items + 1] = {
                text = c.label .. "：" .. line,
                icon = off[c.key] and "undo" or "close",
                mandatory = off[c.key] and _("已取消") or nil,
                keep_open = true,
                callback = function()
                    off[c.key] = not off[c.key] or nil
                    preview:setItems(build())
                end,
            }
        end
        return items
    end

    preview = List:new{
        title = _("确认修改"),
        centered = true,
        items = build(),
    }
    preview:show()
end

--- 显示搜索结果选择页。取消回到来源列表（可换来源再搜），选中落库后 on_done。
---@param identity BookIdentity
---@param results table[]
---@param source string
---@param on_done fun()
local function showResults(identity, results, source, on_done)
    local page = Results:new{
        results = results,
        source = source,
        -- 选中后先预览改动，确认后落库与下封面都完成才通知调用方刷新
        on_pick = function(result)
            showPreview(identity, result, on_done)
        end,
    }
    page:show()
    -- 全屏页盖住来源列表：不强制整屏刷新，只会有零星区域被重画
    UIManager:setDirty(page, "full")
end

--- 执行搜索。在飞句柄挂在 owner.scrape_job 上，owner 关闭时取消（连同「搜索中」提示）。
--- 失败 / 无结果只提示，留在来源列表。
---@param identity BookIdentity
---@param query string
---@param owner table
---@param source_id string
---@param on_done fun()
local function performSearch(identity, query, owner, source_id, on_done)
    local info = require("ui.themes.widgets.progress_dialog"):new{
        title = _("搜索结果"), text = _("搜索中..."), dismissable = false,
    }
    info:show()

    local done = false
    local job = Search.searchAsync(query, source_id, function(results, err, source)
        done = true
        owner.scrape_job = nil
        info:close()

        if err then
            logger.warn("scrape search failed:", err)
            Toast:new{
                text = T(_("搜索失败: %1"), err),
                timeout = 2,
            }:show()
            return
        end

        logger.info("scrape: got results from", source)
        showResults(identity, assert(results), assert(source), on_done)
    end)
    if job and not done then
        owner.scrape_job = { cancel = function()
            info:close()
            job.cancel()
        end }
    end
end

--- 启动刮削流程（调用方已按属主源确认可刮削）：
--- 顶部一行是书名（点按改写），下面依次列出候选数据来源，点哪个搜哪个，取消结果页回到这里换下一个。
---@param identity BookIdentity
---@param default_title string|nil 默认书名
---@param on_close fun()|nil 结束回调（元数据已更新或直接关闭）
---@param owner table 搜索句柄的持有者（详情页），关闭时调 owner.scrape_job.cancel()
function ScrapeUI.start(identity, default_title, on_close, owner)
    local query = Text.trim(default_title or "")
    local list

    local function finish()
        list.close_callback = nil
        list:close()
        if on_close then on_close() end
    end

    local function search(source_id)
        if query == "" then
            Toast:new{ text = _("书名不能为空"), timeout = 2 }:show()
            return
        end
        performSearch(identity, query, owner, source_id, finish)
    end

    local function build()
        local items = { {
            text = _("书名"), icon = "search", mandatory = query ~= "" and query or _("点按输入"),
            chevron = true, keep_open = true,
            callback = function()
                Input:new{
                    title = _("确认书名"),
                    fields = { { text = query, hint = _("请输入要搜索的书名") } },
                    ok_text = _("确定"),
                    callback = function(text)
                        query = Text.trim(text)
                        list:setItems(build())
                    end,
                }:show()
            end,
        } }
        for _idx, src in ipairs(Search.SOURCES) do
            items[#items + 1] = { text = src.name, keep_open = true, callback = function() search(src.id) end }
        end
        return items
    end

    list = List:new{
        title = _("刮削"),
        subtitle = _("选择数据来源"),
        items = build(),
        close_callback = on_close,
    }
    list:show()
end

return ScrapeUI
