--[[--
番茄正文：App reading API（registerkey + batch_full + 本地四神签名）。
协议移植自 fanqie-re；网页 /api/reader/full 仅作未配置时的弱回退。

@module koplugin.book.source.fanqie.official
--]]

local Official = {}

---@param client FanqieClient
---@param book_id string
---@param item_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return CancelHandle|nil
function Official.fetchAsync(client, book_id, item_id, cb)
    return require("source.fanqie.reading").fetchAsync(client.settings, book_id, item_id, cb)
end

return Official
