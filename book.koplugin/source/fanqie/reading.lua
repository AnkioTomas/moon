--[[--
番茄 App reading API 拉正文：registerkey → batch_full → 解密。
协议来自 fanqie-re；网络走 http.request。

@module koplugin.book.source.fanqie.reading
--]]

local Crypto = require("source.fanqie.reading.crypto")
local Device = require("source.fanqie.reading.device")
local Sign = require("source.fanqie.reading.sign")
local JSON = require("json")
local Request = require("http.request")
local logger = require("utils.log")

local Reading = {}

local HOST = Crypto.HOST
local TIMEOUT = 20

---@param text string|nil
---@return table|nil, string|nil
local function decodeJson(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty body"
    end
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" then
        return nil, "invalid json"
    end
    return data
end

--- 带设备签名的 reading API 请求：build_body 非 nil 时以 JSON POST。
--- 传输失败、非 2xx、空响应、非 JSON、业务 code≠0 或 data 非表都归一成 cb(nil, err)。
---@param settings FanqieSettings
---@param name string 接口名，用作错误文案前缀
---@param path string
---@param build_query fun(device: table, ts_ms: number): table
---@param build_body (fun(device: table): string)|nil
---@param cb fun(data: table|nil, err: string|nil) data 为完整回包
---@return CancelHandle
local function signedAsync(settings, name, path, build_query, build_body, cb)
    local device = Device.get(settings)
    if not device then
        cb(nil, "无设备身份")
        return { cancel = function() end }
    end
    local ts_ms = os.time() * 1000 + (math.random(0, 999))
    local qs = Crypto.encode_query(build_query(device, ts_ms))
    local headers = Crypto.build_unsigned_headers(device, ts_ms)
    if build_body then
        headers["Content-Type"] = "application/json"
    end
    for k, v in pairs(Sign.sign_headers(qs, device.device_id, {
        khronos = math.floor(ts_ms / 1000),
        version_name = device.version_name,
        device_type = device.device_type,
        os_version = device.os_version,
    })) do
        headers[k] = v
    end
    headers["X-Ss-Req-Ticket"] = tostring(ts_ms)
    local body = build_body and build_body(device)
    return Request.request({
        url = "https://" .. HOST .. path .. "?" .. qs,
        method = body and "POST" or "GET",
        headers = headers,
        body = body,
        timeout = TIMEOUT,
        allow_redirects = true,
    }, function(res, err)
        if err or not res then
            cb(nil, err or name .. " 请求失败")
            return
        end
        local code = tonumber(res.code)
        if not Request.ok(code) then
            cb(nil, name .. " HTTP " .. tostring(code))
            return
        end
        local body_text = res.body or ""
        if body_text == "" then
            cb(nil, name .. " 空响应（设备身份可能被风控）")
            return
        end
        local data, decode_err = decodeJson(body_text)
        if not data then
            cb(nil, decode_err or name .. " 响应无效")
            return
        end
        if tonumber(data.code) ~= 0 or type(data.data) ~= "table" then
            cb(nil, name .. " 失败: " .. tostring(data.message or data.msg or data.code))
            return
        end
        cb(data)
    end)
end

---@param settings FanqieSettings
---@param cb fun(v1_key: string|nil, err: string|nil)
---@return CancelHandle
local function registerKeyAsync(settings, cb)
    return signedAsync(settings, "registerkey", Crypto.REGISTERKEY_PATH, Crypto.build_common_query, function(device)
        return JSON.encode({
            content = Crypto.build_register_content(device.device_id, 0),
            keyver = 1,
        })
    end, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        if not data.data.key then
            cb(nil, "registerkey 失败: " .. tostring(data.message or data.msg or data.code))
            return
        end
        local ok, v1 = pcall(Crypto.decrypt_server_key, data.data.key)
        if not ok or not v1 then
            cb(nil, "解密 v1_key 失败")
            return
        end
        cb(v1)
    end)
end

---@param settings FanqieSettings
---@param book_id string
---@param item_id string
---@param v1_key string
---@param cb fun(row: table|nil, err: string|nil)
---@return CancelHandle
local function batchFullAsync(settings, book_id, item_id, v1_key, cb)
    local function query(device, ts_ms)
        return Crypto.build_batch_full_query(device, book_id, { item_id }, ts_ms)
    end
    return signedAsync(settings, "batch_full", Crypto.BATCH_FULL_PATH, query, nil, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        local item = data.data[item_id] or data.data[tostring(item_id)]
        if type(item) == "table" and item[1] then
            item = item[1]
        end
        if type(item) ~= "table" then
            cb(nil, "batch_full 无章节数据")
            return
        end
        local ok, text = pcall(Crypto.decode_chapter_item, item, v1_key)
        if not ok then
            cb(nil, "章节解密失败: " .. tostring(text))
            return
        end
        if type(text) ~= "string" or not text:match("%S") then
            cb(nil, "章节正文为空")
            return
        end
        cb({
            content = text,
            title = tostring(item.title or ""),
            author = tostring(item.author or item.authorName or ""),
            source = "reading_batch_full",
        })
    end)
end

--- 拉取单章全文（App reading 协议）。
---@param settings FanqieSettings
---@param book_id string
---@param item_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return CancelHandle
function Reading.fetchAsync(settings, book_id, item_id, cb)
    book_id, item_id = tostring(book_id or ""), tostring(item_id or "")
    if not book_id:match("^%d+$") or not item_id:match("^%d+$") then
        cb(nil, "章节 ID 无效")
        return { cancel = function() end }
    end
    local cancelled = false
    local job
    local handle = {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
    job = Device.ensureAsync(settings, function(device, device_err)
        if cancelled then return end
        if not device then
            cb(nil, device_err or "设备身份注册失败")
            return
        end
        job = registerKeyAsync(settings, function(v1_key, err)
            if cancelled then return end
            if not v1_key then
                cb(nil, err or "registerkey 失败")
                return
            end
            logger.dbg("fanqie reading v1_key ok")
            job = batchFullAsync(settings, book_id, item_id, v1_key, function(row, batch_err)
                if cancelled then return end
                cb(row, batch_err)
            end)
        end)
    end)
    return handle
end

return Reading
