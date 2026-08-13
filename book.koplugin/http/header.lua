--[[--
HTTP Header 拼装

@module koplugin.book.http.header
--]]

local socketutil = require("socketutil")

local Header = {}

--- 合并 headers；extra 覆盖 defaults；nil 值跳过
---@param extra table|nil
---@param defaults table|nil
---@return table
function Header.merge(extra, defaults)
    local headers = {}
    if type(defaults) == "table" then
        for k, v in pairs(defaults) do
            headers[k] = v
        end
    end
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            if v ~= nil then
                headers[k] = v
            end
        end
    end
    return headers
end

--- 普通请求默认头（带 UA）
---@param extra table|nil
---@param accept string|nil 默认 */*
---@return table
function Header.forRequest(extra, accept)
    return Header.merge(extra, {
        ["Accept"] = accept or "*/*",
        ["User-Agent"] = socketutil.USER_AGENT,
    })
end

--- 下载默认头（UA + Connection: close）
---@param extra table|nil
---@return table
function Header.forDownload(extra)
    return Header.merge(extra, {
        ["Accept"] = "*/*",
        ["User-Agent"] = socketutil.USER_AGENT,
        ["Connection"] = "close",
    })
end

return Header
