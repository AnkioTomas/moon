--[[--
刮削 UI 流程

书名行 + 候选数据来源列表 -> 点来源搜索 -> 选择结果 -> 写 books 表 + 下封面 -> 通知属主源上行 -> 通知调用方刷新

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

--- 写 books 表 + 拉封面，两件事都落地后回调。
---@param identity BookIdentity
---@param result table
---@param done fun(err: string|nil)
local function applyResult(identity, result, done)
    -- 分类归本地目录/用户，刮削只补元数据，不覆盖
    local existing = BookDB.get(identity.source_id, identity.stable_id)
    local ok = BookDB.upsertLocal({
        source_id = identity.source_id,
        stable_id = identity.stable_id,
        title = result.title,
        authors = result.author,
        intro = result.intro,
        category = existing and existing.category or nil,
        series = result.series,
        md5 = existing and existing.md5 or nil,
        meta = {
            publisher = result.publisher,
            published = result.year,
            isbn = result.isbn,
            rating = { score = result.rating, by = result.source },
        },
    })
    if not ok then
        done(_("元数据更新失败"))
        return
    end
    saveCover(identity, result.cover_url, result.cover_headers, function()
        require("source.registry").resolve(identity.source_id):onEvent("book_meta_changed", {
            identity = identity,
            cover = result.cover_url ~= "",
        })
        done()
    end)
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
        -- 选中后落库与下封面都完成才通知调用方刷新
        on_pick = function(result)
            applyResult(identity, result, function(err)
                Toast:new{
                    text = err or _("元数据已更新"),
                    timeout = 1.5,
                }:show()
                on_done()
            end)
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
---@param source_id string|nil 空 = 自动（豆瓣 → 微信读书）
---@param on_done fun()
local function performSearch(identity, query, owner, source_id, on_done)
    local info = require("ui.themes.widgets.progress_dialog"):new{
        title = _("搜索结果"), text = _("搜索中..."), dismissable = false,
    }
    info:show()

    local done = false
    local job = Search.searchAsync(query, function(results, err, source)
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
    end, source_id)
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
        }, { text = _("自动（豆瓣 → 微信读书）"), keep_open = true, callback = function() search(nil) end } }
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
