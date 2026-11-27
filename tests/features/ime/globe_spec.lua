--[[--
features.ime.globe：长按地球键弹出键盘布局列表。

输入法关闭时长按保持原生；开启后只改地球键。选中新布局先丢掉未提交拼写，
再切到 zh_CN。重复 onCreate 不把 addKeys 包两层。

@module tests.features.ime.globe_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")

local enabled = true
local layout = "pinyin"
local set_calls = {}
local trace = {}
package.preload["features.ime"] = function()
    return {
        isEnabled = function() return enabled end,
        layout = function() return layout end,
        layouts = function()
            return {
                { id = "pinyin", label = "拼音" },
                { id = "wubi", label = "五笔" },
                { id = "nope", label = "不存在" },
            }
        end,
        setLayout = function(id)
            set_calls[#set_calls + 1] = id
            if id ~= "pinyin" and id ~= "wubi" then return false end
            layout = id
            trace[#trace + 1] = "set"
            return true
        end,
    }
end

local available = { pinyin = true, wubi = false }
package.preload["features.ime.registry"] = function()
    return {
        isAvailable = function(id) return available[id] == true end,
        current = function()
            return { label = layout == "wubi" and "五笔" or "拼音" }
        end,
    }
end

local abandoned = 0
package.preload["features.ime.candidate_bar"] = function()
    return {
        abandon = function()
            abandoned = abandoned + 1
            trace[#trace + 1] = "abandon"
        end,
    }
end

local shown, toast_text
package.preload["ui.themes.widgets.list"] = function()
    return {
        new = function(_, opts)
            shown = opts
            return { show = function() end }
        end,
    }
end
package.preload["ui.themes.widgets.toast"] = function()
    return {
        new = function(_, opts)
            toast_text = opts.text
            trace[#trace + 1] = "toast"
            return { show = function() end }
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        template = function(fmt, value)
            return fmt:gsub("%%1", value)
        end,
    }
end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end

local adds = 0
local VK = {}
function VK:addKeys()
    adds = adds + 1
    self.native_hold = 0
    self.layout = {
        { { label = "q" } },
        {
            {
                label = "🌐",
                hold_callback = function() self.native_hold = self.native_hold + 1 end,
            },
        },
    }
    self.utf8mode_keys = { ["🌐"] = true }
end
function VK:setKeyboardLayout(lang)
    trace[#trace + 1] = "layout:" .. lang
end
function VK:onSwitchingKeyboardLayout()
    trace[#trace + 1] = "switching"
end
package.preload["ui/widget/virtualkeyboard"] = function() return VK end

local Globe = require("features.ime.globe")

local function reset()
    shown, toast_text = nil, nil
    set_calls, trace = {}, {}
    abandoned = 0
    layout = "pinyin"
end

-- 关闭：长按仍是原生切换，不弹列表
enabled = false
Globe.onCreate()
local off = setmetatable({}, { __index = VK })
off:addKeys()
local native = off.layout[2][1].hold_callback
native()
Assert.eq(off.native_hold, 1, "关闭时长按走原生回调")
Assert.is_nil(shown)

-- 开启：只改地球键，松手不补一次点按
enabled = true
reset()
local kb = setmetatable({}, { __index = VK })
kb:addKeys()
local globe = kb.layout[2][1]
local letter = kb.layout[1][1]
Assert.is_nil(letter.hold_callback, "字母键不动")
globe.hold_callback()
Assert.is_true(globe.ignore_key_release)
Assert.eq(kb.native_hold, 0, "长按不再顺手切一次语言")
Assert.eq(shown.title, "键盘布局")
Assert.eq(shown.current, "pinyin")
Assert.eq(shown.centered, true)
Assert.eq(#shown.items, 3)
Assert.eq(shown.items[2].text, "五笔")
Assert.eq(shown.items[2].value, "wubi")

-- 选中当前布局：不改设置、不重建键盘
shown.on_select("pinyin")
Assert.eq(#set_calls, 0)
Assert.eq(abandoned, 0)
Assert.eq(#trace, 0)

-- 词库未下载：仍记下选择并切到中文键盘，提示在重建之后
shown.on_select("wubi")
Assert.eq(layout, "wubi")
Assert.eq(abandoned, 1)
Assert.eq(table.concat(trace, ","), "set,abandon,switching,layout:zh_CN,toast")
Assert.eq(toast_text, "五笔词库未下载")

-- 未知 id：设置拒绝后键盘保持不动
reset()
kb:addKeys()
kb.layout[2][1].hold_callback()
shown.on_select("nope")
Assert.eq(set_calls[1], "nope")
Assert.eq(layout, "pinyin")
Assert.eq(abandoned, 0)
Assert.eq(#trace, 0)

-- 没有地球键、首行不是按键，都不报错
Globe.attach({})
Globe.attach({
    utf8mode_keys = { ["🌐"] = true },
    layout = { { { label = "🌐" } }, { {} } },
})

-- 重复安装不把 addKeys 包两层
local attaches = 0
local orig_attach = Globe.attach
Globe.attach = function(...)
    attaches = attaches + 1
    return orig_attach(...)
end
Globe.onCreate()
local again = setmetatable({}, { __index = VK })
again:addKeys()
Assert.eq(attaches, 1, "第二次 onCreate 不得再包一层")
