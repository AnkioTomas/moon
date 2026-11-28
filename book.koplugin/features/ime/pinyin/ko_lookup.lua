--[[--
KOReader 自带拼音码表（zh_pinyin_data）→ 月读候选条用的词表。

月读增强候选条的存在理由就是绕开 generic_ime 那套抽象输入；没下过
月读 sqlite 词库时，仍画同一条候选条，只是查这张随 KOReader 自带的表。
加载失败才算不可用（测试环境可 stub）。

@module koplugin.book.features.ime.pinyin.ko_lookup
--]]

local MAX = require("features.ime.table_dictionary").MAX_CANDIDATES
local DATA = "frontend/ui/data/keyboardlayouts/zh_pinyin_data.lua"

local M = {
    _map = nil,
    _sorted = nil,
    _tried = false,
}

--- 相对 KOReader 根目录的码表；与 zh_CN_keyboard 同一路径约定。
---@return table|nil
local function loadMap()
    if M._tried then return M._map end
    M._tried = true
    local ok, map = pcall(dofile, DATA)
    if not ok or type(map) ~= "table" then
        -- package.path 里若有 frontend/?，拼绝对路径再试一次（cwd 不在 KO 根时）
        for path in package.path:gmatch("[^;]+") do
            local root = path:match("^(.-)/frontend/%?%.lua$")
                or path:match("^(.-)/frontend/%?/init%.lua$")
            if root then
                ok, map = pcall(dofile, root .. "/" .. DATA)
                if ok and type(map) == "table" then break end
            end
        end
    end
    if type(map) ~= "table" then return nil end
    M._map = map
    local sorted = {}
    for code in pairs(map) do
        sorted[#sorted + 1] = code
    end
    table.sort(sorted)
    M._sorted = sorted
    return map
end

--- 测试用：注入码表；传 nil 标成已试过且失败，避免再 dofile。
---@param map table|nil
function M.reset(map)
    M._sorted = nil
    M._tried = true
    if type(map) ~= "table" then
        M._map = nil
        return
    end
    M._map = map
    local sorted = {}
    for code in pairs(map) do
        sorted[#sorted + 1] = code
    end
    table.sort(sorted)
    M._sorted = sorted
end

function M.isAvailable()
    return loadMap() ~= nil
end

---@param candi string|table|nil
---@param out string[]
---@param seen table
local function append(candi, out, seen)
    if type(candi) == "string" then
        if not seen[candi] and #out < MAX then
            seen[candi] = true
            out[#out + 1] = candi
        end
        return
    end
    if type(candi) ~= "table" then return end
    for i = 1, #candi do
        append(candi[i], out, seen)
        if #out >= MAX then return end
    end
end

--- 排序码表里第一个 `key` 以 `code` 为前缀的下标；没有则 nil。
---@param sorted string[]
---@param code string
---@return number|nil
local function firstPrefix(sorted, code)
    local lo, hi, found = 1, #sorted, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local key = sorted[mid]
        local head = key:sub(1, #code)
        if head < code then
            lo = mid + 1
        elseif head > code then
            hi = mid - 1
        else
            found = mid
            hi = mid - 1
        end
    end
    return found
end

--- 精确命中；没有则按码前缀收集（与 generic_ime.getCandi 同数据，输出给候选条分页）。
---@param code string 小写连写拼音
---@return string[]
function M.lookup(code)
    if type(code) ~= "string" or not code:match("^[a-z]+$") then
        return {}
    end
    local map = loadMap()
    if not map then return {} end
    local out, seen = {}, {}
    append(map[code], out, seen)
    if #out > 0 then return out end
    local sorted = M._sorted
    local start = firstPrefix(sorted, code)
    if not start then return out end
    for i = start, #sorted do
        local key = sorted[i]
        if key:sub(1, #code) ~= code then break end
        append(map[key], out, seen)
        if #out >= MAX then break end
    end
    return out
end

return M
