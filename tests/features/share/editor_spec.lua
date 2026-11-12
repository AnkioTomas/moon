--[[--
书摘编辑页：与锁屏壁纸相同的设置叠层（标题 + 固定预览 + 分组设置行）。

@module tests.features.share.editor_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end }
end
package.preload["utils.paths"] = function()
    return {
        tmpname = function() return "/tmp/share-preview.png" end,
        tmpDir = function() return "/tmp" end,
        ensureDir = function() return true end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) if type(_) == "function" then _() else fn() end end,
        setDirty = function() end,
        show = function() end,
    }
end
package.preload["ui.guard"] = function()
    return { call = function(_name, fn) return fn() end }
end

local writes = {}
package.preload["features.share.card"] = function()
    return {
        OUTPUT_WIDTH = 1125,
        stripTitleMarks = function(name)
            name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
            return (name:gsub("《", ""):gsub("》", ""):gsub("「", ""):gsub("」", ""):gsub("『", ""):gsub("』", ""))
        end,
        STYLES = {
            { id = "calendar", label = "日历" },
            { id = "classic", label = "经典" },
            { id = "ink", label = "墨白" },
            { id = "cinema", label = "静影" },
            { id = "letter", label = "手札" },
            { id = "brocade", label = "锦书" },
            { id = "paper", label = "纸页摘录" },
            { id = "scenic", label = "画境", group = "art" },
            { id = "vista", label = "远山", group = "art" },
        },
        FONTS = {
            { id = "song", label = "宋体" },
            { id = "hei", label = "黑体" },
        },
        SWATCHES = {
            { id = "default", label = "默认" },
            { id = "paper", label = "米白" },
        },
        SCENIC = { sunset = { id = "sunset", label = "暮色" }, window = { id = "window", label = "窗夜" } },
        SCENIC_ORDER = { "sunset", "window" },
        VISTA = { dawn = { id = "dawn", label = "晨岚" } },
        VISTA_ORDER = { "dawn" },
        isStyle = function(id)
            return id == "calendar" or id == "classic" or id == "ink" or id == "cinema"
                or id == "letter" or id == "brocade" or id == "paper"
                or id == "scenic" or id == "vista"
        end,
        isArtTheme = function(id) return id == "scenic" or id == "vista" end,
        hasSwatch = function(id) return id ~= "scenic" and id ~= "vista" and id ~= "cinema" end,
        migrate = function(theme, swatch)
            swatch = swatch or "default"
            if theme == "night" then
                if swatch == "default" then swatch = "night" end
                theme = "paper"
            elseif theme == "official" then
                theme = "paper"
            end
            return theme, swatch
        end,
        normalize = function(opts) return opts end,
        write = function(theme, payload, path, width, opts)
            writes[#writes + 1] = { theme = theme, path = path, width = width, opts = opts, text = payload.text }
            return true
        end,
    }
end

local row_log = {}
package.preload["ui.themes.widgets.row"] = function()
    local Row = {}
    function Row.widget(opts)
        row_log[#row_log + 1] = opts
        return opts
    end
    function Row.choice(opts)
        opts.kind = "choice"
        if opts.status == nil then
            for _idx, item in ipairs(opts.items or {}) do
                if item.value == opts.current then opts.status = item.text end
            end
        end
        opts.callback = function() end
        return Row.widget(opts)
    end
    return Row
end

local overlays = {}
package.preload["desktop.pages.setting.overlay"] = function()
    local Overlay = {}
    function Overlay.previewBox(width, child, height)
        return { kind = "box", width = width, height = height, child = child }
    end
    function Overlay.previewPlaceholder(width, height, text)
        return { kind = "placeholder", width = width, height = height, text = text }
    end
    function Overlay:new(opts)
        opts.show = function(self) self.shown = true end
        opts.updateView = function(self)
            self.updated = (self.updated or 0) + 1
            self.last_preview = self.spec.preview(560)
            self.last_sections = self.spec.sections()
        end
        opts.close = function(self)
            self.closed = true
            if self.close_callback then self.close_callback() end
        end
        overlays[#overlays + 1] = opts
        return opts
    end
    return Overlay
end

package.preload["ui/widget/imagewidget"] = function()
    return {
        new = function(_, opts)
            return {
                file = opts.file,
                getSize = function() return { w = 375, h = 500 } end,
                free = function() end,
            }
        end,
    }
end
package.preload["ui/widget/container/centercontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.widgets.book"] = function()
    return {
        tappable = function(w, h, on_tap)
            return { width = w, height = h, on_tap = on_tap }
        end,
    }
end

local persisted = {}
package.preload["features.share.settings"] = function()
    return {
        read = function()
            local last = persisted[#persisted]
            if not last then return {} end
            local copy = {}
            for k, v in pairs(last) do copy[k] = v end
            return copy
        end,
        write = function(state)
            local copy = {}
            for k, v in pairs(state or {}) do copy[k] = v end
            persisted[#persisted + 1] = copy
        end,
    }
end

local picker
package.preload["ui.widgets.fontpicker"] = function()
    return { open = function(opts) picker = opts end }
end

Kit.install("paper")

package.loaded["features.share.editor"] = nil
local Editor = require("features.share.editor")

Assert.eq(Editor.PREVIEW_HEIGHT, 144, "与锁屏壁纸预览同高")

-- mergeState：非法主题回落日历，画境/远山补默认插画。
local merged = Editor.mergeState({ theme = "nope", show_logo = false })
Assert.eq(merged.theme, "calendar")
Assert.is_false(merged.show_logo)
Assert.eq(Editor.mergeState({ theme = "scenic" }).art, "sunset")
Assert.eq(Editor.mergeState({ theme = "vista" }).art, "dawn")
-- 插画已不在目录时回落默认；字体 id 即使文件暂缺也先保留，绘制时再回落。
local missing = Editor.mergeState({
    theme = "scenic", art = "deleted", font_id = "gone.ttf", font_name = "已卸载",
})
Assert.eq(missing.art, "sunset")
Assert.eq(missing.font_id, "gone.ttf")
Assert.eq(missing.font_name, "已卸载")
Assert.eq(Editor.mergeState({ font = "hei" }).font, "hei")
Assert.is_nil(Editor.mergeState({ font_id = "" }).font_id)
do
    local night = Editor.mergeState({ theme = "night" })
    Assert.eq(night.theme, "paper")
    Assert.eq(night.swatch, "night")
    local kept = Editor.mergeState({ theme = "night", swatch = "blush" })
    Assert.eq(kept.theme, "paper")
    Assert.eq(kept.swatch, "blush")
    local official = Editor.mergeState({ theme = "official", swatch = "blue" })
    Assert.eq(official.theme, "paper")
    Assert.eq(official.swatch, "blue")
    Assert.is_nil(Editor.mergeState({ long = true }).long, "不再恢复长卡片")
end

Assert.eq(#Editor.themeItems(), 9)
Assert.eq(Editor.themeItems()[1].text, "日历")
Assert.eq(Editor.themeItems()[7].text, "纸页摘录")
Assert.eq(Editor.themeItems()[8].text, "画境")
Assert.eq(Editor.fontItems()[1].value, "auto")
Assert.eq(Editor.fontItems()[1].text, "自动（优先宋体）")
Assert.eq(Editor.fontItems()[2].value, "pick")
Assert.eq(Editor.fontItems()[2].text, "选择字体…")
Assert.eq(Editor.swatchItems()[2].text, "米白")
Assert.eq(Editor.artItems("scenic")[2].text, "窗夜")
Assert.eq(Editor.artItems("vista")[1].value, "dawn")

local function titles(sections)
    local out = {}
    for _i, section in ipairs(sections) do
        for _j, row in ipairs(section.rows) do
            out[#out + 1] = row(560).title
        end
    end
    return out
end

-- 打开后是设置叠层：标题「书摘」，先出「生成中…」，再写出预览并重画。
local closed = 0
local editor = Editor:new{
    payload = { text = "明月几时有", title = "东坡乐府" },
    state = { theme = "classic", font = "hei" },
    close_callback = function() closed = closed + 1 end,
}
editor:show()
local overlay = overlays[1]
Assert.not_nil(overlay)
Assert.is_true(overlay.shown)
Assert.eq(overlay.spec.title, "书摘")
Assert.eq(editor.overlay, overlay)
Assert.eq(#writes, 1)
Assert.eq(writes[1].theme, "classic")
Assert.eq(writes[1].width, 750)
Assert.eq(writes[1].opts.font, "hei")
Assert.eq(editor.preview_path, "/tmp/share-preview.png")
local preview = overlay.spec.preview(560)
Assert.eq(preview.width, 560)
Assert.eq(preview[1].kind, "box")
Assert.eq(preview[1].height, 144, "预览框高度走逻辑像素，测试里 Theme.px 恒等")

-- 排版主题：背景色板，没有插画行；导出是设置行而不是底栏按钮。
local section_titles = titles(overlay.spec.sections())
Assert.eq(table.concat(section_titles, ","), "主题,字体,背景,显示 Logo,保存图片,分享")
Assert.eq(overlay.spec.sections()[1].title, "书摘")
local theme_row = overlay.spec.sections()[1].rows[1](560)
Assert.eq(theme_row.kind, "choice")
Assert.eq(theme_row.status, "经典")
Assert.eq(theme_row.icon, "style")
local logo_row = overlay.spec.sections()[1].rows[4](560)
Assert.is_true(logo_row.toggle)
Assert.eq(overlay.spec.sections()[1].rows[5](560).title, "保存图片")
local font_row = overlay.spec.sections()[1].rows[2](560)
Assert.eq(font_row.status, "自动（优先宋体）")
Assert.eq(font_row.items[1].value, "auto")
Assert.eq(font_row.current, "auto")

-- 改成画境后出现插画行，并立刻落盘（不等关窗、也不等保存图片）。
theme_row.on_select("scenic")
Assert.eq(editor.state.theme, "scenic")
Assert.eq(editor.state.art, "sunset")
Assert.eq(#writes, 2)
Assert.eq(persisted[#persisted].theme, "scenic")
Assert.eq(persisted[#persisted].art, "sunset")
section_titles = titles(overlay.spec.sections())
Assert.eq(table.concat(section_titles, ","), "主题,字体,插画,显示 Logo,保存图片,分享")
Assert.eq(overlay.spec.sections()[1].rows[3](560).status, "暮色")

-- 字体走月读字体选择器（在线 / 用户 / 本地 / 系统），选完立刻刷新预览并记住。
font_row = overlay.spec.sections()[1].rows[2](560)
font_row.on_select("pick")
Assert.not_nil(picker)
Assert.eq(picker.title, "字体")
picker.on_select({ id = "KingHwa_OldSong" }, "KingHwa_OldSong", "京华老宋体")
Assert.eq(editor.state.font_id, "KingHwa_OldSong")
Assert.eq(editor.state.font_name, "京华老宋体")
Assert.eq(writes[#writes].opts.font_id, "KingHwa_OldSong")
Assert.eq(persisted[#persisted].font_id, "KingHwa_OldSong")
Assert.eq(persisted[#persisted].font_name, "京华老宋体")
font_row = overlay.spec.sections()[1].rows[2](560)
Assert.eq(font_row.status, "京华老宋体")
Assert.is_nil(font_row.current)

-- 下次打开直接用上次配置。
local again = Editor:new{ payload = { text = "高处不胜寒。" }, state = persisted[#persisted] }
Assert.eq(again.state.theme, "scenic")
Assert.eq(again.state.art, "sunset")
Assert.eq(again.state.font_id, "KingHwa_OldSong")
Assert.eq(again.state.font_name, "京华老宋体")

font_row.on_select("auto")
Assert.is_nil(editor.state.font_id)
Assert.is_nil(persisted[#persisted].font_id)
Assert.eq(overlay.spec.sections()[1].rows[2](560).status, "自动（优先宋体）")

logo_row = overlay.spec.sections()[1].rows[4](560)
logo_row.callback()
Assert.is_false(editor.state.show_logo)
Assert.is_false(persisted[#persisted].show_logo)

-- 静影不出现背景色板行。
theme_row = overlay.spec.sections()[1].rows[1](560)
theme_row.on_select("cinema")
Assert.eq(editor.state.theme, "cinema")
Assert.eq(table.concat(titles(overlay.spec.sections()), ","), "主题,字体,显示 Logo,保存图片,分享")

-- 无路径时预览是占位，不造 ImageWidget。
editor.preview_path = nil
Assert.eq(editor:preview(560).kind, "placeholder")
Assert.eq(editor:preview(560).text, "未生成")
editor.preview_busy = true
Assert.eq(editor:preview(560).text, "生成中…")
editor.preview_busy = false

do -- 已保存导出只在选项不变时复用；预览变化后分享必须重新导出。
    local shared = {}
    package.loaded["features.remote.screenshot"] = {
        share = function(path) shared[#shared + 1] = path end,
    }
    editor.screenshotDir = function() return "/audit-shared" end
    editor:saveImage()
    local saved_path = editor.saved_path
    local count = #writes
    editor:shareImage()
    Assert.eq(shared[#shared], saved_path)
    Assert.eq(#writes, count, "选项没变时复用已保存导出")
    local changes = {
        function() editor.state.theme = "classic" end,
        function() editor.state.font_id, editor.state.font_name = "Song", "宋体" end,
        function() editor.state.show_logo = not editor.state.show_logo end,
    }
    for _idx, change in ipairs(changes) do
        editor:saveImage()
        editor:apply(change)
        Assert.is_nil(editor.saved_path)
        editor:shareImage()
        local export = writes[#writes]
        Assert.eq(export.width, 1125, "分享重新生成完整尺寸")
        Assert.eq(export.theme, editor.state.theme)
        Assert.eq(export.opts.font_id, editor.state.font_id)
        Assert.eq(export.opts.show_logo, editor.state.show_logo)
        Assert.eq(shared[#shared], export.path)
    end
end

-- 关窗清临时文件，并调用调用方提供的关闭回调。
editor:close()
Assert.is_true(overlay.closed)
Assert.is_true(editor.closed)
Assert.eq(closed, 1)
Assert.is_nil(editor.preview_path)

return true
