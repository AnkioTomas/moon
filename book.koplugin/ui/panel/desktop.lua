--[[--
桌面快捷动作与快捷面板服务。

动作配置持久化、设备能力过滤、灯光百分比换算与动作执行统一在这里。

@module koplugin.book.ui.panel.desktop
--]]

require("l10n").apply()

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ActionList = require("ui.panel.action_list")
local Registry = require("ui.panel.actions.registry")

---@class BookQuickPanelDesktop
---@field lightPercent fun(kind: "brightness"|"warmth"): number
---@field options fun(): BookQuickPanelOption[]
---@field enabledCount fun(): number
---@field setEnabled fun(id: string, enabled: boolean): void
---@field move fun(id: string, delta: number): void
---@field sliders fun(): BookQuickPanelSlider[]
---@field menuActions fun(): BookQuickPanelMenuItem[]
---@field executeAction fun(id: string, opts: BookQuickPanelExecuteOpts|nil): boolean
---@field setLevel fun(kind: "brightness"|"warmth", fraction: number): boolean

local Panel = {}

local list = ActionList.create("desktop", "quick_panel_actions", Registry.desktopOrder, {
    can_enable = function(action) return Registry.available(action) end,
})

--- 桌面设置页展示的快捷动作选项。
---@class BookQuickPanelOption
---@field id string
---@field title string
---@field icon string
---@field enabled boolean
---@field position number|nil
---@field available boolean

--- 原生菜单按钮使用的桌面快捷动作项。
---@class BookQuickPanelMenuItem
---@field id string
---@field title string
---@field icon string
---@field active boolean

--- 快捷面板灯光滑杆数据。
---@class BookQuickPanelSlider
---@field kind "brightness"|"warmth"
---@field title string
---@field value number

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

--- 生成快捷面板设置页动作列表。
---@return BookQuickPanelOption[]
function Panel.options()
    return list.options(Registry.desktopOrder)
end

--- 当前启用的桌面动作数量。
---@return number
function Panel.enabledCount()
    return #list.ids()
end

--- 启用或停用某个桌面动作。
---@param id string
---@param enabled boolean
function Panel.setEnabled(id, enabled)
    list.setEnabled(id, enabled)
end

--- 上移或下移某个桌面动作。
---@param id string
---@param delta number
function Panel.move(id, delta)
    list.move(id, delta)
end

--- 生成快捷面板灯光滑杆；按设备能力过滤。
---@return BookQuickPanelSlider[]
function Panel.sliders()
    local sliders = {}
    if Device:hasFrontlight() then
        sliders[#sliders + 1] = { kind = "brightness", title = _("亮度"), value = Panel.lightPercent("brightness") }
    end
    if Device:hasNaturalLight() then
        sliders[#sliders + 1] = { kind = "warmth", title = _("冷暖色调"), value = Panel.lightPercent("warmth") }
    end
    return sliders
end

--- 生成原生菜单里的桌面动作按钮。
---@return BookQuickPanelMenuItem[]
function Panel.menuActions()
    local actions = {}
    for _, id in ipairs(list.ids()) do
        local action = Registry.get(id)
        if Registry.available(action) then
            actions[#actions + 1] = {
                id = id,
                title = action.title,
                icon = action.icon,
                active = Registry.active(id, action),
            }
        end
    end
    return actions
end

--- 执行桌面动作：广播事件，按需保持面板打开并延迟刷新。
---@param id string
---@param opts BookQuickPanelExecuteOpts|nil
---@return boolean
function Panel.executeAction(id, opts)
    opts = opts or {}
    local action = Registry.get(id)
    if not action or not Registry.available(action) then return false end
    if not action.keep_open and opts.close then opts.close() end
    if action.run then
        action.run({ ui = nil })
    elseif action.event then
        UIManager:broadcastEvent(Event:new(action.event))
    else
        return false
    end
    if opts.refresh then
        if action.refresh_delay then
            UIManager:scheduleIn(action.refresh_delay, opts.refresh)
        else
            UIManager:nextTick(opts.refresh)
        end
    end
    return true
end

--- 设置亮度或暖色，并在设备不支持时返回 false。
---@param kind "brightness"|"warmth"
---@param fraction number
---@return boolean
function Panel.setLevel(kind, fraction)
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local powerd = Device:getPowerDevice()
    if kind == "brightness" then
        local min, max = tonumber(powerd.fl_min) or 0, tonumber(powerd.fl_max) or 100
        local native = math.floor(min + fraction * (max - min) + 0.5)
        if native <= min then
            powerd:turnOffFrontlight()
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
