---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- ui.widgets.book：封面状态（已读 / 进度 / 本地下载）、作者行开关与长按入口。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local function widgetModule()
    return {
        new = function(_, opts)
            opts.getSize = opts.getSize or function(self)
                return self.dimen or { w = 10, h = 10 }
            end
            opts.paintTo = opts.paintTo or function() end
            opts.free = opts.free or function() end
            opts.handleEvent = opts.handleEvent or function() return false end
            return opts
        end,
    }
end
for _, name in ipairs({
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/container/centercontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/overlapgroup",
    "ui/widget/textboxwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/textwidget",
    "ui/widget/widget",
}) do
    package.preload[name] = widgetModule
    package.loaded[name] = nil
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/gesturerange"] = widgetModule
package.preload["ui.themes.widgets.image"] = function() return { widget = function(opts) return opts end } end
package.preload["ui.widgets.plain_cover"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.themes.widgets.icon"] = function()
    return {
        widget = function(opts)
            return {
                name = opts and opts.name,
                getSize = function() return { w = 10, h = 10 } end,
                paintTo = function() end,
                free = function() end,
            }
        end,
    }
end
local function coverImage(widget)
    return widget.src and widget or widget[1]
end
package.preload["utils.paths"] = function()
    return {
        coverPath = function(stable_id, source_id)
            return "/covers/" .. tostring(source_id) .. "/" .. tostring(stable_id)
        end,
        ensureLayout = function() end,
    }
end
local existing_files = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            if not existing_files[path] then return nil end
            return key == "mode" and "file" or { mode = "file" }
        end,
    }
end
local resolved = {}
local authoritative = {}
package.preload["source.registry"] = function()
    return {
        resolve = function(id)
            resolved[#resolved + 1] = id
            return {
                id = id,
                coverRequest = function(_, book)
                    return {
                        url = "https://" .. id .. "/" .. book.stable_id,
                        headers = { X = id },
                        authoritative = authoritative[id] or nil,
                    }
                end,
            }
        end,
    }
end
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        face = function(name, size) return { name = name, size = size } end,
        current = function()
            return {
                color = { ink = 1, page = 0, muted = 2, faint = 3, accent = 0x7038A0, headings = 0x7038A0 },
                image = {},
                raised = {},
                space = { xs = 4, sm = 8 },
                control = { icon = 22 },
                font = { caption = 11 },
                progress = { height = 4 },
            }
        end,
    }
end
package.preload["ui.themes.widgets.text"] = function()
    return {
        line = function(_, text, opts)
            return {
                text = text,
                max_width = opts and opts.width,
                color = opts and opts.color,
                getSize = function() return { w = 10, h = 10 } end,
                paintTo = function() end,
                free = function() end,
            }
        end,
        box = function(_, text, width, opts)
            return {
                text = text, width = width, height = opts and opts.height,
                getSize = function() return { w = width or 10, h = 10 } end,
                free = function() end,
            }
        end,
    }
end
package.preload["ui.themes.widgets.progress"] = function()
    return {
        new = function(_, opts)
            opts.getSize = function() return { w = opts.width, h = opts.height or 4 } end
            return opts
        end,
    }
end
package.preload["ui.themes.widgets.box"] = function()
    return {
        new = function(_, opts)
            opts.getSize = function() return { w = 20, h = 16 } end
            return opts
        end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = 0,
        COLOR_BLACK = 1,
        COLOR_GRAY_3 = 2,
        Color8 = function(c) return c end,
        new = function(w, h)
            local blank = { getColor8 = function() return { a = 0 } end }
            return {
                fill = function() end,
                free = function() end,
                getWidth = function() return w end,
                getHeight = function() return h end,
                getPixel = function() return blank end,
            }
        end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end

package.loaded["ui.widgets.book"] = nil
local Book = require("ui.widgets.book")

Assert.is_true(Book.isRead({ read_state = 1 }))
Assert.is_false(Book.isRead({ read_state = 0 }))
Assert.is_false(Book.isRead({ read_state = 2 }))
Assert.is_false(Book.isRead(nil))

-- 简介：纯文本原样；残留 HTML（如 BookOrbit 旧数据）展示前剥掉
Assert.eq(Book.desc({ intro = "纯文本简介" }), "纯文本简介")
Assert.eq(Book.desc({ intro = "<div><p>段一</p><p>段二</p></div>" }), "段一\n段二")
Assert.eq(Book.desc({ intro = "" }), "")
Assert.eq(Book.desc(nil), "")

-- 封面状态叠层：已读与进度互斥，下载独立；下载角标只认查询带出的 book.downloaded。
local status_opts = { badge = true, ribbon = true, download = true }
local unread = select(1, Book.cover(nil, nil, { read_state = 0, percent = 12, downloaded = true }, 80, 120, status_opts))
Assert.len(unread, 3)
Assert.eq(unread[2].overlap_offset[2], 4, "未读有进度：右上进度角标")
Assert.eq(unread[3].overlap_offset[1], 4, "已下载：左下勾")

local finished = select(1, Book.cover(nil, nil, { read_state = 1, percent = 100, downloaded = true }, 80, 120, status_opts))
Assert.len(finished, 3)
Assert.not_nil(finished[2].band, "已读：缎带替代进度角标")

local fresh = select(1, Book.cover(nil, nil, { read_state = 0, percent = 0 }, 80, 120, status_opts))
Assert.is_nil(fresh.overlap_offset, "无进度未下载：不叠层")

local no_badge = select(1, Book.cover(nil, nil, { read_state = 0, percent = 0, downloaded = true }, 80, 120,
    { badge = true }))
Assert.is_nil(no_badge.overlap_offset, "没开下载角标：已下载也不画")
local has_path = select(1, Book.cover(nil, nil, { path = "/a" }, 80, 120, { download = true }))
Assert.is_nil(has_path.overlap_offset, "只有 path 不算已下载（口径在库里）")

Assert.is_nil(Book.progressBadge(80, 0))
Assert.not_nil(Book.progressBadge(80, 12))

local rects = {}
local ribbon = Book.readRibbon(80)
ribbon:paintTo({
    paintRect = function(_, x, y, w, h)
        rects[#rects + 1] = { x = x, y = y, w = w, h = h }
    end,
}, 0, 0)
Assert.is_true(#rects > 0)
Assert.eq(rects[1].x, 0)
Assert.eq(rects[1].w, ribbon.band)
Assert.eq(rects[2].x, 1)
Assert.eq(ribbon.overlap_offset[1], 80 - ribbon:getSize().w)
Assert.eq(ribbon.overlap_offset[2], 0)

local marks = {}
local mark = Book.downloadMark(120)
mark:paintTo({
    paintCircle = function(_, cx, cy, r, color)
        marks[#marks + 1] = { cx = cx, cy = cy, r = r, color = color }
    end,
}, 0, 0)
Assert.len(marks, 1)
Assert.eq(marks[1].r, 9)
Assert.eq(mark.overlap_offset[1], 4)
Assert.eq(mark.overlap_offset[2], 120 - 18 - 4)
Assert.eq(mark.icon.name, "check", "已下载：勾")

-- 已缓存：同一个左下角槽位画 cached，圆底用 muted 色（05 A5）。
local cached_marks = {}
local cached_mark = Book.cachedMark(120)
cached_mark:paintTo({
    paintCircle = function(_, cx, cy, r, color)
        cached_marks[#cached_marks + 1] = { cx = cx, cy = cy, r = r, color = color }
    end,
}, 0, 0)
Assert.len(cached_marks, 1)
Assert.eq(cached_mark.icon.name, "cached")
Assert.eq(cached_mark.overlap_offset[1], mark.overlap_offset[1], "与下载角标同槽")
Assert.eq(cached_mark.overlap_offset[2], mark.overlap_offset[2])
Assert.eq(cached_marks[1].color, require("ui.themes").current().color.muted, "缓存角标 muted 色")

-- 封面叠层：缓存与下载互斥，缓存优先（同时成立只画缓存）。
local cached_cover = select(1, Book.cover(nil, nil, { read_state = 0, percent = 0, cache_mark = true }, 80, 120,
    { badge = true, ribbon = true, download = true, cached = true }))
Assert.len(cached_cover, 2, "无进度未下载：只有封面 + 缓存角标")
Assert.eq(cached_cover[2].icon.name, "cached")
local both_marks = select(1, Book.cover(nil, nil,
    { read_state = 0, percent = 0, downloaded = true, cache_mark = true }, 80, 120,
    { badge = true, ribbon = true, download = true, cached = true }))
Assert.len(both_marks, 2, "缓存与下载互斥：左下角只画一个")
Assert.eq(both_marks[2].icon.name, "cached")
local not_cached = select(1, Book.cover(nil, nil, { read_state = 0, percent = 0, downloaded = true }, 80, 120,
    { download = true, cached = true }))
Assert.eq(not_cached[2].icon.name, "check", "没缓存仍然画下载勾")

local more = Book.moreMark(80, 120)
Assert.eq(more.overlap_offset[1], 80 - 18 - 4)
Assert.eq(more.overlap_offset[2], 120 - 18 - 4)

local opening = Book.openingBar(80, 120)
Assert.eq(opening.overlap_offset[1], 0)
Assert.eq(opening.overlap_offset[2], math.floor((120 - 22) / 2))

local bare = select(1, Book.cover(nil, nil, {}, 80, 120, {}))
Assert.is_nil(bare.overlap_offset)

-- 混合模式：封面按书的 source_id 解析属主源，不用活跃源冒充。
resolved = {}
local active = {
    id = "local",
    coverRequest = function()
        error("must not use active source for foreign book")
    end,
}
local image = select(1, Book.cover(nil, active, {
    source_id = "wechat",
    stable_id = "book-1",
    title = "跨源书",
}, 80, 120, {}))
Assert.eq(resolved[1], "wechat")
Assert.eq(coverImage(image).src, "https://wechat/book-1")
Assert.eq(coverImage(image).headers.X, "wechat")
Assert.eq(coverImage(image).fallback.title, "跨源书", "无图时用生成封面")
Assert.eq(coverImage(image).fallback.author, "")

-- 活跃源就是属主源时不 resolve。
resolved = {}
local same = {
    id = "wechat",
    coverRequest = function(_, book)
        return { url = "https://same/" .. book.stable_id }
    end,
}
image = select(1, Book.cover(nil, same, {
    source_id = "wechat",
    stable_id = "book-2",
}, 80, 120, {}))
Assert.len(resolved, 0)
Assert.eq(coverImage(image).src, "https://same/book-2")

-- 本地封面已落盘：优先本地，不再走远程链接。源仍问一次（只有它知道封面是否权威），但不用它的图。
local local_cover = "/covers/wechat/book-3"
existing_files[local_cover] = true
resolved = {}
image = select(1, Book.cover(nil, active, {
    source_id = "wechat",
    stable_id = "book-3",
    cover_url = "https://remote/book-3.jpg",
}, 80, 120, {}))
Assert.eq(coverImage(image).src, local_cover, "本地封面优先于远程链接")
Assert.is_nil(coverImage(image).headers)
Assert.is_nil(coverImage(image).fallback_src)
Assert.len(resolved, 1)

-- 源声明封面权威（Kavita：本地抽页就是扫描页）：本地缓存只作加载失败兜底。
authoritative.wechat = true
resolved = {}
image = select(1, Book.cover(nil, active, {
    source_id = "wechat",
    stable_id = "book-3",
    cover_url = "https://remote/book-3.jpg",
}, 80, 120, {}))
Assert.eq(resolved[1], "wechat")
Assert.eq(coverImage(image).src, "https://wechat/book-3", "权威源封面压过本地缓存与远程链接")
Assert.eq(coverImage(image).fallback_src, local_cover, "本地缓存留作失败兜底")
authoritative.wechat = nil

-- 显式 src（刮削候选）仍压过本地封面，本地只做失败兜底。
image = select(1, Book.cover(nil, nil, {
    source_id = "wechat",
    stable_id = "book-3",
}, 80, 120, { src = "https://scrape/candidate.jpg" }))
Assert.eq(coverImage(image).src, "https://scrape/candidate.jpg")
Assert.eq(coverImage(image).fallback_src, local_cover)
existing_files[local_cover] = nil

-- 本地没有时仍走远程链接。
image = select(1, Book.cover(nil, nil, {
    source_id = "wechat",
    stable_id = "book-3",
    cover_url = "https://remote/book-3.jpg",
}, 80, 120, {}))
Assert.eq(coverImage(image).src, "https://remote/book-3.jpg")

-- 封面一律拉满框（不保比例）：2:3 常态框与拉宽后的宽框都不传 stretch
-- （Image 的 stretch=true 是按比例缩进，传了反而在宽框里留白边）。
for _, dims in ipairs({ { 80, 120 }, { 120, 120 }, { 90, 120 } }) do
    local filled = select(1, Book.cover(nil, nil, { title = "拉满" }, dims[1], dims[2], {}))
    Assert.is_nil(coverImage(filled).stretch, dims[1] .. "x" .. dims[2])
end

local with_more = select(1, Book.cover(nil, nil, {}, 80, 120, { more = true }))
Assert.eq(with_more.dimen.w, 80)
Assert.eq(with_more.dimen.h, 120)
Assert.eq(with_more[2].overlap_offset[1], 80 - 18 - 4)
Assert.eq(with_more[2].overlap_offset[2], 120 - 18 - 4)

local more_taps = 0
local with_tap = select(1, Book.cover(nil, nil, {}, 80, 120, {
    more = function()
        more_taps = more_taps + 1
    end,
}))
Assert.is_true(with_tap[2]:onTapBookInfo())
Assert.eq(more_taps, 1)

local tapped, held = 0, 0
local widget = Book.tappable(100, 150, function()
    tapped = tapped + 1
end, function()
    held = held + 1
end)
Assert.not_nil(widget.ges_events.TapBookInfo)
Assert.not_nil(widget.ges_events.HoldBookInfo)
Assert.is_true(widget:onTapBookInfo())
Assert.is_true(widget:onHoldBookInfo())
Assert.eq(tapped, 1)
Assert.eq(held, 1)

local plain = Book.widget(nil, nil, { title = "书", authors = "甲" }, 80, 120, {})
local named = Book.widget(nil, nil, { title = "书", authors = "甲" }, 80, 120, { show_author = true })
local unknown = Book.widget(nil, nil, { title = "书" }, 80, 120, { show_author = true, show_title = false })
Assert.eq(#plain, 3)
Assert.eq(plain[3][1].text, "书")
Assert.eq(plain[3][1].color, 0x7038A0, "小字号封面书名也使用主题色")
Assert.eq(#named, 5)
Assert.eq(named[5][1].text, "甲")
Assert.eq(named[5][1].color, 2, "作者仍是次要文字色")
Assert.eq(#unknown, 3)
Assert.eq(unknown[3][1].text, "未知作者")

-- persistCover：分块拷贝到封面缓存；空源文件不落盘、不留 .part
do
    local Paths = require("utils.paths")
    local old = Paths.coverPath
    local dir = os.tmpname()
    os.remove(dir)
    local src, empty, target = dir .. ".src", dir .. ".empty", dir .. ".cover"
    Paths.coverPath = function() return target end
    local big = string.rep("0123456789abcdef", 10000) -- 160KB，跨多块
    local f = assert(io.open(src, "wb")); f:write(big); f:close()
    f = assert(io.open(empty, "wb")); f:close()
    local book = { source_id = "s", stable_id = "b" }
    Book.persistCover(book, empty)
    Assert.is_nil(io.open(target, "rb"))
    Assert.is_nil(io.open(target .. ".part", "rb"))
    Book.persistCover(book, src)
    f = assert(io.open(target, "rb"))
    Assert.eq(f:read("*a"), big)
    f:close()
    os.remove(src); os.remove(empty); os.remove(target)
    Paths.coverPath = old
end

package.loaded["ui.widgets.book"] = nil
