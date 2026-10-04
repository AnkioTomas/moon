---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.update：版本比较、Release 资产约束与更新日志展示。 --]]

local Assert = require("support.assert")

local shown, closed, ticks = {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget) closed[#closed + 1] = widget end,
        nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    }
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
            return opts
        end,
    }
end
package.preload["device"] = function()
    return { screen = { getHeight = function() return 800 end } }
end
package.preload["json"] = function() return { decode = function(value) return value end } end
local check_cb, download_cb, download_opts
local probes = {}
package.preload["http.request"] = function()
    return {
        get = function(_, _, cb)
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
            return { cancel = function() end }
        end,
    }
end
package.preload["utils.paths"] = function()
    return { ensureSettings = function() end, root = function() return "/tmp" end }
end
package.preload["utils.settings"] = function()
    local update = { auto_update_check = false, update_last_checked_at = 0 }
    return {
        feature = function(name) assert(name == "update"); return update end,
        saveSection = function(name) assert(name == "update") end,
    }
end
local job_opts
package.preload["workers.job"] = function()
    return {
        run = function(_, opts)
            job_opts = opts
            return { cancel = function() end }
        end,
    }
end
package.preload["features.update.install"] = function() return {} end
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
job_opts.on_failed("install.lua:1: update checksum mismatch")
Assert.eq(download_opts.url, direct)
download_cb(false, "network failed")
Assert.eq(closed[3], shown[3])
Assert.matches(shown[4].text, "network failed")

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

return true
