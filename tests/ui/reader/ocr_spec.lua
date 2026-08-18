--[[-- ui.reader.ocr：官方语言包下载、原子落位与当前文档语言切换。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local installed = { "eng" }
local popup_opts
local download
local renamed
local files = {}
local shown = {}

package.preload["ui/data/ocr"] = function()
    return { getOCRLangs = function() return installed end }
end
package.preload["document/koptinterface"] = function()
    return { tessocr_data = "/data/tessdata" }
end
package.preload["ui/data/isolanguage"] = function()
    return { getLocalizedLanguage = function(_, code) return "name-" .. code end }
end
package.preload["ui.components.popup"] = function()
    return { list = function(opts) popup_opts = opts end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["util"] = function()
    return { makePath = function(path) return path == "/data/tessdata" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            if files[path] then
                return { mode = "file", size = files[path] }
            end
        end,
    }
end
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download = { opts = opts, dest = dest }
            files[dest] = 2048
            cb(true)
        end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, value) return { name = name, value = value } end }
end

local UIManager = require("ui/uimanager")
UIManager.show = function(_, widget) shown[#shown + 1] = widget end
UIManager.close = function() end

local old_remove, old_rename = os.remove, os.rename
os.remove = function(path) files[path] = nil return true end
os.rename = function(src, dest)
    renamed = { src = src, dest = dest }
    files[dest] = files[src]
    files[src] = nil
    return true
end

package.loaded["ui.reader.ocr"] = nil
local OCR = require("ui.reader.ocr")

Assert.eq(OCR.status(), "已安装 1 种语言")

local events = {}
local ui = {
    document = { koptinterface = {}, configurable = { doc_language = "eng" } },
    handleEvent = function(_, event) events[#events + 1] = event end,
}
OCR.open(ui)
Assert.eq(popup_opts.title, "OCR 语言数据")
Assert.matches(popup_opts.subtitle, "tessdata_fast")
Assert.eq(popup_opts.current, "eng")
Assert.eq(popup_opts.items[1].value, "eng")
Assert.eq(popup_opts.items[1].mandatory, "已安装")
Assert.eq(popup_opts.items[2].value, "chi_sim")
Assert.eq(popup_opts.items[2].mandatory, "下载")

popup_opts.items[1].callback()
Assert.eq(ui.document.configurable.doc_language, "eng")
Assert.eq(events[#events].name, "DocLangUpdate")

popup_opts.items[2].callback()
Assert.matches(download.opts.url, "cdn%.jsdelivr%.net/gh/tesseract%-ocr/tessdata_fast@main/chi_sim%.traineddata$")
Assert.eq(download.dest, "/data/tessdata/chi_sim.traineddata.part")
Assert.eq(renamed.dest, "/data/tessdata/chi_sim.traineddata")
Assert.eq(ui.document.configurable.doc_language, "chi_sim")
Assert.eq(events[#events].value, "chi_sim")
Assert.is_true(#shown >= 2)

local reflow_events = {}
local reflow_ui = {
    document = { configurable = { doc_language = "eng" } },
    handleEvent = function(_, event) reflow_events[#reflow_events + 1] = event end,
}
OCR.open(reflow_ui)
Assert.is_nil(popup_opts.current)
popup_opts.items[1].callback()
Assert.eq(reflow_ui.document.configurable.doc_language, "eng")
Assert.eq(#reflow_events, 0, "安装入口不能误改 EPUB 的排版语言")

os.remove, os.rename = old_remove, old_rename
