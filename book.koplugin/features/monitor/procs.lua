--[[--
进程采样：读 /proc 得到整机内存、整机 CPU 占用，以及各进程的常驻内存与 CPU 占用。

CPU 占用是两次采样之间的差值，所以第一次采样所有 cpu 为 nil；之后每次 `sample()` 与上一次比较。
进程 CPU 按「单核满载 = 100%」算（和 top 一致，多核机器可以超过 100%），整机 CPU 按整机算（0~100%）。
内存为 0 的内核线程不列出。进程以 pid + 启动时刻为键，pid 被复用不会串数据。

`fs` 可注入（离线测试用）：`read(path)` 返回文件内容或 nil，`list(path)` 返回目录项名数组。

@module koplugin.book.features.monitor.procs
--]]

local Procs = {}
Procs.__index = Procs

local PAGE_KB = 4 -- 常驻页数 × 页大小；ARM / x86 的 Linux 与 Android 都是 4 KB

---@class BookProcSample
---@field mem_total integer KB
---@field mem_avail integer KB
---@field cpu number|nil 整机占用 0~100，第一次采样为 nil
---@field procs { pid: integer, name: string, rss: integer, cpu: number|nil }[] rss 单位 KB

local function defaultFs()
    local lfs = require("libs/libkoreader-lfs")
    return {
        read = function(path)
            local f = io.open(path, "r")
            if not f then return nil end
            local data = f:read("*a")
            f:close()
            return data
        end,
        list = function(path)
            local out = {}
            for name in lfs.dir(path) do out[#out + 1] = name end
            return out
        end,
    }
end

---@param fs table|nil
---@return table
function Procs.new(fs)
    return setmetatable({ fs = fs or defaultFs(), prev_total = nil, prev_idle = nil, prev_ticks = {} }, Procs)
end

--- /proc/stat 首行总时间、空闲时间与核数。
---@param text string
---@return integer|nil total, integer idle, integer cores
local function parseStat(text)
    local line = text:match("^cpu%s+([^\n]+)")
    if not line then return nil, 0, 1 end
    local total, idle, i = 0, 0, 0
    for n in line:gmatch("%d+") do
        i = i + 1
        if i <= 8 then total = total + tonumber(n) end -- user..steal；guest 已含在 user 里
        if i == 4 or i == 5 then idle = idle + tonumber(n) end
    end
    local cores = 0
    for _core in text:gmatch("\ncpu%d+") do cores = cores + 1 end
    return total, idle, math.max(cores, 1)
end

---@param text string
---@return integer total, integer avail
local function parseMem(text)
    local function kb(key) return tonumber(text:match(key .. ":%s*(%d+)")) or 0 end
    local avail = text:find("MemAvailable:", 1, true) and kb("MemAvailable")
        or (kb("MemFree") + kb("Buffers") + kb("Cached"))
    return kb("MemTotal"), avail
end

--- /proc/<pid>/stat：comm 在括号里且可能含空格和括号，所以按最后一个右括号切。
---@param text string
---@return string|nil comm, integer ticks, integer rss_kb, string start
local function parseProc(text)
    local comm, rest = text:match("^%d+ %((.*)%) (.*)$")
    if not comm then return nil, 0, 0, "" end
    local fields = {}
    for word in rest:gmatch("%S+") do fields[#fields + 1] = word end
    -- fields[1] 是第 3 项 state；utime 第 14、stime 第 15、starttime 第 22、rss 第 24 项
    local ticks = (tonumber(fields[12]) or 0) + (tonumber(fields[13]) or 0)
    return comm, ticks, (tonumber(fields[22]) or 0) * PAGE_KB, fields[20] or ""
end

--- 进程名：命令行第一段的文件名；没有命令行（如内核线程）用 comm。
---@param cmdline string|nil
---@param comm string
---@return string
local function displayName(cmdline, comm)
    local exe = cmdline and cmdline:match("^([^%z]+)")
    local base = exe and exe:match("([^/]+)$")
    base = (base and base ~= "") and base or comm
    if cmdline and cmdline:find("reader.lua", 1, true) and base:find("luajit", 1, true) then
        return "KOReader (luajit)"
    end
    return base
end

--- 采一次样。读不到 /proc（非 Linux）返回 nil。
---@return BookProcSample|nil
function Procs:sample()
    local fs = self.fs
    local stat = fs.read("/proc/stat")
    local total, idle, cores
    if stat then total, idle, cores = parseStat(stat) end
    if not total then return nil end
    local mem_total, mem_avail = parseMem(fs.read("/proc/meminfo") or "")

    local dtotal = self.prev_total and total - self.prev_total or nil
    if dtotal and dtotal <= 0 then dtotal = nil end
    local cpu
    if dtotal then cpu = 100 * (1 - (idle - self.prev_idle) / dtotal) end

    local procs, ticks = {}, {}
    for _idx, entry in ipairs(fs.list("/proc")) do
        local text = tonumber(entry) and fs.read("/proc/" .. entry .. "/stat")
        local comm, used, rss, start
        if text then comm, used, rss, start = parseProc(text) end
        if comm and rss > 0 then
            local key = entry .. ":" .. start
            ticks[key] = used
            local before = self.prev_ticks[key]
            procs[#procs + 1] = {
                pid = tonumber(entry),
                name = displayName(fs.read("/proc/" .. entry .. "/cmdline"), comm),
                rss = rss,
                cpu = dtotal and before and math.max(0, used - before) / dtotal * cores * 100 or nil,
            }
        end
    end
    self.prev_total, self.prev_idle, self.prev_ticks = total, idle, ticks
    return { mem_total = mem_total, mem_avail = mem_avail, cpu = cpu, procs = procs }
end

--- 从高到低排序（就地）：mem 按常驻内存，cpu 按 CPU 占用（nil 排最后），同值按内存再按 pid。
---@param procs { pid: integer, rss: integer, cpu: number|nil }[]
---@param by "mem"|"cpu"
function Procs.sort(procs, by)
    table.sort(procs, function(a, b)
        if by == "cpu" and (a.cpu or -1) ~= (b.cpu or -1) then return (a.cpu or -1) > (b.cpu or -1) end
        if a.rss ~= b.rss then return a.rss > b.rss end
        return a.pid < b.pid
    end)
end

return Procs
