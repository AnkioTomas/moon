--[[--
features.lockscreen.history：留存、同秒重名、档位裁剪、从不停增。

@module tests.features.lockscreen.history_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local lfs = require("libs/libkoreader-lfs")

package.preload["gettext"] = function() return function(text) return text end end

local settings = {}
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function() end,
    }
end
package.preload["utils.log"] = function()
    return { warn = function() end, dbg = function() end }
end

-- 临时根目录：用真实目录与真实文件，复制 / 裁剪才真的跑一遍。
local root = os.tmpname()
os.remove(root)
assert(lfs.mkdir(root))
local screen_dir = root .. "/screensaver"
assert(lfs.mkdir(screen_dir))
local history_dir = screen_dir .. "/history"

-- 可切换：Kindle 上 DataStorage 把数据目录报成「.」，磁盘路径就是相对的。
local screen_root = screen_dir
package.preload["utils.paths"] = function()
    local P = {}
    function P.screensaverDir() return screen_root end
    function P.ensureDir(path)
        if lfs.attributes(path, "mode") == "directory" then return true end
        local parent = path:match("(.+)/[^/]+/?$")
        if parent then P.ensureDir(parent) end
        return lfs.mkdir(path)
    end
    return P
end

local History = require("features.lockscreen.history")

--- 写一个内容可区分的源文件。
---@param body string
---@return string
local function source(body)
    local path = root .. "/source-" .. body .. ".png"
    local file = assert(io.open(path, "wb"))
    file:write(body)
    file:close()
    return path
end

---@param path string
---@return string
local function read(path)
    local file = assert(io.open(path, "rb"))
    local body = file:read("*a")
    file:close()
    return body
end

--- 预置 n 张历史文件，时间戳递增（2000 年，保证排在真实时间戳之前）。
---@param n integer
local function preseed(n)
    require("utils.paths").ensureDir(history_dir)
    for i = 1, n do
        local file = assert(io.open(string.format("%s/20000101-%06d.png", history_dir, i), "wb"))
        file:write(string.rep("x", i))
        file:close()
    end
end

local function wipe()
    if lfs.attributes(history_dir, "mode") == "directory" then
        for name in lfs.dir(history_dir) do
            os.remove(history_dir .. "/" .. name)
        end
        os.remove(history_dir)
    end
end

---@return integer
local function count()
    return #History.list()
end

---@return string|nil
local function oldest()
    local all = History.list()
    return all[#all] and all[#all].name or nil
end

-- 档位：默认 20，非法值同样回退 20
Assert.eq(History.tier(), "20")
Assert.eq(History.limit(), 20)
Assert.is_true(History.validLimit("off"))
Assert.is_false(History.validLimit("30"))
settings.lock_screen_history_limit = "50"
Assert.eq(History.limit(), 50)
settings.lock_screen_history_limit = "whatever"
Assert.eq(History.limit(), 20)
settings.lock_screen_history_limit = nil
Assert.eq(History.limitLabel("off"), "从不")
Assert.eq(History.limitLabel("10"), "10 张")
Assert.eq(History.limitLabel(nil), "20 张")

-- 1. record 复制源文件，list 看得见（字段齐全）
History.record(source("first"))
local items = History.list()
Assert.eq(#items, 1)
Assert.eq(items[1].path, history_dir .. "/" .. items[1].name)
Assert.eq(items[1].size, 5)
Assert.is_true(items[1].mtime > 0)
Assert.eq(read(items[1].path), "first")

-- 2. 同秒重名追加 -2；两张都在
History.record(source("second"))
items = History.list()
Assert.eq(#items, 2)
Assert.eq(items[1].name:match("%-%d+%.png$"), "-2.png")
Assert.eq(read(items[1].path), "second")
Assert.eq(read(items[2].path), "first")

-- 7. list 降序：同秒重名的 -2 也算更新，排在前
Assert.is_true(items[1].name ~= items[2].name)
Assert.eq(items[2].name:gsub("%.png$", "-2.png"), items[1].name)

-- 3. 默认档位：22 张预置 + 新的一张，裁到 20，最旧的三张被删
wipe()
preseed(22)
settings.lock_screen_history_limit = nil
History.record(source("trim"))
Assert.eq(count(), 20)
Assert.eq(oldest(), "20000101-000004.png", "最旧的三张被裁掉")
Assert.eq(History.list()[1].name:match("^2000"), nil, "新图在最前")

-- 4. off：不新增、不裁剪、不截断
wipe()
preseed(3)
settings.lock_screen_history_limit = "off"
History.record(source("off"))
Assert.eq(count(), 3)

-- 5. 档位 10：裁到 10
wipe()
preseed(12)
settings.lock_screen_history_limit = "10"
History.record(source("ten"))
Assert.eq(count(), 10)
Assert.eq(oldest(), "20000101-000004.png")

-- 6. 源文件不存在：不抛错，也不留半截文件
wipe()
settings.lock_screen_history_limit = "20"
History.record(root .. "/missing.png")
Assert.eq(count(), 0)
Assert.eq(lfs.attributes(history_dir, "mode"), "directory")

-- 7. 数据目录报成「.」时（Kindle）：路径要补成绝对，远程 /download 只收绝对路径
screen_root = "./screensaver"
package.loaded["features.lockscreen.history"] = nil
local Rel = require("features.lockscreen.history")
Assert.eq(Rel.dir(), lfs.currentdir() .. "/screensaver/history")
Assert.eq(Rel.list()[1], nil, "相对目录不存在时安静返回空表")

-- 收尾：清理临时目录
wipe()
os.remove(root)
