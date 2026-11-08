--[[--
连续章节目录：把源目录适配成 KOReader 原生 ReaderToc。

仅替换“页码跳转”为“章节跳转”；缩进、折叠、搜索、当前项定位和菜单样式
全部复用 KOReader 原生实现。

@module koplugin.book.reader.chapter_toc
--]]

require("l10n").apply()

local _ = require("gettext")

---@class BookReaderChapterToc
local ChapterToc = {}

--- ReaderToc 要数字页码；current_idx 缺失或不在目录时退到最近一章 / 首页。
---@param chapter_pages table<integer, integer>
---@param current_idx integer|nil
---@return integer
local function resolvePageno(chapter_pages, current_idx)
    local cur = tonumber(current_idx)
    if not cur then return 1 end
    if chapter_pages[cur] then return chapter_pages[cur] end
    local best, best_idx
    for idx, page in pairs(chapter_pages) do
        if idx <= cur and (not best_idx or idx > best_idx) then
            best, best_idx = page, idx
        end
    end
    return best or 1
end

---@param toc BookChapter[]
---@param current_idx integer|nil
---@param on_select fun(idx: integer, anchor: BookChapterAnchor|nil)
---@return table
function ChapterToc.show(toc, current_idx, on_select)
    local Perf = require("utils.perf")
    local started_at = Perf.now()
    local ReaderToc = require("apps/reader/modules/readertoc")
    local nodes, targets, chapter_pages = {}, {}, {}
    for _idx, chapter in ipairs(toc) do
        local function addNode(title, depth, anchor)
            local page = #nodes + 1
            nodes[page] = {
                title = title,
                depth = math.max(1, math.floor(tonumber(depth) or 1)),
                page = page,
            }
            targets[page] = { idx = chapter.idx, anchor = anchor }
            return page
        end
        local raw = chapter.title
        local title = (type(raw) == "string" and raw ~= "" and raw) or ("#" .. tostring(chapter.idx))
        if chapter.vip and chapter.paid ~= nil then
            title = title .. (chapter.paid and _("（已购）") or _("（未购）"))
        end
        chapter_pages[tonumber(chapter.idx)] = addNode(title, chapter.depth)
        for _idx, anchor in ipairs(chapter.anchors or {}) do
            addNode(anchor.title, anchor.depth, anchor)
        end
    end

    local adapter = setmetatable({
        toc = nodes,
        toc_menu_items_built = false,
        toc_depth = nil,
        collapsed_toc = {},
        collapse_depth = 2,
        expanded_nodes = {},
        pageno = resolvePageno(chapter_pages, current_idx),
        view = {
            shouldInvertBiDiLayoutMirroring = function() return false end,
        },
    }, { __index = ReaderToc })

    adapter.ui = {
        document = {
            hasHiddenFlows = function() return false end,
        },
        link = {
            addCurrentLocationToStack = function() end,
        },
        handleEvent = function(_self, event)
            if event.handler == "onGotoPage" then
                local target = targets[event.args[1]]
                if target then require("ui.guard").call("chapter toc", on_select, target.idx, target.anchor) end
            end
        end,
    }
    adapter.getTitle = function() return _("目录") end
    adapter.completeTocWithChapterLengths = function() end
    adapter:onShowToc()
    Perf.slow("chapter_toc.show " .. #nodes, started_at)
    return adapter
end

return ChapterToc
