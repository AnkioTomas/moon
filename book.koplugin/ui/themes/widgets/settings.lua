--[[--
主题设置弹窗：标题 + 若干设置行，改完就地刷新，不关窗。
用 Row.choice / 开关 / 导航行，不要在 Sheet 上拼选中标记。

  Settings:new{
      title = "最近阅读",
      items = function(page)
          return {
              { title = "布局", items = { { value = "stack", text = "堆叠" } },
                current = "stack", on_select = function(value) end },
              { title = "显示书名", toggle = true, checked = true, callback = function() end },
              { title = "每行 4 本", chevron = true, callback = function() return false end },
              { note = "说明" },
              { buttons = { { text = "往后 10 章", callback = function() end } } },
          }
      end,
      buttons = function(page)
          return {
              { text = "取消", callback = function() page:close() end },
              { text = "开始", variant = "primary", callback = function() end },
          }
      end,
  }:show()

items 是函数：每次刷新重新取当前值。
buttons 是底部按钮（取消 / 开始），可给表或函数(page)；没有则不画。
callback / on_select 返回 false 表示不要刷新（例如又开了选择器）。

@module koplugin.book.ui.themes.widgets.settings
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Modal = require("ui.themes.widgets.modal")
local Row = require("ui.themes.widgets.row")

---@class BookThemeSettings : BookThemeModal
---@field title string|nil
---@field items fun(self: BookThemeSettings): table[]
---@field buttons table[]|fun(self: BookThemeSettings): table[]|nil 底部按钮
local Settings = Modal:extend{
    title = nil,
    items = nil,
    buttons = nil,
}

function Settings:init()
    Modal.init(self)
    self:updateView()
end

--- 把一项描述转成行控件。
---@param item table
---@param width number
---@return table
function Settings:row(item, width)
    if item.note then
        return Row.note(width, item.note)
    end
    if item.buttons then
        return self:buttonRow(item.buttons, width)
    end
    ---@param ok boolean|nil
    local function after(ok)
        if ok ~= false then self:updateView() end
    end
    if item.items then
        return Row.choice{
            width = width,
            title = item.title,
            icon = item.icon,
            items = item.items,
            current = item.current,
            on_select = function(value)
                after(item.on_select and item.on_select(value))
            end,
        }
    end
    if item.toggle then
        return Row.widget({
            width = width,
            title = item.title,
            icon = item.icon,
            toggle = item.checked == true,
            chevron = false,
            callback = function()
                after(item.callback and item.callback())
            end,
        })
    end
    return Row.widget({
        width = width,
        title = item.title,
        icon = item.icon,
        status = item.status,
        status_on = item.status ~= nil,
        chevron = item.chevron,
        callback = function()
            after(item.callback and item.callback())
        end,
    })
end

--- 按当前 items() 重建面板；已经显示过则就地重绘。
function Settings:updateView()
    local shown = self[1] ~= nil
    local width = self:innerWidth()
    local body = VerticalGroup:new{ align = "left" }
    local items = self.items and self.items(self) or {}
    for _idx, item in ipairs(items) do
        body[#body + 1] = self:row(item, width)
    end
    local buttons = self.buttons
    if type(buttons) == "function" then buttons = buttons(self) end
    self:setDialog{ title = self.title, body = body, buttons = buttons }
    if shown then
        UIManager:setDirty(self, "ui")
    end
end

return Settings
