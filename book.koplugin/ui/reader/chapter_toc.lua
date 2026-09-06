--[[--
连续章节目录：把源目录适配成 KOReader 原生 ReaderToc。

仅替换“页码跳转”为“章节跳转”；缩进、折叠、搜索、当前项定位和菜单样式
全部复用 KOReader 原生实现。

@module koplugin.book.ui.reader.chapter_toc
--]]

require("l10n").apply()

local _ = require("gettext")

local ChapterToc = {}

---@param toc BookChapter[]
---@param current_idx integer|nil
---@param on_select fun(idx: integer, anchor: BookChapterAnchor|nil)
---@return table
function ChapterToc.show(toc, current_idx, on_select)
    local ReaderToc = require("apps/reader/modules/readertoc")
    local nodes, targets, chapter_pages = {}, {}, {}
    for _, chapter in ipairs(toc) do
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
        chapter_pages[tonumber(chapter.idx)] = addNode(
            chapter.title or ("#" .. tostring(chapter.idx)), chapter.depth)
        for _, anchor in ipairs(chapter.anchors or {}) do
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
        pageno = chapter_pages[tonumber(current_idx)],
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
        handleEvent = function(_, event)
            if event.handler == "onGotoPage" then
                local target = targets[event.args[1]]
                if target then on_select(target.idx, target.anchor) end
            end
        end,
    }
    adapter.getTitle = function() return _("目录") end
    adapter.completeTocWithChapterLengths = function() end
    adapter:onShowToc()
    return adapter
end

return ChapterToc
