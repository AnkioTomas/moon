--[[--
锁屏历史壁纸：每次成功合成后留存一份，按档位裁剪，供远程管理预览与下载。

文件名即时间戳（YYYYMMDD-HHMMSS.png，同秒重名追加 -2、-3…），没有索引文件：
列表按需扫目录，档位上限 50 个，开销可忽略。

档位 lock_screen_history_limit："off"|"10"|"20"|"50"，默认 20；off 只停新增，已存的不删不隐藏。

@module koplugin.book.features.lockscreen.history
--]]

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local KNOWN = { off = 0, ["10"] = 10, ["20"] = 20, ["50"] = 50 }
local NAME_PATTERN = "^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-?%d*%.png$"

---@param v any
---@return boolean
function M.validLimit(v)
    return KNOWN[v] ~= nil
end

--- 当前档位；未设置或非法值回退到 20。
---@return string
function M.tier()
    local v = MoonSettings.get("features.lockscreen").lock_screen_history_limit
    return M.validLimit(v) and v or "20"
end

--- 保留张数；0 表示从不留存。
---@return number
function M.limit()
    return KNOWN[M.tier()]
end

--- 档位文案，供设置页 status 与选项复用。
---@param tier string|nil
---@return string
function M.limitLabel(tier)
    if not M.validLimit(tier) then tier = "20" end
    return tier == "off" and _("从不") or T(_("%1 张"), tier)
end

--- 历史目录。数据目录可能被报成「.」（相对 cwd，Kindle 上就是这样），
--- 远程 /download 只收绝对路径，这里补成绝对路径。
---@return string
function M.dir()
    local dir = Paths.screensaverDir() .. "/history"
    if dir:sub(1, 1) == "/" then return dir end
    local cwd = lfs.currentdir()
    if not cwd then return dir end
    return cwd .. "/" .. dir:gsub("^%./", "")
end

--- 排序键：时间戳 + 序号，同秒重名的 -2 排在同一秒的 base 之后（裸名字典序会把它排到前面）。
---@param name string
---@return string
local function sort_key(name)
    local stamp, seq = name:match("^(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)%-?(%d*)%.png$")
    return stamp .. string.format("-%04d", seq == "" and 0 or tonumber(seq))
end

--- 目录里的历史文件名，升序（旧到新）；目录不存在时返回空表。
---@return string[]
local function names()
    local out = {}
    local dir = M.dir()
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for name in lfs.dir(dir) do
        if name:match(NAME_PATTERN) then out[#out + 1] = name end
    end
    table.sort(out, function(a, b) return sort_key(a) < sort_key(b) end)
    return out
end

--- 流式复制；失败不留半截目标。
---@param src string
---@param dst string
---@return boolean
local function copy(src, dst)
    local input = io.open(src, "rb")
    if not input then return false end
    local output = io.open(dst, "wb")
    if not output then
        input:close()
        return false
    end
    local failure
    while true do
        local chunk = input:read(64 * 1024)
        if not chunk then break end
        if not output:write(chunk) then
            failure = true
            break
        end
    end
    input:close()
    if not output:close() then failure = true end
    if failure then
        os.remove(dst)
        return false
    end
    return true
end

--- 本次落盘的文件名；同秒重名追加序号，到 -99 为止再多就直接覆盖它。
---@param dir string
---@return string
local function target(dir)
    local base = os.date("%Y%m%d-%H%M%S")
    local name, n = base .. ".png", 1
    while n < 99 and lfs.attributes(dir .. "/" .. name, "mode") do
        n = n + 1
        name = base .. "-" .. n .. ".png"
    end
    return dir .. "/" .. name
end

--- 裁到档位张数；删除失败忽略，下次 record 再试。
function M.prune()
    local limit = M.limit()
    if limit <= 0 then return end
    local dir = M.dir()
    local all = names()
    for i = 1, #all - limit do
        os.remove(dir .. "/" .. all[i])
    end
end

--- 留存一张历史；任何失败只记日志，绝不向上抛（合成结果不能因留存失败而判失败）。
---@param source_path string
function M.record(source_path)
    local ok, err = pcall(function()
        if M.limit() <= 0 then return end
        local dir = M.dir()
        if not Paths.ensureDir(dir) then return end
        if copy(source_path, target(dir)) then M.prune() end
    end)
    if not ok then logger.warn("book lockscreen history record failed", err) end
end

--- 历史壁纸列表，新到旧；off 时不截断（已存的仍可浏览下载）。
---@return { name: string, path: string, size: integer, mtime: integer }[]
function M.list()
    local dir = M.dir()
    local all = names()
    local limit = M.limit()
    local out = {}
    for i = #all, 1, -1 do
        if limit > 0 and #out >= limit then break end
        local path = dir .. "/" .. all[i]
        local attr = lfs.attributes(path) or {}
        out[#out + 1] = { name = all[i], path = path, size = attr.size or 0, mtime = attr.modification or 0 }
    end
    return out
end

return M
