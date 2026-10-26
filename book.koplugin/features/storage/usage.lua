--[[--
月读数据目录（$DATA/.moon）的占用统计：按目录归类，供设置页「存储空间」展示。

子进程里走 `book.cache.walkFiles` 遍历一次，按 `Usage.classify` 归类并累加；书籍内容再细到「源 / 书目录」。
归类只看相对路径，是纯函数；不碰数据库（标题由主进程按目录名对回书库）。

@module koplugin.book.features.storage.usage
--]]

require("l10n").apply()

local _ = require("gettext")

---@class BookStorageUsage
---@field cats table<string, number>
---@field books table<string, table<string, number>>
---@field total number
---@field at integer|nil 主进程的缓存时间
local Usage = {}

--- 展示顺序之外的元信息；`clearable` = 属于 .moon/cache，可经「清理缓存」安全重建。
---@type { id: string, name: string, clearable: boolean }[]
Usage.CATEGORIES = {
    { id = "book", name = _("书籍内容"), clearable = true },
    { id = "image", name = _("封面与图片"), clearable = true },
    { id = "online", name = _("在线数据"), clearable = true },
    { id = "cache", name = _("其它缓存"), clearable = true },
    { id = "dict", name = _("输入法词库"), clearable = false },
    { id = "fonts", name = _("字体"), clearable = false },
    { id = "database", name = _("书库与设置"), clearable = false },
    { id = "log", name = _("运行日志"), clearable = false },
    { id = "other", name = _("其它"), clearable = false },
}

--- 相对 .moon 的路径 → 类别 id；书籍内容另给 源 id 与书目录名（slug）。
---@param rel string
---@return string cat
---@return string|nil source
---@return string|nil slug
function Usage.classify(rel)
    local top, second, third, fourth = rel:match("^([^/]+)/?([^/]*)/?([^/]*)/?([^/]*)")
    if top == "cache" then
        if second == "online" then return "online" end
        if second == "image" or third == "image" then return "image" end
        if third == "book" then return "book", second, fourth ~= "" and fourth or nil end
        return "cache"
    end
    if top:match("^book%.sqlite3") or top == "settings" then return "database" end
    if top:match("^book%.log") then return "log" end
    if top:match("^dictionary") then return "dict" end
    if top == "fonts" then return "fonts" end
    return "other"
end

--- 统计（子进程里遍历，不占主线程）。
--- cb 收 `{ cats = { [类别] = 字节 }, books = { [源] = { [slug] = 字节 } }, total }`；失败时记日志并回调 nil。
---@param cb fun(result: BookStorageUsage|nil)
---@return { cancel: fun() }
function Usage.measureAsync(cb)
    local root = require("utils.paths").root()
    return require("workers.job").run(function()
        local cats, books, total = {}, {}, 0
        require("book.cache").walkFiles(root, function(path, attr)
            local rel = path:sub(#root + 2)
            if rel:sub(1, 13) == "cache/.trash/" then return end -- 删书后待后台清除的残留，不算占用
            local size = tonumber(attr.size) or 0
            local cat, source, slug = Usage.classify(rel)
            cats[cat] = (cats[cat] or 0) + size
            if slug then
                local per = books[source] or {}
                books[source] = per
                per[slug] = (per[slug] or 0) + size
            end
            total = total + size
        end)
        return { cats = cats, books = books, total = total }
    end, {
        name = "storage.usage", kind = "light",
        on_done = cb,
        on_failed = function(err)
            require("utils.log").warn("book storage usage failed", err)
            cb(nil)
        end,
    })
end

return Usage
