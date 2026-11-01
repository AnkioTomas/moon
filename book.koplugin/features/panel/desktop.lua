--[[--
桌面快捷动作与快捷面板服务。

动作配置持久化、设备能力过滤、灯光百分比换算与动作执行统一在这里。

@module koplugin.book.features.panel.desktop
--]]

local Device = require("device")

local ActionList = require("features.panel.action_list")
local Registry = require("features.panel.actions.registry")
local MoonSettings = require("utils.settings")

---@class BookQuickPanelDesktop
---@field lightPercent fun(kind: "brightness"|"warmth"): number
---@field options fun(): BookQuickPanelOption[]
---@field enabledCount fun(): number
---@field setEnabled fun(id: string, enabled: boolean)
---@field move fun(id: string, delta: number)
---@field swap fun(a: string, b: string)
---@field sliders fun(): BookQuickPanelSlider[]
---@field menuActions fun(): BookQuickPanelMenuItem[]
---@field executeAction fun(id: string, opts: BookQuickPanelExecuteOpts|nil): boolean
---@field holdAction fun(id: string, opts: BookQuickPanelExecuteOpts|nil): boolean
---@field setLevel fun(kind: "brightness"|"warmth", fraction: number): boolean

local Panel = {}

local list = ActionList.create("desktop", "quick_panel_actions", Registry.desktopOrder)

--- 桌面设置页展示的快捷动作选项。
---@class BookQuickPanelOption
---@field id string
---@field title string
---@field icon string
---@field enabled boolean
---@field position number|nil
---@field available boolean
---@field scope "desktop"|"reader"|nil

--- 原生菜单按钮使用的桌面快捷动作项。
---@class BookQuickPanelMenuItem
---@field id string
---@field title string
---@field icon string
---@field active boolean
---@field hold boolean 动作声明了长按

--- 快捷面板灯光滑杆。value 是硬件档，不是 0..100。
---@class BookQuickPanelSlider
---@field kind "brightness"|"warmth"
---@field min number 硬件最小档。亮度 0 是关灯
---@field max number
---@field floor number 手势最低档。亮度跳过 0
---@field value number 当前档，灯关着时可以低于 floor

--- 桌面动作执行选项。
---@class BookQuickPanelExecuteOpts
---@field close fun()|nil
---@field refresh fun()|nil

--- 把设备原生亮度或暖色值折算成 0..100。
---@param value number
---@param min number
---@param max number
---@return number
local function percent(value, min, max)
    if max <= min then return 0 end
    return math.max(0, math.min(100, math.floor((value - min) * 100 / (max - min) + 0.5)))
end

--- 读取亮度或暖色的百分比展示值。
---@param kind "brightness"|"warmth"
---@return number
function Panel.lightPercent(kind)
    local powerd = Device:getPowerDevice()
    if kind == "brightness" then
        local min, max = tonumber(powerd.fl_min) or 0, tonumber(powerd.fl_max) or 100
        return percent(tonumber(powerd:frontlightIntensity()) or min, min, max)
    end
    -- frontlightWarmth() 已经是 0..100 的 KOReader 刻度，直接取即可；
    -- 再走 toNativeWarmth 往返会在 Kindle 24 级上丢精度。
    return percent(powerd:frontlightWarmth(), 0, 100)
end

--- 当前启用的桌面动作数量。
---@return number
function Panel.enabledCount()
    return #list.ids()
end

Panel.options = list.options
Panel.setEnabled = list.setEnabled
Panel.move = list.move
Panel.swap = list.swap

--- 亮度或暖色的硬件档位。滑杆按这个刻度走，不再绕 0..100。
---@param kind "brightness"|"warmth"
---@return BookQuickPanelSlider
local function lightSteps(kind)
    local powerd = Device:getPowerDevice()
    if kind == "brightness" then
        local min = tonumber(powerd.fl_min) or 0
        local max = tonumber(powerd.fl_max) or 100
        return {
            kind = kind,
            min = min,
            max = max,
            floor = math.min(max, min + 1),
            value = tonumber(powerd:frontlightIntensity()) or min,
        }
    end
    local min = tonumber(powerd.fl_warmth_min) or 0
    local max = tonumber(powerd.fl_warmth_max) or 100
    return {
        kind = kind,
        min = min,
        max = max,
        floor = min,
        value = powerd:toNativeWarmth(powerd:frontlightWarmth()),
    }
end

--- 生成快捷面板灯光滑杆；按设备能力过滤。
---@return BookQuickPanelSlider[]
function Panel.sliders()
    local sliders = {}
    if Device:hasFrontlight() and MoonSettings.get("features.panel").quick_panel_brightness then
        sliders[#sliders + 1] = lightSteps("brightness")
    end
    if Device:hasNaturalLight() and MoonSettings.get("features.panel").quick_panel_warmth then
        sliders[#sliders + 1] = lightSteps("warmth")
    end
    return sliders
end

--- 生成原生菜单里的桌面动作按钮。
---@return BookQuickPanelMenuItem[]
function Panel.menuActions()
    return list.actions({})
end

--- 执行桌面动作；未注册或当前不可用返回 false。
---@param id string
---@param opts BookQuickPanelExecuteOpts|nil
---@return boolean
function Panel.executeAction(id, opts)
    return list.execute(id, {}, opts)
end

--- 长按桌面动作；没有 hold 返回 false。
---@param id string
---@param opts BookQuickPanelExecuteOpts|nil
---@return boolean
function Panel.holdAction(id, opts)
    return list.hold(id, {}, opts)
end

--- 设置亮度或暖色，并在设备不支持时返回 false。
---@param kind "brightness"|"warmth"
---@param fraction number
---@return boolean
function Panel.setLevel(kind, fraction)
    fraction = math.max(0, math.min(1, fraction))
    local powerd = Device:getPowerDevice()
    if kind == "brightness" then
        local min, max = tonumber(powerd.fl_min) or 0, tonumber(powerd.fl_max) or 100
        local native = math.floor(min + fraction * (max - min) + 0.5)
        -- fraction 0 是自动亮度的「关灯」。调节块不会传 0，正比例再小也停在最低开灯档。
        if fraction <= 0 then
            powerd:turnOffFrontlight()
        elseif native <= min then
            powerd:setIntensity(math.min(max, min + 1))
        else
            powerd:setIntensity(native)
        end
        powerd:updateResumeFrontlightState()
    elseif kind == "warmth" then
        local min = tonumber(powerd.fl_warmth_min) or 0
        local max = tonumber(powerd.fl_warmth_max) or 100
        local native = math.floor(min + fraction * (max - min) + 0.5)
        powerd:setWarmth(powerd:fromNativeWarmth(native))
    else
        return false
    end
    return true
end

---@type BookQuickPanelDesktop
return Panel
