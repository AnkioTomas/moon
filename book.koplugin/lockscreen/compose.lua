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

--- 解析一次当前组合计划；计划内的字段在本轮生成期间保持一致。
---@return table
function M.plan()
    local settings = MoonSettings.get()
    local id = settings.lock_screen_component
    -- current 在注册表里必存在；assert 收窄 table|nil，注册表坏了直接炸。
    local component = assert(Components.find(id) or Components.find("current"))
    local background_mode = settings.lock_screen_background or "bing"
    if not Background.validMode(background_mode) then background_mode = "bing" end
    local asset = component.asset
        or (component.uses_background == false and Background.background("none")
            or Background.background(background_mode))
    local position = settings.lock_screen_position or "center-center"
    if component.supports_position == false or not Layout.validPosition(position) then
        position = "center-center"
    end
    local wide = component.supports_narrow ~= false and settings.lock_screen_wide ~= false
    local source_path = Background.resolve(asset)
    return {
        component = component,
        background_mode = background_mode,
        asset = asset,
        position = position,
        wide = wide,
        supports_narrow = component.supports_narrow == true,
        offline = asset.network ~= true and component.needs_network ~= true,
        source_path = source_path,
        output_path = asset.direct and source_path or COMPOSE_PATH,
    }
end

--- 生成组合图缓存键。
---
--- 键包含日期、布局、主体和动态资源身份；当前书籍封面即使在同一天
--- 更换，也必须触发重新合成。
---@param plan table
---@return string
function M.dayKey(plan)
    local component = plan.component
    local asset = plan.asset
    local parts = {
        Background.dayKey(),
        asset.id,
        component.id,
        plan.position,
        plan.wide and "wide" or "narrow",
        plan.source_path or "",
    }
    if component.cache_key then
        parts[#parts + 1] = tostring(component.cache_key())
    end
    return table.concat(parts, ":")
end

--- 判断已有组合图是否仍可直接交给 KOReader 使用。
---@param plan table
---@param force boolean|nil
---@return boolean
function M.cacheValid(plan, force)
    if force then
        return false
    end
    return MoonSettings.get().lock_screen_day == M.dayKey(plan)
        and Background.isFresh(plan.asset)
        and (plan.asset.direct or Background.isValidImage(plan.output_path))
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
---@param plan table
---@param cb fun(ok: boolean, err: any, output_path: string|nil)
---@return table|nil
function M.build(plan, cb)
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

    --- 回调一次即封口：已取消或已回调过都不再触发 cb。
    ---@param ok boolean
    ---@param err any
    ---@param output_path string|nil direct 资源时为原图路径，否则 nil（用 compose.png）
    local function finish(ok, err, output_path)
        if cancelled or finished then return end
        finished = true
        cb(ok, err, output_path)
    end

    local component = plan.component
    local asset_error, asset_path, text_data
    local asset_ready = false
    -- direct 资源不经 compose.png，拉取文案纯属无效工作。
    local text_ready = plan.asset.direct or type(component.ensureText) ~= "function"

    local function renderWhenReady()
        if cancelled or finished or not asset_ready then return end
        if asset_error then
            finish(false, asset_error)
            return
        end
        if plan.asset.direct then
            finish(true, nil, asset_path)
            return
        end
        if not text_ready then return end
        Paths.ensureScreensaverDir()
        local blocks = buildBlocks(component, plan.position, plan.wide, text_data)
        local Render = require("lockscreen.render")
        local ok, err = Render.write(COMPOSE_PATH, asset_path, blocks)
        if not ok and asset_path and tostring(err):find("cannot decode background", 1, true) then
            Background.invalidate(plan.asset)
        end
        finish(ok, err, nil)
    end

    --- 背景资源就绪后，直接检查是否已具备生成条件。
    ---@param path string|nil 背景图本地路径
    ---@param err any
    local function onAsset(path, err)
        if cancelled then return end
        asset_error = err
        asset_path = path
        asset_ready = true
        renderWhenReady()
    end
    asset_job = Background.ensure(plan.asset, onAsset)

    if finished then return nil end
    if not text_ready then
        text_job = component.ensureText(function(text, source)
            if cancelled then return end
            text_data = { text = text, source = source }
            text_ready = true
            renderWhenReady()
        end)
    end
    return finished and nil or job
end

return M
