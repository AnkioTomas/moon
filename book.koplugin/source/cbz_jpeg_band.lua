--[[--
从基准 JPEG 里按 MCU 行无损抽出一段水平条带，得到一张更矮的 JPEG。
只重打包熵编码的系数，不解码像素。供漫画切片在缺少
tj3SetCroppingRegion 时仍按条带解压，避免整张长图进内存。

只支持 SOF0 基线、1 或 3 个分量。渐进、CMYK、算术编码返回 nil。

@module koplugin.book.source.cbz_jpeg_band
--]]

local Band = {}

---@param s string
---@param i integer
---@return integer
local function be16(s, i)
    return s:byte(i) * 256 + s:byte(i + 1)
end

---@param n integer
---@return string
local function put16(n)
    n = math.floor(n) % 65536
    return string.char(math.floor(n / 256), n % 256)
end

---@param bits integer[]
---@param values integer[]
---@return table|nil
local function buildHuff(bits, values)
    local min_code, max_code, valptr = {}, {}, {}
    local encode = {}
    local code, k = 0, 1
    for len = 1, 16 do
        local count = bits[len] or 0
        if count > 0 then
            min_code[len] = code
            valptr[len] = k
            for _ = 1, count do
                local sym = values[k]
                if sym == nil then return nil end
                encode[sym] = { code = code, len = len }
                k = k + 1
                code = code + 1
            end
            max_code[len] = code - 1
        else
            min_code[len] = -1
            max_code[len] = -1
            valptr[len] = k
        end
        code = code * 2
    end
    return {
        min_code = min_code,
        max_code = max_code,
        valptr = valptr,
        values = values,
        bits = bits,
        encode = encode,
    }
end

---@class CbzJpegBitReader
---@field data string
---@field pos integer
---@field bits integer
---@field nbits integer
---@field ended boolean
local BitReader = {}
BitReader.__index = BitReader

---@param data string
---@param pos integer
---@return CbzJpegBitReader
local function newReader(data, pos)
    return setmetatable({
        data = data,
        pos = pos,
        bits = 0,
        nbits = 0,
        ended = false,
    }, BitReader)
end

---@return integer
function BitReader:nextByte()
    if self.pos > #self.data then
        self.ended = true
        return 0
    end
    local b = self.data:byte(self.pos)
    self.pos = self.pos + 1
    if b ~= 0xFF then return b end
    while self.pos <= #self.data and self.data:byte(self.pos) == 0xFF do
        self.pos = self.pos + 1
    end
    if self.pos > #self.data then
        self.ended = true
        return 0
    end
    local n = self.data:byte(self.pos)
    self.pos = self.pos + 1
    if n == 0x00 then return 0xFF end
    -- 把 RST / EOI / 其它标记退回，留给 MCU 边界处理。
    self.pos = self.pos - 2
    self.ended = true
    return 0
end

--- 若当前位置是 RST 标记则消费并返回 true。
---@return boolean
function BitReader:consumeRestart()
    local i = self.pos
    local data = self.data
    while i <= #data and data:byte(i) == 0xFF do
        local n = data:byte(i + 1)
        if n == nil then return false end
        if n == 0x00 then return false end
        if n >= 0xD0 and n <= 0xD7 then
            self.pos = i + 2
            self.bits = 0
            self.nbits = 0
            self.ended = false
            return true
        end
        if n == 0xFF then
            i = i + 1
        else
            return false
        end
    end
    return false
end

---@param n integer
---@return integer|nil
function BitReader:get(n)
    if n == 0 then return 0 end
    while self.nbits < n do
        if self.ended then return nil end
        local b = self:nextByte()
        if self.ended and self.nbits < n then
            -- nextByte 可能在没读到新字节时置 ended。
            if self.nbits + 8 < n and self.pos >= #self.data then return nil end
        end
        self.bits = self.bits * 256 + b
        self.nbits = self.nbits + 8
        if self.ended and self.nbits < n then return nil end
    end
    local shift = self.nbits - n
    local val = math.floor(self.bits / 2 ^ shift)
    self.bits = self.bits - val * 2 ^ shift
    self.nbits = shift
    return val
end

---@class CbzJpegBitWriter
---@field bytes string[]
---@field acc integer
---@field n integer
local BitWriter = {}
BitWriter.__index = BitWriter

local function newWriter()
    return setmetatable({ bytes = {}, acc = 0, n = 0 }, BitWriter)
end

---@param byte integer
function BitWriter:putByte(byte)
    self.bytes[#self.bytes + 1] = string.char(byte)
    if byte == 0xFF then
        self.bytes[#self.bytes + 1] = "\000"
    end
end

---@param code integer
---@param len integer
function BitWriter:put(code, len)
    if len <= 0 then return end
    self.acc = self.acc * 2 ^ len + (code % 2 ^ len)
    self.n = self.n + len
    while self.n >= 8 do
        local shift = self.n - 8
        local byte = math.floor(self.acc / 2 ^ shift)
        self.acc = self.acc - byte * 2 ^ shift
        self.n = shift
        self:putByte(byte)
    end
end

---@return string
function BitWriter:finish()
    if self.n > 0 then
        -- 规范用 1 填充剩余位。
        local pad = 2 ^ (8 - self.n) - 1
        self:put(pad, 8 - self.n)
    end
    return table.concat(self.bytes)
end

---@param v integer
---@param t integer
---@return integer
local function extend(v, t)
    if t == 0 then return 0 end
    local vt = 2 ^ (t - 1)
    if v < vt then
        return v + (-2 ^ t) + 1
    end
    return v
end

---@param value integer
---@return integer cat
---@return integer bits
local function magnitude(value)
    if value == 0 then return 0, 0 end
    local abs = value < 0 and -value or value
    local cat = 0
    local n = abs
    while n > 0 do
        n = math.floor(n / 2)
        cat = cat + 1
    end
    local bits = value < 0 and (value + 2 ^ cat - 1) or value
    return cat, bits
end

---@param reader CbzJpegBitReader
---@param table table
---@return integer|nil
local function huffDecode(reader, table)
    local code = 0
    for len = 1, 16 do
        local bit = reader:get(1)
        if bit == nil then return nil end
        code = code * 2 + bit
        if table.max_code[len] >= 0 and code <= table.max_code[len] then
            local idx = table.valptr[len] + (code - table.min_code[len])
            return table.values[idx]
        end
    end
    return nil
end

---@param writer CbzJpegBitWriter
---@param table table
---@param symbol integer
---@return boolean
local function huffEncode(writer, table, symbol)
    local ent = table.encode[symbol]
    if not ent then return false end
    writer:put(ent.code, ent.len)
    return true
end

---@param reader CbzJpegBitReader
---@param dc_table table
---@param ac_table table
---@param pred integer
---@return integer[]|nil coeffs
---@return integer|nil pred
local function decodeBlock(reader, dc_table, ac_table, pred)
    local cat = huffDecode(reader, dc_table)
    if cat == nil or cat > 11 then return nil end
    local bits = reader:get(cat)
    if bits == nil then return nil end
    pred = pred + extend(bits, cat)
    ---@type integer[]
    local coeffs = { pred }
    for i = 2, 64 do
        coeffs[i] = 0
    end
    local k = 1
    while k < 64 do
        local rs = huffDecode(reader, ac_table)
        if rs == nil then return nil end
        local run = math.floor(rs / 16)
        local size = rs % 16
        if size == 0 then
            if run == 0 then
                break
            end
            if run ~= 15 then return nil end
            k = k + 16
        else
            k = k + run + 1
            if k > 64 then return nil end
            local ac = reader:get(size)
            if ac == nil then return nil end
            coeffs[k] = extend(ac, size)
        end
    end
    return coeffs, pred
end

---@param writer CbzJpegBitWriter
---@param dc_table table
---@param ac_table table
---@param coeffs integer[]
---@param pred integer
---@return integer|nil pred
local function encodeBlock(writer, dc_table, ac_table, coeffs, pred)
    local diff = coeffs[1] - pred
    local cat, bits = magnitude(diff)
    if not huffEncode(writer, dc_table, cat) then return nil end
    writer:put(bits, cat)
    pred = coeffs[1]
    local k = 2
    while k <= 64 do
        local run = 0
        while k <= 64 and coeffs[k] == 0 do
            k = k + 1
            run = run + 1
        end
        if k > 64 then
            if not huffEncode(writer, ac_table, 0) then return nil end
            break
        end
        while run >= 16 do
            if not huffEncode(writer, ac_table, 0xF0) then return nil end
            run = run - 16
        end
        local ac_cat, ac_bits = magnitude(coeffs[k])
        if not huffEncode(writer, ac_table, run * 16 + ac_cat) then return nil end
        writer:put(ac_bits, ac_cat)
        k = k + 1
        if k > 64 then break end
    end
    return pred
end

---@param data string
---@param start integer
---@param dc table
---@param ac table
---@return integer|nil
local function parseDhtSegment(data, start, dc, ac)
    local len = be16(data, start + 2)
    local i = start + 4
    local last = start + 1 + len
    while i <= last do
        local info = data:byte(i)
        if info == nil then return nil end
        local class = math.floor(info / 16)
        local id = info % 16
        i = i + 1
        ---@type integer[]
        local bits = {}
        local total = 0
        for len_i = 1, 16 do
            local count = data:byte(i)
            if count == nil then return nil end
            bits[len_i] = count
            total = total + count
            i = i + 1
        end
        if total > 256 then return nil end
        ---@type integer[]
        local values = {}
        for v = 1, total do
            local sym = data:byte(i)
            if sym == nil then return nil end
            values[v] = sym
            i = i + 1
        end
        local table = buildHuff(bits, values)
        if not table then return nil end
        if class == 0 then
            dc[id] = table
        elseif class == 1 then
            ac[id] = table
        else
            return nil
        end
    end
    return last + 1
end

---@class CbzJpegComponent
---@field id integer
---@field h integer
---@field v integer
---@field qt integer
---@field td integer
---@field ta integer

---@class CbzJpegInfo
---@field width integer
---@field height integer
---@field mcu_w integer
---@field mcu_h integer
---@field components CbzJpegComponent[]
---@field dc table
---@field ac table
---@field headers string
---@field scan_start integer
---@field dri integer

---@param data string
---@return CbzJpegInfo|nil
function Band.parse(data)
    if type(data) ~= "string" or #data < 4 then return nil end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
    local i = 3
    local header_chunks = { "\255\216" }
    ---@type CbzJpegComponent[]|nil
    local components
    local width, height = 0, 0
    local dc, ac = {}, {}
    local dri = 0
    local precision = 8
    while i < #data do
        if data:byte(i) ~= 0xFF then return nil end
        while i < #data and data:byte(i) == 0xFF and data:byte(i + 1) == 0xFF do
            i = i + 1
        end
        local marker = data:byte(i + 1)
        if marker == nil then return nil end
        if marker == 0xDA then
            local len = be16(data, i + 2)
            if len < 6 then return nil end
            local ns = data:byte(i + 4)
            if not ns or not components or ns ~= #components then return nil end
            local p = i + 5
            for c = 1, ns do
                local id = data:byte(p)
                local dest = data:byte(p + 1)
                if id == nil or dest == nil then return nil end
                local found = false
                for _, comp in ipairs(components) do
                    if comp.id == id then
                        comp.td = math.floor(dest / 16)
                        comp.ta = dest % 16
                        if not dc[comp.td] or not ac[comp.ta] then return nil end
                        found = true
                        break
                    end
                end
                if not found then return nil end
                p = p + 2
            end
            local ss, se, ahal = data:byte(p), data:byte(p + 1), data:byte(p + 2)
            if ss ~= 0 or se ~= 63 or ahal ~= 0 then return nil end
            header_chunks[#header_chunks + 1] = data:sub(i, i + 1 + len)
            return {
                width = width,
                height = height,
                mcu_w = 0,
                mcu_h = 0,
                components = components,
                dc = dc,
                ac = ac,
                headers = table.concat(header_chunks),
                scan_start = i + 2 + len,
                dri = dri,
                precision = precision,
            }
        end
        if marker == 0xD9 or marker == 0xDA then return nil end
        if marker >= 0xD0 and marker <= 0xD8 then
            i = i + 2
        elseif marker == 0x01 then
            i = i + 2
        else
            if i + 3 > #data then return nil end
            local len = be16(data, i + 2)
            if len < 2 or i + 1 + len > #data then return nil end
            if marker == 0xC0 then
                precision = data:byte(i + 4)
                height = be16(data, i + 5)
                width = be16(data, i + 7)
                local nf = data:byte(i + 9)
                if precision ~= 8 or width < 1 or height < 1 or (nf ~= 1 and nf ~= 3) then
                    return nil
                end
                components = {}
                local p = i + 10
                for c = 1, nf do
                    local id = data:byte(p)
                    local hv = data:byte(p + 1)
                    local qt = data:byte(p + 2)
                    if id == nil or hv == nil or qt == nil then return nil end
                    local h = math.floor(hv / 16)
                    local v = hv % 16
                    if h < 1 or v < 1 or h > 4 or v > 4 then return nil end
                    components[c] = { id = id, h = h, v = v, qt = qt, td = 0, ta = 0 }
                    p = p + 3
                end
                header_chunks[#header_chunks + 1] = "SOF0"
            elseif marker == 0xC1 or marker == 0xC2 or marker == 0xC3
                or marker == 0xC5 or marker == 0xC6 or marker == 0xC7
                or marker == 0xC9 or marker == 0xCA or marker == 0xCB
                or marker == 0xCD or marker == 0xCE or marker == 0xCF
                or marker == 0xC8 then
                return nil
            elseif marker == 0xC4 then
                if not parseDhtSegment(data, i, dc, ac) then return nil end
                header_chunks[#header_chunks + 1] = data:sub(i, i + 1 + len)
            elseif marker == 0xDD then
                if len ~= 4 then return nil end
                dri = be16(data, i + 4)
            else
                header_chunks[#header_chunks + 1] = data:sub(i, i + 1 + len)
            end
            i = i + 2 + len
        end
    end
    return nil
end

---@param info CbzJpegInfo
local function finishInfo(info)
    local max_h, max_v = 1, 1
    for _, comp in ipairs(info.components) do
        if comp.h > max_h then max_h = comp.h end
        if comp.v > max_v then max_v = comp.v end
    end
    info.mcu_w = 8 * max_h
    info.mcu_h = 8 * max_v
end

---@param data string
---@return CbzJpegInfo|nil
function Band.info(data)
    local info = Band.parse(data)
    if not info then return nil end
    finishInfo(info)
    return info
end

---@param headers string
---@param width integer
---@param height integer
---@param components CbzJpegComponent[]
---@return string|nil
local function rewriteHeaders(headers, width, height, components)
    local i = 1
    local out = {}
    while i <= #headers do
        if headers:sub(i, i + 3) == "SOF0" then
            local nf = #components
            local sof = "\255\192" .. put16(8 + 3 * nf) .. string.char(8) .. put16(height) .. put16(width) .. string.char(nf)
            for _, comp in ipairs(components) do
                sof = sof .. string.char(comp.id, comp.h * 16 + comp.v, comp.qt)
            end
            out[#out + 1] = sof
            i = i + 4
        elseif headers:byte(i) ~= 0xFF then
            return nil
        else
            local marker = headers:byte(i + 1)
            if marker == 0xD8 then
                out[#out + 1] = headers:sub(i, i + 1)
                i = i + 2
            else
                local len = be16(headers, i + 2)
                out[#out + 1] = headers:sub(i, i + 1 + len)
                i = i + 2 + len
            end
        end
    end
    return table.concat(out)
end

--- 抽出覆盖 [y, y+h) 的 MCU 对齐条带。返回 JPEG 字节以及实际条带在源图中的 y / 高度。
---@param data string
---@param y integer
---@param h integer
---@return string|nil jpeg
---@return integer|nil aligned_y
---@return integer|nil aligned_h
function Band.extract(data, y, h)
    y = math.floor(tonumber(y) or -1)
    h = math.floor(tonumber(h) or 0)
    if y < 0 or h < 1 then return nil end
    local info = Band.parse(data)
    if not info then return nil end
    finishInfo(info)
    if y >= info.height then return nil end
    local src_end = y + h
    if src_end > info.height then src_end = info.height end
    if src_end <= y then return nil end
    local first_row = math.floor(y / info.mcu_h)
    local last_row = math.floor((src_end + info.mcu_h - 1) / info.mcu_h)
    local total_rows = math.floor((info.height + info.mcu_h - 1) / info.mcu_h)
    local total_cols = math.floor((info.width + info.mcu_w - 1) / info.mcu_w)
    if last_row > total_rows then last_row = total_rows end
    if first_row >= last_row then return nil end

    local reader = newReader(data, info.scan_start)
    local preds = {}
    for c = 1, #info.components do
        preds[c] = 0
    end
    ---@type integer[][][]
    local kept = {}
    local mcu_count = 0
    for row = 0, last_row - 1 do
        ---@type integer[][]|nil
        local row_mcus = nil
        if row >= first_row then
            row_mcus = {}
        end
        for col = 1, total_cols do
            if info.dri > 0 and mcu_count > 0 and mcu_count % info.dri == 0 then
                if not reader:consumeRestart() then return nil end
                for c = 1, #info.components do
                    preds[c] = 0
                end
            end
            ---@type integer[][]
            local mcu = {}
            for c, comp in ipairs(info.components) do
                local dc_table = info.dc[comp.td]
                local ac_table = info.ac[comp.ta]
                local blocks = comp.h * comp.v
                for b = 1, blocks do
                    local coeffs, pred = decodeBlock(reader, dc_table, ac_table, preds[c])
                    if not coeffs or pred == nil then return nil end
                    preds[c] = pred
                    if row_mcus then
                        mcu[#mcu + 1] = coeffs
                    end
                end
            end
            if row_mcus then
                row_mcus[#row_mcus + 1] = mcu
            end
            mcu_count = mcu_count + 1
        end
        if row_mcus then
            kept[#kept + 1] = row_mcus
        end
    end

    local aligned_y = first_row * info.mcu_h
    -- 最后一段不要把 MCU 填充行写进 SOF 高度，否则解码器会多显示一截。
    local out_h = (last_row - first_row) * info.mcu_h
    if aligned_y + out_h > info.height then
        out_h = info.height - aligned_y
    end
    local headers = rewriteHeaders(info.headers, info.width, out_h, info.components)
    if not headers then return nil end

    local writer = newWriter()
    local enc_preds = {}
    for c = 1, #info.components do
        enc_preds[c] = 0
    end
    for _, row_mcus in ipairs(kept) do
        for _, mcu in ipairs(row_mcus) do
            local block_i = 1
            for c, comp in ipairs(info.components) do
                local dc_table = info.dc[comp.td]
                local ac_table = info.ac[comp.ta]
                local blocks = comp.h * comp.v
                for _ = 1, blocks do
                    local pred = encodeBlock(writer, dc_table, ac_table, mcu[block_i], enc_preds[c])
                    if pred == nil then return nil end
                    enc_preds[c] = pred
                    block_i = block_i + 1
                end
            end
        end
    end
    local scan = writer:finish()
    return headers .. scan .. "\255\217", aligned_y, out_h
end

return Band
