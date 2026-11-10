--[[--
utils.mem：重书提醒阈值随可用内存伸缩。

@module tests.utils.mem_spec
--]]

local Assert = require("support.assert")

package.loaded["utils.mem"] = nil
package.loaded["util"] = nil

local free_bytes
package.preload["util"] = function()
    return {
        calcFreeMem = function() return free_bytes end,
    }
end

local Mem = require("utils.mem")
local MB = 1024 * 1024

free_bytes = nil
Assert.eq(Mem.warnThresholdBytes(), 20 * MB)

free_bytes = 20 * MB -- /4 = 5MB → 地板 8MB
Assert.eq(Mem.warnThresholdBytes(), 8 * MB)
Assert.is_true(Mem.isHeavy(8 * MB))
Assert.is_false(Mem.isHeavy(7 * MB))

free_bytes = 80 * MB -- /4 = 20MB
Assert.eq(Mem.warnThresholdBytes(), 20 * MB)

free_bytes = 200 * MB -- /4 = 50MB → 封顶 40MB
Assert.eq(Mem.warnThresholdBytes(), 40 * MB)
Assert.is_false(Mem.isHeavy(39 * MB))
Assert.is_true(Mem.isHeavy(40 * MB))

Assert.eq(Mem.mb(40 * MB), 40)
Assert.eq(Mem.mb(100), 1)
Assert.is_nil(Mem.mb(nil))


-- 预检：可用内存不足则拒绝，读不到则放行
Assert.eq(Mem.estimateWoffToSfnt(1000), 1000 + 65536)
Assert.eq(Mem.estimateWoffToSfnt(nil), 65536)

free_bytes = 20 * MB
local ok, err, detail = Mem.canAfford(Mem.estimateWoffToSfnt(2 * MB))
Assert.is_true(ok, "20MB 可用应放得下 2MB 字体")
Assert.eq(detail.unknown, nil)

ok, err, detail = Mem.canAfford(Mem.estimateWoffToSfnt(30 * MB))
Assert.is_false(ok)
Assert.is_true(Mem.isInsufficient(err))
Assert.is_true(detail.needed > 30 * MB)
Assert.eq(detail.available, 20 * MB)

free_bytes = nil
ok, err, detail = Mem.canAfford(100 * MB)
Assert.is_true(ok, "读不到 MemAvailable 不拦截")
Assert.is_true(detail.unknown)

Assert.is_false(Mem.isInsufficient(nil))
Assert.is_false(Mem.isInsufficient("extract failed"))

-- 启动模式：复用 STOP_FRAMEWORK，非 Kindle 为 not-applicable
local real_getenv = os.getenv
os.getenv = function(key)
    if key == "STOP_FRAMEWORK" then return "yes" end
    return real_getenv(key)
end
Assert.eq(Mem.startupMode(), "no-framework")
Assert.is_false(Mem.canOfferNoFramework())
os.getenv = function(key)
    if key == "STOP_FRAMEWORK" then return nil end
    return real_getenv(key)
end
package.loaded["device"] = { isKindle = function() return true end }
Assert.eq(Mem.startupMode(), "framework")
Assert.is_true(Mem.canOfferNoFramework())
package.loaded["device"] = { isKindle = function() return false end }
Assert.eq(Mem.startupMode(), "not-applicable")
Assert.is_false(Mem.canOfferNoFramework())
os.getenv = real_getenv
package.loaded["device"] = nil

-- 弹窗：Kindle + 框架仍在跑时提供 no-framework 重启；否则只告知无法继续
do
    local shown, restarted = nil, false
    package.loaded["ui.themes.widgets.confirm"] = nil
    package.preload["ui.themes.widgets.confirm"] = function()
        return {
            new = function(_, opts)
                shown = opts
                return { show = function() end }
            end,
        }
    end
    package.loaded["utils.restart"] = {
        noFramework = function() restarted = true end,
    }
    package.loaded["gettext"] = package.loaded["gettext"] or function(s) return s end
    if not package.loaded["gettext"] or type(package.loaded["gettext"]) == "function" then
        -- keep support stub if present
    end
    os.getenv = function(key)
        if key == "STOP_FRAMEWORK" then return nil end
        return real_getenv(key)
    end
    package.loaded["device"] = { isKindle = function() return true end }

    local logs = {}
    local logger = require("utils.log")
    local saved_warn, saved_flush = logger.warn, logger.flushSync
    logger.warn = function(...)
        logs[#logs + 1] = table.concat({ ... }, " ", 1, select("#", ...))
    end
    logger.flushSync = function() end

    Mem.promptInsufficient({
        what = "字体转换", needed = 40 * MB, available = 10 * MB,
        id = "song", dest = "/mnt/us/.moon/fonts/song.ttf",
    })
    Assert.not_nil(shown)
    Assert.is_true(shown.text:find("10 MB", 1, true) ~= nil)
    Assert.is_true(shown.text:find("40 MB", 1, true) ~= nil)
    Assert.is_true(shown.text:find("字体转换", 1, true) ~= nil)
    Assert.is_true(shown.text:find("no-framework", 1, true) ~= nil)
    Assert.eq(shown.ok_text, "以 no-framework 重启")
    Assert.eq(shown.cancel_text, "取消")
    shown.ok_callback()
    Assert.is_true(restarted)
    Assert.is_true(logs[1]:find("book.mem insufficient", 1, true) ~= nil)
    Assert.is_true(logs[1]:find("dest=/mnt/us/.moon/fonts/song.ttf", 1, true) ~= nil)
    Assert.is_true(logs[1]:find("startup_mode=framework", 1, true) ~= nil)

    shown, restarted = nil, false
    os.getenv = function(key)
        if key == "STOP_FRAMEWORK" then return "yes" end
        return real_getenv(key)
    end
    Mem.promptInsufficient({ what = "字体转换", needed = 40 * MB, available = 10 * MB })
    Assert.not_nil(shown)
    Assert.is_nil(shown.ok_callback)
    Assert.eq(shown.ok_text, "确定")
    Assert.is_true(shown.text:find("无法继续", 1, true) ~= nil)
    Assert.is_nil(shown.text:find("然后再试一次", 1, true))

    shown = nil
    os.getenv = function(key)
        if key == "STOP_FRAMEWORK" then return nil end
        return real_getenv(key)
    end
    package.loaded["device"] = { isKindle = function() return false end }
    Mem.promptInsufficient({ what = "章节解包", needed = 40 * MB, available = 8 * MB })
    Assert.not_nil(shown)
    Assert.is_nil(shown.ok_callback)
    Assert.is_true(shown.text:find("无法继续", 1, true) ~= nil)

    logger.warn, logger.flushSync = saved_warn, saved_flush
    os.getenv = real_getenv
    package.loaded["device"] = nil
    package.loaded["ui.themes.widgets.confirm"] = nil
    package.preload["ui.themes.widgets.confirm"] = nil
    package.loaded["utils.restart"] = nil
end
