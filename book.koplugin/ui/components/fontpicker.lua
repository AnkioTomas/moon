--[[--
界面字体选择器：系统默认 + KOReader fonts/ + 微信读书（可下载）。

预览：
  微信 — previewImageUrl（SVG），走 Image.widget
  本地 — Font:getFace(basename) + TextWidget 渲样张（候选字，不是当前 UI 字）

列表文案只保留来源（本地 / 在线），不显示大小与是否已下载。
打开时先出加载页，再弹列表。

只负责选中后 MoonFont.set（写配置）；不碰 Font.fontmap。
真正 apply 在 Desktop:rebuild（及 Host.attach）。

布局（走 Popup.list）：
  +----------------------------------+
  | 界面字体                         |
  |----------------------------------|
  | ✓ 系统默认                       |
  | ✓ 本地   [样张 TextWidget]        |
  |   在线   [==== 预览图 ====]       |
  | …                                |
  | Page N of M                      |
  +----------------------------------+

  FontPicker.open{
    title   = _("界面字体"),
    on_done = function(id, name) end,
  }

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
local Popup = require("ui.components.popup")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local FontPicker = {}

---@class FontPickerOpts
---@field title string|nil
---@field on_done fun(id: string, name: string)|nil

--- 把字节数格式化为 MB 文案。
---@param n number|nil
---@return string
local function formatZipMb(n)
    n = tonumber(n) or 0
    if n <= 0 then
        return ""
    end
    return string.format("%.1fMB", n / (1024 * 1024))
end

--- 字体预览区域宽高。
---@return number, number
local function previewSize()
    local w = math.max(UI.sz(120), math.floor(Screen:getWidth() * 0.48))
    local h = UI.sz(36)
    return w, h
end

--- 本地字体样张：用候选文件的 face，不用当前 UI 字。
---@param it MoonFontItem|table
---@return table|nil, number|nil
local function localPreview(it)
    if it.kind ~= "local" or not it.id or it.id == "" then
        return nil
    end
    local pw = select(1, previewSize())
    local face = Font:getFace(it.id, UI.fontSize(18))
    if not face then
        return nil
    end
    local tw = TextWidget:new{
        text = it.name or _("字体预览"),
        face = face,
        max_width = pw,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    return tw, math.min(pw, tw:getSize().w)
end

--- 左侧文案：✓ + 来源（本地/在线）。
---@param it table
---@param cur string
---@return string, string
local function rowMeta(it, cur)
    local mark = (it.id == cur) and "✓ " or ""
    local kind = it.kind == "local" and _("本地") or _("在线")
    return mark, kind
end

--- 写配置 + 提示；不 apply。
---@param opts FontPickerOpts|table
---@param id string
---@param name string
local function saveSelection(opts, id, name)
    MoonFont.set(id, name)
    if id == "" then
        UIManager:show(InfoMessage:new{
            text = _("已选择系统默认字体"),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("已选择：%1"), name),
            timeout = 2,
        })
    end
    if opts.on_done then
        opts.on_done(id, name)
    end
end

--- 下载 weread 字体后 saveSelection。
---@param opts FontPickerOpts|table
---@param item MoonFontItem|table
local function downloadAndSave(opts, item)
    local id = item.id or ""
    local name = item.name or id
    local zip_max = tonumber(item.zip_size) or 0
    local size = formatZipMb(zip_max)
    local dialog
    local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if ok_dlg and ProgressbarDialog then
        dialog = ProgressbarDialog:new{
            title = T(_("正在下载字体 %1"), name),
            subtitle = size ~= "" and size or _("请稍候…"),
            progress_max = zip_max > 0 and zip_max or nil,
            refresh_time_seconds = 0.1,
            dismissable = false,
        }
        dialog:show()
    else
        UIManager:show(InfoMessage:new{
            text = T(_("正在下载字体 %1…"), name),
            timeout = 1,
        })
    end

    MoonFont.ensureInstalledAsync(item, function(bytes)
        if dialog and zip_max > 0 then
            dialog:reportProgress(bytes)
        end
    end, function(ok, err)
        if ok then
            if dialog then
                if zip_max > 0 then
                    dialog:reportProgress(zip_max)
                end
                dialog:close()
                dialog = nil
            end
            saveSelection(opts, id, name)
        else
            if dialog then
                dialog:close()
                dialog = nil
            end
            UIManager:show(InfoMessage:new{
                text = err or _("字体下载失败"),
            })
        end
    end)
end

--- 弹出字体选择列表。
---@param opts FontPickerOpts|table
---@param items MoonFontItem[]|table|nil
local function showPicker(opts, items)
    local cur = MoonFont.currentId()
    local pw, ph = previewSize()
    local default_label = _("系统默认")
    local rows = {
        {
            text = (cur == "") and ("✓ " .. default_label) or default_label,
            value = { id = "", name = default_label, kind = "default" },
        },
    }
    for _i, it in ipairs(items or {}) do
        local mark, kind = rowMeta(it, cur)
        local row = {
            text = mark .. kind,
            value = it,
            fallback = it.name,
        }
        if it.kind == "weread" and it.preview and it.preview ~= "" then
            row.image = it.preview
            row.image_w = pw
            row.image_h = ph
        else
            local preview, ww = localPreview(it)
            if preview then
                row.widget = preview
                row.widget_w = ww
            else
                row.text = mark .. (it.name or "") .. " · " .. kind
            end
        end
        table.insert(rows, row)
    end
    Popup.list{
        title = opts.title or _("界面字体"),
        items = rows,
        image_w = pw,
        image_h = ph,
        on_select = function(item)
            if type(item) ~= "table" then
                return
            end
            local id = item.id or ""
            local name = item.name or id
            if id == "" or item.kind == "local" or MoonFont.isInstalled(item) then
                saveSelection(opts, id, name)
                return
            end
            NetworkMgr:runWhenOnline(function()
                downloadAndSave(opts, item)
            end)
        end,
    }
end

--- 是否存在 weread 项但全部缺预览图。
---@param items table|nil
---@return boolean
local function wereadMissingPreview(items)
    local saw = false
    for _, it in ipairs(items or {}) do
        if it.kind == "weread" then
            saw = true
            if it.preview and it.preview ~= "" then
                return false
            end
        end
    end
    return saw
end

--- 先加载页，再弹列表。
---@param opts FontPickerOpts|table|nil
function FontPicker.open(opts)
    opts = opts or {}
    local loading = InfoMessage:new{ text = _("正在加载字体列表…") }
    UIManager:show(loading)
    local cached = MoonFont.list(false)
    local need_weread = (not MoonFont.hasWereadCache()) or wereadMissingPreview(cached)
    local cancelled = false
    local function finish(items)
        if cancelled then return end
        UIManager:close(loading)
        if not items then
            UIManager:show(InfoMessage:new{ text = _("字体列表加载失败") })
            return
        end
        showPicker(opts, items)
    end
    local fetch_job
    if need_weread and NetworkMgr:isOnline() then
        fetch_job = MoonFont.listAsync(true, function(items)
            finish(items or cached)
        end)
        -- loading 关闭时取消 fetch
        loading.dismiss_callback = function()
            cancelled = true
            if fetch_job and fetch_job.cancel then
                fetch_job.cancel()
            end
        end
    else
        UIManager:nextTick(function()
            finish(cached)
        end)
    end
end

return FontPicker
