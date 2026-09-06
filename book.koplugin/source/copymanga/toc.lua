--[[--
拷贝漫画目录缓存。

@module koplugin.book.source.copymanga.toc
--]]

local JSON = require("json")

local Toc = {}
local TTL = 6 * 60 * 60
local cache = {}

---@param source_id string
---@param stable_id string
---@return string
local function key(source_id, stable_id)
    return source_id .. "\31" .. stable_id
end

---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id)
    local cache_key = key(source_id, stable_id)
    if cache[cache_key] then return cache[cache_key] end
    local payload = require("db.book").getToc(source_id, stable_id, TTL)
    if not payload then return nil end
    local ok, list = pcall(JSON.decode, payload)
    if not ok or type(list) ~= "table" or #list == 0 then return nil end
    cache[cache_key] = list
    return list
end

---@param source_id string
---@param stable_id string
---@param list BookChapter[]
---@return boolean
function Toc.put(source_id, stable_id, list)
    local ok, payload = pcall(JSON.encode, list)
    if not ok or type(payload) ~= "string" then return false end
    if not require("db.book").setToc(source_id, stable_id, payload) then return false end
    cache[key(source_id, stable_id)] = list
    return true
end

function Toc.clear()
    cache = {}
end

return Toc
