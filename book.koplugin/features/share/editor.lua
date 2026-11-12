--[[--
书摘编辑页：与「锁屏壁纸」相同的设置叠层布局。

标题栏 + 固定预览（点按全屏查看）+ 下方分组设置行（主题 / 字体 / 背景或插画 / 开关 / 导出）。
保存写到截图目录，分享走远程管理二维码（不走系统相册 / 微信）。

@module koplugin.book.features.share.editor
--]]

require("l10n").apply()

local Geom = require("ui/geometry")
local CenterContainer = require("ui/widget/container/centercontainer")
local UIManager = require("ui/uimanager")
local Theme = require("ui.themes")
local Overlay = require("desktop.pages.setting.overlay")
local Row = require("ui.themes.widgets.row")
local Toast = require("ui.themes.widgets.toast")
local Card = require("features.share.card")
local Paths = require("utils.paths")
local Guard = require("ui.guard")
local T = require("ffi/util").template
local _ = require("gettext")

---@class BookShareEditor
local Editor = {}
Editor.__index = Editor

--- 与锁屏壁纸设置页预览同高（逻辑像素）。
Editor.PREVIEW_HEIGHT = 144

---@param state table|nil
---@return table
function Editor.mergeState(state)
    state = state or {}
    local theme, swatch = Card.migrate(state.theme, state.swatch or "default")
    theme = Card.isStyle(theme) and theme or "calendar"
    local art = state.art
    if theme == "scenic" and not (art and Card.SCENIC[art]) then art = "sunset" end
    if theme == "vista" and not (art and Card.VISTA[art]) then art = "dawn" end
    local font = state.font
    if font ~= "song" and font ~= "hei" and font ~= "kai" and font ~= "fang" then font = "song" end
    local font_id = state.font_id
    if type(font_id) ~= "string" or font_id == "" then font_id = nil end
    local font_name = state.font_name
    if type(font_name) ~= "string" or font_name == "" then font_name = nil end
    if not font_id then font_name = nil end
    return {
        theme = theme,
        font = font,
        font_id = font_id,
        font_name = font_name,
        swatch = swatch,
        art = art,
        show_logo = state.show_logo ~= false,
    }
end

---@param opts { payload: table, state?: table, close_callback?: fun() }
---@return BookShareEditor
function Editor:new(opts)
    opts = opts or {}
    return setmetatable({
        payload = opts.payload,
        state = Editor.mergeState(opts.state),
        close_callback = opts.close_callback,
        preview_width = math.min(Card.OUTPUT_WIDTH, 750),
    }, self)
end

---@return table
function Editor:opts()
    return Card.normalize({
        theme = self.state.theme,
        font = self.state.font,
        font_id = self.state.font_id,
        font_name = self.state.font_name,
        swatch = self.state.swatch,
        art = self.state.art,
        show_logo = self.state.show_logo,
    })
end

--- 改一项立刻落盘，不等自动保存间隔，也不等「保存图片」。
function Editor:persist()
    require("features.share.settings").write(Editor.mergeState(self.state))
end

--- 更新选项、立刻记住，并刷新预览。
---@param mut fun()
function Editor:apply(mut)
    mut()
    self.state = Editor.mergeState(self.state)
    self:persist()
    self:refreshPreview()
end

--- 字体行状态：未选或已清空时是自动（优先宋体），否则是字体选择器里的名字。
---@return string
function Editor:fontLabel()
    if not self.state.font_id then return _("自动（优先宋体）") end
    return self.state.font_name or self.state.font_id
end

--- 全屏查看预览图；点任意处退出。长图按宽度铺满，可上下滑。
---@param path string
function Editor.showFullscreen(path)
    local ImageWidget = require("ui/widget/imagewidget")
    local Box = require("ui.themes.widgets.box")
    local Modal = require("ui.themes.widgets.modal")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local viewer = Modal:new{
        close_on_tap = true,
        covers_fullscreen = true,
        swipe_dismiss = "off",
        close_callback = function() UIManager:setDirty(nil, "full") end,
    }
    local w, h = viewer.dimen.w, viewer.dimen.h
    local probe = ImageWidget:new{ file = path, file_do_cache = false }
    local size = probe:getSize()
    probe:free()
    local scale = math.min(w / math.max(1, size.w), h / math.max(1, size.h))
    local shown_h = size.h * scale
    if shown_h > h then
        scale = w / math.max(1, size.w)
        shown_h = size.h * scale
    end
    local img = ImageWidget:new{
        file = path, file_do_cache = false, scale_factor = scale,
    }
    size = img:getSize()
    if size.h <= h then
        viewer:setPanel(Box:new{
            style = { bg = Theme.current().color.page },
            width = w, height = h, img,
        })
        viewer:show()
        return
    end
    -- 比屏幕高：上下滑动查看，点按仍关闭。
    local stage = InputContainer:extend{}
    function stage:init()
        self.dimen = Geom:new{ w = w, h = h }
        self.offset = 0
        self.max_offset = math.max(0, size.h - h)
        self.ges_events = {
            SwipePreview = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
        }
    end
    function stage:paintTo(bb, x, y)
        if self.dimen then self.dimen.x, self.dimen.y = x, y end
        img:paintTo(bb, x + math.floor((w - size.w) / 2), y - self.offset)
    end
    function stage:onSwipePreview(_, ges)
        local dist = (ges and (ges.distance or math.abs((ges.relative and ges.relative.y) or 0))) or Theme.px(48)
        if ges and ges.direction == "north" then
            self.offset = math.min(self.max_offset, self.offset + dist)
        elseif ges and ges.direction == "south" then
            self.offset = math.max(0, self.offset - dist)
        else
            return false
        end
        UIManager:setDirty(viewer, "ui")
        return true
    end
    viewer:setPanel(Box:new{
        style = { bg = Theme.current().color.page },
        width = w, height = h, stage:new{},
    })
    viewer:show()
end

--- 固定预览行：与锁屏壁纸相同的卡片框；有图时可点开全屏。
---@param width number
---@return table
function Editor:preview(width)
    local preview_h = Theme.px(Editor.PREVIEW_HEIGHT)
    if self.preview_busy then
        return Overlay.previewPlaceholder(width, preview_h, _("生成中…"))
    end
    local path = self.preview_path
    if not path then
        return Overlay.previewPlaceholder(width, preview_h, _("未生成"))
    end
    local ImageWidget = require("ui/widget/imagewidget")
    local inner_w = math.max(1, width - 2)
    local inner_h = math.max(1, preview_h - 2)
    local probe = ImageWidget:new{ file = path, file_do_cache = false }
    local size = probe:getSize()
    probe:free()
    local scale = math.min(inner_w / math.max(1, size.w), inner_h / math.max(1, size.h))
    local tap = require("ui.widgets.book").tappable(width, preview_h, function()
        Editor.showFullscreen(path)
    end)
    tap[1] = Overlay.previewBox(width, CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        ImageWidget:new{
            file = path,
            scale_factor = scale,
            file_do_cache = false,
        },
    }, preview_h)
    return tap
end

---@param title string
---@param items { value: string, text: string }[]
---@param current string|nil
---@param icon string
---@param apply fun(value: string): boolean|nil
---@param status string|nil
---@return fun(iw: number): table
local function choiceRow(title, items, current, icon, apply, status)
    return function(iw)
        return Row.choice({
            width = iw,
            icon = icon,
            title = title,
            items = items,
            current = current,
            status = status,
            on_select = apply,
        })
    end
end

---@return { value: string, text: string }[]
function Editor.themeItems()
    local items = {}
    for _idx, style in ipairs(Card.STYLES) do
        items[#items + 1] = { value = style.id, text = style.label }
    end
    return items
end

---@return { value: string, text: string }[]
function Editor.fontItems()
    return {
        { text = _("自动（优先宋体）"), value = "auto" },
        { text = _("选择字体…"), value = "pick" },
    }
end

---@return { value: string, text: string }[]
function Editor.swatchItems()
    local items = {}
    for _idx, item in ipairs(Card.SWATCHES) do
        items[#items + 1] = { value = item.id, text = item.label }
    end
    return items
end

---@param theme string
---@return { value: string, text: string }[]
function Editor.artItems(theme)
    local order = theme == "vista" and Card.VISTA_ORDER or Card.SCENIC_ORDER
    local table_ = theme == "vista" and Card.VISTA or Card.SCENIC
    local items = {}
    for _idx, id in ipairs(order) do
        local entry = table_[id]
        items[#items + 1] = { value = id, text = entry.label }
    end
    return items
end

--- 设置行：主题、字体、背景或插画、开关、导出。与锁屏壁纸一样走 Row.choice / toggle / nav。
---@return BookThemeSection[]
function Editor:sections()
    local state = self.state
    local rows = {}
    rows[#rows + 1] = choiceRow(_("主题"), Editor.themeItems(), state.theme, "style", function(value)
        self:apply(function()
            self.state.theme = value
            if value == "scenic" and not Card.SCENIC[self.state.art] then self.state.art = "sunset" end
            if value == "vista" and not Card.VISTA[self.state.art] then self.state.art = "dawn" end
        end)
    end)
    local auto_font = not state.font_id
    rows[#rows + 1] = choiceRow(_("字体"), Editor.fontItems(), auto_font and "auto" or nil, "text_fields", function(value)
        if value == "auto" then
            self:apply(function()
                self.state.font_id = nil
                self.state.font_name = nil
            end)
            return
        end
        require("ui.widgets.fontpicker").open{
            title = _("字体"),
            current_id = function() return self.state.font_id or "" end,
            on_select = function(_item, id, name)
                self:apply(function()
                    self.state.font_id = id
                    self.state.font_name = name
                end)
            end,
        }
        return false
    end, self:fontLabel())
    if Card.isArtTheme(state.theme) then
        rows[#rows + 1] = choiceRow(_("插画"), Editor.artItems(state.theme), state.art, "image", function(value)
            self:apply(function() self.state.art = value end)
        end)
    elseif Card.hasSwatch(state.theme) then
        rows[#rows + 1] = choiceRow(_("背景"), Editor.swatchItems(), state.swatch, "palette", function(value)
            self:apply(function() self.state.swatch = value end)
        end)
    end
    rows[#rows + 1] = function(iw)
        return Row.widget({
            width = iw,
            icon = "photo",
            title = _("显示 Logo"),
            toggle = state.show_logo,
            chevron = false,
            callback = function()
                self:apply(function() self.state.show_logo = not self.state.show_logo end)
            end,
        })
    end
    rows[#rows + 1] = function(iw)
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = "download",
            title = _("保存图片"),
            chevron = false,
            callback = function() self:saveImage() end,
        })
    end
    rows[#rows + 1] = function(iw)
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = "share",
            title = _("分享"),
            chevron = false,
            callback = function() self:shareImage() end,
        })
    end
    return { { title = _("书摘"), rows = rows } }
end

function Editor:refreshPreview()
    local old = self.preview_path
    local path = Paths.tmpname(".png")
    local ok, err = Card.write(self.state.theme, self.payload, path, self.preview_width, self:opts())
    self.preview_busy = false
    if not ok then
        os.remove(path)
        self.preview_path = nil
        Toast:new{ text = T(_("书摘图生成失败：%1"), tostring(err)), timeout = 3 }:show()
        if self.overlay and self.overlay.updateView then self.overlay:updateView() end
        return
    end
    self.preview_path = path
    if old and old ~= path then os.remove(old) end
    if self.overlay and self.overlay.updateView then self.overlay:updateView() end
end

function Editor:show()
    local editor = self
    self.preview_busy = true
    self.overlay = Overlay:new{
        spec = {
            title = _("书摘"),
            preview = function(width) return editor:preview(width) end,
            sections = function() return editor:sections() end,
        },
        close_callback = function()
            editor:cleanup()
            if editor.close_callback then editor.close_callback() end
        end,
    }
    self.overlay:show()
    -- 先出壳再生成预览，避免首帧卡住。
    UIManager:nextTick(function()
        if not editor.closed then
            Guard.call("share preview", function() editor:refreshPreview() end)
        end
    end)
end

function Editor:cleanup()
    self.closed = true
    if self.preview_path then os.remove(self.preview_path) self.preview_path = nil end
    if self.share_path then os.remove(self.share_path) self.share_path = nil end
end

function Editor:close()
    if self.overlay and self.overlay.close then
        self.overlay:close()
        return
    end
    self:cleanup()
    if self.close_callback then self.close_callback() end
end

---@return string|nil
function Editor:screenshotDir()
    local dir
    if G_reader_settings and G_reader_settings.readSetting then
        local shot = G_reader_settings:readSetting("screenshot_dir")
        if type(shot) == "string" and shot ~= "" then dir = shot end
    end
    if not dir then
        local ok, DataStorage = pcall(require, "datastorage")
        if ok and DataStorage.getDataDir then
            dir = DataStorage:getDataDir() .. "/screenshots"
        else
            dir = Paths.tmpDir and Paths.tmpDir() or "/tmp"
        end
    end
    return dir
end

function Editor:fileName()
    local raw = Card.stripTitleMarks(self.payload.title)
    if raw == "" then raw = _("书摘") end
    raw = raw:gsub("[/\\:%*%?\"<>|]", "_")
    return _("月读书摘") .. "-" .. raw .. ".png"
end

function Editor:exportTo(path)
    return Card.write(self.state.theme, self.payload, path, Card.OUTPUT_WIDTH, self:opts())
end

function Editor:saveImage()
    local dir = self:screenshotDir()
    local ok_dir, err_dir = Paths.ensureDir(dir)
    if not ok_dir then
        Toast:new{ text = T(_("保存失败：%1"), tostring(err_dir)), timeout = 3 }:show()
        return
    end
    local name = self:fileName()
    local path = dir .. "/" .. name
    local n = 1
    local lfs = require("libs/libkoreader-lfs")
    while lfs.attributes(path, "mode") == "file" do
        n = n + 1
        path = dir .. "/" .. name:gsub("%.png$", "-" .. n .. ".png")
    end
    local ok, err = self:exportTo(path)
    if not ok then
        Toast:new{ text = T(_("保存失败：%1"), tostring(err)), timeout = 3 }:show()
        return
    end
    self.saved_path = path
    Toast:new{ text = T(_("已保存到 %1"), path), timeout = 3 }:show()
end

function Editor:shareImage()
    local path = self.saved_path
    if not path then
        path = Paths.tmpname(".png")
        local ok, err = self:exportTo(path)
        if not ok then
            os.remove(path)
            Toast:new{ text = T(_("书摘图生成失败：%1"), tostring(err)), timeout = 3 }:show()
            return
        end
        self.share_path = path
    end
    require("features.remote.screenshot").share(path)
end

return Editor
