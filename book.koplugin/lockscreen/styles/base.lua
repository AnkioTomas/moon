--[[--
锁屏样式接口与注册表。

一个 style 提供：

    id      string  稳定 id，落盘到 lock_screen 配置
    label   string  设置页展示名（gettext 源串）
    path()  -> string                        缓存图片路径
    fetch(cb)                                后台下载/生成图片；cb(ok, err)
    dayKey() -> string|nil                   按天更新标记：变化即重下；nil = 永不过期

新增样式：在 styles/ 下加一个文件实现上述接口，再在 M.styles 里注册一行。

@module koplugin.book.lockscreen.styles.base
--]]

local Myrl = require("lockscreen.styles.myrl")
local Reading = require("lockscreen.styles.reading")
local Bill = require("lockscreen.styles.bill")
local Quote = require("lockscreen.styles.quote")
local Bookshelf = require("lockscreen.styles.bookshelf")

local M = {}

local Device = require("device")

--- 竖屏宽高（锁屏会强制竖屏显示图片）。
---@return number, number
function M.portraitSize()
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    if w > h then
        return h, w
    end
    return w, h
end

---@return string 当前日期 YYYY-MM-DD
function M.dayKey()
    return os.date("%Y-%m-%d")
end

--- 已注册样式（顺序即设置页选项顺序）。
M.styles = { Myrl, Reading, Bill, Quote, Bookshelf }

---@param id string|nil
---@return table|nil
function M.find(id)
    for _, style in ipairs(M.styles) do
        if style.id == id then
            return style
        end
    end
    return nil
end

return M
