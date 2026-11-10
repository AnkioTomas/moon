--[[--
可用内存、重书提醒阈值，以及费内存步骤的预检。

开书 / KFX 转换峰值常到文件体积的数倍。提醒阈值 = clamp(可用内存/4, 8MB, 40MB)；
读不到 MemAvailable 时回退 20MB（与历史 BIG_BOOK_BYTES 一致）。
字体/样式「重书」降级仍用 reader.prefs.BIG_BOOK_BYTES，不跟瞬时可用内存晃。

预检（canAfford）：把步骤峰值估算和 util.calcFreeMem（已按 85% 打折）比较，
不够就拒绝开跑，避免 Kindle PaperWhite 2 这类 256MB 设备在转码/解包中被 SIGKILL。
读不到可用内存（非 Linux / 模拟器）不拦截。

Kindle 启动模式复用官方环境变量 STOP_FRAMEWORK（koreader.sh --framework_stop）。

@module koplugin.book.utils.mem
--]]

local Mem = {}

local MB = 1024 * 1024
local FALLBACK = 20 * MB
local FLOOR = 8 * MB
local CEIL = 40 * MB
--- 估算误差与进程余量。calcFreeMem 已留 15%，这里再垫一截，避免刚好卡线仍被杀。
local HEADROOM = 4 * MB
--- Woff.toSfnt 用 inflate.stream 的 64KB 分块写盘（已核对 utils.inflate.CHUNK）。
local WOFF_INFLATE_CHUNK = 65536

Mem.INSUFFICIENT = "memory insufficient"

--- 当前大致可用字节（KOReader util.calcFreeMem，已留 85% 余量）；非 Linux（读不到 /proc/meminfo）为 nil。
---@return number|nil
function Mem.availableBytes()
    local util = require("util")
    local calc = util and util.calcFreeMem
    if type(calc) ~= "function" then return nil end
    local free = calc()
    return type(free) == "number" and free > 0 and free or nil
end

--- 首次打开 / KFX 转换前的确认阈值（字节）。
---@return number
function Mem.warnThresholdBytes()
    local free = Mem.availableBytes()
    if not free then return FALLBACK end
    local q = math.floor(free / 4)
    if q < FLOOR then return FLOOR end
    if q > CEIL then return CEIL end
    return q
end

--- 文件是否达到提醒阈值。
---@param size number|nil
---@return boolean
function Mem.isHeavy(size)
    return (tonumber(size) or 0) >= Mem.warnThresholdBytes()
end

--- 展示用整数 MB（向上取整到至少 1，避免「0 MB」）。
---@param bytes number|nil
---@return number|nil
function Mem.mb(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return nil end
    return math.max(1, math.floor(bytes / MB + 0.5))
end

--- Kindle 当前启动模式。复用 koreader.sh 的 STOP_FRAMEWORK（--framework_stop 时为 "yes"）。
--- no-framework：已关掉 Kindle 系统界面；framework：框架仍在跑；not-applicable：非 Kindle。
---@return string "no-framework"|"framework"|"not-applicable"
function Mem.startupMode()
    if os.getenv("STOP_FRAMEWORK") == "yes" then
        return "no-framework"
    end
    local ok, Device = pcall(require, "device")
    if ok and type(Device) == "table" then
        local ok_k, is_kindle = pcall(function() return Device:isKindle() end)
        if ok_k and is_kindle then return "framework" end
    end
    return "not-applicable"
end

--- 以 no-framework 重启能否腾出 Kindle 系统界面占用的内存。
---@return boolean
function Mem.canOfferNoFramework()
    return Mem.startupMode() == "framework"
end

--- WOFF→sfnt 峰值估算（字节）。
--- 已核对：Woff.toSfnt 先 read("*a") 整份源文件，再按表分块 inflate 写盘（块 64KB），
--- sfnt 不整份留在内存。峰值 ≈ 源文件 + 64KB，不再是旧注释里的「源文件 + 2×最大表」。
---@param woff_bytes number|nil
---@return number
function Mem.estimateWoffToSfnt(woff_bytes)
    return (tonumber(woff_bytes) or 0) + WOFF_INFLATE_CHUNK
end

--- 预检：needed 为步骤峰值增量。不够则返回统一的 memory insufficient 错误串。
---@param needed number|nil
---@return boolean ok
---@return string|nil err
---@return table detail { needed: number, available: number|nil, unknown: boolean|nil }
function Mem.canAfford(needed)
    needed = math.max(0, tonumber(needed) or 0)
    local available = Mem.availableBytes()
    local budget = needed > 0 and (needed + HEADROOM) or 0
    local detail = { needed = budget, available = available }
    if budget <= 0 then return true, nil, detail end
    if not available then
        detail.unknown = true
        return true, nil, detail
    end
    if available >= budget then return true, nil, detail end
    local err = string.format("%s need=%sMB avail=%sMB",
        Mem.INSUFFICIENT, tostring(Mem.mb(budget)), tostring(Mem.mb(available)))
    return false, err, detail
end

---@param err any
---@return boolean
function Mem.isInsufficient(err)
    return type(err) == "string" and err:find(Mem.INSUFFICIENT, 1, true) ~= nil
end

--- 章节解包预检弹窗里的操作名。文案在核心词典，书源不要再 require("gettext")。
---@return string
function Mem.chapterUnpackWhat()
    return require("gettext")("章节解包")
end

--- 内存不够：warn 日志（立刻落盘）并弹确认框。
--- Kindle 且框架仍在跑时，提供「以 no-framework 模式重启」；否则只告知无法继续。
--- 须在 UI 线程调用（不要在 Job 子进程里弹窗）。
---@param opts { what: string, needed: number, available: number|nil, id?: any, dest?: any }
function Mem.promptInsufficient(opts)
    opts = opts or {}
    local logger = require("utils.log")
    local what = opts.what or ""
    local need_mb = Mem.mb(opts.needed) or "?"
    local avail_mb = Mem.mb(opts.available) or "?"
    local mode = Mem.startupMode()
    local parts = {
        "book.mem insufficient", what,
        "need=" .. tostring(need_mb) .. "MB",
        "avail=" .. tostring(avail_mb) .. "MB",
        "startup_mode=" .. mode,
    }
    if opts.id then parts[#parts + 1] = "id=" .. tostring(opts.id) end
    if opts.dest then parts[#parts + 1] = "dest=" .. tostring(opts.dest) end
    logger.warn(unpack(parts))
    logger.flushSync()

    local _ = require("gettext")
    local T = require("ffi/util").template
    local offer = Mem.canOfferNoFramework()
    local text
    if offer then
        text = T(_("当前可用内存约 %1 MB，完成「%2」大约需要 %3 MB，继续的话可能被系统强制结束。可以用 no-framework 模式重启（关闭 Kindle 系统界面以腾出内存），然后再试一次。"),
            avail_mb, what, need_mb)
    else
        text = T(_("当前可用内存约 %1 MB，完成「%2」大约需要 %3 MB，内存不足，无法继续。"),
            avail_mb, what, need_mb)
    end
    local confirm = {
        text = text,
        ok_text = offer and _("以 no-framework 重启") or _("确定"),
        cancel_text = offer and _("取消") or _("关闭"),
    }
    if offer then
        confirm.ok_callback = function() require("utils.restart").noFramework() end
    end
    require("ui.themes.widgets.confirm"):new(confirm):show()
end

return Mem
