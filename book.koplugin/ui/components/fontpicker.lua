--[[--
界面字体选择器：koreader/fonts 本地字 + 微信读书（可下载）。

预览按页懒构建（禁止打开时全表 getFace / 拉图）。
列表走 MoonFont.listAsync（http.Cache 优先，不强制刷新）。
无「系统默认」项；空配置仍由 applyCurrent 回退 fontmap 备份。

@module koplugin.book.ui.components.fontpicker
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local MoonFont = require("utils.font")
local Image = require("ui.components.image")
local Popup = require("ui.components.popup")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local FontPicker = {}

---@class FontPickerOpts
---@field title string|nil
---@field on_done fun(id: string, name: string)|nil

local function previewSize()
    return math.max(UI.sz(120), math.floor(Screen:getWidth() * 0.48)), UI.sz(36)
end

---@param it MoonFontItem|table
---@param pw number
---@return table|nil
local function localPreview(it, pw)
    if it.kind ~= "local" or not it.id or it.id == "" then return nil end
    local face = Font:getFace(it.id, UI.fontSize(18))
    if not face then return nil end
    return TextWidget:new{
        text = it.name or _("字体预览"),
        face = face,
        max_width = pw,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

---@param it MoonFontItem|table
---@param pw number
---@param ph number
---@param menu table
---@return table|nil
local function wereadPreview(it, pw, ph, menu)
    if it.kind ~= "weread" or type(it.preview) ~= "string" or it.preview == "" then
        return nil
    end
    return Image.widget{
        src = it.preview,
        width = pw,
        height = ph,
        alpha = true,
        fallback = it.name,
        show_parent = menu,
    }
end

---@param it table
---@param cur string
---@return string
local function rowText(it, cur)
    local mark = (it.id == cur) and "✓ " or ""
    local kind = it.kind == "local" and _("本地") or _("在线")
    if it.kind == "weread" and (type(it.preview) ~= "string" or it.preview == "") then
        return mark .. (it.name or "") .. " · " .. kind
    end
    return mark .. kind
end

---@param opts FontPickerOpts|table
---@param id string
---@param name string
local function saveSelection(opts, id, name)
    MoonFont.set(id, name)
    UIManager:show(InfoMessage:new{
        text = T(_("已选择：%1"), name),
        timeout = 2,
    })
    if opts.on_done then opts.on_done(id, name) end
end

---@param opts FontPickerOpts|table
---@param item MoonFontItem|table
local function downloadAndSave(opts, item)
    local id, name = item.id or "", item.name or item.id or ""
    local zip_max = tonumber(item.zip_size) or 0
    local dialog
    local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if ok_dlg and ProgressbarDialog then
        dialog = ProgressbarDialog:new{
            title = T(_("正在下载字体 %1"), name),
            subtitle = zip_max > 0 and string.format("%.1fMB", zip_max / (1024 * 1024)) or _("请稍候…"),
            progress_max = zip_max > 0 and zip_max or nil,
            refresh_time_seconds = 0.1,
            dismissable = false,
        }
        dialog:show()
    end
    MoonFont.ensureInstalledAsync(item, function(bytes)
        if dialog and zip_max > 0 then dialog:reportProgress(bytes) end
    end, function(ok, err)
        if dialog then
            if ok and zip_max > 0 then dialog:reportProgress(zip_max) end
            dialog:close()
        end
        if ok then
            saveSelection(opts, id, name)
        else
            UIManager:show(InfoMessage:new{ text = err or _("字体下载失败") })
        end
    end)
end

--- 当前页补预览；挂钩 updateItems，翻页再建。
---@param menu table
---@param sources table
---@param pw number
---@param ph number
local function attachLazyPreviews(menu, sources, pw, ph)
    local done = {}
    local orig = menu.updateItems
    menu.updateItems = function(self, select_number, no_recalculate_dimen)
        local per = self.perpage or 14
        local first = ((self.page or 1) - 1) * per + 1
        local last = math.min(#self.item_table, first + per - 1)
        for i = first, last do
            if not done[i] then
                done[i] = true
                local src = sources[i]
                if type(src) == "table" then
                    local state = localPreview(src, pw) or wereadPreview(src, pw, ph, self)
                    if state then self.item_table[i].state = state end
                end
            end
        end
        if not self.state_w or self.state_w < pw then self.state_w = pw end
        return orig(self, select_number, no_recalculate_dimen)
    end
    menu:updateItems(nil, true)
end

---@param opts FontPickerOpts|table
---@param items MoonFontItem[]|table|nil
local function showPicker(opts, items)
    local cur = MoonFont.currentId()
    local pw, ph = previewSize()
    local rows, sources = {}, {}
    for _, it in ipairs(items or {}) do
        rows[#rows + 1] = { text = rowText(it, cur), value = it, fallback = it.name }
        sources[#sources + 1] = it
    end
    local menu = Popup.list{
        title = opts.title or _("界面字体"),
        items = rows,
        on_select = function(item)
            if type(item) ~= "table" then return end
            local id, name = item.id or "", item.name or item.id or ""
            if item.kind == "local" or MoonFont.isInstalled(item) then
                saveSelection(opts, id, name)
                return
            end
            NetworkMgr:runWhenOnline(function() downloadAndSave(opts, item) end)
        end,
    }
    attachLazyPreviews(menu, sources, pw, ph)
end

---@param opts FontPickerOpts|table|nil
function FontPicker.open(opts)
    opts = opts or {}
    local loading = InfoMessage:new{ text = _("正在加载字体列表…") }
    UIManager:show(loading)
    local cancelled = false
    local job = MoonFont.listAsync(false, function(items)
        if cancelled then return end
        UIManager:close(loading)
        if not items then
            UIManager:show(InfoMessage:new{ text = _("字体列表加载失败") })
            return
        end
        showPicker(opts, items)
    end)
    loading.dismiss_callback = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end
end

return FontPicker
