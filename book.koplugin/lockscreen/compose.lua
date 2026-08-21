--[[--
组合锁屏：背景 × 主体组件 × 九宫格 × 宽/窄 → compose.png。

@module koplugin.book.lockscreen.compose
--]]

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Background = require("lockscreen.background")
local Layout = require("lockscreen.layout")
local Components = require("lockscreen.components.base")

local M = {}

---@param path string
---@return boolean
local function fileOk(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

---@return string
function M.path()
    return Paths.screensaverDir() .. "/compose.png"
end

---@return string
function M.backgroundMode()
    local mode = MoonSettings.get().lock_screen_background or "bing"
    return Background.validMode(mode) and mode or "bing"
end

---@return string
function M.componentId()
    local id = MoonSettings.get().lock_screen_component or "bookmark"
    return Components.find(id) and id or "bookmark"
end

---@return string
function M.position()
    local position = MoonSettings.get().lock_screen_position or "center-center"
    return Layout.validPosition(position) and position or "center-center"
end

---@return boolean
function M.wide()
    local component = Components.find(M.componentId())
    if component and not component.supports_narrow then
        return true
    end
    return MoonSettings.get().lock_screen_wide ~= false
end

---@return string
function M.dayKey()
    local c = MoonSettings.get()
    local parts = {
        Layout.dayKey(),
        M.backgroundMode(),
        M.componentId(),
        M.position(),
        M.wide() and "wide" or "narrow",
    }
    if M.componentId() == "bill" then
        parts[#parts + 1] = c.lock_screen_bill_period or "7d"
    end
    return table.concat(parts, ":")
end

---@param force boolean|nil
---@return boolean
function M.cacheValid(force)
    if force then
        return false
    end
    local Settings = require("lockscreen.settings")
    return Settings.savedDay() == M.dayKey() and fileOk(M.path())
end

---@param component table
---@param sh number
---@return number|nil
local function preferredHeight(component, sh)
    local id = component.id
    if id == "current" then
        return math.max(110, math.floor(sh * 0.22))
    end
    if id == "bookmark" then
        return math.floor(sh * 0.55)
    end
    if id == "stats" or id == "bill" or id == "cover_cards" then
        return math.floor(sh * 0.90)
    end
    return nil
end

---@param component table
---@param position string
---@param wide boolean
---@param data table|nil
---@return table[]
local function buildBlocks(component, position, wide, data)
    if component.id == "none" then
        return {}
    end
    if component.id == "hitokoto" then
        return component.blocks(position, wide, data and data.text or "", data and data.source or "")
    end
    if component.id == "highlight" then
        return component.blocks(position, wide)
    end
    local Render = require("lockscreen.render")
    local sw, sh = Render.size()
    local rect = Layout.panel({
        position = position,
        wide = wide,
        height = preferredHeight(component, sh),
        screen_w = sw,
        screen_h = sh,
    })
    return component.blocks(rect)
end

---@param cb fun(ok: boolean, err: any)
---@return table|nil
function M.build(cb)
    local cancelled = false
    local finished = false
    local bg_job
    local text_job
    local job = {
        cancel = function()
            cancelled = true
            if bg_job and bg_job.cancel then bg_job.cancel() end
            if text_job and text_job.cancel then text_job.cancel() end
        end,
    }

    local function finish(ok, err)
        if cancelled or finished then return end
        finished = true
        cb(ok, err)
    end

    local component = Components.find(M.componentId()) or Components.find("none")
    local position = M.position()
    local wide = M.wide()
    local bg_ready = false
    local text_ready = component.id ~= "hitokoto"
    local bg_path
    local hitokoto_data

    local function renderWhenReady()
        if cancelled or finished or not bg_ready or not text_ready then
            return
        end
        Paths.ensureScreensaverDir()
        local blocks = buildBlocks(component, position, wide, hitokoto_data)
        local Render = require("lockscreen.render")
        local ok, err = Render.write(M.path(), bg_path, blocks)
        finish(ok, err)
    end

    bg_job = Background.ensure(function(path)
        if cancelled then return end
        bg_path = path
        bg_ready = true
        renderWhenReady()
    end)

    if component.id == "hitokoto" then
        text_job = component.ensureText(function(text, source)
            if cancelled then return end
            hitokoto_data = { text = text, source = source }
            text_ready = true
            renderWhenReady()
        end)
        if text_ready then
            renderWhenReady()
        end
    else
        renderWhenReady()
    end

    return finished and nil or job
end

return M
