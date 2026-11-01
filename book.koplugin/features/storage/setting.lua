--[[--
存储空间：挂在「我的设备 → 本机」，点进去才是这一页。设备占用条，以及月读每一类文件是什么、能不能清。
书籍按本清理；字体、输入法词库、生僻字、下载残留按条清理，正在用的那一条不能删。

统计结果缓存在桌面实例的 `storage_usage` 上（1 分钟内复用），算完后刷新叠层；没算完时显示「计算中…」。
清理后立即重新统计。

@module koplugin.book.features.storage.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

local FRESH_SECONDS = 60

local function friendly(bytes)
    return require("util").getFriendlySize(bytes) or tostring(bytes)
end

--- 起一次统计（同一时刻只有一个在飞）；force 忽略缓存新鲜度。
---@param desktop BookDesktop
---@param force boolean|nil
local function measure(desktop, force)
    local cached = desktop.storage_usage
    if desktop.storage_job or (not force and cached and cached.items and os.time() - cached.at < FRESH_SECONDS) then
        return
    end
    desktop.storage_job = require("features.storage.usage").measureAsync(function(result)
        desktop.storage_job = nil
        if not result then return end -- 统计失败：保留上一次结果，不把占用刷成 0
        result.at = os.time()
        desktop.storage_usage = result
        if not desktop.closed and desktop.settings_overlay then desktop.settings_overlay:updateView() end
    end)
end

--- 缓存目录名（slug）→ 显示名与书库里的书。书库的书直接给书名；订阅不在书库里，
--- 工作目录按订阅 id 生成，名字取订阅标题；都对不上的调用方显示路径。
---@return table<string, { title: string, book: Book|nil }>
local function namesBySlug()
    local Paths = require("utils.paths")
    local out = {}
    for _idx, book in ipairs(require("book.books_db").listLibrary()) do
        out[book.source_id .. "\0" .. Paths.slugFor(book.stable_id)] = { title = book.title, book = book }
    end
    for _idx, feed in ipairs(require("features.subscribe.db").feeds()) do
        out["subscribe\0" .. Paths.slugFor(tostring(feed.id))] = { title = _("订阅") .. " · " .. feed.title }
    end
    return out
end

--- 对不上名字的目录：「源名 - 未知书籍」，订阅是「订阅 - 未知订阅」。
---@param source string
---@return string
local function unknownTitle(source)
    if source == "subscribe" then return _("订阅") .. " - " .. _("未知订阅") end
    local meta = require("source.registry").meta(source)
    return (meta and meta.name or source) .. " - " .. _("未知书籍")
end

--- 清掉一本书的缓存：已入库走 Store（保留 .sdr 与书籍信息）；认不出书（目录名是 md5，无法反查）
--- 的目录（订阅等不在书库里的）直接删目录与章节登记。
---@param entry { source: string, slug: string, name: { title: string, book: Book|nil }|nil }
local function clearEntry(entry)
    local book = entry.name and entry.name.book
    if book then
        require("book.store").clearCache(book.source_id, book.stable_id)
        return
    end
    local dir = require("utils.paths").bookDir(entry.source) .. "/" .. entry.slug
    require("book.chapters_db").deleteUnder(dir)
    require("book.cache").purgeAsync(dir)
end

--- 书籍内容按书列出（体积降序，主题分页列表），点一本清理它的缓存。
---@param desktop BookDesktop
local function showBooks(desktop)
    local known = namesBySlug()
    local list = {}
    for source, per in pairs(desktop.storage_usage.books) do
        for slug, bytes in pairs(per) do
            list[#list + 1] = { source = source, slug = slug, bytes = bytes, name = known[source .. "\0" .. slug] }
        end
    end
    table.sort(list, function(a, b)
        if a.bytes ~= b.bytes then return a.bytes > b.bytes end
        return a.slug < b.slug
    end)
    local view
    local function items()
        local out = {}
        for idx, entry in ipairs(list) do
            local title = entry.name and entry.name.title or unknownTitle(entry.source)
            out[#out + 1] = {
                text = title, mandatory = friendly(entry.bytes), keep_open = true,
                callback = function()
                    require("ui.themes.widgets.confirm"):new{
                        text = T(_("清理《%1》的缓存（%2）？书籍信息、进度与划线保留。"), title, friendly(entry.bytes)),
                        ok_text = _("清理"),
                        ok_callback = function()
                            clearEntry(entry)
                            for pos, e in ipairs(list) do
                                if e == entry then table.remove(list, pos) break end
                            end
                            view:setItems(items())
                            desktop:onEvent("shelf_changed")
                            measure(desktop, true)
                        end,
                    }:show()
                end,
            }
        end
        return out
    end
    view = require("ui.themes.widgets.list"):new{ title = _("书籍内容"), items = items() }
    view:show()
end

local DICT_NAME = {
    pinyin = _("拼音"), wubi = _("五笔"), cangjie = _("仓颉"), zhuyin = _("注音"),
}

---@param id string
---@return string
local function stemOf(id)
    local base = id:match("([^/]+)$") or id
    return (base:gsub("%.ttf$", ""):gsub("%.woff$", ""):gsub("%.otf$", ""):gsub("%.ttc$", ""))
end

--- 界面字体、阅读西文、当前这本书、锁屏海报选中的字体，以及海报用到的同族粗体。
---@param desktop BookDesktop
---@return table<string, boolean>
local function fontsInUse(desktop)
    local set = {}
    local function add(id)
        if type(id) == "string" and id ~= "" then set[stemOf(id)] = true end
    end
    add(require("ui.fonts").currentId())
    add(require("utils.settings").get("reader").western_font_id)
    local lock_id = require("utils.settings").get("features.lockscreen").lock_screen_typo_font
    add(lock_id)
    local ui = desktop.plugin and desktop.plugin.ui
    if ui and ui.doc_settings then add(ui.doc_settings:readSetting("book_reader_font_id")) end
    if type(lock_id) == "string" and lock_id ~= "" then
        local path = lock_id:sub(1, 1) == "/" and lock_id or require("ui.fonts").downloadedPath(lock_id)
        local bold = path and require("features.lockscreen.typo").boldSibling(path)
        add(bold)
    end
    return set
end

---@param key string
---@return string
local function rareTitle(key)
    for _idx, item in ipairs(require("features.rare.catalog").remote()) do
        if item.id == key then return item.label end
    end
    return key
end

---@param key string
---@return string
local function leftoverTitle(key)
    local method = key:match("^ime_(.+)_dict%.dl$")
    if method and DICT_NAME[method] then return DICT_NAME[method] end
    local rare_id = key:match("^rare/(.+)%.tsv%.dl$")
    if rare_id then return rareTitle(rare_id) end
    if key == "plugin-update.zip" then return _("更新包") end
    return key:match("([^/]+)$") or key
end

---@param desktop BookDesktop
---@param kind string
---@param key string
---@return boolean
local function itemInUse(desktop, kind, key)
    if kind == "fonts" then return fontsInUse(desktop)[key] == true end
    if kind == "dict" then
        if not require("features.ime").isEnabled() then return false end
        return require("features.ime.registry").current().dictionary == key
    end
    if kind == "rare" then return require("features.rare.catalog").enabled(key) end
    if key == "plugin-update.zip" then return require("features.update").busy() end
    return require("features.ime.download").downloading() == true
end

---@param kind string
---@param key string
---@return string
local function itemTitle(kind, key)
    if kind == "fonts" then
        local Fonts = require("ui.fonts")
        if Fonts.currentId() == key then return Fonts.currentName() end
        return key
    end
    if kind == "dict" then return DICT_NAME[key] or key end
    if kind == "rare" then return rareTitle(key) end
    return leftoverTitle(key)
end

--- 下载残留的 key 是临时目录或未完成文件名，不是已经落盘的词库 / 图片。
--- `.part` 归到去掉后缀的名字上，删的仍是 `.part`，不能连带删掉同名成品。
---@param kind string
---@param key string
---@param done fun(ok: boolean)
local function deleteItem(kind, key, done)
    local Paths = require("utils.paths")
    local lfs = require("libs/libkoreader-lfs")
    --- 删一个文件；以「文件已不在」为成功，失败不假装成功。
    local function gone(path)
        os.remove(path)
        return lfs.attributes(path, "mode") == nil
    end
    if kind == "fonts" then
        local Fonts = require("ui.fonts")
        Fonts.removeDownloaded(key)
        local dir = Paths.fontsDir()
        local ok = gone(dir .. "/" .. key .. ".otf")
        ok = gone(dir .. "/" .. key .. ".ttc") and ok
        done(ok and Fonts.wereadPath(key) == nil)
        return
    end
    if kind == "dict" then
        local known = key == "pinyin" or key == "wubi" or key == "cangjie" or key == "zhuyin"
        if known then require("features.ime.registry").reset(key) end
        local path = key == "pinyin" and Paths.root() .. "/dictionary.sqlite3"
            or Paths.root() .. "/dictionary-" .. key .. ".sqlite3"
        local ok = gone(path)
        ok = gone(path .. "-wal") and ok
        ok = gone(path .. "-shm") and ok
        if ok and known then
            local saved = require("utils.settings").get("features.ime")
            if saved.ime_dict_built_at then saved.ime_dict_built_at[key] = nil end
            require("utils.settings").save("features.ime")
        end
        done(ok)
        return
    end
    if kind == "rare" then
        local Catalog = require("features.rare.catalog")
        Catalog.delete(key)
        done(not Catalog.installed(key))
        return
    end
    local root = Paths.root() .. "/"
    local body, part = require("features.storage.usage").leftoverTargets(key)
    local ok = gone(root .. part)
    if not body then
        done(ok)
        return
    end
    if body:sub(-3) == ".dl" then
        require("features.storage.usage").removeAsync(root .. body, function(removed) done(removed and ok) end)
        return
    end
    done(gone(root .. body) and ok)
end

--- 字体 / 词库 / 生僻字 / 下载残留按条列出。正在用的只展示，其余确认后删除。
---@param desktop BookDesktop
---@param kind string
---@param title string
local function showItems(desktop, kind, title)
    local bucket = desktop.storage_usage.items[kind] or {}
    local list = {}
    for key, bytes in pairs(bucket) do
        list[#list + 1] = { key = key, bytes = bytes, title = itemTitle(kind, key) }
    end
    table.sort(list, function(a, b)
        if a.bytes ~= b.bytes then return a.bytes > b.bytes end
        return a.title < b.title
    end)
    local redownload = kind ~= "leftover"
    local font_busy = kind == "fonts" and fontsInUse(desktop) or nil
    local view
    local function rows()
        local out = {}
        for _idx, entry in ipairs(list) do
            local current = entry
            local busy = font_busy and font_busy[current.key] == true
                or (not font_busy and itemInUse(desktop, kind, current.key))
            out[#out + 1] = {
                text = current.title,
                mandatory = busy and _("正在使用") or friendly(current.bytes),
                keep_open = true,
                callback = not busy and function()
                    require("ui.themes.widgets.confirm"):new{
                        text = redownload
                            and T(_("删除「%1」（%2）？删了要重新下载。"), current.title, friendly(current.bytes))
                            or T(_("删除「%1」（%2）？"), current.title, friendly(current.bytes)),
                        ok_text = _("删除"),
                        ok_callback = function()
                            deleteItem(kind, current.key, function(ok)
                                if not ok then
                                    require("ui.themes.widgets.toast"):new{ text = _("删除失败") }:show()
                                    return
                                end
                                for pos, e in ipairs(list) do
                                    if e == current then table.remove(list, pos) break end
                                end
                                view:setItems(rows())
                                measure(desktop, true)
                            end)
                        end,
                    }:show()
                end or nil,
            }
        end
        return out
    end
    view = require("ui.themes.widgets.list"):new{ title = title, items = rows() }
    view:show()
end

--- 设备占用条：已用 / 总量。
---@param disk table
---@return fun(iw: number): table
local function barRow(disk)
    return function(iw)
        local Theme = require("ui.themes")
        local Geom = require("ui/geometry")
        local pad = Theme.px(Theme.current().space.md)
        return require("ui/widget/container/centercontainer"):new{
            dimen = Geom:new{ w = iw, h = pad * 3 },
            require("ui.themes.widgets.progress"):new{
                width = iw - pad * 2, percent = disk.used / disk.total * 100,
            },
        }
    end
end

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local Row = require("ui.themes.widgets.row")
    local Usage = require("features.storage.usage")
    measure(desktop)
    local cached = desktop.storage_usage
    local disk = require("features.storage").disk() or {}
    local device = {}
    if disk.total and disk.total > 0 then
        device[1] = barRow(disk)
        device[2] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "storage",
                title = T(_("已用 %1 / 共 %2"), friendly(disk.used), friendly(disk.total)),
                status = T(_("可用 %1"), friendly(disk.available)), status_on = true })
        end
    end
    local rows = {}
    if not cached or not cached.items then
        rows[1] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "hourglass_empty", title = _("计算中…") })
        end
    else
        local list = {}
        for _idx, cat in ipairs(Usage.CATEGORIES) do
            local bytes = cached.cats[cat.id] or 0
            if bytes > 0 then list[#list + 1] = { cat = cat, bytes = bytes } end
        end
        table.sort(list, function(a, b) return a.bytes > b.bytes end)
        for _idx, item in ipairs(list) do
            local id, name, icon, note, bytes = item.cat.id, item.cat.name, item.cat.icon, item.cat.note, item.bytes
            local open = id == "book" or id == "fonts" or id == "dict" or id == "rare" or id == "leftover"
            rows[#rows + 1] = function(iw)
                return Row.widget({
                    width = iw, icon = icon, title = name, subtitle = note,
                    status = friendly(bytes), status_on = true, chevron = open,
                    callback = open and function()
                        if id == "book" then showBooks(desktop) else showItems(desktop, id, name) end
                    end or nil,
                })
            end
        end
    end
    local title = cached and _("月读占用") .. " · " .. friendly(cached.total) or _("月读占用")
    local out = {}
    out[#out + 1] = { title = _("设备"), rows = device }
    out[#out + 1] = { title = title, rows = rows }
    return out
end

require("utils.extension").add("setting.device_section", {
    id = "storage",
    order = 10,
    icon = "storage",
    title = _("存储空间"),
    status = function()
        local disk = require("features.storage").disk()
        if not disk or not disk.total or disk.total <= 0 then return nil end
        return T(_("%1 / %2"), friendly(disk.available), friendly(disk.total))
    end,
    sections = sections,
})

return Setting
