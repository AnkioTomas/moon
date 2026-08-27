--[[--
刮削 UI 流程

用户确认书名 -> 搜索 -> 选择结果 -> 写 books 表 + 下封面 -> 通知调用方刷新

@module koplugin.book.scrape.ui
--]]

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Results = require("scrape.results")
local Search = require("scrape.search")
local Image = require("ui.components.image")
local BookDB = require("utils.db.book")
local DbQueue = require("utils.db.queue")
local Paths = require("utils.paths")
local Text = require("utils.text")
local SourceCapabilities = require("types.book_source").SourceCapabilities
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ScrapeUI = {}

--- 原样复制文件（先写 .part 再改名，避免半截封面被读到）。
---@param from string
---@param to string
---@return boolean
local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then
        return false
    end
    local data = src:read("*a")
    src:close()
    local tmp = to .. ".part"
    local dst = io.open(tmp, "wb")
    if not dst then
        return false
    end
    dst:write(data)
    dst:close()
    os.remove(to)
    if os.rename(tmp, to) then
        return true
    end
    os.remove(tmp)
    return false
end

--- 下载封面并落进本源封面缓存；books 表不存链接，UI 只认本地文件。
---@param identity BookIdentity
---@param url string
---@param headers table|nil 源站防盗链头（豆瓣必须带 Referer）
---@param done fun()
local function saveCover(identity, url, headers, done)
    if url == "" then
        done()
        return
    end
    Image.fetchAsync(url, headers, function(path, err)
        if path then
            copyFile(path, Paths.coverPath(identity.stable_id, identity.source_id))
        else
            logger.warn("scrape cover download failed:", url, err)
        end
        done()
    end)
end

--- 写 books 表 + 拉封面，两件事都落地后回调。
---@param identity BookIdentity
---@param result table
---@param done fun()
local function applyResult(identity, result, done)
    DbQueue.run(function()
        -- 分类归本地目录/用户，刮削只补元数据，不覆盖
        local existing = BookDB.get(identity.source_id, identity.stable_id)
        BookDB.upsert({
            source_id = identity.source_id,
            stable_id = identity.stable_id,
            title = result.title,
            authors = result.author,
            intro = result.intro,
            category = existing and existing.category or nil,
            series = result.series,
            percent = existing and existing.percent or 0,
            favorite = existing and existing.favorite or nil,
            md5 = existing and existing.md5 or nil,
            fetched_at = os.time(),
        })
    end, {
        on_done = function()
            saveCover(identity, result.cover_url, result.cover_headers, done)
        end,
    })
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
        -- 选中后落库与下封面都是异步：全部完成才通知调用方刷新
        on_pick = function(result)
            applyResult(identity, result, function()
                UIManager:show(InfoMessage:new{
                    text = _("元数据已更新"),
                    timeout = 1.5,
                })
                if on_close then on_close() end
            end)
        end,
        close_callback = on_close,
    }
    UIManager:show(page)
    -- 全屏页盖住详情页：不强制整屏刷新，只会有零星区域被重画
    UIManager:setDirty(page, "full")
end

--- 执行搜索
---@param identity BookIdentity
---@param query string
---@param on_close fun()|nil
local function performSearch(identity, query, on_close)
    local info = InfoMessage:new{ text = _("搜索中...") }
    UIManager:show(info)

    Search.searchAsync(query, function(results, err, source)
        UIManager:close(info)

        if err then
            logger.warn("scrape search failed:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("搜索失败: %1"), err),
                timeout = 2,
            })
            if on_close then on_close() end
            return
        end

        logger.info("scrape: got results from", source)
        showResults(identity, results, source, on_close)
    end)
end

--- 启动刮削流程
---@param identity BookIdentity
---@param default_title string|nil 默认书名
---@param on_close fun()|nil 完成回调
function ScrapeUI.start(identity, default_title, on_close)
    if not identity or type(identity.source_id) ~= "string" or type(identity.stable_id) ~= "string" then
        logger.warn("scrape: invalid book identity")
        return
    end
    local src = require("source.registry").resolve(identity.source_id)
    if not SourceCapabilities.supportsScrape(src) then
        UIManager:show(InfoMessage:new{
            text = _("当前数据源不支持刮削"),
            timeout = 2,
        })
        if on_close then
            on_close()
        end
        return
    end

    local dialog
    dialog = InputDialog:new{
        title = _("确认书名"),
        input = default_title or "",
        input_hint = _("请输入要搜索的书名"),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if on_close then on_close() end
                end,
            },
            {
                text = _("搜索"),
                is_enter_default = true,
                callback = function()
                    local query = Text.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    if query == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("书名不能为空"),
                            timeout = 2,
                        })
                        if on_close then on_close() end
                        return
                    end
                    performSearch(identity, query, on_close)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return ScrapeUI
