--[[--
调用方 spec 用的主题弹层记录桩：不渲染，只把 new 的参数原样记下来。

测主题组件本身用 support.widget_stubs（真组件 + KOReader 控件桩）；
测「谁弹了什么、点了之后发生什么」用这里，免得每个 spec 各写一套。

  local Themed = require("support.theme_stubs")
  Themed.install()                       -- 每个 spec 顶部、require 被测模块之前
  Themed.last("list").on_select("box")   -- 最近一次 List:new 的参数
  Themed.choose(Themed.last("list"), 2)  -- 按 List 语义点第 2 行
  Themed.on_show = function(o) … end     -- 可选：show 时回调（记录弹出顺序）

@module tests.support.theme_stubs
--]]

local Themed = {}

local NAMES = { "list", "sheet", "spin", "input", "toast", "confirm", "progress_dialog", "text_viewer", "qr" }

--- 登记桩并清空记录。
function Themed.install()
    Themed.made, Themed.on_show = {}, nil
    for _, name in ipairs(NAMES) do
        local mod = {
            new = function(_, o)
                o = o or {}
                o.kind = name
                o.show = function(self)
                    self.shown = true
                    if Themed.on_show then Themed.on_show(self) end
                    return self
                end
                o.close = function(self)
                    self.closed = true
                    if self.close_callback then self.close_callback() end
                end
                o.dismiss = function(self)
                    self:close()
                    if self.on_background then self.on_background() end
                end
                o.setItems = function(self, items) self.items = items end
                o.bytes = function(self, done, total) self.progress = { done, total } end
                o.updates = {}
                o.update = function(self, text, done, total) self.updates[#self.updates + 1] = { text, done, total } end
                o.sets = {}
                o.set = function(self, text, percent) self.sets[#self.sets + 1] = { text, percent } end
                Themed.made[#Themed.made + 1] = o
                return o
            end,
        }
        package.preload["ui.themes.widgets." .. name] = function() return mod end
        package.loaded["ui.themes.widgets." .. name] = nil
    end
end

--- 最近一次指定组件的 new 参数。
---@param name string
---@return table|nil
function Themed.last(name)
    for i = #Themed.made, 1, -1 do
        if Themed.made[i].kind == name then return Themed.made[i] end
    end
end

--- 某组件的全部 new 参数（按创建顺序）。
---@param name string
---@return table[]
function Themed.all(name)
    local out = {}
    for _, o in ipairs(Themed.made) do
        if o.kind == name then out[#out + 1] = o end
    end
    return out
end

--- 按 List 单选语义点一行：非 keep_open 先关，再走 item.callback，没有则 on_select。
---@param list table
---@param index integer
function Themed.choose(list, index)
    local item = list.items[index]
    if not item.keep_open then list:close() end
    if item.callback then return item.callback() end
    return list.on_select(item.value, item)
end

return Themed
