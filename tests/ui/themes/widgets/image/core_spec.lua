--[[-- ui.themes.widgets.image.core：下载限流；文件就绪后直接 ImageWidget。 --]]

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
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
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

-- 假时钟：每次解码推进 decode_ms，模拟设备上的解码耗时。
local now_ms, decode_ms = 0, 0
package.preload["utils.perf"] = function()
    return { now = function() return now_ms end }
end
package.loaded["utils.perf"] = nil

local image_widgets = {}
package.preload["ui/widget/imagewidget"] = function()
    return {
        new = function(_, opts)
            now_ms = now_ms + decode_ms
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
package.loaded["ui.themes.widgets.image.core"] = nil
package.loaded["ui.themes.widgets.image.download"] = nil
local Image = require("ui.themes.widgets.image.core")

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
Assert.is_true(image_widgets[1].original_in_nightmode, "默认夜间保持原色")
Assert.eq(dirty_count, 0, "未上屏不得自己刷屏")

-- 原地替换过的文件不能走 ImageWidget 的按路径位图缓存，必须重新解码交给 image=。
local rendered = {}
package.loaded["ui/renderimage"] = {
    renderImageFile = function(_, path, _, w, h)
        rendered[#rendered + 1] = { path = path, w = w, h = h }
        return { fake_bb = true }
    end,
}
local replaced_path = Config.dir() .. "/image-replaced-test.png"
local replaced_file = assert(io.open(replaced_path, "wb"))
replaced_file:write("replaced")
replaced_file:close()
Image.invalidate(replaced_path)
Image.widget{ src = replaced_path, width = 40, height = 60 }:free()
Assert.len(rendered, 1)
Assert.eq(rendered[1].path, replaced_path)
Assert.eq(rendered[1].w, 40)
Assert.is_nil(image_widgets[#image_widgets].file, "失效路径不得按 file 命中旧位图")
Assert.is_true(image_widgets[#image_widgets].image.fake_bb)
Assert.is_true(image_widgets[#image_widgets].image_disposable)
Assert.eq(image_widgets[1].file, image_path, "未失效路径仍走 file 缓存")
os.remove(replaced_path)
package.loaded["ui/renderimage"] = nil

local glyph = Image.widget{ src = image_path, width = 40, height = 60, invert_in_night = true }
Assert.is_false(image_widgets[#image_widgets].original_in_nightmode, "字形图夜间随屏反色")
glyph:free()

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
Assert.is_true(downloads[1].opts.allow_redirects, "封面 CDN 常 302 到签名地址，必须跟随")
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

-- 网络封面失败时，已有源专属本地封面必须回退显示。
local before_fallback = #image_widgets
local fallback = Image.widget{
    src = "https://example.test/remote-fallback.jpg",
    fallback_src = image_path,
    width = 40,
    height = 60,
}
downloads[#downloads].cb(false, "HTTP 404")
Assert.eq(#image_widgets, before_fallback + 1)
Assert.eq(image_widgets[#image_widgets].file, image_path)
fallback:free()

-- 异步出图：图一律换进占位；仍在显示中才刷新，宿主取窗口栈里的所属窗口。
local dirty_hosts = {}
local dirty_regions = {}
function UIManager:setDirty(host, refresh)
    dirty_hosts[#dirty_hosts + 1] = host
    local _, region = refresh()
    dirty_regions[#dirty_regions + 1] = region
end
local visible = {}
local shown_depth
local orig_shown = UIManager.isSubwidgetShown
function UIManager:isSubwidgetShown(widget, max_depth)
    shown_depth = max_depth
    if visible[widget] then return true, 3, visible[widget] end
    return false
end
-- 沙箱磁盘缓存跨运行保留：先删掉上次落地的文件，保证这里真的走下载。
for _, name in ipairs({ "shown", "hidden", "unpainted" }) do
    local base = require("utils.paths").imageRootDir() .. "/"
        .. require("ffi/sha2").md5("https://example.test/" .. name .. ".png")
    os.remove(base .. ".png")
end
local function arrive(box)
    local d = downloads[#downloads]
    local f = assert(io.open(d.dest, "wb"))
    f:write("\137PNG\r\n\26\n0000")
    f:close()
    d.cb(true)
    return box[1]
end
local window = { name = "window" }
local shown_box = Image.widget{ src = "https://example.test/shown.png", width = 40, height = 60 }
shown_box:paintTo({}, 5, 7)
visible[shown_box] = window
local placeholder = shown_box[1]
Assert.is_true(arrive(shown_box) ~= placeholder, "图换进占位")
Assert.len(dirty_hosts, 1)
Assert.eq(dirty_hosts[1], window, "刷新图片所属的顶层窗口")
Assert.eq(dirty_regions[1].x, 5)
Assert.eq(dirty_regions[1].y, 7)
Assert.eq(dirty_regions[1].w, 40, "只刷图片自己那块")
Assert.eq(shown_depth, 64, "主题控件嵌套深，不用默认 15 层")

local unpainted_box = Image.widget{ src = "https://example.test/unpainted.png", width = 40, height = 60 }
visible[unpainted_box] = window
placeholder = unpainted_box[1]
Assert.is_true(arrive(unpainted_box) ~= placeholder, "没上过屏也照样设置图片")
Assert.len(dirty_hosts, 1, "没上过屏不刷新")

local hidden_box = Image.widget{ src = "https://example.test/hidden.png", width = 40, height = 60 }
hidden_box:paintTo({}, 5, 7) -- 上过屏，随后窗口关了 / 翻页换掉
placeholder = hidden_box[1]
Assert.is_true(arrive(hidden_box) ~= placeholder, "不显示也照样设置图片")
Assert.len(dirty_hosts, 1, "不显示不刷新")
for _, b in ipairs({ shown_box, unpainted_box, hidden_box }) do b:free() end
UIManager.isSubwidgetShown = orig_shown
function UIManager:setDirty() dirty_count = dirty_count + 1 end

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
direct:cancel()
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

-- 大图走模块位图缓存：key = 路径 + 尺寸，每个用例换宽度避开前面用例的缓存。
local renders = {}
local px_bytes = 1
package.loaded["ui/renderimage"] = {
    renderImageFile = function(_, path, _, w, h)
        renders[#renders + 1] = { path = path, w = w, h = h }
        return { stride = w * px_bytes, h = h }
    end,
}
local next_w = 200
local function big()
    next_w = next_w + 1
    return next_w
end

-- 封面尺寸：不在构造时解，等 nextTick。
local before_large = #image_widgets
local large = {}
local large_w = big()
for _ = 1, 3 do
    large[#large + 1] = Image.widget{ src = image_path, width = large_w, height = 200 }
end
Assert.eq(#image_widgets, before_large, "大图不得在拼页时解码")
Stubs.flush()
Assert.eq(#image_widgets, before_large + 3, "大图在后续帧解码")
Assert.len(renders, 1, "同路径同尺寸只解一次")
Assert.is_nil(image_widgets[#image_widgets].file, "大图位图由模块给出")
Assert.eq(image_widgets[#image_widgets].image, image_widgets[#image_widgets - 1].image)
Assert.is_false(image_widgets[#image_widgets].image_disposable, "共享位图不得被 ImageWidget free")
for i = 1, #large do large[i]:free() end

-- 缓存命中：重建时拼页当场出图，不排队、不重解。
local hit = Image.widget{ src = image_path, width = large_w, height = 200 }
Assert.eq(#image_widgets, before_large + 4, "命中缓存拼页即出图")
Assert.len(renders, 1)
local hit_done = false
Image.await(hit, function() hit_done = true end)
Assert.is_true(hit_done, "命中即落定")
hit:free()

-- 原地替换过的文件：丢掉缓存位图，重新排队解码。
Image.invalidate(image_path)
local stale = Image.widget{ src = image_path, width = large_w, height = 200 }
Assert.eq(#image_widgets, before_large + 4, "失效后不得命中旧位图")
Stubs.flush()
Assert.len(renders, 2)
stale:free()

-- 超预算按最久未用淘汰；刚解的那张保留。
--- 建一张大图并冲刷解码队列，返回后即释放控件（位图仍在缓存）。
---@param w number
local function decodeOnce(w)
    local box = Image.widget{ src = image_path, width = w, height = 200 }
    Stubs.flush()
    box:free()
end
px_bytes = 300 -- 单张约 12 MiB，两张超 16 MiB 预算
local lru_a, lru_b = big(), big()
decodeOnce(lru_a)
decodeOnce(lru_a)
Assert.len(renders, 3, "A 已缓存")
decodeOnce(lru_b)
Assert.len(renders, 4)
local before_evicted = #image_widgets
local evicted = Image.widget{ src = image_path, width = lru_a, height = 200 }
Assert.eq(#image_widgets, before_evicted, "A 被 B 挤出缓存后须重新排队")
Stubs.flush()
evicted:free()
decodeOnce(lru_a)
Assert.len(renders, 5, "A 重解后又命中")
px_bytes = 1

-- SVG（在线字体预览）不进位图缓存：交给 ImageWidget 按后缀走 NanoSVG 保比例，排队解码。
local svg_path = Config.dir() .. "/image-preview-test.svg"
local svg_file = assert(io.open(svg_path, "wb"))
svg_file:write("<svg xmlns='http://www.w3.org/2000/svg'/>")
svg_file:close()
local before_svg_renders, before_svg_widgets = #renders, #image_widgets
local svg = Image.widget{ src = svg_path, width = 400, height = 36, alpha = true }
Assert.eq(#image_widgets, before_svg_widgets, "大 SVG 仍排队")
Stubs.flush()
Assert.len(renders, before_svg_renders, "SVG 不得走 renderImageFile")
Assert.eq(image_widgets[#image_widgets].file, svg_path)
svg:free()
os.remove(svg_path)

local delays = {}
local schedule_in = UIManager.scheduleIn
function UIManager:scheduleIn(delay, fn)
    delays[#delays + 1] = delay
    return schedule_in(self, delay, fn)
end

-- 预算内（缓存命中/快解码）一拍出齐，不得每张图空等一次续排。
local page = {}
for i = 1, 12 do
    page[i] = Image.widget{ src = image_path, width = big(), height = 200 }
end
Stubs.flush()
Assert.len(delays, 0, "预算内整页封面一拍解完")
for i = 1, #page do page[i]:free() end

-- 超预算必须续排；续排若 0 延迟，UIManager 会在读输入前把整个队列解完，切页卡死。
decode_ms = 60
local yielding = {
    Image.widget{ src = image_path, width = big(), height = 200 },
    Image.widget{ src = image_path, width = big(), height = 200 },
}
Stubs.flush()
decode_ms = 0
UIManager.scheduleIn = schedule_in
Assert.len(delays, 1)
Assert.is_true(delays[1] > 0, "续排解码必须让出输入轮询")
for i = 1, #yielding do yielding[i]:free() end

local large_done = false
Image.await(Image.widget{ src = image_path, width = big(), height = 200 }, function()
    large_done = true
end)
Assert.is_false(large_done, "大图未解码不得写锁屏")
Stubs.flush()
Assert.is_true(large_done)

local dropped = Image.widget{ src = image_path, width = big(), height = 200 }
local before_drop = #image_widgets
dropped:free()
Stubs.flush()
Assert.eq(#image_widgets, before_drop, "已释放的大图不得再解码")

-- Independent waiters on the same tree do not share cancellation state.
local waiting = Image.widget{ src = image_path, width = big(), height = 200 }
local first_wait, second_wait = 0, 0
local cancelled_wait = Image.await({ waiting }, function() first_wait = first_wait + 1 end)
Image.await({ waiting, waiting }, function() second_wait = second_wait + 1 end)
cancelled_wait:cancel()
Stubs.flush()
Assert.eq(first_wait, 0)
Assert.eq(second_wait, 1, "duplicate tree references count only once")
waiting:free()

-- Construction order and nested callers cannot overwrite another batch.
local a = Image.widget{ src = image_path, width = big(), height = 200 }
local b = Image.widget{ src = image_path, width = big(), height = 200 }
local completed = {}
Image.await(a, function() completed[#completed + 1] = "a" end)
Image.await(b, function() completed[#completed + 1] = "b" end)
Stubs.flush()
Assert.eq(table.concat(completed, ","), "a,b")
a:free()
b:free()

-- 本地封面解码前留白，不画兜底控件：冷启动整屏排队解码时不能先闪一遍假封面。
local function fbWidget()
    local fb = { freed = 0 }
    fb.getSize = function() return { w = 1, h = 1 } end
    fb.free = function() fb.freed = fb.freed + 1 end
    return fb
end
local fb_ok = fbWidget()
local blank = Image.widget{ src = image_path, width = big(), height = 200, fallback = fb_ok }
Assert.is_true(blank[1][1] ~= fb_ok, "解码前留白")
Stubs.flush()
Assert.is_true(blank[1][1] ~= fb_ok and blank[1][1].image ~= nil, "解码后换成图")
Assert.eq(fb_ok.freed, 1, "没用上的兜底控件随出图释放")
blank:free()
Assert.eq(fb_ok.freed, 1, "不得重复释放")

local render_ok = package.loaded["ui/renderimage"].renderImageFile
package.loaded["ui/renderimage"].renderImageFile = function() error("bad image") end
local fb_bad = fbWidget()
local broken = Image.widget{ src = image_path, width = big(), height = 200, fallback = fb_bad }
Stubs.flush()
Assert.eq(broken[1][1], fb_bad, "解码失败补上兜底控件")
broken:free()
package.loaded["ui/renderimage"].renderImageFile = render_ok

local fb_net = fbWidget()
local loading = Image.widget{ src = "https://example.test/loading.png", width = 40, height = 60, fallback = fb_net }
Assert.eq(loading[1][1], fb_net, "下载中仍显示兜底控件")
loading:free()

local fb_none = fbWidget()
local none = Image.widget{ width = 40, height = 60, fallback = fb_none }
Assert.eq(none[1][1], fb_none, "没有来源直接显示兜底控件")
none:free()

os.remove(image_path)
os.remove(cached_file)
package.loaded["ui/renderimage"] = nil

package.preload["utils.perf"] = nil
package.loaded["utils.perf"] = nil
package.preload["http.request"] = nil
package.loaded["http.request"] = nil
package.loaded["ui.themes.widgets.image.core"] = nil
package.loaded["ui.themes.widgets.image.download"] = nil
return true
