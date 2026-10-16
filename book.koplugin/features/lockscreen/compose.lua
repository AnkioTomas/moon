--[[--
组合锁屏：背景 × 主体组件 × 布局合成为 compose.png。

流水线：plan → Background.ensure（与主体 ensureText 并行）→ Layout.panel → components/<id>.blocks → render。
direct 资源直接出原图路径。先写完整新文件再替换，失败保留上一张；设置 revision 变了丢弃过期回调。
新增主体：components/<id>.lua（blocks，可选 cache_key）+ components/base.lua 的 COMPONENT_MODULES 登记，设置页经 options() 自动出现。

@module koplugin.book.features.lockscreen.compose
--]]

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Background = require("features.lockscreen.background")
local Layout = require("features.lockscreen.layout")
local Components = require("features.lockscreen.components.base")

local M = {}
local COMPOSE_PATH = Paths.screensaverDir() .. "/compose.png"

-- 组合图是可丢弃的派生文件；源资源和设置变化都会使它失效。

--- 当前生效的主体；只读设置不碰盘，设置页判断能力位用它，别走 plan()。
---@return table
function M.component()
    -- current 在注册表里必存在；assert 收窄 table|nil，注册表坏了直接炸。
    return assert(Components.find(MoonSettings.get("features.lockscreen").lock_screen_component)
        or Components.find("current"))
end

--- 解析一次当前组合计划；计划内的字段在本轮生成期间保持一致。
---@return table
function M.plan()
    local settings = MoonSettings.get("features.lockscreen")
    local component = M.component()
    local background_mode = settings.lock_screen_background or "bing"
    if not Background.validMode(background_mode) then background_mode = "bing" end
    local asset = Background.background(background_mode)
    local position = settings.lock_screen_position or "center-center"
    if component.supports_position == false or not Layout.validPosition(position) then
        position = "center-center"
    end
    local wide = component.supports_narrow == false or settings.lock_screen_wide ~= false
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
        output_path = COMPOSE_PATH,
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
    if asset.cache_key then
        parts[#parts + 1] = asset.cache_key()
    end
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
    -- compose.png 是本模块原子写出的（.part + rename），存在且非空即完整，不必整张解码。
    return MoonSettings.get("features.lockscreen").lock_screen_day == M.dayKey(plan)
        and Background.isFresh(plan.asset)
        and (lfs.attributes(plan.output_path, "size") or 0) > 0
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
---@return table[]
local function buildBlocks(component, position, wide)
    if component.layout == "quote" then
        return component.blocks(position, wide)
    end
    local sw, sh = Layout.portraitSize()
    if component.full_screen then
        return component.blocks({ x = 0, y = 0, w = sw, h = sh, pad = 0 })
    end
    local rect = Layout.panel({
        position = position,
        wide = wide,
        height = preferredHeight(component, sh),
    })
    return component.blocks(rect)
end

--- 背景就绪后合成。
--- 返回值是可取消任务；本地背景在本次调用中同步完成，返回 nil。
---@param plan table
---@param cb fun(ok: boolean, err: any, transparent: boolean|nil)
---@return table|nil
function M.build(plan, cb)
    local cancelled, done = false, false
    local asset_job
    asset_job = Background.ensure(plan.asset, function(path, err)
        if cancelled then return end
        done = true
        if err then return cb(false, err) end
        -- 建块与写盘同步完成，中途不会被取消；块里的 widget 由 Render.write 释放。
        local sw, sh = Layout.portraitSize()
        local backdrop = plan.asset.blocks and plan.asset.blocks({ x = 0, y = 0, w = sw, h = sh, pad = 0 })
        local blocks = buildBlocks(plan.component, plan.position, plan.wide)
        local ok, render_err, transparent = require("features.lockscreen.render").write(COMPOSE_PATH,
            { path = path, contain = plan.asset.contain, blocks = backdrop }, blocks)
        if not ok and path and tostring(render_err):find("cannot decode background", 1, true) then
            Background.invalidate(plan.asset)
        end
        cb(ok, render_err, transparent)
    end)
    if done then return nil end
    return { cancel = function()
        cancelled = true
        if asset_job then asset_job:cancel() end
    end }
end

return M
