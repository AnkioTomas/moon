--[[-- ui.components.image：图片解码单任务后台队列，网络下载有限并发。 --]]

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

local runs = {}
local worker_stub = {}
function worker_stub.run(_, opts)
    local run = { opts = opts, aborted = false }
    runs[#runs + 1] = run
    local job = {}
    function job:abort()
        if run.aborted then return end
        run.aborted = true
        if opts.on_cancelled then opts.on_cancelled() end
    end
    job.cancel = job.abort
    return job
end
package.preload["workers.job"] = function() return worker_stub end

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
local Image = require("ui.components.image")

-- 本地/缓存也必须后台解码，构造页面时不能阻塞或直接创建图片控件。
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
Assert.eq(#runs, 1, "图片解码必须只运行一个后台任务")
Assert.eq(#image_widgets, 0, "后台解码完成前不得创建图片控件")
Assert.eq(dirty_count, 0, "缓存图不得自己刷屏")

-- 当前任务结束后才启动下一张；排队任务取消后不会占住队列。
local first_runs = #runs
local_widgets[6]:free()
runs[1].opts.on_failed()
Assert.eq(#runs, first_runs + 1)
local_widgets[2]:free()
Assert.is_true(runs[2].aborted)
for i = 1, #local_widgets do local_widgets[i]:free() end
local local_runs = #runs

local network = {}
for i = 1, 7 do
    network[i] = Image.widget{
        src = "https://example.test/" .. i .. ".png",
        width = 40,
        height = 60,
    }
end
local download_limit = #downloads
Assert.is_true(download_limit < #network, "封面下载必须限制并发请求数")
Assert.eq(downloads[1].opts.connect_timeout, 30)
Assert.eq(#runs, local_runs, "下载完成前不得启动解码")

-- 取消第一个排队项后，活动项完成只能补进后一个未取消任务。
network[download_limit + 1]:free()
downloads[1].cb(false, "HTTP 404")
Assert.eq(#downloads, download_limit + 1)
Assert.eq(downloads[#downloads].opts.url, "https://example.test/7.png")

-- 404 在短期内直接失败，不得因页面重建再次冲击服务端。
local failed = Image.widget{
    src = "https://example.test/1.png",
    width = 40,
    height = 60,
}
Stubs.flush()
Assert.eq(#downloads, download_limit + 1)

failed:free()
for i = 1, #network do network[i]:free() end

local before_abort = #downloads
for i = 10, 16 do
    Image.widget{
        src = "https://example.test/" .. i .. ".png",
        width = 40,
        height = 60,
    }
end
Assert.eq(#downloads, before_abort + download_limit)
local direct = Image.fetchAsync("https://example.test/direct.png", nil, function() end)
Image.abortPending()
Assert.eq(#downloads, before_abort + download_limit + 1,
    "批量取消不得丢弃不属于 Widget 的排队下载")
for i = before_abort + 1, #downloads do
    if downloads[i].opts.url ~= "https://example.test/direct.png" then
        Assert.is_true(downloads[i].cancelled)
    end
end
Assert.eq(downloads[#downloads].opts.url, "https://example.test/direct.png")
direct.cancel()

-- 磁盘缓存命中不再下载，但仍走同一个后台解码队列。
local Paths = require("utils.paths")
Paths.ensureImageRoot()
local md5 = require("ffi/sha2").md5
local cached_url = "https://example.test/cached.png"
local cached_file = Paths.imageRootDir() .. "/" .. md5(cached_url) .. ".png"
local cached = assert(io.open(cached_file, "wb"))
cached:write("cached")
cached:close()
local before_cached = #downloads
local before_runs = #runs
local cached_widget = Image.widget{
    src = cached_url,
    width = 40,
    height = 60,
}
Assert.eq(#downloads, before_cached, "缓存命中不得再下载")
Assert.eq(#runs, before_runs + 1, "缓存命中也必须进入后台解码")
Assert.eq(#image_widgets, 0, "后台解码完成前不得创建图片控件")
cached_widget:free()

os.remove(image_path)
os.remove(cached_file)

package.preload["http.request"] = nil
package.loaded["http.request"] = nil
package.loaded["ui.components.image"] = nil

return true
