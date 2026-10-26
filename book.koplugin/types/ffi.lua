--- KOReader / 第三方 FFI 桩，仅供 LuaLS / EmmyLua。
--- 真实实现在 koreader/base/ffi；方法挂在 metatable 上，无 ---@class 时会 undefined-field。

---@meta

--- ffi/blitbuffer.lua
---@class BlitBuffer : ffi.cdata*
---@field data ffi.cdata*
---@field stride integer
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

--- 按 intensity 混合贴图：dst·(1-intensity) + src·intensity。
---@param src BlitBuffer
---@param dest_x number
---@param dest_y number
---@param offs_x number
---@param offs_y number
---@param width number
---@param height number
---@param intensity number 0..1
function BlitBuffer:addblitFrom(src, dest_x, dest_y, offs_x, offs_y, width, height, intensity) end

---@return BlitBuffer
function BlitBuffer:copy() end

---@param x number
---@param y number
---@param color any
function BlitBuffer:setPixel(x, y, color) end

---@param x number
---@param y number
---@param color any
function BlitBuffer:setPixelClamped(x, y, color) end

---@param x number
---@param y number
---@return any
function BlitBuffer:getPixel(x, y) end

---@return number
function BlitBuffer:getWidth() end

---@return number
function BlitBuffer:getHeight() end

---@return integer TYPE_BB8 / TYPE_BBRGB32 ...
function BlitBuffer:getType() end

function BlitBuffer:free() end

---@param path string
---@param color any|nil
---@return boolean|nil
function BlitBuffer:writePNG(path, color) end

---@param x number
---@param y number
---@param w number
---@param h number
---@param border number
---@param color any
---@param radius number|nil
---@param anti_alias boolean|nil 圆角抗锯齿（只在 C 实现、Color8 下生效）
function BlitBuffer:paintBorder(x, y, w, h, border, color, radius, anti_alias) end

---@param src BlitBuffer
---@param dest_x number
---@param dest_y number
---@param offs_x number
---@param offs_y number
---@param w number
---@param h number
---@param color any
function BlitBuffer:colorblitFrom(src, dest_x, dest_y, offs_x, offs_y, w, h, color) end

--- ffi.new("moon_z_stream")，番茄正文 inflate。
---@class MoonZStream : ffi.cdata*
---@field next_in ffi.cdata*
---@field avail_in integer
---@field next_out ffi.cdata*
---@field avail_out integer

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

--- 按列取全部结果：result[列][行]；没有行时返回 nil, 0。
---@return table|nil, integer
function SQLiteStatement:resultset() end

function SQLiteStatement:reset() end

function SQLiteStatement:clearbind() end

function SQLiteStatement:close() end

--- ffi/archiver Writer（copymanga CBZ 等）
---@class ArchiverWriter
local ArchiverWriter = {}

---@param o table|nil
---@return ArchiverWriter
function ArchiverWriter:new(o) end

---@param path string
---@param format string|nil
---@return boolean|nil
function ArchiverWriter:open(path, format) end

function ArchiverWriter:close() end

--- ffi/freetype.lua 的 FT_Size 元表。
---@class FreeTypeSize : ffi.cdata*
local FreeTypeSize = {}
---@param codepoint integer
---@return boolean
function FreeTypeSize:hasGlyph(codepoint) end
function FreeTypeSize:done() end

--- KOReader 在 ffi/loadlib.lua 扩充的 LuaJIT FFI 字段。
---@class ffilib
---@field loadlib (fun(name: string): any)|nil
---@field log (fun(...: any))|nil
