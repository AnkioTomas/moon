--[[--
界面字体选择器：本地/系统字库 + 微信读书（可下载）。

底部 Tab 栏（在线/本地/系统）走 Popup 的 bottom_tabs（完整 pager 之下独立一行）。
列表行只留通栏预览：本地/系统把字体名用该字体渲染，在线用远程预览图；当前项左侧标 ✓。
预览按页懒构建（禁止打开时全表 getFace / 拉图）。
列表走 MoonFont.listAsync（http.Cache 优先，不强制刷新）。
无「系统默认」项；空配置仍由 applyCurrent 回退 fontmap 备份。

@module koplugin.book.ui.components.fontpicker
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local MoonFont = require("utils.font")
local Image = require("ui.components.image")
local Popup = require("ui.components.popup")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template

local FontPicker = {}
local TABS = {
    { "weread", "在线", "cloud" },
    { "local", "本地", "folder" },
    { "system", "系统", "desktop_windows" },
}

---@class FontPickerOpts
---@field title string|nil
---@field on_done fun(id: string, name: string)|nil

---@param it MoonFontItem|table
---@param pw number
---@return table|nil
local function localPreview(it, pw)
    if (it.kind ~= "local" and it.kind ~= "system") or not it.id or it.id == "" then
        return nil
    end
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

--- 当前页补预览；挂钩 updateItems。
--- Menu 翻页会 free 旧 item 的 state，所以每次 updateItems 都对当前页重建，不能跨页缓存。
--- 预览宽度 = 行内容宽（屏宽扣行 padding）；state 容器不裁剪，预览通栏绘制。
--- 禁止回写 state_w：文字列剩余宽 = 内容宽 - state_w，撑满会让 TextWidget 拿到负宽崩溃。
---@param menu table
---@param sources table
local function attachLazyPreviews(menu, sources)
    local pw = menu.inner_dimen.w - 2 * Size.padding.fullscreen
    local ph = UI.sz(36)
    local orig = menu.updateItems
    menu.updateItems = function(self, select_number, no_recalculate_dimen)
        local per = self.perpage or 14
        local first = ((self.page or 1) - 1) * per + 1
        local last = math.min(#self.item_table, first + per - 1)
        for i = first, last do
            local src = sources.list[i]
            if type(src) == "table" then
                local state = localPreview(src, pw) or wereadPreview(src, pw, ph, self)
                if state then self.item_table[i].state = state end
            end
        end
        return orig(self, select_number, no_recalculate_dimen)
    end
    menu:updateItems(nil, true)
end

---@param opts FontPickerOpts|table
---@param items MoonFontItem[]|table|nil
local function showPicker(opts, items)
    local cur = MoonFont.currentId()
    local groups = { weread = {}, ["local"] = {}, system = {} }
    local active = "weread"
    for _, it in ipairs(items or {}) do
        (groups[it.kind] or groups.weread)[#(groups[it.kind] or groups.weread) + 1] = it
        if it.id == cur and groups[it.kind] then active = it.kind end
    end
    local menu
    local sources = { list = {} }
    local function rowsFor(kind)
        local rows, sources = {}, {}
        for _, it in ipairs(groups[kind]) do
            rows[#rows + 1] = { text = "", value = it, fallback = it.name,
                mandatory = it.id == cur and "✓" or nil } -- 当前项标记放右侧，避免盖住预览左端
            sources[#sources + 1] = it
        end
        if #rows == 0 then rows[1] = { text = _("暂无字体"), enabled = false } end
        return rows, sources
    end
    local function select(item)
        if menu then UIManager:close(menu); menu = nil end
        if item.kind == "local" or item.kind == "system" or MoonFont.isInstalled(item) then
            saveSelection(opts, item.id, item.name or item.id)
        else
            NetworkMgr:runWhenOnline(function() downloadAndSave(opts, item) end)
        end
    end
    local function switch(kind)
        local rows, list = rowsFor(kind)
        sources.list = list
        Popup.setListItems(menu, opts.title or _('界面字体'), rows, select)
        menu:setBottomTabActive(kind)
        menu:updateItems(nil, true)
    end
    local tabs = {}
    for i, tab in ipairs(TABS) do
        tabs[i] = { id = tab[1], text = _(tab[2]), icon = tab[3] }
    end
    local rows, initial_sources = rowsFor(active)
    sources.list = initial_sources
    menu = Popup.single{
        title = opts.title or _("界面字体"),
        items = rows,
        on_select = select,
        bottom_tabs = { tabs = tabs, active = active, on_tab = switch },
    }
    attachLazyPreviews(menu, sources)
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
