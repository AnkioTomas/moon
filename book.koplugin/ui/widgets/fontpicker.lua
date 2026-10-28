--[[--
界面字体选择器：用户/本地/系统字库 + 微信读书（可下载）。

底部分栏（在线/用户/本地/系统）走主题 List 的 tabs。
列表行只留通栏预览：已装字体把字体名用该字体渲染，在线用远程预览图；当前项是选中的单选标记。
预览按页懒构建（List 翻到该页才调 item.widget；禁止打开时全表 getFace / 拉图）。
列表走 FontCatalog.listAsync（微信列表经 http.Cache，TTL 内不联网）。
无「系统默认」项；空配置仍由 applyCurrent 回退 fontmap 备份。

@module koplugin.book.ui.widgets.fontpicker
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local Fonts = require("ui.fonts")
local FontCatalog = require("ui.fonts.catalog")
local Theme = require("ui.themes")
local Image = require("ui.themes.widgets.image")
local List = require("ui.themes.widgets.list")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookFontPicker
local FontPicker = {}
local TABS = {
    { "weread", "在线", "cloud" },
    { "user", "用户", "person" },
    { "local", "本地", "folder" },
    { "system", "系统", "text_fields" },
}

---@class FontPickerOpts
---@field title string|nil
---@field initial_tab string|nil 无当前选中项时默认打开的分栏
---@field on_done fun(id: string, name: string)|nil
---@field current_id? fun(): string|nil
---@field on_select fun(item: MoonFontItem|table, id: string, name: string)|nil

---@param it MoonFontItem|table
---@param pw number
---@return table|nil
local function localPreview(it, pw)
    if it.kind == "weread" or not it.id or it.id == "" then
        return nil
    end
    local face = Font:getFace(it.id, Theme.fontSize(18))
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
---@return table|nil
local function wereadPreview(it, pw, ph)
    if it.kind ~= "weread" or type(it.preview) ~= "string" or it.preview == "" then
        return nil
    end
    -- 微信预览图都是 90×24 的透明 SVG：按比例定宽才能和本地字体名一样靠左；style = {} 去掉 image 表面的灰底。
    return Image.widget({
        src = it.preview,
        width = math.min(pw, math.floor(ph * 90 / 24)),
        height = ph,
        style = {},
        alpha = true,
        invert_in_night = true,
        fallback = it.name,
    })
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
    Fonts.set(id, name)
    Toast:new{ text = T(_("已选择：%1"), name), timeout = 2 }:show()
    if opts.on_done then opts.on_done(id, name) end
end

---@param opts FontPickerOpts|table
---@param item MoonFontItem|table
local function downloadAndSave(opts, item)
    local id, name = item.id or "", item.name or item.id or ""
    local zip_max = tonumber(item.zip_size) or 0
    local install_job
    local done = false
    -- 收起弹窗即取消下载；下载结束后关窗不算取消。
    local dialog = ProgressDialog:new{
        title = T(Fonts.downloadedPath(id) and _("正在准备字体 %1") or _("正在下载字体 %1"), name),
        close_callback = function()
            if done then return end
            done = true
            if install_job then install_job.cancel() end
        end,
    }
    dialog:show()
    if zip_max > 0 then dialog:bytes(0, zip_max) end
    install_job = FontCatalog.ensureInstalledAsync(item, function(bytes)
        if not done and zip_max > 0 then dialog:bytes(bytes, zip_max) end
    end, function(ok, err)
        if done then return end
        done = true
        dialog:close()
        if ok then
            saveSelection(opts, id, name, item)
        else
            Toast:new{ text = err or _("字体下载失败") }:show()
        end
    end)
end

--- 已下载的在线字体：选「使用」或确认后删除文件；删的正是当前字体时恢复系统默认。
---@param opts FontPickerOpts|table
---@param item MoonFontItem|table
---@param current_id string
local function askUseOrDelete(opts, item, current_id)
    local name = item.name or item.id
    require("ui.themes.widgets.sheet"):new{
        title = name,
        items = {
            { text = _("使用"), callback = function() downloadAndSave(opts, item) end },
            { text = _("删除字体"), callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = T(_("删除已下载的字体 %1？需要时可重新下载。"), name),
                    ok_text = _("删除"),
                    ok_callback = function()
                        if not Fonts.removeDownloaded(item.id) then
                            Toast:new{ text = _("删除失败") }:show()
                            return
                        end
                        if item.id == current_id and not opts.on_select then Fonts.set("") end
                        Toast:new{ text = T(_("已删除：%1"), name), timeout = 2 }:show()
                    end,
                } :show()
            end },
        },
    }:show()
end

--- 列表已就绪时直接弹选择菜单（阅读页侧栏自己拉列表、借走这个菜单）。
---@param opts FontPickerOpts|table
---@param items MoonFontItem[]|table|nil
function FontPicker.show(opts, items)
    local cur = (opts.current_id and opts.current_id()) or Fonts.currentId()
    local groups = {}
    for _idx, tab in ipairs(TABS) do groups[tab[1]] = {} end
    local active = opts.initial_tab or "weread"
    for _idx, it in ipairs(items or {}) do
        local group = groups[it.kind] or groups.weread
        group[#group + 1] = it
        if it.id == cur and groups[it.kind] then active = it.kind end
    end
    -- 预览占满行内文字区：行宽扣两侧 md 边距、单选标记和它后面的 sm 间隔。
    local t = Theme.current()
    local pw = Device.screen:getWidth() - Theme.px(t.space.md) * 2
        - Theme.px(t.control.icon) - Theme.px(t.space.sm) * 2
    local ph = Theme.px(36)
    --- 把某一分组的字体转成列表项；预览由 List 翻到该页时才构建。分组为空给一条禁用占位行。
    ---@param kind string 分组名：weread / user / local / system
    ---@return table[]
    local function rowsFor(kind)
        local rows = {}
        for _idx, it in ipairs(groups[kind]) do
            rows[#rows + 1] = {
                text = "",
                value = it,
                checked = it.id == cur,
                widget = function() return localPreview(it, pw) or wereadPreview(it, pw, ph) end,
            }
        end
        if #rows == 0 then rows[1] = { text = _("暂无字体"), enabled = false } end
        return rows
    end
    local tabs = {}
    for i, tab in ipairs(TABS) do
        tabs[i] = { id = tab[1], text = _(tab[2]), icon = tab[3] }
    end
    List:new{
        title = opts.title or _("界面字体"),
        items = rowsFor(active),
        tabs = { tabs = tabs, active = active, on_tab = rowsFor },
        --- 本地/系统/已安装的直接落盘，未安装的联网下载后再落盘。
        on_select = function(item)
            if item.kind ~= "weread" then
                saveSelection(opts, item.id, item.name or item.id, item)
            elseif Fonts.downloadedPath(item.id) then
                askUseOrDelete(opts, item, cur)
            else
                NetworkMgr:runWhenConnected(function() downloadAndSave(opts, item) end)
            end
        end,
    }:show()
end

---@param opts FontPickerOpts|table|nil
function FontPicker.open(opts)
    opts = opts or {}
    local loading = ProgressDialog:new{
        title = opts.title or _("界面字体"), text = _("正在加载字体列表…"), dismissable = false,
    }
    loading:show()
    FontCatalog.listAsync(function(items)
        loading:close()
        if not items then
            Toast:new{ text = _("字体列表加载失败") }:show()
            return
        end
        FontPicker.show(opts, items)
    end)
end

return FontPicker
