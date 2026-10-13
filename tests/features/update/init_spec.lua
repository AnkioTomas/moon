---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.update：版本比较、Release 资产约束与更新日志展示。 --]]

local Assert = require("support.assert")

local shown, closed, ticks = {}, {}, {}
local restarted = 0
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget) closed[#closed + 1] = widget end,
        nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
        broadcastEvent = function(_, event)
            if event.handler == "onRestart" then restarted = restarted + 1 end
        end,
    }
end
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
local function flush()
    while #ticks > 0 do table.remove(ticks, 1)() end
end
package.loaded["ui/uimanager"] = nil
local function dialogModule()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            function opts:close() closed[#closed + 1] = self end
            return opts
        end,
    }
end
package.preload["ui.themes.widgets.confirm"] = dialogModule
package.preload["ui.themes.widgets.toast"] = dialogModule
package.preload["ui.themes.widgets.text_viewer"] = dialogModule
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            function opts:close() closed[#closed + 1] = self end
            function opts:bytes(done, total)
                self.progress = done
                self.progress_max = total
            end
            function opts:set(text, percent)
                self.status, self.percent = text, percent
            end
            return opts
        end,
    }
end
package.preload["device"] = function()
    return { screen = { getHeight = function() return 800 end } }
end
package.preload["json"] = function() return { decode = function(value) return value end } end
local check_cb, download_cb, download_opts, download_handle
local probes = {}
local gets = 0
package.preload["http.request"] = function()
    return {
        get = function(_, _, cb)
            gets = gets + 1
            check_cb = cb
            return { cancel = function() end }
        end,
        stream = function(opts, handlers)
            local probe = { url = opts.url, handlers = handlers }
            probe.cancel = function()
                if probe.cancelled then return end
                probe.cancelled = true
                handlers.on_done("cancelled")
            end
            probes[#probes + 1] = probe
            return probe
        end,
        download = function(opts, _, cb)
            download_opts = opts
            download_cb = cb
            download_handle = { cancel = function(self) self.cancelled = true end }
            return download_handle
        end,
    }
end
package.preload["utils.paths"] = function()
    return { ensureDir = function() return true end, root = function() return "/tmp" end }
end
package.preload["utils.settings"] = function()
    local update = { auto_update_check = false, update_last_checked_at = 0 }
    return {
        get = function(name) assert(name == "features.update"); return update end,
        save = function(name) assert(name == "features.update") end,
    }
end
local job_opts, job_worker
local fork_fails = false
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            job_worker, job_opts = worker, opts
            if fork_fails then opts.on_failed("fork failed") end
            return { cancel = function() end }
        end,
    }
end
local install_args
package.preload["features.update.install"] = function()
    return {
        run = function(archive, root, sha)
            install_args = { archive = archive, root = root, sha = sha }
            return true
        end,
    }
end
package.preload["bookversion"] = function() return "1.2.3" end

local Update = require("features.update")

-- 解析只经公开的 Update.check：json 桩原样返回，喂给 check_cb 的表即「响应体」。
local hash = string.rep("a", 64)
local function release(tag, body)
    return {
        tag_name = tag,
        body = body,
        assets = {{
            name = "book.koplugin-" .. tag .. ".zip",
            browser_download_url = "https://github.com/AnkioTomas/moon/releases/download/" .. tag .. "/book.koplugin-" .. tag .. ".zip",
            digest = "sha256:" .. hash,
            size = 2048,
        }},
    }
end
local function check(response)
    local got, got_err
    Update.check(function(r, e) got, got_err = r, e end)
    check_cb(response)
    return got, got_err
end

-- 版本比较（当前 1.2.3）
Assert.is_true(check(release("v1.2.4")).available)
Assert.is_true(check(release("v2.0.0")).available)
Assert.is_false(check(release("v1.2.3")).available)
Assert.is_false(check(release("v1.2.2")).available)

-- 空日志
Assert.is_nil(check(release("v1.2.4")).notes)
Assert.is_nil(check(release("v1.2.4", "")).notes)
Assert.is_nil(check(release("v1.2.4", "   ")).notes)

local notes = check(release("v1.2.4", [[
## 月读 v1.2.4

安装：解压后复制到 plugins。

### 更新内容

相对上一版本 `v1.2.3`：

#### 新功能

- :sparkles: (update): 显示更新日志 (abc1234)
- :bug: (ui): 修弹窗 (def5678)

### 完整对比

https://github.com/AnkioTomas/moon/compare/v1.2.3...v1.2.4
]])).notes
Assert.not_nil(notes)
Assert.matches(notes, "相对上一版本 v1.2.3")
Assert.matches(notes, "新功能")
Assert.matches(notes, "%(update%): 显示更新日志")
Assert.matches(notes, "%(ui%): 修弹窗")
Assert.is_nil(notes:find("安装：", 1, true))
Assert.is_nil(notes:find("完整对比", 1, true))
Assert.is_nil(notes:find(":sparkles:", 1, true))
Assert.is_nil(notes:find("https://github.com", 1, true))

local parsed, err = check(release("v1.2.4"))
Assert.not_nil(parsed, err)
Assert.eq(parsed.version, "1.2.4")
Assert.eq(parsed.sha256, hash)
Assert.eq(parsed.size, 2048)

local bad = release("v1.2.4")
bad.assets[1].digest = nil
local missing, missing_err = check(bad)
Assert.is_nil(missing)
Assert.matches(missing_err, "checksum")

-- digest 不是 64 位十六进制也不认。
bad.assets[1].digest = "sha256:abc"
Assert.is_nil(check(bad))

-- 同名资产若跳到任意主机，不能拿来更新。
bad = release("v1.2.4")
bad.assets[1].browser_download_url = "https://example.com/book.koplugin-v1.2.4.zip"
local foreign, foreign_err = check(bad)
Assert.is_nil(foreign)
Assert.matches(foreign_err, "plugin archive")

-- 草稿 / 预发布 / 非 JSON 都是无效响应。
local draft = release("v1.2.4")
draft.draft = true
Assert.matches(select(2, check(draft)), "invalid release response")
Assert.matches(select(2, check("not json")), "invalid release response")

-- 手动检查必须展示更新日志，确认后再下载安装。
local update_release = {
    tag_name = "v1.2.4",
    body = "## 月读 v1.2.4\n\n### 更新内容\n\n- :sparkles: show notes\n",
    assets = {{
        name = "book.koplugin-v1.2.4.zip",
        browser_download_url = "https://github.com/AnkioTomas/moon/releases/download/v1.2.4/book.koplugin-v1.2.4.zip",
        digest = "sha256:" .. hash,
        size = 4096,
    }},
}
Update.manualCheck("/plugins/book.koplugin")
Assert.eq(shown[1].text, "正在检查月读更新…")
Assert.is_nil(shown[1].timeout)
check_cb(update_release)
Assert.eq(closed[1], shown[1])

local prompt = shown[2]
Assert.eq(prompt.title, "更新日志")
Assert.matches(prompt.text, "发现月读 1%.2%.4")
Assert.matches(prompt.text, "show notes")
Assert.is_nil(prompt.text:find(":sparkles:", 1, true))
local function headers(length, mime)
    local values = { ["Content-Length"] = length and tostring(length), ["Content-Type"] = mime }
    return { get = function(_, name) return values[name] end }
end
local direct = update_release.assets[1].browser_download_url

prompt.buttons[2].callback()
Assert.eq(closed[2], prompt)
Assert.eq(shown[3].title, "正在下载月读更新…")

-- 直连 + 5 个随机镜像并发探测；镜像地址 = 前缀 + github.com 之后的路径。
Assert.len(probes, 6)
Assert.eq(probes[1].url, direct)
for i = 2, 6 do
    Assert.matches(probes[i].url, "/AnkioTomas/moon/releases/download/v1%.2%.4/book%.koplugin%-v1%.2%.4%.zip$")
    Assert.is_true(probes[i].url ~= direct)
end

-- 非 200、长度对不上、200 但回的是网页（死镜像首页）都不算胜出。
probes[2].handlers.on_headers(302, headers())
probes[3].handlers.on_headers(200, headers(1))
probes[6].handlers.on_headers(200, headers(nil, "text/html; charset=utf-8"))
flush()
Assert.is_nil(download_opts)

-- 最先回合格响应头的镜像胜出，其余探测全部取消。
probes[4].handlers.on_headers(200, headers(4096, "application/octet-stream"))
probes[5].handlers.on_headers(200, headers())
flush()
Assert.eq(download_opts.url, probes[4].url)
for _, probe in ipairs(probes) do Assert.is_true(probe.cancelled) end
download_opts.on_progress(1024)
Assert.eq(shown[3].progress, 1024)
Assert.eq(shown[3].progress_max, 4096)

-- 镜像给的包校验不过：回落直连重下。
download_cb(true)
Assert.eq(closed[3], shown[3])
job_opts.on_failed("install.lua:1: update checksum mismatch")
Assert.eq(download_opts.url, direct)
download_cb(false, "network failed")
Assert.eq(closed[#closed], shown[4])
Assert.eq(shown[5].text, "月读更新失败：network failed")

-- 探测全部失败：直接走直连。
local parsed_update = check(update_release)
probes, download_opts = {}, nil
local install_ok, install_err
Update.install(parsed_update, "/plugins/book.koplugin", function(ok, e) install_ok, install_err = ok, e end)
for _, probe in ipairs(probes) do probe.handlers.on_done("timeout") end
Assert.is_nil(download_opts)
flush()
Assert.eq(download_opts.url, direct)
download_cb(false, "direct failed")
Assert.is_false(install_ok)
Assert.eq(install_err, "direct failed")

-- 镜像下载失败回落直连；直连装包的非校验错误不再重试。
probes, download_opts = {}, nil
Update.install(parsed_update, "/plugins/book.koplugin", function(ok, e) install_ok, install_err = ok, e end)
probes[2].handlers.on_headers(200, headers(4096))
flush()
local mirror_url = download_opts.url
Assert.eq(mirror_url, probes[2].url)
download_cb(false, "mirror reset")
Assert.eq(download_opts.url, direct)
download_cb(true)
job_opts.on_failed("install.lua:1: cannot back up current plugin")
Assert.is_false(install_ok)
Assert.matches(install_err, "cannot back up")

-- 下载地址不是字符串：当无效资产，不在回调里抛错。
bad = release("v1.2.4")
bad.assets[1].browser_download_url = 42
Assert.matches(select(2, check(bad)), "plugin archive")

--- 手动检查 → 确认安装，返回下载进度窗。
local function startFromPrompt()
    shown, closed, probes, download_opts = {}, {}, {}, nil
    Update.manualCheck("/plugins/book.koplugin")
    check_cb(update_release)
    shown[2].buttons[2].callback()
    local dialog = shown[3]
    probes[1].handlers.on_headers(200, headers(4096))
    flush()
    return dialog
end

-- 下载中可取消：只关窗、取消下载，不回调；之后可以再查。
local downloading = startFromPrompt()
Assert.is_false(downloading.dismissable)
downloading.on_cancel()
Assert.is_true(download_handle.cancelled)
Assert.is_nil(select(2, check(update_release)))

-- 下载完换成不可关闭、没有取消的安装窗；装好直接重启，没有「稍后」。
downloading = startFromPrompt()
download_cb(true)
Assert.eq(closed[#closed], downloading)
local installing = shown[#shown]
Assert.eq(installing.title, "正在安装月读更新…")
Assert.is_false(installing.dismissable)
Assert.is_nil(installing.on_cancel)
job_opts.on_done()
Assert.eq(installing.status, "更新完成，正在重启 KOReader…")
Assert.eq(restarted, 0)
flush()
Assert.eq(restarted, 1)

-- 直连包校验不过：提示中文原因，不带堆栈。
downloading = startFromPrompt()
download_cb(true)
job_opts.on_failed("update checksum mismatch\nstack traceback:\n\tinstall.lua:61")
Assert.eq(shown[#shown].text, "月读更新失败：更新包校验失败，请稍后再试")

-- 忙时手动检查：提示中文原因。
shown = {}
Update.check(function() end)
local pending_check = check_cb
Update.manualCheck("/plugins/book.koplugin")
Assert.eq(shown[#shown].text, "检查更新失败：正在检查或安装更新，请稍候")
pending_check(update_release)

-- 自动检查：没连网不发请求；连上后照常查。
local settings = require("utils.settings").get("features.update")
settings.auto_update_check, settings.update_last_checked_at = true, 0
connected = false
local before = gets
Update.autoCheck("/plugins/book.koplugin")
Assert.eq(gets, before)
connected = true
Update.autoCheck("/plugins/book.koplugin")
Assert.eq(gets, before + 1)
check_cb(release("v1.2.3"))

-- 远程上传的包：不带校验值装包，成败都删包；错误只留首行。
local function tempArchive()
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write("zip")
    f:close()
    return path
end
local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end
local archive_ok, archive_err
local archive = tempArchive()
Update.installArchive(archive, "/plugins/book.koplugin", function(ok, e) archive_ok, archive_err = ok, e end)
job_worker()
Assert.eq(install_args.archive, archive)
Assert.eq(install_args.root, "/plugins/book.koplugin")
Assert.is_nil(install_args.sha)
-- 装包期间在线更新与再次上传都是忙。
local check_err
Update.check(function(_, e) check_err = e end)
Assert.eq(check_err, "busy")
local busy_archive = tempArchive()
local busy_ok, busy_err
Update.installArchive(busy_archive, "/plugins/book.koplugin", function(ok, e) busy_ok, busy_err = ok, e end)
Assert.is_false(busy_ok)
Assert.eq(busy_err, "busy")
Assert.is_false(exists(busy_archive))
job_opts.on_done()
Assert.is_true(archive_ok)
Assert.is_nil(archive_err)
Assert.is_false(exists(archive))

archive = tempArchive()
Update.installArchive(archive, "/plugins/book.koplugin", function(ok, e) archive_ok, archive_err = ok, e end)
job_opts.on_failed("not a moon plugin archive\nstack traceback:\n\tinstall.lua:1")
Assert.is_false(archive_ok)
Assert.eq(archive_err, "not a moon plugin archive")
Assert.is_false(exists(archive))

-- fork 失败同步回调：不能留下「忙」。
fork_fails = true
Update.installArchive(tempArchive(), "/plugins/book.koplugin", function(ok, e) archive_ok, archive_err = ok, e end)
fork_fails = false
Assert.eq(archive_err, "fork failed")
Assert.is_nil(Update._job)

return true
