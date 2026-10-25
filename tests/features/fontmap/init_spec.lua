--[[-- 开书自动发现缺失字体、记住映射、立即重排；关闭书籍后取消扫描。 --]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local mappings = {}
---@type { pending?: { on_done: fun(names: string[]), on_failed: fun(err: string) } }
local callbacks = {}
---@type FontPickerOpts|nil
local picker
local saved, cancelled, warnings = 0, 0, 0
local version = 202607020046
local identities, face_calls, jobs = {}, 0, 0
package.loaded["book.store"] = { identityFor = function(path) return identities[path] end }
package.loaded["version"] = { getNormalizedCurrentVersion = function() return version end }
package.loaded["utils.settings"] = {
    get = function() return { mappings = mappings } end,
    save = function() saved = saved + 1 end,
}
package.loaded["utils.log"] = { warn = function() warnings = warnings + 1 end }
package.loaded["ui.fonts"] = {
    faceForId = function(id)
        face_calls = face_calls + 1
        if id == "bad" then return nil, "missing file" end
        return id
    end,
}
package.loaded["ui.widgets.fontpicker"] = { open = function(opts) picker = opts end }
package.loaded["workers.job"] = { run = function(_worker, opts)
    jobs = jobs + 1
    callbacks.pending = opts
    return { cancel = function() cancelled = cancelled + 1 end }
end }
package.loaded["ui.guard"] = { wrap = function(_label, fn) return fn end }
local FontMap = require("features.fontmap")
Assert.is_true(FontMap.supported())
version = 202607020045
Assert.is_false(FontMap.supported())
version = nil
Assert.is_false(FontMap.supported())
version = 202608000000

Assert.eq(FontMap.css({}), "")
Assert.eq(FontMap.css({ ["楷体"] = "Kai", ["汉仪旗黑"] = "Sans" }),
    '@font-face{font-family:"楷体";src:local("Kai");}\n@font-face{font-family:"汉仪旗黑";src:local("Sans");}')
Assert.eq(FontMap.css({ ['A"\\\n'] = "Kai" }), '@font-face{font-family:"A\\"\\\\\\a ";src:local("Kai");}')

local function ui(styles)
    local document = {
        file = "test.epub", configurable = { embedded_css = styles, embedded_fonts = 0 },
        getEmbeddedFontList = function() return { Embedded = false } end,
        engineInit = function() return { getFontFaces = function() return { "Present Face" } end } end,
        setStyleSheet = function(self, file, appended) self.file_css, self.appended_css = file, appended; return "ok" end,
        setFontFamilyFontFaces = function(self, _families, ignore) self.ignore = ignore end,
        setEmbeddedFonts = function(self, value) self.fonts = value end,
    }
    local reader = {
        rolling = {}, document = document, updates = 0, reloads = 0, doc_settings = { values = {} },
    }
    function reader.doc_settings:saveSetting(key, value) self.values[key] = value end
    function reader:handleEvent(_event)
        self.updates = self.updates + 1
        self.document:setStyleSheet("book.css", "p{color:black}")
    end
    function reader:reloadDocument(_after_close, seamless) self.reloads = self.reloads + 1; self.seamless = seamless end
    reader.font = { updateFontFamilyFonts = function() document:setFontFamilyFontFaces({}, true) end }
    return reader
end

local reader = ui(1)
local original = reader.document.setStyleSheet
local plugin = { ui = reader, path = "" }
FontMap.onCreate(plugin)
FontMap.onReaderReady(plugin)
local state = reader._book_fontmap
Assert.is_true(state.job ~= nil)
Assert.is_nil(Themed.last("list"))
callbacks.pending.on_done({ "Absent", "Embedded", "present face" })
local dialog = Themed.last("list")
Assert.len(dialog.items, 1)
Assert.eq(dialog.items[1].text, "Absent")
Assert.eq(reader.document.configurable.embedded_fonts, 0)
dialog.items[1].callback()
Assert.eq(picker.title, "映射字体：Absent")
picker.on_select({ id = "Kai", name = "文楷", kind = "system" }, "Kai", "文楷")
Assert.eq(saved, 1)
Assert.eq(mappings.Absent.id, "Kai")
Assert.eq(reader.document.configurable.embedded_fonts, 1)
Assert.eq(reader.doc_settings.values.copt_embedded_fonts, 1)
Assert.eq(reader.reloads, 1, "选择映射后自动重载，不需要用户手动关书")
FontMap.events.CloseDocument(plugin)
reader = ui(1)
original = reader.document.setStyleSheet
plugin = { ui = reader, path = "" }
FontMap.onCreate(plugin)
FontMap.onReaderReady(plugin)
callbacks.pending.on_done({ "Absent", "Embedded", "present face" })
state = reader._book_fontmap
Assert.eq(reader.document.ignore, false, "只在当前文档接受字体名，不更改全局设置")
Assert.eq(reader.document.file_css, "book.css")
Assert.eq(reader.document.appended_css, '@font-face{font-family:"Absent";src:local("Kai");}\np{color:black}')
Assert.len(state:missing(), 0)

-- 快捷面板请求显示本书全部字体，既有字体不再提示为缺失。
state:start(true)
Assert.len(Themed.last("list").items, 3)
Assert.eq(Themed.last("list").items[2].mandatory, "本机已有")
local updates, previous_jobs = reader.updates, jobs
state:start(true)
Assert.eq(reader.updates, updates, "重复打开映射面板不触发重排")
Assert.eq(jobs, previous_jobs, "同一文档只扫描一次")
Themed.last("list").items[1].callback()
Themed.last("sheet").items[2].callback()
Assert.is_nil(mappings.Absent)
Assert.eq(reader.reloads, 1, "清除映射必须重载，不能留下 CRE 的旧别名")
Assert.is_true(reader.seamless)
FontMap.events.CloseDocument(plugin)
Assert.eq(reader.document.setStyleSheet, original)
Assert.is_nil(reader._book_fontmap)

-- 关闭内嵌样式不开扫描、不弹自动映射框；手动入口给出原因。
local disabled = ui(0)
callbacks.pending = nil
FontMap.onCreate({ ui = disabled, path = "" })
FontMap.onReaderReady({ ui = disabled, path = "" })
Assert.is_nil(callbacks.pending)
disabled._book_fontmap:start(true)
Assert.eq(Themed.last("toast").text, "请先开启本书的内嵌样式")
disabled.document.configurable.embedded_css = 1
disabled._book_fontmap:start(true)
Assert.is_true(callbacks.pending ~= nil)
FontMap.onExit({ ui = disabled, path = "" })
Assert.eq(cancelled, 1)
local made = #Themed.made
callbacks.pending.on_done({ "Absent" })
Assert.eq(#Themed.made, made, "关书后不弹迟到的字体映射框")

-- 保存的映射在新书自动生效；丢失的目标字体重新提示，不影响其它映射。
mappings.Absent = { id = "Kai", name = "文楷" }
local second = ui(1)
FontMap.onCreate({ ui = second, path = "" })
FontMap.onReaderReady({ ui = second, path = "" })
made = #Themed.made
callbacks.pending.on_done({ "Absent", "Embedded" })
Assert.eq(#Themed.made, made)
Assert.eq(second.document.fonts, 1)
local disabled_saved = ui(0)
local calls_before = face_calls
FontMap.onCreate({ ui = disabled_saved, path = "" })
disabled_saved.document:setStyleSheet("book.css", "p{color:black}")
Assert.eq(disabled_saved.document.appended_css, "p{color:black}", "关闭内嵌样式时不注入已保存映射")
Assert.eq(face_calls, calls_before, "关闭样式时不解析/注册映射字体")
FontMap.onExit({ ui = disabled_saved, path = "" })
mappings.Absent = { id = "bad", name = "丢失字体" }
local third = ui(1)
FontMap.onCreate({ ui = third, path = "" })
FontMap.onReaderReady({ ui = third, path = "" })
callbacks.pending.on_done({ "Absent" })
Assert.eq(Themed.last("list").items[1].mandatory, "缺失字体")
Assert.eq(warnings, 1)
third._book_fontmap:close()

local failing = ui(1)
FontMap.onCreate({ ui = failing, path = "" })
FontMap.onReaderReady({ ui = failing, path = "" })
callbacks.pending.on_failed("cannot read")
Assert.eq(Themed.last("toast").text, "检测书内字体失败：cannot read")
version = 202607000000
callbacks.pending = nil
local old = FontMap.new(ui(1))
made = #Themed.made
old:start(false)
Assert.is_nil(callbacks.pending)
old:start(true)
Assert.eq(#Themed.made, made, "低版本手动/自动入口都静默跳过")
local old_reader = ui(1)
local old_stylesheet = old_reader.document.setStyleSheet
calls_before = face_calls
FontMap.onCreate({ ui = old_reader, path = "" })
FontMap.onReaderReady({ ui = old_reader, path = "" })
Assert.is_nil(old_reader._book_fontmap, "低版本不安装 hook")
Assert.eq(old_reader.document.setStyleSheet, old_stylesheet)
Assert.eq(face_calls, calls_before)
Assert.is_nil(callbacks.pending, "低版本不扫描正文")
version = 202608000000

-- 来源与整书/章节无关；订阅身份明确排除，不靠猜文件名。
for _, source in ipairs({ "local", "wechat", "jjwxc", "jdread", "moon", "ext.demo" }) do
    for _, chapter in ipairs({ false, true }) do
        local candidate = ui(1)
        candidate.document.file = source .. (chapter and "-1.html" or ".epub")
        identities[candidate.document.file] = { source_id = source, chapter_idx = chapter and 1 or nil }
        Assert.is_true(FontMap.available(candidate), source .. (chapter and " chapter" or " book"))
    end
end
local subscription = ui(1)
subscription.document.file = "subscription.html"
identities[subscription.document.file] = { source_id = "subscribe", chapter_idx = 1 }
Assert.is_false(FontMap.available(subscription))
callbacks.pending = nil
FontMap.onCreate({ ui = subscription, path = "" })
FontMap.onReaderReady({ ui = subscription, path = "" })
Assert.is_nil(subscription._book_fontmap)
Assert.is_nil(callbacks.pending, "订阅不扫描、不注入、不提示")

mappings.Absent = { id = "Kai", name = "文楷" }
mappings.Other = { id = "Kai", name = "文楷" }
local dedup = ui(1)
FontMap.onCreate({ ui = dedup, path = "" })
calls_before = face_calls
dedup.document:setStyleSheet("book.css", "")
Assert.eq(face_calls, calls_before + 1, "同一目标只解析一次")
dedup.document:setStyleSheet("book.css", "")
Assert.eq(face_calls, calls_before + 1, "重排不重复准备字体")
FontMap.onExit({ ui = dedup, path = "" })
