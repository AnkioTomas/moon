--[[--
刮削 UI 流程

用户确认书名 -> 搜索 -> 选择结果 -> 写 books 表 + 下封面 -> 通知属主源上行 -> 通知调用方刷新

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

--- 显示搜索结果选择页
---@param identity BookIdentity
---@param results table[]
---@param source string
---@param on_close fun()|nil
local function showResults(identity, results, source, on_close)
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
                if on_close then on_close() end
            end)
        end,
        close_callback = on_close,
    }
    page:show()
    -- 全屏页盖住详情页：不强制整屏刷新，只会有零星区域被重画
    UIManager:setDirty(page, "full")
end

--- 执行搜索。在飞句柄挂在 owner.scrape_job 上，owner 关闭时取消（连同「搜索中」提示）。
---@param identity BookIdentity
---@param query string
---@param on_close fun()|nil
---@param owner table
local function performSearch(identity, query, on_close, owner)
    local info = Toast:new{ text = _("搜索中...") }
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
            if on_close then on_close() end
            return
        end

        logger.info("scrape: got results from", source)
        showResults(identity, assert(results), assert(source), on_close)
    end)
    if job and not done then
        owner.scrape_job = { cancel = function()
            info:close()
            job.cancel()
        end }
    end
end

--- 启动刮削流程（调用方已按属主源确认可刮削）
---@param identity BookIdentity
---@param default_title string|nil 默认书名
---@param on_close fun()|nil 完成回调
---@param owner table 搜索句柄的持有者（详情页），关闭时调 owner.scrape_job.cancel()
function ScrapeUI.start(identity, default_title, on_close, owner)
    Input:new{
        title = _("确认书名"),
        fields = { { text = default_title or "", hint = _("请输入要搜索的书名") } },
        ok_text = _("搜索"),
        cancel_callback = on_close,
        callback = function(text)
            local query = Text.trim(text)
            if query == "" then
                Toast:new{
                    text = _("书名不能为空"),
                    timeout = 2,
                }:show()
                if on_close then on_close() end
                return
            end
            performSearch(identity, query, on_close, owner)
        end,
    }:show()
end

return ScrapeUI
