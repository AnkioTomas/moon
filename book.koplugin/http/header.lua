--[[--
HTTP Header 拼装

不碰网络。默认 UA 为 KOReader/MoonBook；
调用方通过 extra 覆盖任意键，包括 User-Agent / Accept / Connection。

  Header.merge(extra, defaults)     -- extra 覆盖 defaults；nil 值跳过
  Header.forRequest(extra, accept?) -- 默认 Accept + UA，extra 可全覆盖
  Header.forDownload(extra)         -- 默认 Accept + UA + Connection: close

@module koplugin.book.http.header
--]]

local USER_AGENT = "KOReader/MoonBook"

local Header = {}

--- 合并 headers；extra 覆盖 defaults；nil 值跳过（不删掉 defaults 里已有键）
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

--- 普通请求默认头。extra 可覆盖 UA / Accept / 任意自定义头。
---@param extra table|nil
---@param accept string|nil 默认 */*；若 extra 已带 Accept 则以 extra 为准
---@return table
function Header.forRequest(extra, accept)
    return Header.merge(extra, {
        ["Accept"] = accept or "*/*",
        ["User-Agent"] = USER_AGENT,
    })
end

--- 下载默认头。extra 可覆盖 UA / Connection / Accept。
---@param extra table|nil
---@return table
function Header.forDownload(extra)
    return Header.merge(extra, {
        ["Accept"] = "*/*",
        ["User-Agent"] = USER_AGENT,
        ["Connection"] = "close",
    })
end

return Header
