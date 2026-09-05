--[[-- ui.components.image：图片下载/解码采用有限并发，并正确补位/取消。 --]]

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
package.preload["ui/widget/imagewidget"] = simpleWidget
package.preload["ui/widget/widget"] = simpleWidget
package.preload["ui/widget/container/widgetcontainer"] = simpleWidget
package.preload["ui/widget/textwidget"] = simpleWidget
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = 0,
        fromstring = function() error("unexpected decode") end,
        tostring = function() error("unexpected decode") end,
    }
end

local image_path = Config.dir() .. "/image-queue-test.png"
local file = assert(io.open(image_path, "wb"))
file:write("not decoded by this test")
file:close()

local runs = {}
local downloads = {}
local worker_stub = {}
function worker_stub.run(_, opts)
    local run = { opts = opts, aborted = false }
    runs[#runs + 1] = run
    local job = {}
    function job:abort()
        if run.aborted then return end
        run.aborted = true
        opts.on_cancelled()
    end
    job.cancel = job.abort
    run.job = job
    return job
end
package.preload["workers.job"] = function() return worker_stub end
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

package.loaded["workers.job"] = nil
package.loaded["http.request"] = nil
package.loaded["ui.components.image"] = nil
local Image = require("ui.components.image")
Assert.eq(package.loaded["workers.job"], worker_stub)
local widgets = {}
for i = 1, 6 do
    widgets[i] = Image.widget{
        src = image_path,
        width = 40,
        height = 60,
    }
end

Assert.is_true(#runs < #widgets, "图片解码必须限制并发 worker 数")

-- 取消排队项后，活动槽完成不得再启动该任务。
widgets[6]:free()
local active_decodes = #runs
runs[1].opts.on_failed()
Assert.eq(#runs, active_decodes)

-- 活动项释放必须取消 worker，并继续释放对应并发槽。
widgets[2]:free()
Assert.is_true(runs[2].aborted)

widgets[1]:free()
for i = 3, 5 do widgets[i]:free() end

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

os.remove(image_path)

package.preload["workers.job"] = nil
package.loaded["workers.job"] = nil
package.preload["http.request"] = nil
package.loaded["http.request"] = nil
package.loaded["ui.components.image"] = nil

return true
