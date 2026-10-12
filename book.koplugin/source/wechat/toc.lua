--[[--
微信读书目录缓存：共用 ``source.toc``，只多一个目录格式判断。

@module koplugin.book.source.wechat.toc
--]]

local Toc = setmetatable({}, { __index = require("source.toc") })

--- 目录格式版本，Mapper.chapters 写在首章。3：网文章名补「第 N 章」。
Toc.FORMAT_VERSION = 3

--- 当前目录是否为最新格式；旧缓存返回 false，触发源重新拉取。
---@param list BookChapter[]|nil
---@return boolean
function Toc.isCurrent(list)
    return type(list) == "table"
        and type(list[1]) == "table"
        and tonumber(list[1].toc_version) == Toc.FORMAT_VERSION
end

return Toc
