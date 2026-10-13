--[[--
月读更新路由：POST|PUT /api/update，raw body 是插件发布包（book.koplugin-*.zip）。

收齐后交给 handlers.install_update 装包；成功回 ok，设备随后自行重启 KOReader。

@module koplugin.book.features.remote.update
--]]

local logger = require("utils.log")

local Update = {}

-- 与在线更新的包体上限一致，发布包远小于此。
Update.MAX_BYTES = 100 * 1024 * 1024

local ERROR_CODES = {
    ["busy"] = 409,
    ["not a moon plugin archive"] = 400,
    ["cannot open update archive"] = 400,
}

---@param conn table
---@param method string
---@param headers table 已小写化的请求头
function Update.route(self, conn, method, headers)
    if method ~= "POST" and method ~= "PUT" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_acceptFile(conn, headers, Update.MAX_BYTES, function(temp, reply)
        self.handlers.install_update(temp, function(ok, err)
            if not ok then
                logger.warn("book remote update failed", err)
                return reply(self.errorResp(ERROR_CODES[err] or 500, err))
            end
            reply(self.jsonResp(200, '{"ok":true}'))
        end)
    end)
end

return Update
