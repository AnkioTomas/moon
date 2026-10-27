--[[-- 中西文字体选择、候补顺序和切换恢复。 --]]
local Assert = require("support.assert")
local settings = { mixed_fonts = true, western_font_id = "", western_font_name = "" }
local saves = 0
package.preload["utils.settings"] = function() return {
    get = function() return settings end,
    save = function() saves = saves + 1 end,
} end
local probes = 0
package.preload["ffi/freetype"] = function()
    return { newFaceSize = function(path)
        probes = probes + 1
        return { hasGlyph = function(_, cp)
            if cp == 0x41 then return path ~= "Symbols.ttf" end
            if cp == 0x2019 then return path ~= "ASCII.ttf" end
            Assert.eq(cp, 0x4E2D)
            return path == "Chinese.ttf"
        end, done = function() end }
    end }
end
local reader_settings = {}
_G.G_reader_settings = {
    nilOrTrue = function() return true end,
    readSetting = function(_, key) return reader_settings[key] end,
    isFalse = function(_, key) return reader_settings[key] == false end,
}
package.preload["ui.fonts"] = function() return {
    faceForId = function(id)
        if id == "custom.ttf" then return "Custom West" end
        if id == "cjk.ttf" then return "中文字体" end
        if id == "ascii.ttf" then return "ASCII" end
        if id == "symbols.ttf" then return "Symbols" end
        return nil, "字体文件不存在"
    end,
} end
package.preload["document/credocument"] = function() return {
    engineInit = function() return { getFontFaceFilenameAndFaceIndex = function(face)
        return face == "中文字体" and "Chinese.ttf" or face == "ASCII" and "ASCII.ttf"
            or face == "Symbols" and "Symbols.ttf" or "Western.ttf", 0
    end } end,
} end
local Mixed = require("ui.fonts.mixed")

local function document(faces)
    local props, fallback_writes = {}, {}
    return {
        fallback_fonts = { "Other", "中文字体", "Noto Serif" },
        engineInit = function() return {
            getFontFaces = function() return faces end,
            getFontFaceFilenameAndFaceIndex = function(face)
                if face == "Missing" then return end
                return face == "中文字体" and "Chinese.ttf" or "Western.ttf", 0
            end,
        } end,
        _document = {
            getStringProperty = function(_, key) return props[key] end,
            setStringProperty = function(_, key, value)
                props[key] = value
                fallback_writes[#fallback_writes + 1] = value
            end,
        },
        setFontFace = function(self, face) self.face = face end,
        setupFallbackFontFaces = function()
            props["crengine.font.fallback.faces"] = "Other|中文字体|Noto Serif"
        end,
        setAdjustedFallbackFontSizes = function(self, value) self.adjusted = value end,
        setWordSpacing = function(self, values) self.spacing = values end,
        props = props,
        fallback_writes = fallback_writes,
    }
end

local doc = document({ "Bookerly", "Noto Serif", "中文字体" })
Mixed.install(doc)
local hook = doc.setFontFace
Mixed.install(doc)
Assert.eq(doc.setFontFace, hook, "同一文档只安装一次")
local compact = { 75, 50 }
doc:setWordSpacing(compact)
doc:setFontFace("中文字体")
Assert.eq(doc.face, "Bookerly")
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体|Other|Noto Serif")
Assert.len(doc.fallback_writes, 1, "切换到组合模式只写一次最终候补列表")
Assert.is_false(doc.adjusted, "汉字不按西文字体 x-height 缩小")
Assert.eq(doc.spacing[1], 100, "组合模式使用自然空格宽度")
Assert.eq(doc.spacing[2], 100, "两端对齐不能再次挤掉英文空格")
Assert.eq(compact[1], 75, "不改动原词距配置表")
Assert.eq(compact[2], 50)
doc:setWordSpacing({ 125, 75 })
Assert.eq(doc.spacing[1], 125, "尊重更宽的词距")
Assert.eq(doc.spacing[2], 100)
doc:setWordSpacing(compact)
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体|Other|Noto Serif", "刷新候补不能覆盖中文首选")
Assert.len(doc.fallback_writes, 1, "同值刷新不写原生属性、不清字形缓存")
reader_settings.fallback_font = "Preferred"
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体|Preferred|Other|Noto Serif")
Assert.len(doc.fallback_writes, 2, "原生候补设置改变时只提交一次")
reader_settings.additional_fallback_fonts = false
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体|Preferred", "关闭附加候补时保留用户首选")
reader_settings.fallback_font = "Bookerly"
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体", "主字体不重复进入候补")
reader_settings.fallback_font = "中文字体"
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体", "中文首选不重复进入候补")
reader_settings.fallback_font = nil
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体|Other", "没有用户候补时保留原生首项")
reader_settings.additional_fallback_fonts = nil
doc:setupFallbackFontFaces()
Assert.eq(doc.props["crengine.font.fallback.faces"], "中文字体|Other|Noto Serif")
doc:setAdjustedFallbackFontSizes(true)
Assert.is_false(doc.adjusted)
doc:setFontFace("中文字体")
Assert.eq(probes, 1, "同一字体不重复读取")
doc:setFontFace("Noto Serif")
Assert.eq(doc.face, "Noto Serif", "主动选择西文字体照旧生效")
Assert.eq(doc.props["crengine.font.fallback.faces"], "Other|中文字体|Noto Serif")
Assert.is_true(doc.adjusted, "离开中西文组合后恢复字号选项")
Assert.eq(doc.spacing, compact, "离开组合模式恢复原词距")
doc:setFontFace("Missing")
Assert.eq(doc.face, "Missing", "失效字体仍交给原生缺字处理")

local next_chapter = document({ "Noto Serif", "中文字体" })
Mixed.install(next_chapter)
next_chapter:setFontFace("中文字体")
Assert.eq(next_chapter.face, "Noto Serif", "没有 Bookerly 时使用随 KOReader 提供的西文字体")
Assert.eq(next_chapter.props["crengine.font.fallback.faces"], "中文字体|Other")

Assert.is_true(Mixed.setWestern("custom.ttf", "自选西文"))
Assert.eq(settings.western_font_id, "custom.ttf")
Assert.eq(settings.western_font_name, "自选西文")
Assert.eq(saves, 1)
local before_repeat_probes = probes
local unchanged, _, changed = Mixed.setWestern("custom.ttf", "重复选择")
Assert.is_true(unchanged)
Assert.is_false(changed)
Assert.eq(probes, before_repeat_probes, "重复选择不重新读取字体")
Assert.eq(saves, 1, "重复选择不写配置")
Assert.eq(settings.western_font_name, "自选西文")
local custom = document({ "Bookerly", "中文字体" })
Mixed.install(custom)
custom:setFontFace("中文字体")
Assert.eq(custom.face, "Custom West", "用户的选择优先于自动字体")
Assert.eq(custom.props["crengine.font.fallback.faces"], "中文字体|Other|Noto Serif")
local rejected, reason = Mixed.setWestern("cjk.ttf", "中文字体")
Assert.is_nil(rejected, "拒绝会覆盖中文候补的字体")
Assert.eq(reason, "请选择不含中文字形的字体，以保留所选中文字体")
Assert.eq(settings.western_font_id, "custom.ttf", "拒绝中文字形时保留原选择")
Assert.eq(saves, 1, "拒绝中文字形时不保存配置")
Assert.is_true(Mixed.setWestern("ascii.ttf", "不支持弯撇号"), "允许缺少弯撇号的字体")
Assert.eq(settings.western_font_id, "ascii.ttf")
Assert.is_true(Mixed.setWestern("symbols.ttf", "符号字体"), "允许不支持英文字母的字体")
local bad, err = Mixed.setWestern("missing.ttf", "缺失字体")
Assert.is_nil(bad)
Assert.eq(err, "字体文件不存在")
Assert.eq(settings.western_font_id, "symbols.ttf", "校验失败时保留原选择")
Assert.eq(settings.western_font_name, "符号字体")
Assert.eq(saves, 3, "只有有效选择才保存配置")
Assert.is_true(Mixed.setWestern("", ""))
local auto = document({ "Bookerly", "中文字体" })
Mixed.install(auto)
auto:setFontFace("中文字体")
Assert.eq(auto.face, "Bookerly", "恢复自动选择")
local before_auto_saves = saves
local _, _, auto_changed = Mixed.setWestern("", "")
Assert.is_false(auto_changed)
Assert.eq(saves, before_auto_saves, "重复使用自动选择不写配置")

settings.mixed_fonts = require("reader.setting").defaults.mixed_fonts
Assert.is_false(settings.mixed_fonts)
local off = document({ "Bookerly" })
local original = off.setFontFace
Mixed.install(off)
Assert.eq(off.setFontFace, original, "关闭功能不安装 hook")
off:setFontFace("中文字体")
off:setWordSpacing(compact)
Assert.eq(off.face, "中文字体", "默认关闭时不替换正文字体")
Assert.eq(off.spacing, compact, "默认关闭时保留原生词距")
Mixed.install({}) -- PDF 等非 CRE 文档
Assert.eq(doc.face, "Missing", "其它文档的安装不影响当前实例")
