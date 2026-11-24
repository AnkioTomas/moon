--[[--
在线字体下载页（moon-store.ankio.net）：按在线分类（全部 / 宋体 / 黑体 / 楷体 / 圆体 / 其他）
浏览远程字体名预览图，点按下载到本地用户字体目录（$DATA/fonts）。

- 预览按页懒构建（560×120 PNG，等比缩放 + 夜间反色）。
- 左上角刷新按钮强制重新拉取在线列表。
- 已下载的字体标为已下载，点按可「设为界面字体」「重新下载」或「删除」。

@module koplugin.book.ui.widgets.online_fonts
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local NetworkMgr = require("ui/network/manager")
local RightContainer = require("ui/widget/container/rightcontainer")
local Fonts = require("ui.fonts")
local FontCatalog = require("ui.fonts.catalog")
local Theme = require("ui.themes")
local Image = require("ui.themes.widgets.image")
local List = require("ui.themes.widgets.list")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local Text = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local TaskDialog = require("workers.ui.task_dialog")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookOnlineFonts
local OnlineFonts = {}

local PREVIEW_W = 560
local PREVIEW_H = 120

local CATEGORY_TABS = {
    { id = "all", text = "全部", icon = "apps" },
    { id = "song", text = "宋体", icon = "title" },
    { id = "hei", text = "黑体", icon = "text_fields" },
    { id = "kai", text = "楷体", icon = "brush" },
    { id = "yuan", text = "圆体", icon = "circle" },
    { id = "other", text = "其他", icon = "more_horiz" },
}

---@param bytes number|nil
---@return string
local function formatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes <= 0 then return "" end
    if bytes < 1024 * 1024 then
        return string.format("%.0f KB", bytes / 1024)
    end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

---@param it MoonFontItem|table
---@param pw number
---@param ph number
---@param downloaded boolean
---@return table|nil
local function rowPreview(it, pw, ph, downloaded)
    local t = Theme.current()
    local label_text = downloaded and _("已下载") or (it.size_label or formatSize(it.size))
    local label = label_text ~= "" and Text.line("caption", label_text, {
        color = downloaded and t.color.accent or t.color.muted,
    }) or nil
    local label_w = label and (label:getSize().w + Theme.px(t.space.sm)) or 0
    local img_max_w = math.max(1, pw - label_w)
    local left_widget
    if type(it.preview) == "string" and it.preview ~= "" then
        left_widget = Image.widget({
            src = it.preview,
            width = math.min(img_max_w, math.floor(ph * PREVIEW_W / PREVIEW_H)),
            height = ph,
            style = {},
            stretch = true,
            invert_in_night = true,
            fallback = it.name,
        })
    else
        left_widget = Text.line("body", it.name or it.id or "", { width = img_max_w, color = t.color.ink })
    end
    if not label then
        return LeftContainer:new{ dimen = Geom:new{ w = pw, h = ph }, left_widget }
    end
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = img_max_w, h = ph }, left_widget },
        RightContainer:new{ dimen = Geom:new{ w = label_w, h = ph }, label },
    }
end

---@param opts { on_done?: fun() }
---@param item MoonFontItem|table
---@param on_updated fun()
local function downloadFont(opts, item, on_updated)
    local name = item.name or item.id or ""
    local total_bytes = tonumber(item.size) or 0
    local key_id = FontCatalog.targetFilename(item) or item.id or name
    TaskDialog.start{
        key = "font\0" .. key_id,
        kind = "download",
        title = name,
        restartable = true,
        run = function(report, done)
            if total_bytes > 0 then report(nil, 0, total_bytes) end
            return FontCatalog.downloadToUserAsync(item, function(bytes)
                report(nil, bytes, total_bytes > 0 and total_bytes or nil)
            end, function(ok, detail)
                done({
                    ok = ok == true,
                    filename = ok and detail or nil,
                    err = (not ok) and detail or nil,
                })
            end)
        end,
        on_done = function(result)
            if not result.ok then
                Toast:new{ text = result.err or _("字体下载失败") }:show()
                return
            end
            on_updated()
            Toast:new{ text = T(_("已下载到用户字体：%1"), name), timeout = 2 }:show()
            if opts.on_done then opts.on_done() end
        end,
    }
end

---@param opts { on_done?: fun() }
---@param item MoonFontItem|table
---@param on_updated fun()
local function askDownloadedAction(opts, item, on_updated)
    local name = item.name or item.id or ""
    local filename = FontCatalog.targetFilename(item)
    require("ui.themes.widgets.sheet"):new{
        title = name,
        items = {
            { text = _("设为界面字体"), callback = function()
                if not filename then return end
                local ok, err = Fonts.set(filename, name)
                if not ok then
                    Toast:new{ text = err or _("字体无法打开") }:show()
                    return
                end
                Fonts.applyCurrent()
                Toast:new{ text = T(_("已选择：%1"), name), timeout = 2 }:show()
                if opts.on_done then opts.on_done() end
            end },
            { text = _("重新下载"), callback = function()
                downloadFont(opts, item, on_updated)
            end },
            { text = _("删除"), callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = T(_("删除用户字体「%1」？删除后无法恢复，如正在使用将回退系统默认。"), name),
                    ok_text = _("删除"),
                    ok_callback = function()
                        if not filename or not Fonts.deleteUserFont(filename) then
                            Toast:new{ text = _("删除失败") }:show()
                            return
                        end
                        on_updated()
                        Toast:new{ text = T(_("已删除：%1"), name), timeout = 2 }:show()
                        if opts.on_done then opts.on_done() end
                    end,
                }:show()
            end },
        },
    }:show()
end

---@param items MoonFontItem[]
---@return table<string, MoonFontItem[]>
local function groupByCategory(items)
    local groups = { all = {} }
    for _idx, tab in ipairs(CATEGORY_TABS) do
        if tab.id ~= "all" then groups[tab.id] = {} end
    end
    for _idx, it in ipairs(items or {}) do
        groups.all[#groups.all + 1] = it
        local cat = type(it.category) == "string" and groups[it.category] and it.category or "other"
        groups[cat][#groups[cat] + 1] = it
    end
    return groups
end

--- 列表已就绪时直接展示按分类分组的在线字体页。
---@param opts { title?: string, initial_category?: string, on_done?: fun() }|nil
---@param items MoonFontItem[]
function OnlineFonts.show(opts, items)
    opts = opts or {}
    local groups = groupByCategory(items)
    local active = groups[opts.initial_category] and opts.initial_category or "all"
    local t = Theme.current()
    local pw = Device.screen:getWidth() - Theme.px(t.space.md) * 2
        - Theme.px(t.control.icon) - Theme.px(t.space.sm) - 1
    local ph = Theme.px(36)
    local list
    local closed = false
    local rowsFor

    local function refreshCurrent()
        if list and not closed then list:setItems(rowsFor(list.tabs.active)) end
    end

    rowsFor = function(cat_id)
        local rows = {}
        for _idx, it in ipairs(groups[cat_id] or {}) do
            local entry = it
            local downloaded = FontCatalog.isDownloadedToUser(entry)
            rows[#rows + 1] = {
                text = "",
                icon = downloaded and "check_circle" or "download",
                value = entry,
                keep_open = true,
                widget = function() return rowPreview(entry, pw, ph, downloaded) end,
                callback = function()
                    if FontCatalog.isDownloadedToUser(entry) then
                        askDownloadedAction(opts, entry, refreshCurrent)
                    else
                        downloadFont(opts, entry, refreshCurrent)
                    end
                end,
            }
        end
        if #rows == 0 then rows[1] = { text = _("暂无字体"), enabled = false } end
        return rows
    end

    local tabs = {}
    for _idx, tab in ipairs(CATEGORY_TABS) do
        tabs[#tabs + 1] = { id = tab.id, text = _(tab.text), icon = tab.icon }
    end

    local function forceRefresh()
        NetworkMgr:runWhenConnected(function()
            local loading = ProgressDialog:new{
                title = opts.title or _("在线字体"), text = _("正在刷新字体列表…"), dismissable = false,
            }
            loading:show()
            FontCatalog.listOnlineAsync(function(fresh, err)
                loading:close()
                if not fresh then
                    Toast:new{ text = err or _("字体列表加载失败") }:show()
                    return
                end
                groups = groupByCategory(fresh)
                refreshCurrent()
                Toast:new{ text = _("字体列表已更新"), timeout = 2 }:show()
            end, { force = true })
        end)
    end

    list = List:new{
        title = opts.title or _("在线字体"),
        left_icon = "refresh",
        left_callback = forceRefresh,
        items = rowsFor(active),
        tabs = { tabs = tabs, active = active, on_tab = rowsFor },
        close_callback = function() closed = true end,
    }
    list:show()
end

---@param opts { title?: string, initial_category?: string, on_done?: fun() }|nil
function OnlineFonts.open(opts)
    opts = opts or {}
    local loading = ProgressDialog:new{
        title = opts.title or _("在线字体"), text = _("正在加载字体列表…"), dismissable = false,
    }
    loading:show()
    FontCatalog.listOnlineAsync(function(items, err)
        loading:close()
        if not items then
            Toast:new{ text = err or _("字体列表加载失败") }:show()
            return
        end
        OnlineFonts.show(opts, items)
    end)
end

return OnlineFonts
