--[[-- ui.components.image：下载限流；文件就绪后直接 ImageWidget。 --]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, value) return value end,
            scaleByDPI = function(_, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        face = function() return {} end,
        line = function() return 1 end,
        muted = function() return 0 end,
        pluginRoot = function() return Config.root() .. "/book.koplugin/" end,
    }
end
local function simpleWidget()
    return {
        new = function(_, opts)
            opts.free = opts.free or function(self)
                if self[1] and self[1].free then self[1]:free() end
            end
            opts.getSize = opts.getSize or function(self)
                return self.dimen or { w = self.width or 0, h = self.height or 0 }
            end
            return opts
        end,
        paintTo = function() end,
        free = function(self)
            if self[1] and self[1].free then self[1]:free() end
        end,
    }
end
package.preload["ui/widget/container/centercontainer"] = simpleWidget
package.preload["ui/widget/container/framecontainer"] = simpleWidget
package.preload["ui/widget/widget"] = simpleWidget
package.preload["ui/widget/container/widgetcontainer"] = simpleWidget
package.preload["ui/widget/textwidget"] = simpleWidget
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0 }
end

local image_widgets = {}
package.preload["ui/widget/imagewidget"] = function()
    return {
        new = function(_, opts)
            image_widgets[#image_widgets + 1] = opts
            opts.free = function() end
            opts.getSize = function()
                return { w = opts.width or 0, h = opts.height or 0 }
            end
            return opts
        end,
    }
end

local image_path = Config.dir() .. "/image-queue-test.png"
local file = assert(io.open(image_path, "wb"))
file:write("not decoded by this test")
file:close()

local downloads = {}
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            local download = { opts = opts, dest = dest, cb = cb, cancelled = false }
            downloads[#downloads + 1] = download
            return {
                cancel = function()
                    download.cancelled = true
                end,
            }
        end,
    }
end

package.loaded["http.request"] = nil
package.loaded["ui.components.image"] = nil
package.loaded["ui.components.image.download"] = nil
local Image = require("ui.components.image")

local UIManager = require("ui/uimanager")
local dirty_count = 0
function UIManager:setDirty()
    dirty_count = dirty_count + 1
end

local local_widgets = {}
for _ = 1, 6 do
    local_widgets[#local_widgets + 1] = Image.widget{
        src = image_path,
        width = 40,
        height = 60,
    }
end
Assert.eq(#downloads, 0, "本地图不得发起下载")
Assert.eq(#image_widgets, 6, "本地图直接 ImageWidget")
Assert.eq(image_widgets[1].file, image_path)
Assert.eq(image_widgets[1].width, 40)
Assert.eq(image_widgets[1].height, 60)
Assert.eq(dirty_count, 0, "未上屏不得自己刷屏")

local_widgets[6]:free()
for i = 1, #local_widgets do local_widgets[i]:free() end
local local_images = #image_widgets

local network = {}
for i = 1, 12 do
    network[i] = Image.widget{
        src = "https://example.test/" .. i .. ".png",
        width = 40,
        height = 60,
    }
end
local download_limit = #downloads
Assert.is_true(download_limit < #network, "封面下载必须限制并发请求数")
Assert.eq(download_limit, 10)
Assert.eq(downloads[1].opts.connect_timeout, 30)
Assert.eq(#image_widgets, local_images, "下载完成前不得创建图片控件")

-- 取消第一个排队项后，活动项完成只能补进后一个未取消任务。
network[download_limit + 1]:free()
downloads[1].cb(false, "HTTP 404")
Assert.eq(#downloads, download_limit + 1)
Assert.eq(downloads[#downloads].opts.url, "https://example.test/12.png")

-- 404 在短期内直接失败，不得因页面重建再次冲击服务端。
local failed = Image.widget{
    src = "https://example.test/1.png",
    width = 40,
    height = 60,
}
Assert.eq(#downloads, download_limit + 1)

failed:free()
for i = 1, #network do network[i]:free() end

local before_abort = #downloads
local extras = {}
for i = 20, 32 do
    extras[#extras + 1] = Image.widget{
        src = "https://example.test/" .. i .. ".png",
        width = 40,
        height = 60,
    }
end
Assert.eq(#downloads, before_abort + download_limit)
local direct = Image.fetchAsync("https://example.test/direct.png", nil, function() end)
extras[1]:cancel()
Assert.is_true(downloads[before_abort + 1].cancelled, "abort 只杀这一张")
for i = before_abort + 2, #downloads do
    Assert.is_false(downloads[i].cancelled, "abort 不得误杀其它下载")
end
direct:abort()
for i = 1, #extras do extras[i]:free() end

-- 磁盘缓存命中不再下载，直接 ImageWidget。
local Paths = require("utils.paths")
Paths.ensureImageRoot()
local md5 = require("ffi/sha2").md5
local cached_url = "https://example.test/cached.png"
local cached_file = Paths.imageRootDir() .. "/" .. md5(cached_url) .. ".png"
local cached = assert(io.open(cached_file, "wb"))
cached:write("cached")
cached:close()
local before_cached = #downloads
local before_images = #image_widgets
local cached_widget = Image.widget{
    src = cached_url,
    width = 40,
    height = 60,
}
Assert.eq(#downloads, before_cached, "缓存命中不得再下载")
Assert.eq(#image_widgets, before_images + 1, "缓存命中直接 ImageWidget")
Assert.eq(image_widgets[#image_widgets].file, cached_file)
cached_widget:free()

local paused = Image.widget{ src = "https://example.test/pause.png", width = 40, height = 60 }
Assert.not_nil(paused._download)
paused:onHomePause()
Assert.is_false(paused._alive)
Assert.is_nil(paused._download)
paused:onHomePause()
paused:free()

local instant = false
Image.await({}, function() instant = true end)
Assert.is_true(instant)

local batch_done = false
Image.await(Image.widget{ src = image_path, width = 40, height = 60 }, function()
    batch_done = true
end)
Assert.is_true(batch_done, "本地图就绪即可写锁屏")

-- 封面尺寸：不在构造时解，等 nextTick。
local before_large = #image_widgets
local large = {}
for _ = 1, 3 do
    large[#large + 1] = Image.widget{ src = image_path, width = 200, height = 200 }
end
Assert.eq(#image_widgets, before_large, "大图不得在拼页时解码")
Stubs.flush()
Assert.eq(#image_widgets, before_large + 3, "大图在后续帧解码")
for i = 1, #large do large[i]:free() end

local large_done = false
Image.await(Image.widget{ src = image_path, width = 200, height = 200 }, function()
    large_done = true
end)
Assert.is_false(large_done, "大图未解码不得写锁屏")
Stubs.flush()
Assert.is_true(large_done)

local dropped = Image.widget{ src = image_path, width = 200, height = 200 }
local before_drop = #image_widgets
dropped:free()
Stubs.flush()
Assert.eq(#image_widgets, before_drop, "已释放的大图不得再解码")

-- Independent waiters on the same tree do not share cancellation state.
local waiting = Image.widget{ src = image_path, width = 200, height = 200 }
local first_wait, second_wait = 0, 0
local cancelled_wait = Image.await({ waiting }, function() first_wait = first_wait + 1 end)
Image.await({ waiting, waiting }, function() second_wait = second_wait + 1 end)
cancelled_wait:cancel()
Stubs.flush()
Assert.eq(first_wait, 0)
Assert.eq(second_wait, 1, "duplicate tree references count only once")
waiting:free()

-- Construction order and nested callers cannot overwrite another batch.
local a = Image.widget{ src = image_path, width = 200, height = 200 }
local b = Image.widget{ src = image_path, width = 200, height = 200 }
local completed = {}
Image.await(a, function() completed[#completed + 1] = "a" end)
Image.await(b, function() completed[#completed + 1] = "b" end)
Stubs.flush()
Assert.eq(table.concat(completed, ","), "a,b")
a:free()
b:free()

os.remove(image_path)
os.remove(cached_file)

package.preload["http.request"] = nil
package.loaded["http.request"] = nil
package.loaded["ui.components.image"] = nil
package.loaded["ui.components.image.download"] = nil
return true
