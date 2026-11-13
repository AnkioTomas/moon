--[[--
workers.slim：fork 后只丢掉确认安全的位图缓存，不动文档对象。
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local warnings = {}
package.loaded["utils.log"] = {
    dbg = function() end,
    warn = function(...) warnings[#warnings + 1] = { ... } end,
    flushSync = function() end,
}
package.loaded["workers.slim"] = nil
local Slim = require("workers.slim")

local gc = 0
local real_collectgarbage = collectgarbage
collectgarbage = function(...)
    gc = gc + 1
    return real_collectgarbage(...)
end

Assert.eq(Slim.dropPluginBitmaps(), 0)
Assert.eq(Slim.dropImageCache(), 0)
Assert.eq(Slim.dropDocCacheTiles(), 0)
Slim.afterFork()
Assert.eq(gc, 0, "瘦身不得对整个 Lua 状态 collectgarbage")

local released = {}
package.loaded["ui.themes.widgets.image.core"] = {
    releaseCachedBitmaps = function(release)
        local bb = {
            stride = 10,
            h = 10,
            free = function(self) released[#released + 1] = "plugin" end,
        }
        release(bb)
        return 1
    end,
}
Assert.eq(Slim.dropPluginBitmaps(), 1)
Assert.eq(released[1], "plugin")

local ImageCache = {
    items = {},
    cache = {},
}
ImageCache.cache.pairs = function()
    return pairs(ImageCache.items)
end
function ImageCache:clear()
    self.cleared = true
    self.items = {}
    self.cache.pairs = function()
        return pairs(self.items)
    end
end
local image_bb = {
    stride = 8,
    h = 8,
    free = function(self) released[#released + 1] = "image" end,
}
ImageCache.items.icon = { bb = image_bb, is_straight_alpha = false }
local ImageWidget = {}
function ImageWidget._loadfile()
    return ImageCache
end
package.loaded["ui/widget/imagewidget"] = ImageWidget
Assert.eq(Slim.dropImageCache(), 1)
Assert.eq(released[2], "image")
Assert.is_true(ImageCache.cleared)
Assert.is_nil(image_bb and ImageCache.items.icon)

local store = {}
local doccache = {
    cache = {
        pairs = function()
            return pairs(store)
        end,
        delete = function(_, key)
            local item = store[key]
            store[key] = nil
            if item and item.onFree then item:onFree() end
        end,
    },
}
store.tile = {
    bb = {
        stride = 16,
        h = 16,
        free = function(self) released[#released + 1] = "tile" end,
    },
    excerpt = { x = 0, y = 0, w = 16, h = 16 },
    onFree = function(self)
        if self.bb and self.bb.free then self.bb:free() end
        self.bb = nil
        released[#released + 1] = "onFree"
    end,
}
store.meta = {
    page_size = { w = 1, h = 1 },
    onFree = function() error("must not free non-tile") end,
}
store.ctx = {
    kctx = {},
    onFree = function() error("must not free kctx") end,
}
package.loaded["document/doccache"] = doccache
Assert.eq(Slim.dropDocCacheTiles(), 1)
Assert.eq(released[3], "tile")
Assert.eq(released[4], "onFree")
Assert.not_nil(store.meta)
Assert.not_nil(store.ctx)
Assert.is_nil(store.tile)

-- 缺 API 的桩不得抛错。
package.loaded["document/doccache"] = { cached = {} }
Assert.eq(Slim.dropDocCacheTiles(), 0)
package.loaded["ui/widget/imagewidget"] = { _loadfile = function() end }
Assert.eq(Slim.dropImageCache(), 0)

released = {}
package.loaded["ui.themes.widgets.image.core"] = {
    releaseCachedBitmaps = function(release)
        release({ free = function() released[#released + 1] = "again" end, stride = 1, h = 1 })
        return 1
    end,
}
package.loaded["ui/widget/imagewidget"] = ImageWidget
ImageCache.items = {}
ImageCache.cleared = false
ImageCache.cache.pairs = function()
    return pairs(ImageCache.items)
end
package.loaded["document/doccache"] = { cached = {} }
Slim.afterFork()
Assert.eq(released[1], "again")
Assert.eq(gc, 0, "afterFork 仍不得 collectgarbage")

package.loaded["ui.themes.widgets.image.core"] = {
    releaseCachedBitmaps = function(release)
        release({ stride = 1, h = 1, free = function() error("free failed") end })
        return 1
    end,
}
Assert.eq(Slim.dropPluginBitmaps(), 0, "释放失败不得计为成功")
Assert.len(warnings, 1)
Assert.eq(warnings[1][1], "book.worker slim bitmaps failed")
Assert.matches(warnings[1][2], "free failed")

ImageCache.items.icon = {
    bb = { stride = 1, h = 1, free = function() error("image free failed") end },
}
Assert.errors(Slim.dropImageCache, "image free failed")
ImageCache.items = {}
local clear = ImageCache.clear
ImageCache.clear = function() error("cache clear failed") end
Assert.errors(Slim.dropImageCache, "cache clear failed")
ImageCache.clear = clear

collectgarbage = real_collectgarbage
return true
