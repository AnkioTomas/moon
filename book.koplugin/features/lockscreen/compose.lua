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
-- 锁屏次数见 cycle.lua（零依赖，cache_key 可安全 require）。

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
        "accent-v1",
        tostring(require("ui.themes").current().color.accent),
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
--- 建块仍在主进程下一拍（要碰 UI 控件）；写 PNG 走 workers.job（heavy）：
--- 低端 Kindle 整屏解码 + 画块 + 编码数秒，不能堵 UI 循环。
---@param plan table
---@param cb fun(ok: boolean, err: any, transparent: boolean|nil)
---@return table|nil
function M.build(plan, cb)
    local cancelled = false
    local asset_job
    local write_job
    local UIManager = require("ui/uimanager")
    asset_job = Background.ensure(plan.asset, function(path, err)
        if cancelled then return end
        if err then return cb(false, err) end
        UIManager:nextTick(function()
            if cancelled then return end
            local sw, sh = Layout.portraitSize()
            local backdrop = plan.asset.blocks and plan.asset.blocks({ x = 0, y = 0, w = sw, h = sh, pad = 0 })
            local blocks = buildBlocks(plan.component, plan.position, plan.wide)
            local bg = { path = path, contain = plan.asset.contain, blocks = backdrop }
            write_job = require("workers.job").run(function()
                local ok, render_err, transparent = require("features.lockscreen.render").write(
                    COMPOSE_PATH, bg, blocks)
                if not ok then
                    return { ok = false, err = render_err and tostring(render_err) or "render failed" }
                end
                return { ok = true, transparent = transparent or false }
            end, {
                name = "lockscreen.compose",
                kind = "heavy",
                timeout = 120,
                on_done = function(result)
                    write_job = nil
                    if cancelled then return end
                    if not (result and result.ok) then
                        if path and result and result.err
                            and tostring(result.err):find("cannot decode background", 1, true) then
                            Background.invalidate(plan.asset)
                        end
                        return cb(false, result and result.err)
                    end
                    cb(true, nil, result.transparent)
                end,
                on_failed = function(job_err)
                    write_job = nil
                    if cancelled then return end
                    cb(false, job_err)
                end,
                on_cancelled = function()
                    write_job = nil
                end,
            })
            if cancelled and write_job and write_job.cancel then
                write_job:cancel()
                write_job = nil
            end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if asset_job then asset_job:cancel() end
        if write_job and write_job.cancel then write_job:cancel() end
        write_job = nil
    end }
end

return M
