--[[-- ui.components.bookinfo：封面状态（已读 / 进度 / 本地下载）与长按入口。 --]]

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
package.preload["ui.components.image"] = function() return { widget = function(opts) return opts end } end
package.preload["ui.components.icon"] = function()
    return {
        widget = function()
            return {
                getSize = function() return { w = 10, h = 10 } end,
                paintTo = function() end,
                free = function() end,
            }
        end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        face = function() return {} end,
        sz = function(v) return v end,
        cardRadius = function() return 0 end,
        surface = function() return 0 end,
    }
end
package.preload["ui.components.surface"] = function()
    return { build = function(opts) return opts.child end }
end
package.preload["utils.paths"] = function()
    return {
        coverPath = function(stable_id, source_id)
            return "/covers/" .. tostring(source_id) .. "/" .. tostring(stable_id)
        end,
        ensureLayout = function() end,
    }
end
local download_checks = 0
package.preload["book.store"] = function()
    return {
        isDownloaded = function(book)
            download_checks = download_checks + 1
            return type(book) == "table" and type(book.path) == "string" and book.path ~= ""
        end,
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
package.preload["source.registry"] = function()
    return {
        resolve = function(id)
            resolved[#resolved + 1] = id
            return {
                id = id,
                coverRequest = function(_, book)
                    return { url = "https://" .. id .. "/" .. book.stable_id, headers = { X = id } }
                end,
            }
        end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY_3 = 2 }
end
package.preload["gettext"] = function() return function(s) return s end end

package.loaded["ui.components.bookinfo"] = nil
local BookInfo = require("ui.components.bookinfo")

Assert.is_true(BookInfo.isRead({ read_state = 1 }))
Assert.is_false(BookInfo.isRead({ read_state = 0 }))
Assert.is_false(BookInfo.isRead({ read_state = 2 }))
Assert.is_false(BookInfo.isRead(nil))

-- 封面状态叠层：已读与进度互斥，下载独立；没开下载角标不查下载状态。
local status_opts = { badge = true, ribbon = true, download = true }
local unread = select(1, BookInfo.cover(nil, nil, { read_state = 0, percent = 12, path = "/a" }, 80, 120, status_opts))
Assert.len(unread, 3)
Assert.eq(unread[2].overlap_offset[2], 4, "未读有进度：右上进度角标")
Assert.eq(unread[3].overlap_offset[1], 4, "已下载：左下勾")

local finished = select(1, BookInfo.cover(nil, nil, { read_state = 1, percent = 100, path = "/a" }, 80, 120, status_opts))
Assert.len(finished, 3)
Assert.not_nil(finished[2].band, "已读：缎带替代进度角标")

local fresh = select(1, BookInfo.cover(nil, nil, { read_state = 0, percent = 0 }, 80, 120, status_opts))
Assert.is_nil(fresh.overlap_offset, "无进度未下载：不叠层")

download_checks = 0
BookInfo.cover(nil, nil, { read_state = 0, percent = 12, path = "/a" }, 80, 120, { badge = true })
Assert.eq(download_checks, 0, "没开下载角标不查下载状态")
BookInfo.cover(nil, nil, { path = "/a" }, 80, 120, { download = true })
Assert.eq(download_checks, 1)

Assert.is_nil(BookInfo.progressBadge(80, 0))
Assert.not_nil(BookInfo.progressBadge(80, 12))

local rects = {}
local ribbon = BookInfo.readRibbon(80)
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
local mark = BookInfo.downloadMark(120)
mark:paintTo({
    paintCircle = function(_, cx, cy, r)
        marks[#marks + 1] = { cx = cx, cy = cy, r = r }
    end,
}, 0, 0)
Assert.len(marks, 1)
Assert.eq(marks[1].r, 9)
Assert.eq(mark.overlap_offset[1], 4)
Assert.eq(mark.overlap_offset[2], 120 - 18 - 4)

local more = BookInfo.moreMark(80, 120)
Assert.eq(more.overlap_offset[1], 80 - 18 - 4)
Assert.eq(more.overlap_offset[2], 120 - 18 - 4)

local opening = BookInfo.openingBar(80, 120)
Assert.eq(opening.overlap_offset[1], 0)
Assert.eq(opening.overlap_offset[2], math.floor((120 - 22) / 2))

local bare = select(1, BookInfo.cover(nil, nil, {}, 80, 120, {}))
Assert.is_nil(bare.overlap_offset)

-- 混合模式：封面按书的 source_id 解析属主源，不用活跃源冒充。
resolved = {}
local active = {
    id = "local",
    coverRequest = function()
        error("must not use active source for foreign book")
    end,
}
local image = select(1, BookInfo.cover(nil, active, {
    source_id = "wechat",
    stable_id = "book-1",
    title = "跨源书",
}, 80, 120, {}))
Assert.eq(resolved[1], "wechat")
Assert.eq(image.src, "https://wechat/book-1")
Assert.eq(image.headers.X, "wechat")

-- 活跃源就是属主源时不 resolve。
resolved = {}
local same = {
    id = "wechat",
    coverRequest = function(_, book)
        return { url = "https://same/" .. book.stable_id }
    end,
}
image = select(1, BookInfo.cover(nil, same, {
    source_id = "wechat",
    stable_id = "book-2",
}, 80, 120, {}))
Assert.len(resolved, 0)
Assert.eq(image.src, "https://same/book-2")

-- 本地封面已落盘：优先本地，不再走远程链接 / 源 coverRequest。
local local_cover = "/covers/wechat/book-3"
existing_files[local_cover] = true
resolved = {}
image = select(1, BookInfo.cover(nil, active, {
    source_id = "wechat",
    stable_id = "book-3",
    cover_url = "https://remote/book-3.jpg",
}, 80, 120, {}))
Assert.eq(image.src, local_cover, "本地封面优先于远程链接")
Assert.is_nil(image.headers)
Assert.is_nil(image.fallback_src)
Assert.len(resolved, 0)

-- 显式 src（刮削候选）仍压过本地封面，本地只做失败兜底。
image = select(1, BookInfo.cover(nil, nil, {
    source_id = "wechat",
    stable_id = "book-3",
}, 80, 120, { src = "https://scrape/candidate.jpg" }))
Assert.eq(image.src, "https://scrape/candidate.jpg")
Assert.eq(image.fallback_src, local_cover)
existing_files[local_cover] = nil

-- 本地没有时仍走远程链接。
image = select(1, BookInfo.cover(nil, nil, {
    source_id = "wechat",
    stable_id = "book-3",
    cover_url = "https://remote/book-3.jpg",
}, 80, 120, {}))
Assert.eq(image.src, "https://remote/book-3.jpg")

local with_more = select(1, BookInfo.cover(nil, nil, {}, 80, 120, { more = true }))
Assert.eq(with_more.dimen.w, 80)
Assert.eq(with_more.dimen.h, 120)
Assert.eq(with_more[2].overlap_offset[1], 80 - 18 - 4)
Assert.eq(with_more[2].overlap_offset[2], 120 - 18 - 4)

local more_taps = 0
local with_tap = select(1, BookInfo.cover(nil, nil, {}, 80, 120, {
    more = function()
        more_taps = more_taps + 1
    end,
}))
Assert.is_true(with_tap[2]:onTapBookInfo())
Assert.eq(more_taps, 1)

local tapped, held = 0, 0
local widget = BookInfo.tappable(100, 150, function()
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

package.loaded["ui.components.bookinfo"] = nil
