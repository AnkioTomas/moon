--[[--
微信读书目录缓存：共用 ``source.toc``，只多一个目录格式判断。

@module koplugin.book.source.wechat.toc
--]]

local Toc = setmetatable({}, { __index = require("source.toc") })

--- Mapper.chapters 在首章写入的目录格式版本。
local FORMAT_VERSION = 2

--- 当前目录是否包含章内锚点格式；旧缓存返回 false，触发源重新拉取。
---@param list BookChapter[]|nil
---@return boolean
function Toc.isCurrent(list)
    return type(list) == "table"
        and type(list[1]) == "table"
        and tonumber(list[1].toc_version) == FORMAT_VERSION
end

return Toc
