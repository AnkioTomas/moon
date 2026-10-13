--[[-- 排序列表的「设为第几位」：Sheet 条目，点开数字输入框，确认后按差值移动。
@module koplugin.book.desktop.pages.setting.position
--]]

local Input = require("ui.themes.widgets.input")
local _ = require("gettext")
local T = require("ffi/util").template

local Position = {}

--- 生成 Sheet 条目；输入非数字忽略，越界由 move 截断到首尾。
---@param position integer 当前位次
---@param count integer 列表长度
---@param move fun(delta: integer) 与上移 / 下移同一个移动函数
---@return table
function Position.item(position, count, move)
    return {
        text = _("设为第几位…"),
        enabled = count > 1,
        callback = function()
            Input:new{
                title = _("设为第几位"),
                fields = { { text = tostring(position), input_type = "number", hint = T("1 - %1", count) } },
                callback = function(text)
                    local target = tonumber(text)
                    if target then move(math.floor(target) - position) end
                end,
            }:show()
        end,
    }
end

return Position
