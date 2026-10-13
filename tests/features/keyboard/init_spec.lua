--[[--
features.keyboard 离线用例：VirtualKeyboard / Guard 全 stub。

验证：末行最宽键让出 1 格放「收起」（插在末键前）、不改原布局、没有可让的键时原样返回；
addKeys 只改一次；收起键关键盘并通知输入框父窗口，其余键透传。

@module tests.features.keyboard.init_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

local orig_add_keys, closed, passed = 0, 0, {}
local VK = {}
function VK:addKeys() orig_add_keys = orig_add_keys + 1 end
function VK:addChar(key) passed[#passed + 1] = key end
function VK:onClose() closed = closed + 1 end
package.preload["ui/widget/virtualkeyboard"] = function() return VK end
local cfg = { enabled = true }
package.preload["utils.settings"] = function()
    return { get = function(owner) assert(owner == "features.keyboard") return cfg end }
end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end

local Keyboard = require("features.keyboard")

local function layout()
    return {
        { { "q" }, { "w" } },
        {
            { label = "⌥", width = 1.5 },
            { "." },
            { label = "space", width = 3.0 },
            { label = "Enter", width = 1.5 },
        },
    }
end

-- 末行：空格 3 → 2，收起插在 Enter 前，总宽不变
local keys = layout()
local out = Keyboard.withHideKey(keys)
local row = out[2]
Assert.len(row, 5)
Assert.eq(row[3].width, 2)
Assert.eq(row[4].label, "\238\168\142")
Assert.eq(row[5].label, "Enter")
Assert.is_true(out._with_hide)
Assert.eq(out[1], keys[1])

-- 原布局不动
Assert.len(keys[2], 4)
Assert.eq(keys[2][3].width, 3.0)
Assert.is_nil(keys._with_hide)

-- 末行没有宽 ≥ 2 的键：原样返回
local narrow = { { { "a" }, { label = "Enter", width = 1.5 } } }
Assert.eq(Keyboard.withHideKey(narrow), narrow)

-- 收起键在每一层都是同一个私用区字符
local hide = row[4][1]
for layer = 1, 12 do Assert.eq(row[4][layer], hide) end

-- 挂钩：addKeys 只改一次布局
Keyboard.onCreate()
Keyboard.onCreate()
local kb = setmetatable({ KEYS = layout() }, { __index = VK })
kb:addKeys()
local first = kb.KEYS
kb:addKeys()
Assert.eq(kb.KEYS, first)
Assert.len(kb.KEYS[2], 5)
Assert.eq(orig_add_keys, 2)

-- 开关关：不加收起键
cfg.enabled = false
local plain = setmetatable({ KEYS = layout() }, { __index = VK })
plain:addKeys()
Assert.len(plain.KEYS[2], 4)
Assert.is_nil(plain.KEYS._with_hide)
cfg.enabled = true

-- 收起：关键盘 + 通知父窗口；普通键透传
local notified = 0
kb.inputbox = { parent = { onKeyboardClosed = function() notified = notified + 1 end } }
kb:addChar(hide)
Assert.eq(closed, 1)
Assert.eq(notified, 1)
Assert.len(passed, 0)

kb:addChar("a")
Assert.eq(passed[1], "a")

-- 父窗口没有 onKeyboardClosed 也能收起
kb.inputbox = { parent = {} }
kb:addChar(hide)
Assert.eq(closed, 2)
