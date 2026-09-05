--[[--
形码输入法通用只读词库。

数据库由构建工具生成；运行时只做精确匹配和前缀补全，不解释 Rime schema。

@module koplugin.book.ime.table_dictionary
--]]

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")

local MAX_CANDIDATES = 21
local SCHEMA_VERSION = "1"

local Dictionary = {}
Dictionary.__index = Dictionary

---@param id "wubi"|"cangjie"|"zhuyin"
---@return table
function Dictionary:new(id)
    return setmetatable({
        id = id,
        conn = nil,
        meta = nil,
        statements = nil,
    }, self)
end

---@return table|nil
function Dictionary:open()
    if self.conn ~= nil then return self.conn or nil end
    self.conn = false
    local path = Paths.imeDictPath(self.id)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then return nil end
    local loaded, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not loaded or not SQ3 then return nil end
    local opened, conn = pcall(SQ3.open, path, "ro")
    if not opened or not conn then return nil end
    local valid = pcall(function()
        local stmt = assert(conn:prepare("SELECT v FROM meta WHERE k = 'schema_version'"))
        local row = stmt:step()
        stmt:close()
        assert(row and row[1] == SCHEMA_VERSION)
    end)
    if not valid then
        pcall(function() conn:close() end)
        return nil
    end
    self.conn = conn
    self.statements = {}
    return conn
end

function Dictionary:isAvailable()
    return self:open() ~= nil
end

function Dictionary:fileExists()
    local attr = lfs.attributes(Paths.imeDictPath(self.id))
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

function Dictionary:reset()
    if self.conn and self.conn ~= false then
        pcall(function() self.conn:close() end)
    end
    self.conn = nil
    self.meta = nil
    self.statements = nil
end

---@param name string
---@param sql string
---@param ... any
---@return string[]
function Dictionary:fetch(name, sql, ...)
    local stmt = self.statements[name]
    if not stmt then
        stmt = assert(self.conn:prepare(sql))
        self.statements[name] = stmt
    end
    stmt:clearbind():reset()
    for i = 1, select("#", ...) do stmt:bind1(i, select(i, ...)) end
    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = row[1]
        if #rows >= MAX_CANDIDATES then break end
    end
    stmt:clearbind():reset()
    return rows
end

---@param code string
---@return string[]
function Dictionary:lookup(code)
    if type(code) ~= "string" or code == "" or not self:open() then return {} end
    local words, seen = {}, {}
    local ok = pcall(function()
        local exact = self:fetch("exact",
            "SELECT text FROM entries WHERE code = ?"
                .. " ORDER BY weight DESC, source_order LIMIT " .. MAX_CANDIDATES,
            code)
        for _, word in ipairs(exact) do
            if not seen[word] then
                seen[word] = true
                words[#words + 1] = word
            end
        end
        if #words >= MAX_CANDIDATES then return end
        local completion = self:fetch("completion",
            "SELECT text FROM entries WHERE code GLOB ? AND code <> ?"
                .. " ORDER BY weight DESC, source_order LIMIT " .. MAX_CANDIDATES,
            code .. "*", code)
        for _, word in ipairs(completion) do
            if not seen[word] then
                seen[word] = true
                words[#words + 1] = word
                if #words >= MAX_CANDIDATES then break end
            end
        end
    end)
    if not ok then
        for _, stmt in pairs(self.statements or {}) do
            pcall(function() stmt:clearbind():reset() end)
        end
        return {}
    end
    return words
end

---@param key string
---@return string|nil
function Dictionary:metaValue(key)
    if self.meta then return self.meta[key] end
    if not self:open() then return nil end
    self.meta = {}
    local ok = pcall(function()
        local stmt = assert(self.conn:prepare("SELECT k, v FROM meta"))
        for row in stmt:rows() do self.meta[row[1]] = row[2] end
        stmt:close()
    end)
    if not ok then
        self.meta = nil
        return nil
    end
    return self.meta[key]
end

function Dictionary:entries()
    return self:metaValue("entries")
end

function Dictionary:builtAt()
    return self:metaValue("built_at")
end

return Dictionary
