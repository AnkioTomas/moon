--[[--
虚拟键盘收起键：每个虚拟键盘的最后一行加一个收起键（键盘 + 向下箭头图标），点了收起键盘（等同实体返回键）。

KOReader 的键盘只有实体返回键能收起，没有返回键的触屏设备只能点输入框外面。

  [⌥][🌐][。][  空格  ][←][→][⌨↓][⮠]     空格从 3 格让出 1 格，行总宽不变

不改布局数据（ime 会按基线重置 zh_CN 布局）：每个键盘实例在 addKeys 前给自己的 KEYS
换一份最后一行的拷贝，从最宽的键让出 1 格宽插在回车前。最宽的键不到 2 格的布局不加。
收起键的字符是私有区码位，在 addChar 截下，不会写进输入框。

开关在「输入法」设置页（`features.ime.hide_key`，默认开），下次弹出键盘生效。

收起做的事同 VirtualKeyboard:onCloseWithKey（KOReader 2026.08 才有，插件最低支持 2026.07）：
关键盘，再告诉输入框所在窗口键盘没了，让它重新排版。

@module koplugin.book.features.ime.hide_key
--]]

local Guard = require("ui.guard")

--- U+F8FF（私有区），布局里不会出现的字符。
local HIDE = "\239\163\191"
--- 键帽：U+EA0E（KOReader nerdfonts symbols.ttf 的 MDI keyboard-close），与退格 / Shift 同一套字形。
--- 不用 icon 字段：VirtualKey 的 ImageWidget 不按 alpha 混合，透明 SVG 会画成黑块。
local LABEL = "\238\168\142"
--- 各布局层数上限（pt 布局 12 层）；收起键每层都是同一个字符。
local LAYERS = 12

local Keyboard = { _hooked = false }

---@param t table
---@return table
local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- 带收起键的 KEYS 拷贝；放不下时返回原表。
---@param keys table VirtualKeyboard.KEYS
---@return table
function Keyboard.withHideKey(keys)
    local last = keys[#keys]
    local widest, widest_w = nil, 1
    for j, key in ipairs(last) do
        local w = key.width or last.width or 1
        if w > widest_w then widest, widest_w = j, w end
    end
    if widest_w < 2 then return keys end
    local row = copy(last)
    row[widest] = copy(last[widest])
    row[widest].width = widest_w - 1
    local hide = { label = LABEL }
    for layer = 1, LAYERS do hide[layer] = HIDE end
    table.insert(row, #row, hide)
    local out = copy(keys)
    out[#keys] = row
    out._with_hide = true
    return out
end

--- 关键盘并通知输入框所在窗口（主题 Input 回到贴顶、KOReader 全屏 InputDialog 重新排版）。
---@param kb table VirtualKeyboard
function Keyboard.hide(kb)
    kb:onClose()
    local parent = kb.inputbox and kb.inputbox.parent
    if parent and parent.onKeyboardClosed then parent:onKeyboardClosed() end
end

function Keyboard.onCreate()
    if Keyboard._hooked then return end
    Keyboard._hooked = true
    local VK = require("ui/widget/virtualkeyboard")
    local orig_addKeys, orig_addChar = VK.addKeys, VK.addChar
    VK.addKeys = function(self, ...)
        if not self.KEYS._with_hide and require("utils.settings").get("features.ime").hide_key then
            self.KEYS = Guard.call("keyboard hide key", Keyboard.withHideKey, self.KEYS) or self.KEYS
        end
        return orig_addKeys(self, ...)
    end
    VK.addChar = function(self, key)
        if key == HIDE then return Keyboard.hide(self) end
        return orig_addChar(self, key)
    end
end

return Keyboard
