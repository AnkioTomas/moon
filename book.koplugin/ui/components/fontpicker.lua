--[[--
微信读书字库选择器（列表 / 下载进度 / 应用）

依赖 moon.font：list / isInstalled / ensureInstalled / set / currentId。
下载走 Flight 单飞（key=`font:<id>`）+ ProgressbarDialog；无进度条时降级 InfoMessage。

  FontPicker.open{
    title   = _("界面字体"),              -- 可选；列表标题
    on_done = function(id, name) end,     -- 可选；MoonFont.set 成功后回调
  }

流程：
  1. list(false) 有缓存 → 直接弹列表
  2. 无缓存 → 联网 list(true) 后再弹
  3. 选「系统默认」(id="") → 直接 set
  4. 已下载 → 直接 set
  5. 未下载 → 联网 ensureInstalled → set

@module koplugin.book.ui.components.fontpicker
--]]

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Async = require("moon.async")
local Flight = require("moon.flight")
local MoonFont = require("moon.font")
local Popup = require("ui.components.popup")
local _ = require("gettext")
local T = require("ffi/util").template

local FontPicker = {}

---@class FontPickerOpts
---@field title string|nil 列表标题；默认「界面字体」
---@field on_done fun(id: string, name: string)|nil set 成功后回调（设置页用来 rebuild）

--- zip_size 字节 → "1.2MB"；≤0 返回空串（不展示）
---@param n number|nil
---@return string
local function formatZipMb(n)
    n = tonumber(n) or 0
    if n <= 0 then
        return ""
    end
    return string.format("%.1fMB", n / (1024 * 1024))
end

--- MoonFont.set + 成功/失败提示；成功再调 opts.on_done
---@param opts FontPickerOpts
---@param id string 空=恢复系统默认
---@param name string 展示名
local function applyFont(opts, id, name)
    local ok, err = MoonFont.set(id, name)
    if not ok then
        UIManager:show(InfoMessage:new{ text = err or _("应用字体失败") })
        return
    end
    if id == "" then
        UIManager:show(InfoMessage:new{
            text = _("已恢复系统默认字体"),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("已应用：%1"), name),
            timeout = 2,
        })
    end
    if opts.on_done then
        opts.on_done(id, name)
    end
end

--- 下载字体（Flight 单飞）成功后 applyFont
---@param opts FontPickerOpts
---@param item MoonFontItem
local function downloadAndApply(opts, item)
    local id = item.id or ""
    local name = item.name or id
    local key = "font:" .. tostring(id)
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

    Flight.watch(key, function(result)
        if dialog then
            if result and result.ok and zip_max > 0 then
                dialog:reportProgress(zip_max)
            end
            dialog:close()
            dialog = nil
        end
        if type(result) ~= "table" or not result.ok then
            UIManager:show(InfoMessage:new{
                text = (result and result.err) or _("字体下载失败"),
            })
            return
        end
        applyFont(opts, id, name)
    end)

    Flight.run(key, function()
        local ok, err = MoonFont.ensureInstalled(item, function(bytes)
            if dialog and zip_max > 0 then
                dialog:reportProgress(bytes)
            end
        end)
        if ok then
            return { ok = true }
        end
        return { ok = false, err = err or _("字体下载失败") }
    end)
end

--- 弹出 Popup.list：首行系统默认 + 字库项（✓ / 大小 / 未下载）
---@param opts FontPickerOpts
---@param items MoonFontItem[]|nil
local function showPicker(opts, items)
    local cur = MoonFont.currentId()
    local default_label = _("系统默认")
    local rows = {
        {
            text = (cur == "") and ("✓ " .. default_label) or default_label,
            value = { id = "", name = default_label },
        },
    }
    for _, it in ipairs(items or {}) do
        local mark = (it.id == cur) and "✓ " or ""
        local size = formatZipMb(it.zip_size)
        local suffix = size ~= "" and (" · " .. size) or ""
        local installed = MoonFont.isInstalled(it.id) and "" or _(" · 未下载")
        table.insert(rows, {
            text = mark .. it.name .. suffix .. installed,
            value = it,
        })
    end
    Popup.list{
        title = opts.title or _("界面字体"),
        items = rows,
        on_select = function(item)
            if type(item) ~= "table" then
                return
            end
            local id = item.id or ""
            local name = item.name or id
            if id == "" then
                applyFont(opts, "", name)
                return
            end
            if MoonFont.isInstalled(id) then
                applyFont(opts, id, name)
                return
            end
            NetworkMgr:runWhenOnline(function()
                downloadAndApply(opts, item)
            end)
        end,
    }
end

--- 打开字体选择器；有本地 list 缓存则立即弹，否则联网拉取
---@param opts FontPickerOpts|nil
---
--- opts 字段：
---   title    string|nil                 列表标题，默认「界面字体」
---   on_done  fun(id, name)|nil          set 成功后回调；id="" 表示系统默认
function FontPicker.open(opts)
    opts = opts or {}
    local cached = MoonFont.list(false)
    if cached then
        showPicker(opts, cached)
        return
    end
    NetworkMgr:runWhenOnline(function()
        local loading = InfoMessage:new{ text = _("正在获取字体列表…") }
        UIManager:show(loading)
        Async.run(function()
            return MoonFont.list(true)
        end, function(ok, items, err)
            UIManager:close(loading)
            if not ok or not items then
                UIManager:show(InfoMessage:new{ text = err or _("字体列表获取失败") })
                return
            end
            showPicker(opts, items)
        end)
    end)
end

return FontPicker
