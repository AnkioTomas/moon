--[[--
features.passcode：PIN 存取与校验、失败冷却（含时钟回拨）、冷启动 / 唤醒上锁、解锁后排队任务、
键盘异常关窗后下次唤醒重新上屏、关闭密码清掉 .old 备份。
@module tests.features.passcode.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Paths = require("utils.paths")

local conf, saves = {}, 0
package.loaded["utils.settings"] = {
    get = function(owner)
        assert(owner == "features.passcode")
        return conf
    end,
    save = function(owner)
        assert(owner == "features.passcode")
        saves = saves + 1
    end,
}

local pads = {}
package.loaded["features.passcode.pad"] = {
    new = function(_cls, o)
        o.show = function() o.shown = true end
        o.cleared = 0
        o.clear = function() o.cleared = o.cleared + 1 end
        -- 真键盘 on_submit 返回 true 或异常关窗都会走 UIManager:close → close_callback。
        o.close = function() o.close_callback() end
        pads[#pads + 1] = o
        return o
    end,
}

local guarded = {}
package.loaded["ui.guard"] = {
    call = function(label, fn, ...)
        guarded[#guarded + 1] = label
        local res = { pcall(fn, ...) }
        if res[1] then return unpack(res, 2) end
    end,
    wrap = function(label, fn)
        return function(...) return package.loaded["ui.guard"].call(label, fn, ...) end
    end,
}

local now = 1000
os.time = function() return now end

local Passcode = require("features.passcode")

--- 锁着时 afterUnlock 只排队；探针用固定 key，解锁时跑掉也无副作用。
local function isLocked()
    local ran = false
    Passcode.afterUnlock("probe", function() ran = true end)
    return not ran
end

-- 没有 PIN：不上锁，排队的事立即执行。
Passcode.onCreate()
Stubs.flush()
Assert.is_false(isLocked())
Assert.len(pads, 0)

-- 设 PIN：只存盐与哈希。
Passcode.setPin("1234")
Assert.is_true(Passcode.hasPin())
Assert.is_true(type(conf.salt) == "string" and conf.salt ~= "")
Assert.eq(#conf.hash, 64)
Assert.is_nil(conf.pin)
Assert.is_true(Passcode.verify("1234"))
local ok, err = Passcode.verify("0000")
Assert.is_false(ok)
Assert.eq(err, "密码错误")
Assert.eq(conf.fails, 1)
Assert.is_true(Passcode.verify("1234"))
Assert.is_nil(conf.fails)

-- 同一 PIN 重设换盐，哈希跟着变。
local old_hash = conf.hash
Passcode.setPin("1234")
Assert.is_true(conf.hash ~= old_hash)

-- 连错 5 次冷却；冷却中输对也不放行；过期后输对清零。
for _i = 1, 4 do Assert.eq(select(2, Passcode.verify("9999")), "密码错误") end
Assert.eq(select(2, Passcode.verify("9999")), "密码错误，请 30 秒后再试")
Assert.eq(conf.locked_until, 1030)
now = 1010
ok, err = Passcode.verify("1234")
Assert.is_false(ok)
Assert.eq(err, "尝试次数过多，请 20 秒后再试")
now = 1031
Assert.eq(select(2, Passcode.verify("9999")), "密码错误，请 30 秒后再试") -- 冷却后再错一次立即再冷却
now = 1062
Assert.is_true(Passcode.verify("1234"))
Assert.is_nil(conf.fails)
Assert.is_nil(conf.locked_until)

-- 时钟回拨：截止时间远超冷却时长，按过期处理，不锁死。
conf.fails, conf.locked_until = 5, now + 100000
Assert.is_true(Passcode.verify("1234"))

-- 冷启动：onCreate 当场记为已锁，下一 tick 才上屏；第二个插件实例不重复。
Passcode.onCreate()
Assert.len(pads, 0, "booted 后不再按冷启动上锁")

package.loaded["features.passcode"] = nil
Passcode = require("features.passcode")
Passcode.onCreate()
Assert.is_true(isLocked(), "冷启动当场记为已锁，后面的 feature 的 onCreate 要看得到")
Assert.len(pads, 0)
Stubs.flush()
Assert.len(pads, 1)
Assert.is_true(pads[1].shown)
Assert.contains(guarded, "passcode showPad", "nextTick 回调不在任何入口里，必须自己经 guard")
Assert.is_false(pads[1].dismissable)
Passcode.onCreate()
Stubs.flush()
Assert.len(pads, 1)

-- 锁着时排队，同 key 只留最后一个；唤醒不叠第二层，只清掉没输完的位数。
local order = {}
Passcode.afterUnlock("remote", function() order[#order + 1] = "old" end)
Passcode.afterUnlock("remote", function() order[#order + 1] = "remote" end)
Passcode.onResume()
Assert.len(pads, 1)
Assert.eq(pads[1].cleared, 1)

Assert.eq(pads[1].on_submit("0000"), "密码错误")
Assert.is_true(isLocked())
Assert.len(order, 0)
Assert.is_true(pads[1].on_submit("1234"))
pads[1].close()
Assert.is_false(isLocked())
Assert.eq(table.concat(order, ","), "remote")

-- 唤醒：同步上屏（不等 tick）。排队的任务各自经 guard：一个抛错不拦其余，键盘照样关。
Passcode.onResume()
Assert.is_true(isLocked())
Assert.len(pads, 2)
Assert.is_true(pads[2].shown)
local after = 0
Passcode.afterUnlock("boom", function() error("boom") end)
Passcode.afterUnlock("ok", function() after = after + 1 end)
Assert.is_true(pads[2].on_submit("1234"))
pads[2].close()
Assert.eq(after, 1)
Assert.contains(guarded, "passcode afterUnlock boom")
Assert.contains(guarded, "passcode afterUnlock ok")

-- 键盘没输对就被关掉（Modal 绘制出错会自行关窗）：仍算锁着、排队的不跑，下次唤醒重新上屏。
Passcode.onResume()
Assert.len(pads, 3)
local waited = 0
Passcode.afterUnlock("remote", function() waited = waited + 1 end)
pads[3].close()
Assert.is_true(isLocked())
Assert.eq(waited, 0)
Passcode.onResume()
Assert.len(pads, 4)
Assert.is_true(pads[4].shown)
Assert.is_true(pads[4].on_submit("1234"))
pads[4].close()
Assert.eq(waited, 1)

-- 关闭密码后唤醒不再上锁；LuaSettings 留下的 .old 一并删掉，否则主文件丢失时锁会从备份复活。
local old = Paths.sectionPath("passcode") .. ".old"
local f = assert(io.open(old, "w"))
f:write("return { hash = 'stale' }\n")
f:close()
Passcode.clear()
Assert.is_false(Passcode.hasPin())
Assert.is_nil(conf.salt)
Assert.is_nil(io.open(old, "r"), "clear 删掉 passcode.lua.old")
Passcode.onResume()
Assert.is_false(isLocked())
Assert.len(pads, 4)
Assert.is_true(saves > 0)
