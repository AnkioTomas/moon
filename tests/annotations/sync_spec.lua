--[[-- annotations.sync 上报完整快照，包括空快照删除传播。 --]]

local Assert = require("support.assert")

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function()
        return "device-1"
    end,
    saveSetting = function() end,
}

package.preload["ui/network/manager"] = function()
    return {
        runWhenOnline = function(_, fn)
            fn()
        end,
    }
end
package.loaded["ui/network/manager"] = nil
package.loaded["annotations.sync"] = nil

local sent = {}
local source = {
    id = "moon",
    syncAnnotationsAsync = function(_, payload, cb)
        sent[#sent + 1] = payload
        cb({ code = 200 })
    end,
}
local annotations = {
    {
        datetime = "2026-08-15 21:11:53",
        datetime_updated = "2026-08-15 21:35:51",
        drawer = "lighten",
        color = "cyan",
        text = "高亮文字",
        note = "笔记",
        chapter = "第一章",
        pageno = 12,
        page = "/body/p[1].0",
        pos0 = "/body/p[1].0",
        pos1 = "/body/p[1].4",
        ignored = "不能上报",
    },
}
local ui = {
    document = {
        getPageCount = function()
            return 100
        end,
    },
    doc_settings = {
        flush = function() end,
        readSetting = function(_, key)
            if key == "annotations" then
                return annotations
            end
        end,
    },
}
local ref = { source_id = "moon", stable_id = "小说.epub" }
local Sync = require("annotations.sync")

Sync.push(ui, source, ref)
Assert.eq(#sent, 1)
Assert.eq(sent[1].filename, "小说.epub")
Assert.eq(sent[1].device_id, "device-1")
Assert.eq(sent[1].annotations[1].total_pages, 100)
Assert.eq(sent[1].annotations[1].text, "高亮文字")
Assert.eq(sent[1].annotations[1].ignored, nil)

annotations = {}
Sync.push(ui, source, ref)
Assert.eq(#sent, 2)
Assert.eq(#sent[2].annotations, 0, "空快照必须上报以传播删除")

_G.G_reader_settings = previous_settings
