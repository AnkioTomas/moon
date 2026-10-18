--[[--
存储空间管理：维护组里的导航页，类似手机的「存储空间」——设备占用条、月读各类目录占用（带占比）、
书籍内容按书查看并清理、一键清理缓存。数据库 / 设置 / 词库 / 字体不提供清理入口。

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
    if desktop.storage_job or (not force and cached and os.time() - cached.at < FRESH_SECONDS) then return end
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
    local disk = require("util").diskUsage(require("datastorage"):getDataDir())
    local device = {}
    if disk.total and disk.total > 0 then
        device[1] = barRow(disk)
        device[2] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "storage",
                title = T(_("已用 %1 / 共 %2"), friendly(disk.used), friendly(disk.total)),
                status = T(_("可用 %1"), friendly(disk.available)), status_on = true })
        end
    end
    local rows, cache_bytes = {}, 0
    if not cached then
        rows[1] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "hourglass_empty", title = _("计算中…") })
        end
    else
        local list = {}
        for _idx, cat in ipairs(Usage.CATEGORIES) do
            local bytes = cached.cats[cat.id] or 0
            if cat.clearable then cache_bytes = cache_bytes + bytes end
            if bytes > 0 then list[#list + 1] = { cat = cat, bytes = bytes } end
        end
        table.sort(list, function(a, b) return a.bytes > b.bytes end)
        for _idx, item in ipairs(list) do
            rows[#rows + 1] = function(iw)
                return Row.widget({
                    width = iw, icon = "folder", title = item.cat.name,
                    subtitle = T(_("占月读 %1%"), math.floor(item.bytes * 100 / cached.total + 0.5)),
                    status = friendly(item.bytes), status_on = true,
                    chevron = item.cat.id == "book",
                    callback = item.cat.id == "book" and function() showBooks(desktop) end or nil,
                })
            end
        end
    end
    local title = cached and _("月读占用") .. " · " .. friendly(cached.total) or _("月读占用")
    local out = {}
    if cached and cache_bytes > 0 then
        out[1] = { title = _("清理"), rows = { function(iw)
            return Row.widget({
                width = iw, chevron = false, kind = "action", icon = "delete", title = _("清理缓存"),
                status = friendly(cache_bytes), status_on = true,
                callback = function()
                    require("ui.themes.widgets.confirm"):new{
                        text = T(_("删除 .moon/cache（%1）？"), friendly(cache_bytes)), ok_text = _("清理"),
                        ok_callback = function()
                            require("desktop.pages.setting.maintenance"):clearCache(desktop, function() measure(desktop, true) end)
                        end,
                    }:show()
                end,
            })
        end } }
    end
    out[#out + 1] = { title = _("设备"), rows = device }
    out[#out + 1] = { title = title, rows = rows }
    return out
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "maintenance",
            order = 10,
            id = "storage", icon = "storage", title = _("存储空间"),
            subtitle = _("查看设备空间与月读各类数据的占用"),
            page = { title = _("存储空间"), sections = function() return sections(desktop) end },
        },
    }
end

return Setting
