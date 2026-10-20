--[[--
锁屏密码：冷启动和每次唤醒时盖一层整屏数字键盘，输对 PIN 才放行。

只是隐私遮挡，不是加密：USB / SSH 仍能直接读书和配置。忘记密码时删掉 settings/passcode.lua 及其 .old 即解除
（LuaSettings 落盘时会把旧文件留成 .old，主文件不在时会读它）。
有没有锁只看有没有 PIN（settings 里的 hash），没有单独的开关。
PIN 只存 sha256(salt .. pin)，只为不落明文：位数太少，拿到文件就能穷举。
连续输错 MAX_FAILS 次后每错一次冷却 COOLDOWN 秒，次数与截止时间落盘，重启不清零。

唤醒时在 Resume 里同步上屏：KOReader 关屏保与广播 Resume 在同一个 tick，下一帧重绘时锁层已在栈顶，书页不会露出来。
冷启动时 onCreate 早于 FM / 阅读器上屏，只先记下已锁，下一 tick 再上屏，盖住随后打开的桌面。

别的 feature 要等解锁才做的事（远程管理起服）经 `afterUnlock(key, fn)` 排队，同 key 只留最后一个；
它们必须排在本 feature 之后（features/init.lua 的 list），onCreate / onResume 时才看得到已锁。

@module koplugin.book.features.passcode
--]]

local Guard = require("ui.guard")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local OWNER = "features.passcode"
local MAX_FAILS = 5
local COOLDOWN = 30
local RESET_PIN = "000000"

local Passcode = {}

-- locked：还没输对 PIN；pad：屏上的解锁键盘。两者不总同步：键盘被 Modal 异常关掉时仍算锁着。
local locked = false
---@type BookPasscodePad|nil
local pad
local booted = false
---@type table<string, fun()>
local waiters = {}

---@param salt string
---@param pin string
---@return string
local function digest(salt, pin)
    return sha2.sha256(salt .. pin) --[[@as string]]
end

---@return boolean
function Passcode.hasPin()
    return MoonSettings.get(OWNER).hash ~= nil
end

--- 设新 PIN，清掉失败记录。
---@param pin string
function Passcode.setPin(pin)
    local conf = MoonSettings.get(OWNER)
    conf.salt = sha2.md5(os.time() .. os.clock() .. math.random()) --[[@as string]]
    conf.hash = digest(conf.salt, pin)
    conf.fails, conf.locked_until = nil, nil
    MoonSettings.save(OWNER)
end

--- 去掉 PIN，即关闭锁屏密码。落盘可能刚把带 hash 的旧文件转成 .old，一并删掉，免得主文件丢失时锁又回来。
function Passcode.clear()
    local conf = MoonSettings.get(OWNER)
    conf.salt, conf.hash, conf.fails, conf.locked_until = nil, nil, nil, nil
    MoonSettings.save(OWNER)
    os.remove(Paths.sectionPath("passcode") .. ".old")
end

--- 校验 PIN；失败时第二个返回值是给用户看的原因。
--- 冷却截止离现在超过 COOLDOWN 说明时钟被往回拨过（Kindle 没电后会回到 1970），按已过期处理，免得锁死几十年。
---@param pin string
---@return boolean ok
---@return string|nil err
function Passcode.verify(pin)
    local conf = MoonSettings.get(OWNER)
    -- 忘记密码：USB 删掉密码文件后输 000000 解锁，免得卡在锁屏没法重启；文件还在就当普通输入。
    if pin == RESET_PIN and not lfs.attributes(Paths.sectionPath("passcode"), "mode") then
        Passcode.clear()
        return true
    end
    local now = os.time()
    local wait = (conf.locked_until or now) - now
    if wait > 0 and wait <= COOLDOWN then
        return false, T(_("尝试次数过多，请 %1 秒后再试"), wait)
    end
    if digest(conf.salt, pin) == conf.hash then
        if conf.fails then
            conf.fails, conf.locked_until = nil, nil
            MoonSettings.save(OWNER)
        end
        return true
    end
    conf.fails = (conf.fails or 0) + 1
    conf.locked_until = conf.fails >= MAX_FAILS and now + COOLDOWN or nil
    MoonSettings.save(OWNER)
    if conf.locked_until then
        return false, T(_("密码错误，请 %1 秒后再试"), COOLDOWN)
    end
    return false, _("密码错误")
end

--- 是否连续输错到了上限，此时解锁页给出「忘记密码」入口。
---@return boolean
function Passcode.tooManyFails()
    return (MoonSettings.get(OWNER).fails or 0) >= MAX_FAILS
end

--- 解锁后执行 fn；没锁就立即执行。同 key 重复排队只留最后一个。
---@param key string
---@param fn fun()
function Passcode.afterUnlock(key, fn)
    if not locked then return fn() end
    waiters[key] = fn
end

local function showPad()
    if pad then return end
    pad = require("features.passcode.pad"):new{
        title = _("输入密码解锁"),
        dismissable = false,
        header = true,
        forgot = Passcode.tooManyFails,
        on_forgot = function()
            require("ui.themes.widgets.confirm"):new{
                title = _("忘记了设备密码？"),
                text = T(_("不需要输入密码：用 USB 连接电脑，删除 %1 和 %1.old，然后在密码页输入 000000 即可解锁并关闭密码。"),
                    Paths.sectionPath("passcode")),
                ok_text = _("知道了"),
            }:show()
        end,
        on_submit = function(pin)
            local ok, err = Passcode.verify(pin)
            if not ok then return err end
            locked = false
            local list = waiters
            waiters = {}
            -- 各自隔离：一个抛错不能拦住其余的，也不能让已解锁的键盘留在屏上。
            for key, fn in pairs(list) do Guard.call("passcode afterUnlock " .. key, fn) end
            return true
        end,
        -- 异常关窗（绘制出错）不当场重弹：会反复出错。locked 保持，下次唤醒重新上屏。
        close_callback = function() pad = nil end,
    }
    pad:show()
end

function Passcode.onCreate()
    if booted then return end
    booted = true
    if not Passcode.hasPin() then return end
    locked = true
    require("ui/uimanager"):nextTick(Guard.wrap("passcode showPad", showPad))
end

--- 已有键盘就只清掉休眠前没输完的位数。
function Passcode.onResume()
    if not Passcode.hasPin() then return end
    locked = true
    if pad then return pad:clear() end
    showPad()
end

return Passcode
