--[[--
内置源的元信息（id / 名称 / 类型）。注册表列源、选择器只要名字，不该为此加载整个源（客户端、解析器、
几十个模块）；各源门面的 `meta()` 也读这里，名字只有一份。

@module koplugin.book.source.meta
--]]

local _ = require("gettext")

local Meta = {}

---@type table<SourceId, { name: string, type: string }>
local BUILTIN = {
    ["local"] = { name = "本地书籍", type = "book" },
    moon = { name = "月读服务", type = "book" },
    wechat = { name = "微信读书", type = "chapter" },
    jdread = { name = "京东读书", type = "chapter" },
    copymanga = { name = "拷贝漫画", type = "chapter" },
    fanqie = { name = "番茄小说", type = "chapter" },
    qimao = { name = "七猫小说", type = "chapter" },
    legado = { name = "开源阅读", type = "chapter" },
    jjwxc = { name = "晋江文学城", type = "chapter" },
    qidian = { name = "起点中文网", type = "chapter" },
    qqreader = { name = "QQ阅读", type = "chapter" },
    iread = { name = "iRead", type = "chapter" },
    changpei = { name = "长佩文学", type = "chapter" },
    xiaoxiang = { name = "潇湘书院", type = "chapter" },
    kindle = { name = "Kindle 书库", type = "book" },
}

--- 内置源元信息；不是内置源为 nil。名字每次按当前语言翻译。
---@param id SourceId
---@return BookSourceMeta|nil
function Meta.get(id)
    local m = BUILTIN[id]
    return m and { id = id, name = _(m.name), type = m.type } or nil
end

return Meta
