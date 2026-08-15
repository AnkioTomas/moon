--[[--
刮削 UI 流程

用户确认书名 -> 搜索 -> 选择结果 -> 写入 books 表

@module koplugin.book.scrape.ui
--]]

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Popup = require("ui.components.popup")
local Search = require("scrape.search")
local BookDB = require("utils.db.book")
local DbQueue = require("utils.db.queue")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ScrapeUI = {}

--- 格式化搜索结果为显示文本
---@param result table
---@return string
local function formatResult(result)
    local parts = {}
    if result.title and result.title ~= "" then
        parts[#parts + 1] = result.title
    end
    if result.author and result.author ~= "" then
        parts[#parts + 1] = "作者: " .. result.author
    end
    if result.rating and result.rating ~= "" then
        parts[#parts + 1] = "评分: " .. result.rating
    end
    if result.year and result.year ~= "" then
        parts[#parts + 1] = result.year
    end
    if result.publisher and result.publisher ~= "" then
        parts[#parts + 1] = result.publisher
    end
    if result.source then
        local source_name = result.source == "douban" and "豆瓣" or "微信读书"
        parts[#parts + 1] = "[" .. source_name .. "]"
    end
    return table.concat(parts, " · ")
end

--- 将搜索结果写入 books 表
---@param book_key string
---@param source_id string
---@param stable_id string
---@param result table
local function saveToBooks(book_key, source_id, stable_id, result)
    DbQueue.run(function()
        local tags = result.tags
        local category = ""
        if type(tags) == "table" and #tags > 0 then
            category = table.concat(tags, ",")
        end

        BookDB.upsert({
            book_key = book_key,
            source_id = source_id,
            stable_id = stable_id,
            title = result.title,
            authors = result.author,
            intro = result.intro or result.full_intro,
            category = category ~= "" and category or nil,
            series = result.series,
            fetched_at = os.time(),
        })
    end)
end

--- 显示搜索结果选择对话框
---@param ref BookRef
---@param results table[]
---@param on_close fun()|nil
local function showResults(ref, results, on_close)
    if not results or #results == 0 then
        UIManager:show(InfoMessage:new{
            text = _("未找到匹配的书籍"),
            timeout = 2,
        })
        if on_close then on_close() end
        return
    end

    local items = {}
    for _, result in ipairs(results) do
        local item = {
            text = formatResult(result),
            callback = function()
                saveToBooks(ref.book_key, ref.source_id, ref.stable_id, result)
                UIManager:show(InfoMessage:new{
                    text = _("元数据已更新"),
                    timeout = 1.5,
                })
                if on_close then on_close() end
            end,
        }
        if result.cover_url and result.cover_url ~= "" then
            item.image = result.cover_url
            item.image_w = 60
            item.image_h = 80
        end
        items[#items + 1] = item
    end

    Popup.list{
        title = _("选择匹配的书籍"),
        items = items,
        close_callback = on_close,
    }
end

--- 执行搜索
---@param ref BookRef
---@param query string
---@param on_close fun()|nil
local function performSearch(ref, query, on_close)
    local info = UIManager:show(InfoMessage:new{
        text = _("搜索中..."),
    })

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

        if source then
            local source_name = source == "douban" and "豆瓣" or "微信读书"
            logger.info("scrape: got results from", source_name)
        end

        showResults(ref, results, on_close)
    end)
end

--- 启动刮削流程
---@param ref BookRef
---@param default_title string|nil 默认书名
---@param on_close fun()|nil 完成回调
function ScrapeUI.start(ref, default_title, on_close)
    if not ref or not ref.book_key then
        logger.warn("scrape: invalid book ref")
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
                    local query = dialog:getInputText()
                    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    if query == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("书名不能为空"),
                            timeout = 2,
                        })
                        if on_close then on_close() end
                        return
                    end
                    performSearch(ref, query, on_close)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return ScrapeUI
