--[[--
组合锁屏：普通主体由资源 × 组件 × 布局合成为 compose.png；direct 资源直接使用原图。

@module koplugin.book.lockscreen.compose
--]]

local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Background = require("lockscreen.background")
local Layout = require("lockscreen.layout")
local Components = require("lockscreen.components.base")

local M = {}
local COMPOSE_PATH = Paths.screensaverDir() .. "/compose.png"

-- 组合图是可丢弃的派生文件；源资源和设置变化都会使它失效。

local function selectedComponent()
    local id = MoonSettings.get().lock_screen_component
    return Components.find(id) or Components.find("current")
end

--- 读取并校验用户选择的背景模式。
---@return string
function M.backgroundMode()
    local mode = MoonSettings.get().lock_screen_background or "bing"
    return Background.validMode(mode) and mode or "bing"
end

--- 读取并校验主体 ID；已删除或未知主体统一回退到当前阅读。
---@return string
function M.componentId()
    return selectedComponent().id
end

--- 返回当前主体实际使用的资源描述。
---@return table
function M.asset()
    local component = selectedComponent()
    if component.asset then return component.asset end
    if component.uses_background == false then return Background.background("none") end
    return Background.background(M.backgroundMode())
end

--- 返回系统锁屏最终应读取的文件；direct 资源绕过组合图。
---@return string
function M.outputPath()
    local asset = M.asset()
    if asset.direct then
        return Background.resolve(asset)
    end
    return COMPOSE_PATH
end

--- 读取九宫格位置，保证布局层只接收合法值。
---@return string
function M.position()
    if selectedComponent().supports_position == false then
        return "center-center"
    end
    local position = MoonSettings.get().lock_screen_position or "center-center"
    return Layout.validPosition(position) and position or "center-center"
end

--- 根据主体能力决定是否允许窄屏布局。
---@return boolean
function M.wide()
    if selectedComponent().supports_narrow == false then
        return true
    end
    return MoonSettings.get().lock_screen_wide ~= false
end

--- 生成组合图缓存键。
---
--- 键包含日期、布局、主体和动态资源身份；当前书籍封面即使在同一天
--- 更换，也必须触发重新合成。
---@return string
function M.dayKey()
    local component = selectedComponent()
    local id = component.id
    local asset = M.asset()
    local parts = {
        Layout.dayKey(),
        asset.id,
        id,
        M.position(),
        M.wide() and "wide" or "narrow",
        Background.resolve(asset) or "",
    }
    if component and component.cache_key then
        parts[#parts + 1] = tostring(component.cache_key())
    end
    return table.concat(parts, ":")
end

--- 判断已有组合图是否仍可直接交给 KOReader 使用。
---@param force boolean|nil
---@return boolean
function M.cacheValid(force)
    if force then
        return false
    end
    local asset = M.asset()
    local path = M.outputPath()
    return MoonSettings.get().lock_screen_day == M.dayKey()
        and Background.isFresh(asset)
        and Background.isValidImage(path)
end

--- 将主体声明的相对高度换算为像素高度。
---@param component table
---@param sh number
---@return number|nil
local function preferredHeight(component, sh)
    if not component.preferred_height then return nil end
    return math.max(
        component.min_height or 0,
        math.floor(sh * component.preferred_height)
    )
end

--- 调用主体生成统一的绘制块。
--- quote 主体使用自己的动态高度，其余主体使用共享面板矩形。
---@param component table
---@param position string
---@param wide boolean
---@param data table|nil
---@return table[]
local function buildBlocks(component, position, wide, data)
    if component.layout == "quote" then
        return component.blocks(position, wide, data and data.text or "", data and data.source or "")
    end
    local sw, sh = Layout.portraitSize()
    if component.full_screen then
        return component.blocks({ x = 0, y = 0, w = sw, h = sh, pad = 0 })
    end
    local rect = Layout.panel({
        position = position,
        wide = wide,
        height = preferredHeight(component, sh),
        screen_w = sw,
        screen_h = sh,
    })
    return component.blocks(rect)
end

--- 并行准备资源和异步文案，二者都完成后才写入组合图。
---
--- 返回值是可取消任务；本地背景和同步主体会直接在本次调用中完成。
---@param cb fun(ok: boolean, err: any, output_path: string|nil)
---@return table|nil
function M.build(cb)
    local cancelled = false
    local finished = false
    local asset_job
    local text_job
    local job = {
        cancel = function()
            cancelled = true
            if asset_job and asset_job.cancel then asset_job.cancel() end
            if text_job and text_job.cancel then text_job.cancel() end
        end,
    }

    local function finish(ok, err, output_path)
        if cancelled or finished then return end
        finished = true
        cb(ok, err, output_path)
    end

    local component = selectedComponent()
    local position = M.position()
    local wide = M.wide()
    local asset = M.asset()
    local asset_error
    local asset_path, hitokoto_data
    local has_text = type(component.ensureText) == "function"
    local pending = has_text and 2 or 1

    local function renderWhenReady()
        if cancelled or finished or pending > 0 then
            return
        end
        if asset_error then
            finish(false, asset_error)
            return
        end
        -- direct 资源本身就是完整锁屏图，不需要再经过 compose.png。
        if asset.direct then
            finish(true, nil, asset_path)
            return
        end
        Paths.ensureScreensaverDir()
        local blocks = buildBlocks(component, position, wide, hitokoto_data)
        local Render = require("lockscreen.render")
        local ok, err = Render.write(COMPOSE_PATH, asset_path, blocks)
        if not ok and asset_path and tostring(err):find("cannot decode background", 1, true) then
            Background.invalidate(asset)
        end
        finish(ok, err, nil)
    end

    local function onAsset(path, err)
        if cancelled then return end
        asset_error = err
        asset_path = path
        pending = pending - 1
        renderWhenReady()
    end
    asset_job = Background.ensure(asset, onAsset)

    if has_text then
        text_job = component.ensureText(function(text, source)
            if cancelled then return end
            hitokoto_data = { text = text, source = source }
            pending = pending - 1
            renderWhenReady()
        end)
    end
    renderWhenReady()

    return finished and nil or job
end

return M
