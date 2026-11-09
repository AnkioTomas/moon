--[[--
features.system_ime 作为 07 Android 后端的契约：可用性、接管失败返回 false、
回退顺序、height=0 收起、number / password / readonly 绕过、last_status 持久化、
快照直写 inputbox（不走 vk:addChar/delChar）。

全部用假 Android / 假 JNI 引擎，不依赖真机。

@module tests.features.system_ime.init_spec
--]]

local Assert = require("support.assert")

-- ── 桩：配置 ─────────────────────────────────────────
local owners = {}
local save_calls = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            owners[owner] = owners[owner] or {}
            return owners[owner]
        end,
        save = function(owner, values)
            if values and values ~= owners[owner] then owners[owner] = values end
            save_calls[#save_calls + 1] = owner
        end,
    }
end

-- ── 桩：Android 运行时 ───────────────────────────────
local android_present = true
package.preload["android"] = function()
    if not android_present then error("android runtime absent") end
    return { app = { activity = { vm = {}, clazz = {} } }, jni = {} }
end

-- ── 桩：日志 / 文案 / 调度 / Toast ────────────────────
local log_lines = {}
package.preload["utils.log"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function(...) log_lines[#log_lines + 1] = table.concat({ ... }, " ") end,
    }
end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end

local scheduled = {}
local UIManager = {}
function UIManager:scheduleIn(delay, fn)
    scheduled[#scheduled + 1] = { delay = delay, fn = fn }
end
function UIManager:unschedule(fn)
    for i = #scheduled, 1, -1 do
        if scheduled[i].fn == fn then table.remove(scheduled, i) end
    end
end
package.preload["ui/uimanager"] = function() return UIManager end

local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    local Toast = {}
    Toast.__index = Toast
    function Toast:new(o)
        return setmetatable(o or {}, Toast)
    end
    function Toast:show()
        toasts[#toasts + 1] = self.text
    end
    return Toast
end

-- ── 桩：JNI 引擎 ─────────────────────────────────────
local engine_state = {
    fail_load = nil,
    show_error = nil,
    height = nil,
    input = nil,
    log = {},
    load_count = 0,
    show_calls = 0,
    hide_calls = 0,
    sync_calls = 0,
    clear_calls = 0,
    last_show = nil,
}

local fake_engine = {
    show = function(text, start, stop)
        engine_state.show_calls = engine_state.show_calls + 1
        engine_state.last_show = { text = text, start = start, stop = stop }
        engine_state.log[#engine_state.log + 1] = "show"
        if engine_state.show_error then error(engine_state.show_error) end
    end,
    hide = function()
        engine_state.hide_calls = engine_state.hide_calls + 1
        engine_state.log[#engine_state.log + 1] = "hide"
    end,
    sync = function()
        engine_state.sync_calls = engine_state.sync_calls + 1
    end,
    clear = function()
        engine_state.clear_calls = engine_state.clear_calls + 1
    end,
    read_height = function() return engine_state.height end,
    take_input = function()
        local content = engine_state.input
        engine_state.input = nil
        return content
    end,
}

package.preload["features.system_ime.engine"] = function()
    return {
        load = function(_android, _plugin_path)
            engine_state.load_count = engine_state.load_count + 1
            if engine_state.fail_load then return nil, engine_state.fail_load end
            return fake_engine
        end,
    }
end

-- ── 假输入框 / VK ────────────────────────────────────
local function makeInputbox(fields)
    local ib = fields or {}
    ib.text = ib.text or ""
    ib.charpos = ib.charpos or 1
    ib.added, ib.setTexts, ib.moved = {}, {}, {}
    ib.deleted = 0
    ib.parent = { closed = 0, height_changes = 0 }
    function ib.parent:onKeyboardClosed() self.closed = self.closed + 1 end
    function ib.parent:onKeyboardHeightChanged() self.height_changes = self.height_changes + 1 end
    function ib:getText() return self.text end
    function ib:addChars(chars)
        self.added[#self.added + 1] = chars
        self.text = self.text .. chars
    end
    function ib:delChar()
        self.deleted = self.deleted + 1
        self.text = self.text:sub(1, math.max(0, #self.text - 1))
    end
    function ib:setText(text)
        self.setTexts[#self.setTexts + 1] = text
        self.text = text
    end
    function ib:moveCursorToCharPos(pos)
        self.charpos = pos
        self.moved[#self.moved + 1] = pos
    end
    return ib
end

local function makeVK(ib)
    local vk = { inputbox = ib, dimen = { h = 250 }, visible = false, show_calls = 0 }
    function vk:showKeyboard()
        self.show_calls = self.show_calls + 1
        self.visible = true
    end
    return vk
end

local function reset(opts)
    opts = opts or {}
    android_present = opts.android ~= false
    package.loaded["android"] = nil
    owners = { ["features.system_ime"] = opts.settings or {} }
    save_calls = {}
    scheduled = {}
    toasts = {}
    log_lines = {}
    engine_state.fail_load = opts.fail_load
    engine_state.show_error = opts.show_error
    engine_state.height = opts.height
    engine_state.input = opts.input
    engine_state.log = {}
    engine_state.load_count = 0
    engine_state.show_calls = 0
    engine_state.hide_calls = 0
    engine_state.sync_calls = 0
    engine_state.clear_calls = 0
    engine_state.last_show = nil
    package.loaded["features.system_ime"] = nil
    return require("features.system_ime")
end

local function scheduledAfter(delay, fn)
    for _idx, item in ipairs(scheduled) do
        if fn(item) then return item end
    end
    return nil
end

-- ── 非 Android：available=false，安装是空操作 ─────────
do
    local M = reset{ android = false }
    Assert.is_false(M.available())
    Assert.eq(M.status(), "unavailable")
    local vk = makeVK(makeInputbox())
    Assert.is_false(M.show(vk), "不可用时 show 返回 false")
    Assert.eq(vk.show_calls, 0, "不可用时不由后端补弹内置键盘")
    M.onCreate({ path = "/plugin" })
    Assert.eq(engine_state.load_count, 0, "非 Android 不加载 dex")
    M.hide(vk)
end

-- ── dex 缺失 / 哈希不符：not_ready + show false + 延迟回退 ──
do
    local M = reset{ fail_load = "dex missing" }
    M.onCreate({ path = "/plugin" })
    Assert.eq(M.status(), "not_ready")
    Assert.eq(owners["features.system_ime"].last_status, "not_ready", "last_status 落盘")
    Assert.contains(save_calls, "features.system_ime")

    local ib = makeInputbox()
    local vk = makeVK(ib)
    Assert.is_false(M.show(vk), "加载失败 show 返回 false")
    Assert.len(toasts, 1, "回退提示一次")
    Assert.matches(toasts[1], "切回内置键盘")

    local fallback = scheduledAfter(0, function(item) return item.delay ~= 0.05 end)
    Assert.not_nil(fallback, "回退已排程")
    Assert.is_true(fallback.delay >= 0.15 and fallback.delay <= 0.2, "延迟 150–200ms")
    fallback.fn()
    Assert.eq(vk.show_calls, 1, "延迟后补弹内置键盘")
end

-- ── 接管成功：直写状态、标记可见、开始轮询 ─────────────
do
    local M = reset{}
    M.onCreate({ path = "/plugin" })
    Assert.eq(M.status(), "ready")
    Assert.eq(owners["features.system_ime"].last_status, "ready")

    local ib = makeInputbox{ text = "你a", charpos = 2 }
    local vk = makeVK(ib)
    Assert.is_true(M.show(vk))
    Assert.is_true(vk.visible, "system 模式 VK 标记为可见（供 place 排版）")
    Assert.eq(engine_state.last_show.text, "你a")
    Assert.eq(engine_state.last_show.start, 1, "光标按 UTF-16 传给 dex")
    local poll = scheduledAfter(0, function(item) return item.delay == 0.05 end)
    Assert.not_nil(poll, "开始轮询快照")

    -- 收起：hide 清活动状态、收系统键盘
    scheduled = {}
    M.hide(vk)
    Assert.is_false(vk.visible)
    Assert.eq(engine_state.hide_calls, 1)
    Assert.len(scheduled, 0, "收起后停止轮询")
    M.poll()
    Assert.eq(ib.parent.closed, 0, "主动收起不触发 onKeyboardClosed")
end

-- ── JNI show 失败：先 hide 再延迟内置键盘 ─────────────
do
    local M = reset{ show_error = "jni boom" }
    M.onCreate({ path = "/plugin" })
    local vk = makeVK(makeInputbox{ text = "hi", charpos = 3 })
    Assert.is_false(M.show(vk), "show 失败返回 false")
    Assert.eq(engine_state.hide_calls, 1, "先隐藏系统键盘")
    Assert.eq(M.status(), "not_ready", "show 失败写 not_ready")
    local fallback = scheduledAfter(0, function(item) return item.delay ~= 0.05 end)
    Assert.not_nil(fallback)
    Assert.is_true(fallback.delay >= 0.15 and fallback.delay <= 0.2)
    fallback.fn()
    Assert.eq(vk.show_calls, 1, "隐藏之后才显示内置键盘")
    Assert.eq(engine_state.log[1], "show")
    Assert.eq(engine_state.log[2], "hide")
end

-- ── 直写 inputbox：CH / BS / ST 都不走 vk 方法 ────────
do
    local M = reset{}
    M.onCreate({ path = "/plugin" })
    local ib = makeInputbox{ text = "", charpos = 1 }
    local vk = makeVK(ib)
    Assert.is_true(M.show(vk))
    Assert.is_nil(vk.addChar, "后端根本不碰 vk:addChar")
    Assert.is_nil(vk.delChar, "后端根本不碰 vk:delChar")

    engine_state.input = table.concat({
        "CH:hello",
        "BS",
        "ST:0:12:aGVsbG8gd29ybGQ=",
    }, "\n")
    M.poll()
    Assert.eq(ib.added[1], "hello")
    Assert.eq(ib.deleted, 1)
    Assert.eq(ib.setTexts[#ib.setTexts], "hello world")
    Assert.eq(ib.moved[#ib.moved], 12, "ST 光标按 UTF-16 还原")
end

-- ── height=0：清活动状态 + onKeyboardClosed，之后还能再弹 ──
do
    local M = reset{}
    M.onCreate({ path = "/plugin" })
    local ib = makeInputbox()
    local vk = makeVK(ib)
    Assert.is_true(M.show(vk))
    scheduled = {}
    engine_state.height = 0
    M.poll()
    Assert.is_false(vk.visible, "height=0 视为已收起")
    Assert.eq(ib.parent.closed, 1, "通知对话框重新排版")
    Assert.len(scheduled, 0, "收起后停止轮询")

    engine_state.height = nil
    Assert.is_true(M.show(vk), "同一对话框再次输入仍可接管")
end

-- ── height > 0：双向同步键盘高度 ─────────────────────
do
    local M = reset{}
    M.onCreate({ path = "/plugin" })
    local ib = makeInputbox()
    local vk = makeVK(ib)
    M.show(vk)
    engine_state.height = 400
    M.poll()
    Assert.eq(vk.dimen.h, 400, "系统键盘高度同步给 VK")
    Assert.eq(ib.parent.height_changes, 1)
end

-- ── number / password / readonly：后端即使被调用也不接管 ──
local bypass = {
    { name = "number", fields = { input_type = "number" } },
    { name = "password text_type", fields = { text_type = "password" } },
    { name = "password is_password_type", fields = { is_password_type = true } },
    { name = "readonly", fields = { readonly = true } },
}
for _idx, case in ipairs(bypass) do
    local M = reset{}
    M.onCreate({ path = "/plugin" })
    engine_state.load_count = 0
    local vk = makeVK(makeInputbox(case.fields))
    Assert.is_false(M.show(vk), case.name .. " 返回 false 让路由走内置键盘")
    Assert.eq(engine_state.load_count, 0, case.name .. " 连 dex 都不加载")
    Assert.eq(engine_state.show_calls, 0, case.name .. " 不接管")
    Assert.len(toasts, 0, case.name .. " 不弹回退提示")
end

-- ── hide 在未接管时也安全 ────────────────────────────
do
    local M = reset{}
    local vk = makeVK(makeInputbox())
    M.hide(vk)
    M.hide(nil)
    Assert.eq(engine_state.hide_calls, 0, "未加载引擎时不调 JNI")
end
