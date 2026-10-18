--[[--
月读数据目录（$DATA/.moon）的占用统计：按用途归类，供设置页「存储空间」列出。

遍历走 `book.cache.walkAsync`（分 tick，不卡 UI）；归类只看相对路径，是纯函数。

@module koplugin.book.features.storage.usage
--]]

require("l10n").apply()

local _ = require("gettext")
local T = require("ffi/util").template

local Usage = {}

--- 相对 .moon 的路径 → 归类键。缓存按「源 / 子目录」细分（封面、书籍文件），其余按顶层名。
---@param rel string
---@return string
function Usage.bucket(rel)
    local top, second, third = rel:match("^([^/]+)/?([^/]*)/?([^/]*)")
    if top == "cache" then
        if second == "" then return "cache" end
        if second == "online" or second == "image" then return "cache/" .. second end
        if third == "image" or third == "book" then return "cache/" .. second .. "/" .. third end
        return "cache/" .. second
    end
    if top:match("^book%.sqlite3") then return "database" end
    if top:match("^book%.log") then return "log" end
    if top:match("^dictionary") then return "ime" end
    return top
end

local NAMES = {
    database = _("书库数据库"),
    log = _("运行日志"),
    ime = _("输入法词库"),
    backups = _("补丁备份"),
    screensaver = _("锁屏资源"),
    wallpapers = _("壁纸"),
    settings = _("设置"),
    ["cache/online"] = _("在线数据缓存"),
    ["cache/image"] = _("网络图片缓存"),
}

--- 归类键 → 显示名；没登记的缓存按源名、其余原样显示键。
---@param key string
---@return string
function Usage.label(key)
    if NAMES[key] then return NAMES[key] end
    local src, kind = key:match("^cache/([^/]+)/?(.*)$")
    if not src then return key end
    if kind == "image" then return T(_("%1 封面与图片"), src) end
    if kind == "book" then return T(_("%1 书籍与章节文件"), src) end
    return T(_("%1 其它缓存"), src)
end

--- 统计（子进程里遍历，不占主线程）；cb 收 `{ { key, bytes }... 按体积降序 }, 合计`，失败时记日志并给空结果。
---@param cb fun(list: { [1]: string, [2]: number }[], total: number)
---@return { cancel: fun() }
function Usage.measureAsync(cb)
    local root = require("utils.paths").root()
    return require("workers.job").run(function()
        local sizes, total = {}, 0
        require("book.cache").walkFiles(root, function(path, attr)
            local key = Usage.bucket(path:sub(#root + 2))
            local size = tonumber(attr.size) or 0
            sizes[key] = (sizes[key] or 0) + size
            total = total + size
        end)
        local list = {}
        for key, bytes in pairs(sizes) do list[#list + 1] = { key, bytes } end
        table.sort(list, function(a, b)
            if a[2] ~= b[2] then return a[2] > b[2] end
            return a[1] < b[1]
        end)
        return { list = list, total = total }
    end, {
        name = "storage.usage", kind = "light",
        on_done = function(result) cb(result.list, result.total) end,
        on_failed = function(err)
            require("utils.log").warn("book storage usage failed", err)
            cb({}, 0)
        end,
    })
end

return Usage
