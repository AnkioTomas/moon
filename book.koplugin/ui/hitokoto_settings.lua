--[[--
一言设置：首页与锁屏共用联网刷新间隔、句子类型，以及设置弹窗。
锁屏不要去 require 首页组件实现。

@module koplugin.book.ui.hitokoto_settings
--]]

require("l10n").apply()
local Hitokoto = require("online.hitokoto")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local M = {}

M.INTERVALS = {
    { value = 600, text = _("10 分钟") },
    { value = 3600, text = _("1 小时") },
    { value = 86400, text = _("1 天") },
    { value = 0, text = _("不联网（有缓存用缓存，没有再用内置句子）") },
}

---@return { value: number, text: string }[]
function M.intervals()
    return M.INTERVALS
end

---@return number
function M.ttl()
    return Hitokoto.configuredTtl()
end

---@param ttl number|nil
---@return string
function M.ttlLabel(ttl)
    ttl = ttl or M.ttl()
    for _idx, opt in ipairs(M.INTERVALS) do
        if opt.value == ttl then return opt.text end
    end
    return _("1 小时")
end

--- 写回间隔并按新值决定是否联网。
---@param ttl number
function M.setTtl(ttl)
    local home = MoonSettings.get("desktop.pages.home")
    home.home_hitokoto_ttl = ttl
    MoonSettings.save("desktop.pages.home", home)
    Hitokoto:ensureConfigured()
end

--- 全选显示「全部」；否则用顿号拼接已选类型名，过长由行状态列截断。
---@return string
function M.typesStatus()
    local selected = Hitokoto.selectedTypes()
    if #selected >= #Hitokoto.TYPES then return _("全部") end
    local want = {}
    for _idx, id in ipairs(selected) do want[id] = true end
    local names = {}
    for _idx, typ in ipairs(Hitokoto.TYPES) do
        if want[typ.id] then names[#names + 1] = typ.label end
    end
    return table.concat(names, "、")
end

---@param types string[]
function M.setTypes(types)
    local home = MoonSettings.get("desktop.pages.home")
    home.home_hitokoto_types = types
    MoonSettings.save("desktop.pages.home", home)
    Hitokoto:ensureConfigured()
end

--- 居中多选句子类型；至少留 1 个。
---@param opts { on_change?: fun(), on_close?: fun() }|nil
function M.showTypes(opts)
    opts = opts or {}
    local selected = {}
    for _idx, id in ipairs(Hitokoto.selectedTypes()) do
        selected[id] = true
    end
    local items = {}
    for _idx, typ in ipairs(Hitokoto.TYPES) do
        items[#items + 1] = {
            text = typ.label,
            value = typ.id,
            checked = selected[typ.id] == true,
        }
    end
    require("ui.themes.widgets.list"):new{
        title = _("句子类型"),
        multi = true,
        centered = true,
        items = items,
        on_toggle = function(_value, _checked, item)
            local types = {}
            for _idx, entry in ipairs(items) do
                if entry.checked then types[#types + 1] = entry.value end
            end
            if #types == 0 then
                item.checked = true
                require("ui.themes.widgets.toast"):new{
                    text = _("至少选择一种类型"),
                    timeout = 2,
                }:show()
                return
            end
            M.setTypes(types)
            if opts.on_change then opts.on_change() end
        end,
        close_callback = opts.on_close,
    }:show()
end

--- 正式设置弹窗：可选居中开关、联网刷新、句子类型。
---@param opts { desktop?: BookDesktop, center_key?: string, on_change?: fun() }
function M.show(opts)
    opts = opts or {}
    local center_key = opts.center_key
    require("ui.themes.widgets.settings"):new{
        title = _("一言"),
        items = function(page)
            local rows = {}
            if center_key then
                local on = MoonSettings.get("desktop.pages.home")[center_key] == true
                rows[#rows + 1] = {
                    title = _("居中"),
                    toggle = true,
                    checked = on,
                    callback = function()
                        local home = MoonSettings.get("desktop.pages.home")
                        home[center_key] = not (home[center_key] == true)
                        MoonSettings.save("desktop.pages.home", home)
                        if opts.on_change then opts.on_change() end
                    end,
                }
            end
            rows[#rows + 1] = {
                title = _("联网刷新"),
                items = M.INTERVALS,
                current = M.ttl(),
                on_select = function(value)
                    M.setTtl(value)
                    if opts.on_change then opts.on_change() end
                end,
            }
            rows[#rows + 1] = {
                title = _("句子类型"),
                status = M.typesStatus(),
                chevron = true,
                callback = function()
                    M.showTypes({
                        on_change = opts.on_change,
                        on_close = function()
                            page:updateView()
                        end,
                    })
                    return false
                end,
            }
            return rows
        end,
    }:show()
end

return M
