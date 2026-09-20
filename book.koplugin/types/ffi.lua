--- KOReader / 第三方 FFI 桩，仅供 LuaLS / EmmyLua。
--- 真实实现在 koreader/base/ffi；方法挂在 metatable 上，无 ---@class 时会 undefined-field。

---@meta

--- ffi/blitbuffer.lua
---@class BlitBuffer
local BlitBuffer = {}

---@param x number
---@param y number
---@param w number
---@param h number
---@param value any
---@param setter any|nil
function BlitBuffer:paintRect(x, y, w, h, value, setter) end

---@param x number
---@param y number
---@param w number
---@param h number
---@param color any
---@param setter any|nil
function BlitBuffer:paintRectRGB32(x, y, w, h, color, setter) end

---@param x number
---@param y number
---@param w number
---@param h number
---@param color any
---@param radius number|nil
function BlitBuffer:paintRoundedRect(x, y, w, h, color, radius) end

---@param x number
---@param y number
---@param radius number
---@param color any
---@param setter any|nil
function BlitBuffer:paintCircle(x, y, radius, color, setter) end

---@param x number
---@param y number
---@param w number
---@param h number
---@param by number|nil 缺省 0.5
function BlitBuffer:lightenRect(x, y, w, h, by) end

---@param color any
function BlitBuffer:fill(color) end

---@param src BlitBuffer
---@param ... any
function BlitBuffer:blitFrom(src, ...) end

---@return BlitBuffer
function BlitBuffer:copy() end

---@param x number
---@param y number
---@param color any
function BlitBuffer:setPixel(x, y, color) end

---@param x number
---@param y number
---@return any
function BlitBuffer:getPixel(x, y) end

--- lua-ljsqlite3
---@class SQLiteConnection
local SQLiteConnection = {}

---@param sql string
---@return any
function SQLiteConnection:exec(sql) end

function SQLiteConnection:close() end

---@param sql string
---@return SQLiteStatement
function SQLiteConnection:prepare(sql) end

---@class SQLiteStatement
local SQLiteStatement = {}

---@param ... any
---@return SQLiteStatement
function SQLiteStatement:bind(...) end

---@return any
function SQLiteStatement:step() end

function SQLiteStatement:reset() end

function SQLiteStatement:clearbind() end

function SQLiteStatement:close() end

--- 可取消异步句柄（HTTP / Job / 源 Async）
---@class CancelHandle
---@field cancel fun(self: CancelHandle|nil)|fun()
local CancelHandle = {}
