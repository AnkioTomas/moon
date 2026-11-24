--[[--
字体选择器：只展示本地字体（用户 / 本地 / 系统），不访问网络。

底部分栏（用户 / 本地 / 系统）走主题 List 的 tabs；
「用户」分栏（$DATA/fonts 根目录，含在线下载到本地的字体）每行右侧提供删除按钮，确认后删除文件，
若删除的正是当前正在使用的字体则自动回退系统默认，避免闪退。
预览按页懒构建（List 翻到该页才调 item.widget；禁止打开时全表 getFace）。
无「系统默认」项；空配置仍由 applyCurrent 回退 fontmap 备份。

@module koplugin.book.ui.widgets.fontpicker
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local Fonts = require("ui.fonts")
local FontCatalog = require("ui.fonts.catalog")
local Theme = require("ui.themes")
local List = require("ui.themes.widgets.list")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local Text = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookFontPicker
local FontPicker = {}
local TABS = {
    { "user", "用户", "person" },
    { "local", "本地", "folder" },
    { "system", "系统", "text_fields" },
}

---@class FontPickerOpts
---@field title string|nil
---@field initial_tab string|nil 无当前选中项时默认打开的分栏（user/local/system）
---@field on_done fun(id: string, name: string)|nil
---@field current_id? fun(): string|nil
---@field on_select fun(item: MoonFontItem|table, id: string, name: string)|nil

---@param it MoonFontItem|table
---@return boolean
local function isWoffFont(it)
    return it.woff == true or (type(it.id) == "string" and it.id:lower():match("%.woff2?$") ~= nil)
end

---@param it MoonFontItem|table
---@param pw number
---@param fgcolor any
---@return table|nil
local function localPreview(it, pw, fgcolor)
    if not it.id or it.id == "" then
        return nil
    end
    -- 不用直接调用宿主 Font:getFace：系统字体常以 basename 匹配 FontList，
    -- 而 getFace 只转义 `-` 再 path:find，文件名含 `%1` 等会抛 invalid capture index，整页被 Guard 关掉。
    local ok, face = pcall(Fonts.getFace, it.id, Theme.fontSize(18), it.faceindex)
    if not ok then
        require("utils.log").warn("book.font preview failed", it.id, face)
        return nil
    end
    if type(face) ~= "table" then return nil end
    return TextWidget:new{
        text = it.name or _("字体预览"),
        face = face,
        max_width = pw,
        fgcolor = fgcolor or Blitbuffer.COLOR_BLACK,
    }
end

--- 字体行预览：始终占满 pw 并左对齐（贴紧左侧单选框，避免被 Row 的 RightContainer 推到最右）；
--- 用户目录下的 WOFF 字体额外在右侧标明「WOFF · 兼容性差」。
---@param it MoonFontItem|table
---@param pw number
---@param selected boolean
---@return table
local function rowPreview(it, pw, selected)
    local t = Theme.current()
    local inverted = selected and t.selected.ink == 0xFF
    local fg_token = inverted and 0xFF or t.color.ink
    local fg = Theme.color(fg_token)
    if not isWoffFont(it) then
        local text_w = math.max(1, pw - Theme.px(t.space.sm))
        local left = localPreview(it, text_w, fg)
            or Text.line("body", it.name or it.id or "", { width = text_w, color = fg_token })
        return LeftContainer:new{
            dimen = Geom:new{ w = pw, h = left:getSize().h },
            left,
        }
    end
    local badge = Text.line("caption", _("WOFF · 兼容性差"), {
        color = inverted and 0xFF or t.color.muted,
    })
    local badge_w = badge:getSize().w + Theme.px(t.space.sm)
    local name_w = math.max(1, pw - badge_w)
    local left = localPreview(it, name_w, fg)
        or Text.line("body", it.name or it.id or "", { width = name_w, color = fg_token })
    local h = math.max(left:getSize().h, badge:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = name_w, h = h }, left },
        RightContainer:new{ dimen = Geom:new{ w = badge_w, h = h }, badge },
    }
end

---@param opts FontPickerOpts|table
---@param id string
---@param name string
---@param item MoonFontItem|table|nil
local function saveSelection(opts, id, name, item)
    if opts.on_select then
        opts.on_select(item or { id = id, name = name }, id, name)
        if opts.on_done then opts.on_done(id, name) end
        return
    end
    -- set 里 FreeType 实开校验：坏文件拒写，避免下次冷启动 FileManager 直接崩。
    local ok, err = Fonts.set(id, name)
    if not ok then
        Toast:new{ text = err or _("字体无法打开") }:show()
        return
    end
    Toast:new{ text = T(_("已选择：%1"), name), timeout = 2 }:show()
    if opts.on_done then opts.on_done(id, name) end
end

--- 列表已就绪时直接弹选择菜单（阅读页侧栏自己拉列表、借走这个菜单）。
---@param opts FontPickerOpts|table
---@param items MoonFontItem[]|table|nil
function FontPicker.show(opts, items)
    local cur = (opts.current_id and opts.current_id()) or Fonts.currentId()
    local groups = {}
    for _idx, tab in ipairs(TABS) do groups[tab[1]] = {} end
    local active = groups[opts.initial_tab] and opts.initial_tab or "user"
    for _idx, it in ipairs(items or {}) do
        local group = groups[it.kind]
        if group then
            group[#group + 1] = it
            if it.id == cur then active = it.kind end
        end
    end
    local t = Theme.current()
    local icon_w = Theme.px(t.control.icon) + Theme.px(t.space.sm)
    local base_pw = Device.screen:getWidth() - Theme.px(t.space.md) * 2 - icon_w - 1
    local list
    local rowsFor

    local function askDelete(it)
        local name = it.name or it.id
        require("ui.themes.widgets.confirm"):new{
            text = T(_("删除用户字体「%1」？删除后无法恢复，如正在使用将回退系统默认。"), name),
            ok_text = _("删除"),
            ok_callback = function()
                if not Fonts.deleteUserFont(it.id) then
                    Toast:new{ text = _("删除失败") }:show()
                    return
                end
                for i, entry in ipairs(groups.user) do
                    if entry.id == it.id then
                        table.remove(groups.user, i)
                        break
                    end
                end
                if cur == it.id then
                    cur = ""
                    if opts.on_done then opts.on_done("", "") end
                end
                if list then list:setItems(rowsFor("user")) end
                Toast:new{ text = T(_("已删除：%1"), name), timeout = 2 }:show()
            end,
        }:show()
    end

    --- 把某一分组的字体转成列表项；预览由 List 翻到该页时才构建。分组为空给一条禁用占位行。
    ---@param kind string 分组名：user / local / system
    ---@return table[]
    rowsFor = function(kind)
        local rows = {}
        local is_user = kind == "user"
        local pw = math.max(1, is_user and (base_pw - icon_w) or base_pw)
        for _idx, it in ipairs(groups[kind]) do
            local entry = it
            local checked = entry.id == cur
            rows[#rows + 1] = {
                text = "",
                value = entry,
                checked = checked,
                widget = function() return rowPreview(entry, pw, checked) end,
                action_icon = is_user and "delete" or nil,
                action_callback = is_user and function() askDelete(entry) end or nil,
            }
        end
        if #rows == 0 then rows[1] = { text = _("暂无字体"), enabled = false } end
        return rows
    end

    local tabs = {}
    for _idx, tab in ipairs(TABS) do
        tabs[#tabs + 1] = { id = tab[1], text = _(tab[2]), icon = tab[3] }
    end
    list = List:new{
        title = opts.title or _("界面字体"),
        items = rowsFor(active),
        tabs = { tabs = tabs, active = active, on_tab = rowsFor },
        on_select = function(item)
            local name = item.name or item.id
            if isWoffFont(item) then
                require("ui.themes.widgets.confirm"):new{
                    text = T(_("「%1」是 WOFF 格式字体，兼容性差且内存占用较高，建议改用 TTF 字体。仍要使用？"), name),
                    ok_text = _("仍要使用"),
                    ok_callback = function()
                        saveSelection(opts, item.id, name, item)
                    end,
                }:show()
                return
            end
            saveSelection(opts, item.id, name, item)
        end,
    }
    list:show()
end

---@param opts FontPickerOpts|table|nil
function FontPicker.open(opts)
    opts = opts or {}
    local loading = ProgressDialog:new{
        title = opts.title or _("界面字体"), text = _("正在加载字体列表…"), dismissable = false,
    }
    loading:show()
    FontCatalog.listLocalAsync(function(items)
        loading:close()
        if not items then
            Toast:new{ text = _("字体列表加载失败") }:show()
            return
        end
        FontPicker.show(opts, items)
    end)
end

return FontPicker
