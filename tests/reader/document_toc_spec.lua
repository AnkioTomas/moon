--[[--
session.document_toc 离线用例：文档内目录归一化与当前章定位。

@module tests.reader.document_toc_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local DocumentToc = require("reader.session.document_toc")

local state = { page = 12 }
local ui = {
    getCurrentPage = function() return state.page end,
    document = {
        getToc = function()
            return {
                { page = 1, title = "序", xpointer = "/body/1" },
                { page = 10, title = "第一章", xpointer = "/body/10" },
                { page = 20, title = "第二章", xpointer = "/body/20" },
            }
        end,
        getPageCount = function() return 100 end,
    },
    toc = {
        toc = nil,
        fillToc = function(self)
            self.toc = self.ui.document:getToc()
        end,
        getTocIndexByPage = function(_, page)
            if page >= 20 then return 3 end
            if page >= 10 then return 2 end
            if page >= 1 then return 1 end
        end,
        getTocTitleByPage = function(_, page)
            if page >= 20 then return "第二章" end
            if page >= 10 then return "第一章" end
            return "序"
        end,
        ui = nil,
    },
}
ui.toc.ui = ui

Assert.len(DocumentToc.list(ui), 3)
Assert.eq(DocumentToc.list(ui)[2].title, "第一章")

local current = DocumentToc.current(ui)
Assert.not_nil(current)
Assert.eq(current.idx, 2)
Assert.eq(current.title, "第一章")

-- 流式文档（有 xpointer）：章内比例仍按页码算，ReaderToc 的章内页数接口不认 xpointer。
do
    ui.document.getXPointer = function() return "/body/DocFragment[3]/p[2]" end
    ui.toc.getChapterPagesDone = function(_, page) return type(page) == "number" and page - 10 or nil end
    ui.toc.getChapterPagesLeft = function(_, page) return type(page) == "number" and 19 - page or nil end
    state.page = 15
    Assert.eq(DocumentToc.chapterFraction(ui), 5 / 9)
    ui.document.getXPointer = nil
end

-- 章内页码：第几页从 1 数，本章页数用 ReaderToc 的口径；首章之前没有章内页码。
do
    ui.toc.getChapterPagesDone = function(_, page) return page >= 10 and page - 10 or nil end
    ui.toc.getChapterPageCount = function() return 10 end
    state.page = 10
    local page, count = DocumentToc.chapterPages(ui)
    Assert.eq(page, 1, "章首页是第 1 页")
    Assert.eq(count, 10)
    state.page = 15
    Assert.eq(DocumentToc.chapterPages(ui), 6)
    state.page = 5
    Assert.is_nil(DocumentToc.chapterPages(ui))
end
