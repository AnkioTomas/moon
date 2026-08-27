--[[--
session.document_toc 离线用例：文档内目录归一化与当前章定位。

@module tests.ui.reader.document_toc_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["ui/event"] = function()
    return {
        new = function(_, name, ...)
            return { name = name, args = { ... } }
        end,
    }
end

local DocumentToc = require("ui.reader.session.document_toc")

local state = {
    last_event = nil,
    page = 12,
}
local ui = {
    getCurrentPage = function() return state.page end,
    handleEvent = function(_, ev)
        state.last_event = ev
    end,
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
        getNextChapter = function(_, page)
            if page < 10 then return 10 end
            if page < 20 then return 20 end
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

Assert.is_true(DocumentToc.gotoIndex(ui, 3))
Assert.eq(state.last_event.name, "GotoXPointer")

Assert.is_true(DocumentToc.onBoundary(ui, 1))
Assert.eq(state.last_event.name, "GotoPage")
