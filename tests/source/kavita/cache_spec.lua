--[[--
book.koplugin/source/kavita/cache.lua：kamare 缓存适配层。

kamare 的 `kamarecache` 是唯一的缓存执行者。这里只做探测、能力门面、配置镜像、
错误文案、书架投影与删除保护，所有 kamare 模块都在函数内 pcall require、不持有 table。

@module tests.source.kavita.cache_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")

local PLUGIN = Config.root() .. "/book.koplugin/source/kavita"

-- 源配置：每个用例自己改；cache 只读 base_url / api_key。
local cfg = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function() end,
    }
end

-- 日志：记录每一行，供「一次性 / 不刷屏」断言。
local logs = {}
package.preload["utils.log"] = function()
    local function push(level, ...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(index, ...))
        end
        logs[#logs + 1] = { level = level, text = table.concat(parts, " ") }
    end
    return {
        dbg = function(...) push("dbg", ...) end,
        info = function(...) push("info", ...) end,
        warn = function(...) push("warn", ...) end,
        error = function(...) push("error", ...) end,
    }
end

package.preload["source.kavita.cache"] = function()
    return dofile(PLUGIN .. "/cache.lua")
end
local Cache = require("source.kavita.cache")

--- 清空 kamare 模块，模拟未安装。
local function uninstall()
    package.loaded["kamarecache"] = nil
    package.preload["kamarecache"] = nil
    package.loaded["kamareimageviewer"] = nil
    package.preload["kamareimageviewer"] = nil
    package.loaded["kamareversion"] = nil
    package.preload["kamareversion"] = nil
end

--- 装一个 kamarecache 桩；status 用 loadstring 造出可预测的模块路径。
---@param spec table { api_version, capabilities, version, path, viewer }
---@return table
local function installCache(spec)
    package.loaded["kamareimageviewer"] = spec.viewer
    local mod = {
        api_version = spec.api_version,
        capabilities = spec.capabilities or {},
    }
    if spec.path then
        mod.status = assert(loadstring("return function() end", "@" .. spec.path))()
    end
    package.loaded["kamarecache"] = mod
    if spec.version then
        package.loaded["kamareversion"] = spec.version
    end
    Cache.reset()
    return mod
end

local function resetLogs()
    logs = {}
end

local function logText()
    local parts = {}
    for _idx, line in ipairs(logs) do parts[#parts + 1] = line.text end
    return table.concat(parts, "\n")
end

--- 含某段文字的行数（一次性 / 不刷屏断言用）。
---@param fragment string
---@return integer
local function countLines(fragment)
    local count = 0
    for _idx, line in ipairs(logs) do
        if line.text:find(fragment, 1, true) then count = count + 1 end
    end
    return count
end

----------------------------------------------------------------------
-- 探测：四安装态、版本、加载路径；成功记忆、失败不记忆。
----------------------------------------------------------------------
uninstall()
Cache.reset()
local probe = Cache.probe()
Assert.is_false(probe.ok, "没有 kamarecache 不可用")
Assert.eq(probe.state, "missing", "未安装 / 已安装但被禁用")
Assert.eq(probe.reason, "missing")
Assert.eq(Cache.available("open"), false, "未安装时没有任何缓存能力")

uninstall()
package.loaded["kamareimageviewer"] = { new = function() end }
Cache.reset()
probe = Cache.probe()
Assert.is_false(probe.ok, "官方版没有缓存接口")
Assert.eq(probe.state, "official", "有查看器但无 kamarecache")

installCache({ api_version = 2, capabilities = { status = true, open = true } })
probe = Cache.probe()
Assert.is_false(probe.ok, "主版本不符整体禁用")
Assert.eq(probe.state, "incompatible")
Assert.eq(probe.api_version, 2)
Assert.eq(probe.reason, "major_mismatch")
Assert.eq(Cache.available("status"), false, "主版本不符整体禁用缓存")
Assert.eq(Cache.available("open"), false, "没有查看器可退回时 open 也不可用")

local fake_path = "/fake/plugins/kamare.koplugin/src/kamarecache.lua"
installCache({
    api_version = 1,
    capabilities = { status = true, open = true },
    version = "0.10.0-dev",
    path = fake_path,
})
probe = Cache.probe()
Assert.is_true(probe.ok)
Assert.eq(probe.state, "enhanced")
Assert.eq(probe.api_version, 1)
Assert.eq(probe.version, "0.10.0-dev", "kamareversion 返回字符串")
Assert.eq(probe.path, fake_path, "加载路径取自 debug.getinfo(module.status)")

-- data 目录里的插件路径是 `plugins//x.koplugin`（KOReader 的 extra_plugin_paths 带尾斜杠）：
-- 展示前归一，否则用户会以为路径坏了。
installCache({
    api_version = 1,
    capabilities = { status = true, open = true },
    version = "0.10.0-dev",
    path = "/fake/plugins//kamare.koplugin/kamarecache.lua",
})
Assert.eq(Cache.probe().path, "/fake/plugins/kamare.koplugin/kamarecache.lua", "重复斜杠归一")
Assert.eq(probe.capabilities.status, true)
Assert.eq(Cache.available("status"), true)
Assert.eq(Cache.available("index"), false, "能力逐项判断")

-- 成功结果进程内记忆：模块从 package 里消失后仍按上次结果
package.loaded["kamarecache"] = nil
Assert.eq(Cache.probe().state, "enhanced", "成功结果记住，不重复 require")
Assert.eq(Cache.reprobe().state, "missing", "「重新检测」清掉成功记忆")
Cache.reset()
Assert.eq(Cache.probe().state, "missing", "reset 后重新探测")

-- 失败不记忆：装上模块后立刻能看到增强版
Assert.eq(Cache.probe().state, "missing")
installCache({ api_version = 1, capabilities = {} })
Assert.eq(Cache.probe().state, "enhanced", "失败结果不缓存")

-- kamareversion 用表形状也认（老写法）
package.loaded["kamareversion"] = { version = "0.9.9" }
Cache.reset()
Assert.eq(Cache.probe().version, "0.9.9")

----------------------------------------------------------------------
-- 门面：每个能力一个显式包装，参数只从配置补 base_url；缺能力则 unsupported。
----------------------------------------------------------------------
cfg = { base_url = "http://kav/", api_key = " k " }

local calls = {}
local function record(name, impl)
    return function(...)
        calls[#calls + 1] = { name = name, args = { ... } }
        if impl then return impl(...) end
        return true
    end
end

local function lastCall(name)
    for index = #calls, 1, -1 do
        if calls[index].name == name then return calls[index] end
    end
end

local index_result = { used = 1, available = 2, series = { ["60"] = { seriesId = 60 } } }
local mod = installCache({
    api_version = 1,
    capabilities = {
        status = true, summary = true, resume = true, queue = true,
        index = true, enqueue = true, delete = true, estimate = true,
        queue_control = true,
    },
})
mod.index = record("index", function() return index_result end)
mod.status = record("status", function() return { state = "complete" } end)
mod.resume_page = record("resume_page", function() return { page = 7 } end)
mod.summary = record("summary", function() return { used = 10, available = 20, chapters = 3 } end)
mod.queue_state = record("queue_state", function() return { state = "idle" } end)
mod.enqueue = record("enqueue", function() return true, nil, { chapters = 1 } end)
mod.delete = record("delete", function() return true, nil, 1 end)
mod.estimate = record("estimate", function() return { ok = true, chapters = 1, bytes = 1, available = 2 } end)

Assert.eq(Cache.index(), index_result)
Assert.eq(lastCall("index").args[1], "http://kav", "base_url 去尾斜杠；不传 api_key")

Assert.eq(Cache.status(6001).state, "complete")
Assert.eq(lastCall("status").args[1], "http://kav")
Assert.eq(lastCall("status").args[2], 6001)

Assert.eq(Cache.resumePage(6001, 60).page, 7)
Assert.eq(lastCall("resume_page").args[1], "http://kav")
Assert.eq(lastCall("resume_page").args[2], 6001)
Assert.eq(lastCall("resume_page").args[3], 60)

Assert.eq(Cache.summary().chapters, 3)
Assert.eq(lastCall("summary").args[1], "http://kav")

Assert.eq(Cache.queueState().state, "idle")
Assert.eq(lastCall("queue_state").args[1], "http://kav")

local ok, code, info = Cache.enqueue({ { chapterId = 6001 } })
Assert.is_true(ok)
Assert.is_nil(code)
Assert.eq(info.chapters, 1, "成功时第三个返回值原样透出")
Assert.eq(lastCall("enqueue").args[1], "http://kav")
Assert.eq(lastCall("enqueue").args[2][1].chapterId, 6001)

local deleted_ok, deleted_code, deleted = Cache.delete({ 6001 })
Assert.is_true(deleted_ok)
Assert.is_nil(deleted_code)
Assert.eq(deleted, 1)
Assert.eq(lastCall("delete").args[1], "http://kav")
Assert.eq(lastCall("delete").args[2][1], 6001)

Assert.is_true(Cache.estimate({ { chapterId = 6001 } }).ok)
Assert.eq(lastCall("estimate").args[1], "http://kav")
Assert.eq(lastCall("estimate").args[2][1].chapterId, 6001)

-- 队列控制：三个显式包装，全部作用在全局队列上。
mod.queue_pause = record("queue_pause")
mod.queue_resume = record("queue_resume")
mod.queue_retry = record("queue_retry")
Assert.is_true(Cache.queuePause())
Assert.is_true(Cache.queueResume())
Assert.is_true(Cache.queueRetry({ 6001, 6002 }))
Assert.eq(lastCall("queue_pause").args[1], "http://kav")
Assert.eq(lastCall("queue_resume").args[1], "http://kav")
Assert.eq(lastCall("queue_retry").args[1], "http://kav")
Assert.eq(lastCall("queue_retry").args[2][2], 6002)

-- 缺能力：对应功能单独降级，kamare 的函数不会被调用。
calls = {}
installCache({ api_version = 1, capabilities = { status = true } })
local value, code = Cache.status(1)
Assert.eq(code, "unsupported", "能力声明了但没有函数也按缺失处理")
value, code = Cache.index()
Assert.is_nil(value, "缺 index 返回 nil")
Assert.eq(code, "unsupported")
value, code = Cache.summary()
Assert.is_nil(value)
Assert.eq(code, "unsupported")
Assert.eq(select(2, Cache.queueState()), "unsupported")
Assert.eq(select(2, Cache.queueState()), "unsupported")
Assert.eq(select(2, Cache.queuePause()), "unsupported")
Assert.eq(select(2, Cache.enqueue({ { chapterId = 1 } })), "unsupported")
Assert.eq(select(2, Cache.delete({ 1 })), "unsupported")
Assert.eq(select(2, Cache.estimate({ { chapterId = 1 } })), "unsupported")

-- 未配置服务器：静默 unknown_server，不碰 kamare。
cfg = { base_url = "", api_key = "" }
calls = {}
Assert.eq(select(2, Cache.index()), "unknown_server")
Assert.eq(select(2, Cache.enqueue({ { chapterId = 1 } })), "unknown_server")
Assert.len(calls, 0, "未配置时不发任何调用")

-- kamare 的错误码原样透出，文案交给 message 表。
cfg = { base_url = "http://kav/", api_key = "k" }
installCache({
    api_version = 1,
    capabilities = { index = true, enqueue = true },
})
mod = package.loaded["kamarecache"]
mod.index = function() return nil, "unknown_server" end
mod.enqueue = function() return nil, "not_enough_space", "空间不足", { needed = 3, available = 1 } end
local read, read_code = Cache.index()
Assert.is_nil(read)
Assert.eq(read_code, "unknown_server")
local written, write_code, write_message, write_detail = Cache.enqueue({ { chapterId = 1 } })
Assert.is_nil(written)
Assert.eq(write_code, "not_enough_space")
Assert.eq(write_message, "空间不足")
Assert.eq(write_detail.available, 1)

----------------------------------------------------------------------
-- 配置镜像：首次缓存操作前 + 每次写操作前；只传 base_url + api_key，不传 name。
----------------------------------------------------------------------
cfg = { base_url = "http://kav/", api_key = " k " }
calls = {}
resetLogs()
local mirror_mod = installCache({
    api_version = 1,
    capabilities = { server = true, index = true, status = true, enqueue = true,
        delete = true, queue_control = true, estimate = true },
})
mirror_mod.register_server = record("register_server", function() return "srv-1" end)
mirror_mod.index = record("index", function() return { series = {} } end)
mirror_mod.status = record("status")
mirror_mod.enqueue = record("enqueue", function() return true end)
mirror_mod.delete = record("delete", function() return true, nil, 1 end)
mirror_mod.queue_pause = record("queue_pause")
mirror_mod.queue_resume = record("queue_resume")
mirror_mod.queue_retry = record("queue_retry")
mirror_mod.estimate = record("estimate", function() return { ok = true } end)

local function callCount(name)
    local n = 0
    for _idx, call in ipairs(calls) do
        if call.name == name then n = n + 1 end
    end
    return n
end

--- 某次调用在 calls 里的位置（从 1 起；没有为 0）
local function callIndex(name)
    for index, call in ipairs(calls) do
        if call.name == name then return index end
    end
    return 0
end

Cache.index()
Assert.eq(callCount("register_server"), 1, "首次缓存操作前镜像一次")
local registered = lastCall("register_server").args[1]
Assert.eq(registered.base_url, "http://kav", "URL 规范化：去尾斜杠")
Assert.eq(registered.api_key, "k", "API Key 去空白")
Assert.is_nil(registered.name, "不传固定显示名（否则两台服务器会共用一个缓存目录）")

Cache.status(1)
Assert.eq(callCount("register_server"), 1, "读操作不重复镜像")

Cache.enqueue({ { chapterId = 1 } })
Assert.eq(callCount("register_server"), 2, "每次写操作前幂等兜底")
Assert.is_true(callIndex("register_server") < callIndex("enqueue"), "镜像先于写入")

Cache.delete({ 1 })
Cache.queuePause()
Cache.queueResume()
Cache.queueRetry({ 1 })
Cache.estimate({ { chapterId = 1 } })
Assert.eq(callCount("register_server"), 6, "delete / queue_* / 估计写盘前路径都镜像")

-- 显式调用：设置页保存后走这一个入口。
local server_key, mirror_code = Cache.registerServer("http://kav/", " k ")
Assert.eq(server_key, "srv-1")
Assert.is_nil(mirror_code)
Assert.eq(callCount("register_server"), 7)

-- 失败：后台只记一次日志，功能照常交给 kamare（按 unknown_server 静默降级）。
mirror_mod.register_server = record("register_server", function() return nil, "settings_write_failed" end)
local before = callCount("register_server")
Cache.enqueue({ { chapterId = 2 } })
Assert.eq(callCount("register_server"), before + 1)
Assert.eq(callCount("enqueue"), 2, "镜像失败不阻断写操作，最终以 kamare 为准")
Assert.is_true(Cache.mirrorFailed(), "本次会话镜像失败")
Assert.matches(logText(), "settings_write_failed", "失败记一行")
local mirror_lines = 0
for _idx, line in ipairs(logs) do
    if line.text:find("mirror", 1, true) then mirror_lines = mirror_lines + 1 end
end
Assert.eq(mirror_lines, 1, "同一原因只记一次")
Cache.enqueue({ { chapterId = 3 } })
mirror_lines = 0
for _idx, line in ipairs(logs) do
    if line.text:find("mirror", 1, true) then mirror_lines = mirror_lines + 1 end
end
Assert.eq(mirror_lines, 1, "重复失败不刷屏")

mirror_mod.register_server = record("register_server", function() return "srv-1" end)
Cache.enqueue({ { chapterId = 4 } })
Assert.is_false(Cache.mirrorFailed(), "成功后清除失败态")

-- 未配置 / 未安装时不假装镜像。
cfg = { base_url = "", api_key = "" }
calls = {}
Cache.index()
Assert.len(calls, 0, "未配置不发镜像")

cfg = { base_url = "http://kav/", api_key = "k" }
uninstall()
Cache.reset()
calls = {}
Cache.available("index")
Assert.len(calls, 0, "未安装不发镜像")

----------------------------------------------------------------------
-- 文案：02 A9 的 code 表 + 07 A7 的 lastError 特征。
----------------------------------------------------------------------
local CODE_CASES = {
    { "offline_not_cached", "这一卷还没缓存，联网后可下载" },
    { "viewer_running", "漫画阅读器已在运行" },
    { "no_pages", "这一卷没有可显示的页面" },
    { "settings_write_failed", "无法写入 kamare 配置" },
    { "retry_no_entry", "没有可重试的任务" },
    { "chapter_open", "正在阅读这一卷，关闭后可以删除" },
}
for _idx, case in ipairs(CODE_CASES) do
    Assert.eq(Cache.message(case[1]), case[2], "code → 文案: " .. case[1])
end
-- 静默：已是目标状态 / 未知服务器都当无缓存，不打扰用户。
Assert.is_nil(Cache.message("unknown_server"), "unknown_server 静默")
Assert.is_nil(Cache.message("already_cached"), "已缓存静默")
Assert.is_nil(Cache.message("already_queued"), "已排队静默")
Assert.is_nil(Cache.message(nil), "没有 code 没有说话")
-- 未知 code：kamare 的 message 优先，再退通用文案。
Assert.eq(Cache.message("weird_code", "kamare 的原话"), "kamare 的原话")
Assert.eq(Cache.message("weird_code"), "缓存操作失败")

local MB = 1024 * 1024
Assert.eq(Cache.sizeText(3 * MB), "3.0 MB")
Assert.eq(Cache.message("not_enough_space", nil, { needed = 3 * MB, available = MB }),
    "空间不足：需要 3.0 MB，可用 1.0 MB")
Assert.eq(Cache.message("cache_limit_reached", nil, { needed = 2 * MB, limit = 9 * MB }),
    "缓存空间已满：需要 2.0 MB，上限 9.0 MB")
Assert.eq(Cache.message("low_space", nil, { available = MB, low_water = 500 * MB }),
    "可用空间低于 500.0 MB，清理后再下载")

-- estimate 的三种裁决：确认框就地换文案，不复制 kamare 的 2.05 / 500MB 常量。
Assert.eq(Cache.estimateMessage({ reason = "nothing_to_do" }), "全部已缓存或正在下载")
Assert.eq(Cache.estimateMessage({ reason = "space", bytes = 3 * MB, available = MB }),
    "空间不足：需要 3.0 MB，可用 1.0 MB")
Assert.eq(Cache.estimateMessage({ reason = "low_water", available = MB }),
    "可用空间不足（剩余 1.0 MB），清理后再下载")
Assert.is_nil(Cache.estimateMessage({ ok = true, reason = nil }), "可下载时没有额外文案")
Assert.is_nil(Cache.estimateMessage(nil))

-- 失败原因（07 A7）：按 kamare 的 lastError 特征归并成可读文案。
local FAILED = {
    { "http 403 while fetching page 3", "服务器拒绝下载（403），检查 API Key / 权限" },
    { "not an archive: text/html", "下载内容不完整或不是有效压缩包" },
    { "size 120/900", "下载内容不完整或不是有效压缩包" },
    { "extracted 3 of 5 pages", "下载内容不完整或不是有效压缩包" },
    { "sink write failed: no space left on device", "存储空间不足或写入失败" },
    { "socket closed", "网络中断或服务器不可达" },
    { "connect timeout", "网络中断或服务器不可达" },
    { "connection truncated", "网络中断或服务器不可达" },
}
for _idx, case in ipairs(FAILED) do
    Assert.eq(Cache.failureText(case[1]), case[2], "lastError → 文案: " .. case[1])
end
Assert.eq(Cache.failureText("weird failure"), "缓存失败：weird failure", "未知错误前缀保留原话")
Assert.is_nil(Cache.failureText(nil))

----------------------------------------------------------------------
-- 打开：enhanced 有 open 走 kamare；官方 / 缺 open 退回 legacy；记录当前打开的章。
----------------------------------------------------------------------
cfg = { base_url = "http://kav/", api_key = "k" }
calls = {}
local opened = installCache({
    api_version = 1,
    capabilities = { open = true, delete = true, server = true },
})
opened.register_server = record("register_server", function() return "srv-1" end)
local closed = {}
local nexts = {}
local fake_viewer = { kind = "viewer" }
opened.open = record("open", function() return fake_viewer end)
Assert.is_true(Cache.enhancedOpen(), "增强版有 open：由 kamare 决定起始页 / 离线")
local open_result, open_code = Cache.open({
    base_url = "http://kav/", api_key = "k",
    entry = { chapterId = 6001, pages = 20 }, title = "漫画",
    on_close = function(page, total) closed[#closed + 1] = { page, total } end,
    on_next = function(id) nexts[#nexts + 1] = id end,
})
Assert.eq(open_result, fake_viewer)
Assert.is_nil(open_code)
local open_opts = lastCall("open").args[1]
Assert.eq(open_opts.entry.chapterId, 6001, "目录条目原样交给 kamare")
Assert.eq(open_opts.title, "漫画")
Assert.not_nil(open_opts.on_next)
Assert.is_true(Cache.isChapterOpen(6001), "打开成功记下当前章")
Assert.is_false(Cache.isChapterOpen(6002))

open_opts.on_close(7, 20)
Assert.eq(closed[1][1], 7, "关闭回调原样透出")
Assert.eq(closed[1][2], 20)
Assert.is_false(Cache.isChapterOpen(6001), "关闭后清除当前章")

-- 打开失败不留 active。
opened.open = function() return nil, "viewer_running", "漫画阅读器已在运行" end
local failed, failed_code, failed_message = Cache.open({
    base_url = "http://kav/", api_key = "k", entry = { chapterId = 6003, pages = 4 },
})
Assert.is_nil(failed)
Assert.eq(failed_code, "viewer_running")
Assert.eq(failed_message, "漫画阅读器已在运行")
Assert.is_false(Cache.isChapterOpen(6003))

-- 删除保护：本地先拦，kamare 的 delete 根本不会被调用。
calls = {}
local deleted_viewer = installCache({
    api_version = 1,
    capabilities = { open = true, delete = true },
})
deleted_viewer.open = record("open", function() return { kind = "viewer" } end)
deleted_viewer.delete = record("delete", function() return true, nil, 1 end)
Cache.open({ base_url = "http://kav/", api_key = "k", entry = { chapterId = 6001, pages = 20 } })
local del_ok, del_code = Cache.delete({ 6001 })
Assert.is_nil(del_ok)
Assert.eq(del_code, "chapter_open", "正在读的章拒绝删除")
Assert.eq(Cache.message(del_code), "正在阅读这一卷，关闭后可以删除")
Assert.eq(callCount("delete"), 0, "kamare 的 delete 不被调用")

Assert.is_true(Cache.delete({ 6002 }), "别的章照删")
Assert.eq(lastCall("delete").args[2][1], 6002)

-- 关掉查看器后可以删。
lastCall("open").args[1].on_close(1, 20)
Assert.is_true(Cache.delete({ 6001 }))

-- 官方版 / enhanced 缺 open：退回 legacy 通道（今天的在线看图能力不能丢）。
uninstall()
package.loaded["kamareimageviewer"] = { new = function(_self, spec) return spec end }
local streamed = {}
package.loaded["kavitaclient"] = {
    streamChapter = function(_self, id) streamed[#streamed + 1] = id; return { { pageNumber = 1 } } end,
}
local shown = {}
package.loaded["ui/uimanager"] = { show = function(_, widget) shown[#shown + 1] = widget end }
Cache.reset()
Assert.is_true(Cache.available("open"), "官方版仍能在线看图")
Assert.is_false(Cache.enhancedOpen(), "官方版不接管 open：起始页由 moon 补")
local legacy_viewer, legacy_code = Cache.open({
    base_url = "http://kav/", api_key = "k", entry = { chapterId = 6001, pages = 20 }, title = "漫画",
    start_page = 3, on_close = function() end, on_next = function() end,
})
Assert.is_nil(legacy_code)
Assert.eq(legacy_viewer.metadata.chapterId, 6001)
Assert.eq(legacy_viewer.metadata.startPage, 3)
Assert.eq(legacy_viewer.images_list_nb, 20)
Assert.eq(legacy_viewer.title, "漫画")
Assert.eq(require("kavitaclient").api_key, "k")
Assert.eq(require("kavitaclient").device_id, "moon-kavita")
Assert.eq(streamed[1], 6001)
Assert.eq(shown[1], legacy_viewer, "交给 UIManager 显示")
Assert.is_true(Cache.isChapterOpen(6001), "legacy 也记当前章")

-- enhanced 但缺 open 能力：同样退回 legacy。
installCache({ api_version = 1, capabilities = { status = true } })
Assert.is_false(Cache.enhancedOpen(), "增强版缺 open：退回 legacy，由 moon 给起始页")
package.loaded["kamareimageviewer"] = { new = function(_self, spec) return spec end }
package.loaded["kavitaclient"] = { streamChapter = function() return { { pageNumber = 1 } } end }
Cache.reset()
local fallback = Cache.open({
    base_url = "http://kav/", api_key = "k", entry = { chapterId = 6004, pages = 4 },
})
Assert.not_nil(fallback, "增强版缺 open 时退回查看器")
Assert.eq(fallback.metadata.chapterId, 6004)

-- legacy 没有页面 / 查看器已被占用 / 串流失败：稳定 code。
Cache.reset()
local no_pages, no_pages_code = Cache.open({
    base_url = "http://kav/", api_key = "k", entry = { chapterId = 6005, pages = 0 },
})
Assert.is_nil(no_pages)
Assert.eq(no_pages_code, "no_pages")

package.loaded["kamareimageviewer"] = { new = function(_self, spec) spec._aborted = true; return spec end }
local running, running_code = Cache.open({
    base_url = "http://kav/", api_key = "k", entry = { chapterId = 6006, pages = 3 },
})
Assert.is_nil(running)
Assert.eq(running_code, "viewer_running")

package.loaded["kamareimageviewer"] = { new = function(_self, spec) return spec end }
package.loaded["kavitaclient"] = { streamChapter = function() return nil end }
local broken, broken_code, broken_message = Cache.open({
    base_url = "http://kav/", api_key = "k", entry = { chapterId = 6007, pages = 3 },
})
Assert.is_nil(broken)
Assert.eq(broken_code, "open_failed")
Assert.eq(broken_message, "打开漫画阅读器失败")

-- 完全没有 kamare：不能假装能打开。
uninstall()
Cache.reset()
Assert.is_false(Cache.available("open"))
local none, none_code = Cache.open({ base_url = "http://kav/", api_key = "k", entry = { chapterId = 1, pages = 1 } })
Assert.is_nil(none)
Assert.eq(none_code, "unsupported")

----------------------------------------------------------------------
-- 书架投影：complete / stale 才算已缓存；三张表按服务器记忆，无 TTL。
----------------------------------------------------------------------
cfg = { base_url = "http://kav/", api_key = "k" }
local work = Config.dir() .. "/cache_spec"
os.execute("mkdir -p '" .. work .. "'")
local cover = work .. "/cover-60.jpg"
local cover_file = assert(io.open(cover, "wb"))
cover_file:write("jpeg")
cover_file:close()

calls = {}
local shelf_mod = installCache({
    api_version = 1,
    capabilities = { index = true, server = true, enqueue = true, delete = true, queue_control = true },
})
shelf_mod.register_server = record("register_server", function() return "srv" end)
local shelf_index = {
    series = {
        ["60"] = { seriesId = 60, chapters = 2, complete = true, coverPath = cover },
        ["61"] = { seriesId = 61, chapters = 0, complete = true, coverPath = work .. "/missing.jpg" },
        ["62"] = { seriesId = 62, chapters = 1, stale = true },
        ["63"] = { seriesId = 63, chapters = 1 },
        ["64"] = { seriesId = 64, chapters = 3, stale = true, complete = false },
    },
}
shelf_mod.index = record("index", function() return shelf_index end)
shelf_mod.enqueue = record("enqueue", function() return true end)
shelf_mod.delete = record("delete", function() return true, nil, 1 end)
shelf_mod.queue_pause = record("queue_pause", function() return true end)

local shelf = Cache.shelf()
Assert.is_true(shelf.series_ids["60"], "complete 算已缓存")
Assert.is_true(shelf.mark["60"])
Assert.is_true(shelf.series_ids["62"], "stale 与 complete 等价")
Assert.is_true(shelf.series_ids["64"])
Assert.is_nil(shelf.series_ids["61"], "没有章不算（chapters = 0）")
Assert.is_nil(shelf.series_ids["63"], "queued / downloading 不算")
Assert.eq(shelf.cover["60"], cover, "封面路径存在才给")
Assert.is_nil(shelf.cover["61"], "文件不存在不给")
Assert.eq(callCount("index"), 1)

Cache.shelf()
Assert.eq(callCount("index"), 1, "进程内记忆，无 TTL、翻页不重拉")

-- 三类失效：写操作成功、手动刷新、Registry.reload（源实例重建时调 resetShelf）。
Cache.enqueue({ { chapterId = 6001 } })
Cache.shelf()
Assert.eq(callCount("index"), 2, "enqueue 成功后失效")
Cache.delete({ 6001 })
Cache.shelf()
Assert.eq(callCount("index"), 3, "delete 成功后失效")
Cache.queuePause()
Cache.shelf()
Assert.eq(callCount("index"), 4, "queue_* 成功后失效")
Cache.resetShelf()
Cache.shelf()
Assert.eq(callCount("index"), 5, "手动刷新 / Registry.reload")

-- 写失败不能误伤投影（失败时缓存没变）。
shelf_mod.enqueue = record("enqueue", function() return nil, "not_enough_space" end)
Cache.enqueue({ { chapterId = 6002 } })
Cache.shelf()
Assert.eq(callCount("index"), 5, "失败的写操作不失效")

-- 按服务器分开记忆：切回旧服务器不重拉。
cfg.base_url = "http://other/"
Cache.shelf()
Assert.eq(callCount("index"), 6)
Assert.eq(lastCall("index").args[1], "http://other")
cfg.base_url = "http://kav/"
Cache.shelf()
Assert.eq(callCount("index"), 6, "旧服务器的投影还在")

-- unknown_server 不记忆：下次进书架再试（可能刚镜像完）。
shelf_mod.index = record("index", function() return nil, "unknown_server" end)
cfg.base_url = "http://third/"
Assert.is_nil(Cache.shelf())
Assert.is_nil(Cache.shelf())
Assert.eq(callCount("index"), 8, "无缓存不写空投影")

-- 缺 index 能力：整块降级为无标记。
installCache({ api_version = 1, capabilities = { status = true } })
Assert.is_nil(Cache.shelf(), "缺 index 无书架标记")

-- 「已缓存」口径只在一处：章状态与 index 摘要两种形状都认（03 A3）。
Assert.is_true(Cache.isCached({ state = "complete" }))
Assert.is_true(Cache.isCached({ state = "stale" }))
Assert.is_false(Cache.isCached({ state = "partial" }))
Assert.is_false(Cache.isCached(nil))
Assert.is_true(Cache.isCached({ chapters = 1, complete = true }))
Assert.is_false(Cache.isCached({ chapters = 1 }))

-- 能力名单排序与拼接：设置页与日志共用同一份（08）。
Assert.eq(Cache.capabilityNames({ open = true, index = true }), "index,open")
Assert.eq(Cache.capabilityNames({ open = true, index = true }, "、"), "index、open")
Assert.eq(Cache.capabilityNames(nil), "none")

----------------------------------------------------------------------
-- 日志：探测每进程一次、写操作一行、open 失败去重、暂停原因只在变化时记。
----------------------------------------------------------------------
cfg = { base_url = "http://kav/", api_key = "secret-key" }
uninstall()
resetLogs()
Cache.reset()
Cache.probe()
Cache.probe()
Assert.eq(countLines("kamare probe"), 1, "探测结果每进程只记一次")
Assert.matches(logText(), "kamare probe ok=false state=missing")
Assert.is_nil(logText():find("secret-key", 1, true), "日志里绝不出现 API Key")

installCache({
    api_version = 1,
    capabilities = { status = true, index = true, enqueue = true, delete = true,
        queue = true, queue_control = true, open = true },
    version = "0.10.0",
    path = "/fake/plugins/kamare.koplugin/kamarecache.lua",
})
resetLogs()
Cache.probe()
Cache.probe()
Assert.eq(countLines("kamare probe ok=true"), 1)
Assert.matches(logText(), "state=enhanced")
Assert.matches(logText(), "version=0.10.0")
Assert.matches(logText(), "caps=.*index")
Assert.is_nil(logText():find("secret-key", 1, true))

local log_mod = package.loaded["kamarecache"]
log_mod.status = function() return { state = "complete" } end
log_mod.index = function() return { series = {} } end
log_mod.enqueue = function() return nil, "not_enough_space", "空间不足", { needed = 9, available = 1 } end
resetLogs()
Cache.enqueue({ { chapterId = 6001 }, { chapterId = 6002 } })
Cache.enqueue({ { chapterId = 6003 } })
Assert.eq(countLines("cache enqueue cid=6001,6002 code=not_enough_space"), 1, "每次写操作一行，带 code 与章 id")
Assert.eq(countLines("cache enqueue cid=6003 code=not_enough_space"), 1, "另一次失败另记一行")

log_mod.delete = function() return true, nil, 1 end
resetLogs()
Cache.delete({ 6004 })
Assert.eq(countLines("cache delete cid=6004 code=ok"), 1)

log_mod.queue_pause = function() return true end
resetLogs()
Cache.queuePause()
Assert.eq(countLines("cache queue_pause cid=- code=ok"), 1, "队列动作没有章 id，记 -")

-- 轮询路径不刷日志，只在暂停原因变化时记一行。
log_mod.queue_state = function() return { state = "paused", pause_reason = "offline" } end
resetLogs()
Cache.queueState()
Cache.queueState()
Assert.eq(countLines("queue paused reason=offline"), 1, "1 秒轮询不重复记")
log_mod.queue_state = function() return { state = "idle" } end
Cache.queueState()
log_mod.queue_state = function() return { state = "paused", pause_reason = "offline" } end
Cache.queueState()
Assert.eq(countLines("queue paused reason=offline"), 2, "恢复后再次暂停要再记")
log_mod.queue_state = function() return { state = "paused", pause_reason = "network" } end
Cache.queueState()
Assert.eq(countLines("queue paused reason=network"), 1)

-- 读操作不写日志。
resetLogs()
Cache.status(6001)
Cache.index()
Assert.len(logs, 0, "读路径零日志")

-- settings 模块加载失败是真故障：降级成未配置，但不能静默。
local settings_preload = package.preload["utils.settings"]
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function() error("settings module broken") end
resetLogs()
Cache.reset()
Assert.is_nil(Cache.shelf())
Assert.is_nil(Cache.shelf())
Assert.eq(countLines("kavita cache settings unavailable"), 1, "配置模块故障只记一次")
Assert.eq(logs[1] and logs[1].level, "warn", "真实故障记警告")
package.preload["utils.settings"] = settings_preload
package.loaded["utils.settings"] = nil
Cache.reset()

-- open 失败同一原因只记一次。
log_mod.open = function() return nil, "viewer_running" end
resetLogs()
Cache.open({ base_url = "http://kav/", api_key = "k", entry = { chapterId = 6001, pages = 4 } })
Cache.open({ base_url = "http://kav/", api_key = "k", entry = { chapterId = 6001, pages = 4 } })
Assert.eq(countLines("cache open cid=6001 code=viewer_running"), 1, "open 失败去重")

-- chapters / delete_all / plan / summaryAll：清理门面
cfg.base_url, cfg.api_key = "http://kav", "k"
local cleanup_calls = {}
local cleanup_mod = installCache({
    api_version = 1,
    capabilities = { status = true, summary = true, chapters = true, delete = true,
        delete_all = true, server = true },
    version = "0.10.0",
})
function cleanup_mod.chapters(base_url, series_id)
    cleanup_calls.chapters = { base_url, series_id }
    return { { chapterId = 1, pages = 10, bytes = 100, read = true } }
end
function cleanup_mod.delete_all()
    cleanup_calls.delete_all = (cleanup_calls.delete_all or 0) + 1
    return true, nil, { chapters = 3, bytes = 300 }
end
function cleanup_mod.summary(base_url)
    cleanup_calls.summary = (cleanup_calls.summary or 0) + 1
    cleanup_calls.summary_base = base_url
    return { used = 300, available = 1000, chapters = 3 }
end
function cleanup_mod.register_server() return "srv" end
Cache.reset()

local plan_rows = Cache.chapters(42)
Assert.eq(cleanup_calls.chapters[1], "http://kav", "chapters 用当前服务器")
Assert.eq(cleanup_calls.chapters[2], 42, "chapters 透传 series_id")
Assert.len(plan_rows, 1, "chapters 返回数组")

local ok, _code, _message, detail = Cache.deleteAll()
Assert.is_true(ok, "deleteAll 成功")
Assert.eq(detail and detail.chapters, 3, "deleteAll 透传估算")
Assert.eq(cleanup_calls.delete_all, 1, "deleteAll 调 kamare 一次")

Assert.eq(Cache.summaryAll().chapters, 3, "summaryAll 返回合计")
Assert.eq(cleanup_calls.summary_base, nil, "summaryAll 不传 base_url")

local plan = Cache.plan(plan_rows, "read", nil)
Assert.eq(plan.chapters, 1, "read 过滤保留已读")
Assert.eq(plan.bytes, 100, "字节合计")
Assert.eq(plan.ids[1], 1, "ids 供批量删除")
local not_read = Cache.plan({ { chapterId = 2, pages = 10, bytes = 50, read = false } }, "read", nil)
Assert.eq(not_read.chapters, 0, "未读不入选")
local via_toc = Cache.plan({ { chapterId = 3, pages = 10, bytes = 50, read = false } }, "read",
    { ["3"] = 10 })
Assert.eq(via_toc.chapters, 1, "toc 的 pagesRead 补第三源")
local queued = Cache.plan({ { chapterId = 4, pages = 10, bytes = 1, read = true, queued = true } }, "all", nil)
Assert.eq(queued.queued, 1, "排队数进计划")


return true
