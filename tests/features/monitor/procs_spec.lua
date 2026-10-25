--[[--
monitor.procs：解析 /proc，CPU 占用按两次采样差值算，排序从高到低。
@module tests.features.monitor.procs_spec
--]]

local Assert = require("support.assert")

local Procs = require("features.monitor.procs")

local files
local function fs()
    return {
        read = function(path) return files[path] end,
        list = function() return { "1", "2", "3", "self", "4" } end,
    }
end

-- /proc/<pid>/stat 第 14、15 项 utime / stime，第 22 项 starttime，第 24 项 rss（页）
local function stat(pid, comm, utime, stime, start, rss_pages)
    local f = {}
    for i = 3, 52 do f[i] = 0 end
    f[3], f[14], f[15], f[22], f[24] = "S", utime, stime, start, rss_pages
    return pid .. " (" .. comm .. ") " .. table.concat(f, " ", 3, 52)
end

local function cpuLine(user, idle) return "cpu  " .. user .. " 0 0 " .. idle .. " 0 0 0 0 0 0\ncpu0 0 0 0 0\ncpu1 0 0 0 0\n" end

files = {
    ["/proc/stat"] = cpuLine(100, 900),
    ["/proc/meminfo"] = "MemTotal: 1000 kB\nMemFree: 10 kB\nMemAvailable: 400 kB\n",
    ["/proc/1/stat"] = stat(1, "init", 10, 0, 5, 250),
    ["/proc/1/cmdline"] = "/sbin/init\0--flag\0",
    ["/proc/2/stat"] = stat(2, "kthreadd", 0, 0, 5, 0), -- 内存 0：不列
    ["/proc/3/stat"] = stat(3, "a (b) c", 20, 10, 7, 500),
    ["/proc/3/cmdline"] = "",
}

local p = Procs.new(fs())
local first = p:sample()
Assert.eq(first.mem_total, 1000)
Assert.eq(first.mem_avail, 400)
Assert.is_nil(first.cpu)
Assert.len(first.procs, 2)
Assert.is_nil(first.procs[1].cpu)

files["/proc/stat"] = cpuLine(200, 1000) -- 两核，期间共 200 个 tick，其中空闲 100
files["/proc/3/stat"] = stat(3, "a (b) c", 50, 20, 7, 500) -- 又用了 40 个 tick
local second = p:sample()
Assert.eq(second.cpu, 50)
local by = {}
for _idx, proc in ipairs(second.procs) do by[proc.pid] = proc end
Assert.eq(by[1].name, "init")
Assert.eq(by[1].rss, 1000)
Assert.eq(by[1].cpu, 0)
Assert.eq(by[3].name, "a (b) c") -- 没有命令行用 comm，括号和空格原样
Assert.eq(by[3].rss, 2000)
Assert.eq(by[3].cpu, 40 / 200 * 2 * 100)

local list = second.procs
Procs.sort(list, "mem")
Assert.eq(list[1].pid, 3)
Procs.sort(list, "cpu")
Assert.eq(list[1].pid, 3)

-- pid 被复用（启动时刻变了）不能拿旧进程的 tick 算差值
files["/proc/stat"] = cpuLine(300, 1100)
files["/proc/3/stat"] = stat(3, "other", 5, 0, 99, 100)
local third = p:sample()
for _idx, proc in ipairs(third.procs) do
    if proc.pid == 3 then Assert.is_nil(proc.cpu) end
end

-- 没有 /proc（非 Linux）
files = {}
Assert.is_nil(Procs.new(fs()):sample())

-- 本进程内存构成
files = { ["/proc/self/status"] = "VmRSS:\t  104876 kB\nRssAnon:\t   79524 kB\nRssFile:\t   25352 kB\n" }
local own = Procs.new(fs()):own()
Assert.eq(own.rss, 104876)
Assert.eq(own.anon, 79524)
Assert.eq(own.file, 25352)
files = {}
Assert.is_nil(Procs.new(fs()):own())
