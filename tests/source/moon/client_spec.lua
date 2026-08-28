--[[-- moon client 的回包判定：HTTP 状态码与业务 code 都要算。 --]]

local Assert = require("support.assert")

local response
package.preload["http.request"] = function()
    return {
        request = function(_req, cb)
            cb(response.res, response.err)
            return { cancel = function() end }
        end,
        download = function() return { cancel = function() end } end,
    }
end
package.preload["http.cache"] = function()
    return {
        key = function() return nil end,
        getAsync = function(_k, cb) cb(nil) end,
        set = function() end,
    }
end
-- 环境里的 json 是桩，decode 不真解析：这里按 body 字面量查表返回
local decoded = {
    ['{"code":200,"data":{"ok":true}}'] = { code = 200, data = { ok = true } },
    ['{"code":500,"msg":"服务器炸了"}'] = { code = 500, msg = "服务器炸了" },
    ['{"error":"bad gateway"}'] = { error = "bad gateway" },
    ["{}"] = {},
}
package.preload["json"] = function()
    return {
        encode = function() return "{}" end,
        decode = function(raw)
            local value = decoded[raw]
            if value == nil then error("unexpected body: " .. tostring(raw)) end
            return value
        end,
    }
end
package.loaded["json"] = nil
package.loaded["http.request"] = nil
package.loaded["http.cache"] = nil
package.loaded["source.moon.client"] = nil

local Client = require("source.moon.client")
local client = Client:new({ base_url = "https://example.com", token = "t" })

---@param res table|nil
---@param err string|nil
---@return table|nil, string|nil
local function post(res, err)
    response = { res = res, err = err }
    local out_data, out_err
    client:_jsonAsync("POST", "/api/report", { body = { a = 1 } }, function(data, e)
        out_data, out_err = data, e
    end)
    return out_data, out_err
end

-- 正常路径
local data, data_err = post({ code = 200, body = '{"code":200,"data":{"ok":true}}' })
Assert.is_nil(data_err)
Assert.eq(data.code, 200)

-- 业务 code 非 200
local _d, err = post({ code = 200, body = '{"code":500,"msg":"服务器炸了"}' })
Assert.is_nil(_d)
Assert.eq(err, "服务器炸了")

-- HTTP 5xx 但回包是不带业务 code 的 JSON：以前会被当成功，
-- 上报类调用据此清掉脏标记，数据静默丢失。
local d2, err2 = post({ code = 502, body = '{"error":"bad gateway"}' })
Assert.is_nil(d2, "非 2xx 不能算成功")
Assert.matches(err2, "502")

-- HTTP 404 + 空 JSON 对象同理
local d3, err3 = post({ code = 404, body = "{}" })
Assert.is_nil(d3)
Assert.matches(err3, "404")

-- 401 仍走令牌失效分支
local d4, err4 = post({ code = 401, body = "{}" })
Assert.is_nil(d4)
Assert.matches(err4, "令牌")

-- 传输失败
local d5, err5 = post(nil, "timeout")
Assert.is_nil(d5)
Assert.eq(err5, "timeout")
