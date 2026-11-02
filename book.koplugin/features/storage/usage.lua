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
---@field items table<string, table<string, number>> 字体 / 词库 / 生僻字 / 下载残留，按条目
---@field total number
---@field at integer|nil 主进程的缓存时间
local Usage = {}

--- 更新包暂存文件名（utils.plugin_update 的 target.archive）→ 负责它的更新器模块。
Usage.UPDATE_ARCHIVES = {
    ["plugin-update.zip"] = "features.update",
    ["kamare-update.zip"] = "source.kavita.kamare_update",
    ["kindle-plugin-update.zip"] = "source.kindle.plugin_update",
}

--- 每一类都写明是什么、能不能清。体积为 0 的不显示。
---@type { id: string, icon: string, name: string, note: string }[]
Usage.CATEGORIES = {
    { id = "book", icon = "menu_book", name = _("书籍内容"), note = _("已下载的正文。点按可按书清理") },
    { id = "image", icon = "image", name = _("封面与图片"), note = _("封面和网络图片。清理对应的书时一起删") },
    { id = "online", icon = "cloud", name = _("在线数据"), note = _("天气、一言等缓存。过期会自己重拉，不能清理") },
    { id = "cache", icon = "folder", name = _("其它缓存"), note = _("其余临时文件。不能清理") },
    { id = "dict", icon = "keyboard", name = _("输入法词库"), note = _("输入法词库。点按可清理，正在用的不能删") },
    { id = "fonts", icon = "font_download", name = _("字体"), note = _("已下载的字体。点按可清理，正在用的不能删") },
    { id = "rare", icon = "text_fields", name = _("生僻字"), note = _("生僻字词表。点按可清理，正在用的不能删") },
    { id = "database", icon = "database", name = _("书库"), note = _("书籍、进度和划线。不能清理") },
    { id = "settings", icon = "settings", name = _("设置"), note = _("各功能的配置。不能清理") },
    { id = "log", icon = "description", name = _("运行日志"), note = _("插件日志。不能清理") },
    { id = "leftover", icon = "download", name = _("下载残留"), note = _("没下完的词库、字典或更新包。点按可清理") },
    { id = "trash", icon = "delete", name = _("删除残留"), note = _("删书后还没清完的文件。后台会清掉") },
    { id = "screensaver", icon = "wallpaper", name = _("锁屏"), note = _("锁屏和壁纸。不能清理") },
    { id = "backup", icon = "backup", name = _("补丁备份"), note = _("关掉功能时用来还原。不能清理") },
    { id = "other", icon = "folder_data", name = _("其它"), note = _("没归到上面各类的文件") },
}

--- 相对 .moon 的路径 → 类别 id；书籍内容另给 源 id 与书目录名（slug）。
---@param rel string
---@return string cat
---@return string|nil source
---@return string|nil slug
function Usage.classify(rel)
    local top, second, third, fourth = rel:match("^([^/]+)/?([^/]*)/?([^/]*)/?([^/]*)")
    if not top then return "other" end
    -- 没下完的包：词库 / 字典 / 生僻字临时目录、分片、更新包。先于缓存目录判断，避免 .part 算进封面。
    if rel:find(".dl/", 1, true) or rel:match("%.dl$") or Usage.UPDATE_ARCHIVES[top] or rel:sub(-5) == ".part" then
        return "leftover"
    end
    if top == "cache" then
        if second == ".trash" then return "trash" end
        if second == "online" then return "online" end
        if second == "image" or third == "image" then return "image" end
        if third == "book" then return "book", second, fourth ~= "" and fourth or nil end
        return "cache"
    end
    if top:match("^book%.sqlite3") then return "database" end
    if top == "settings" then return "settings" end
    if top:match("^book%.log") then return "log" end
    if top:match("^dictionary") then return "dict" end
    if top == "fonts" then return "fonts" end
    if top == "rare" then return "rare" end
    if top == "screensaver" then return "screensaver" end
    if top == "backups" then return "backup" end
    return "other"
end

--- 字体、词库、生僻字、下载残留再拆成一条。其它类别不拆。纯函数，不读设置。
---@param cat string
---@param rel string
---@return string|nil
function Usage.itemKey(cat, rel)
    if cat == "fonts" then
        local file = rel:match("^fonts/([^/]+)$")
        if not file then return nil end
        return (file:gsub("%.ttf$", ""):gsub("%.woff$", ""):gsub("%.otf$", ""):gsub("%.ttc$", ""))
    end
    if cat == "dict" then
        local name = rel:match("^([^/]+)"):gsub("%-wal$", ""):gsub("%-shm$", "")
        if name == "dictionary.sqlite3" then return "pinyin" end
        return name:match("^dictionary%-(.+)%.sqlite3$")
    end
    if cat == "rare" then
        return rel:match("^rare/([^/]+)%.tsv$")
    end
    if cat == "leftover" then
        local dl = rel:match("^(.-%.dl)/") or rel:match("^(.-%.dl)$")
        if dl then return dl end
        local archive = rel:gsub("%.part$", "")
        if Usage.UPDATE_ARCHIVES[archive] then return archive end
        if rel:sub(-5) == ".part" then return (rel:gsub("%.part$", "")) end
        return rel:match("^([^/]+)")
    end
end

--- 一条下载残留要删掉的相对路径。`.part` 只删分片，不碰同名成品；`.dl` 和更新包本身就是残留。
---@param key string
---@return string|nil body 临时目录或更新包；只有分片时为 nil
---@return string part
function Usage.leftoverTargets(key)
    if key:sub(-3) == ".dl" or Usage.UPDATE_ARCHIVES[key] then return key, key .. ".part" end
    return nil, key .. ".part"
end

--- 删一个文件或目录（不跟随符号链接）。目录放子进程，避免主线程卡在大临时目录上。
---@param path string
---@param cb fun(ok: boolean)
---@return { cancel: fun() }
function Usage.removeAsync(path, cb)
    return require("workers.job").run(function()
        local lfs = require("libs/libkoreader-lfs")
        local function rm(target)
            local attr = lfs.symlinkattributes(target)
            if not attr then return end
            if attr.mode == "directory" then
                local iter, state = lfs.dir(target)
                if type(iter) == "function" then
                    for name in iter, state do
                        if name ~= "." and name ~= ".." then rm(target .. "/" .. name) end
                    end
                end
            end
            os.remove(target)
        end
        rm(path)
        return lfs.symlinkattributes(path) == nil
    end, {
        name = "storage.remove", kind = "light",
        on_done = cb,
        on_failed = function(err)
            require("utils.log").warn("book storage remove failed", path, err)
            cb(false)
        end,
    })
end

--- 统计（子进程里遍历，不占主线程）。
--- cb 收占用；失败时记日志并回调 nil。
---@param cb fun(result: BookStorageUsage|nil)
---@return { cancel: fun() }
function Usage.measureAsync(cb)
    local root = require("utils.paths").root()
    return require("workers.job").run(function()
        local cats, books, total = {}, {}, 0
        local items = { fonts = {}, dict = {}, rare = {}, leftover = {} }
        require("book.cache").walkFiles(root, function(path, attr)
            local rel = path:sub(#root + 2)
            local size = tonumber(attr.size) or 0
            local cat, source, slug = Usage.classify(rel)
            cats[cat] = (cats[cat] or 0) + size
            if slug then
                local per = books[source] or {}
                books[source] = per
                per[slug] = (per[slug] or 0) + size
            end
            local bucket = items[cat]
            local key = bucket and Usage.itemKey(cat, rel)
            if key then bucket[key] = (bucket[key] or 0) + size end
            total = total + size
        end)
        return { cats = cats, books = books, items = items, total = total }
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
