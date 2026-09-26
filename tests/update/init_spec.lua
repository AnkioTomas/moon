--[[-- update.init：版本比较、Release 资产约束与更新日志展示。 --]]

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
package.preload["ui/widget/confirmbox"] = function() return { new = function(_, opts) return opts end } end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, opts) return opts end } end
package.preload["ui/widget/textviewer"] = function()
    return {
        new = function(_, opts)
            function opts:onClose()
                closed[#closed + 1] = self
            end
            return opts
        end,
    }
end
package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            function opts:close() closed[#closed + 1] = self end
            function opts:reportProgress(bytes) self.progress = bytes end
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
    return { save = function() end }
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
package.preload["update.install"] = function() return { MAX_ARCHIVE_BYTES = 100 } end
package.preload["bookversion"] = function() return "1.2.3" end

local Update = require("update.init")

Assert.is_true(Update._newer("1.2.4", "1.2.3"))
Assert.is_true(Update._newer("2.0.0", "1.9.9"))
Assert.is_false(Update._newer("1.2.3", "1.2.3"))
Assert.is_false(Update._newer("1.2.2", "1.2.3"))

Assert.is_nil(Update._formatNotes(nil))
Assert.is_nil(Update._formatNotes(""))
Assert.is_nil(Update._formatNotes("   "))

local notes = Update._formatNotes([[
## 月读 v1.2.4

安装：解压后复制到 plugins。

### 更新内容

相对上一版本 `v1.2.3`：

#### 新功能

- :sparkles: (update): 显示更新日志 (abc1234)
- :bug: (ui): 修弹窗 (def5678)

### 完整对比

https://github.com/AnkioTomas/moon/compare/v1.2.3...v1.2.4
]])
Assert.not_nil(notes)
Assert.matches(notes, "相对上一版本 v1.2.3")
Assert.matches(notes, "新功能")
Assert.matches(notes, "%(update%): 显示更新日志")
Assert.matches(notes, "%(ui%): 修弹窗")
Assert.is_nil(notes:find("安装：", 1, true))
Assert.is_nil(notes:find("完整对比", 1, true))
Assert.is_nil(notes:find(":sparkles:", 1, true))
Assert.is_nil(notes:find("https://github.com", 1, true))

local hash = string.rep("a", 64)
local release = {
    tag_name = "v1.2.4",
    body = "## 月读 v1.2.4\n\n### 更新内容\n\n- :sparkles: hello\n",
    assets = {
        {
            name = "book.koplugin-v1.2.4.zip",
            browser_download_url = "https://github.com/AnkioTomas/moon/releases/download/v1.2.4/book.koplugin-v1.2.4.zip",
            digest = "sha256:" .. hash,
            size = 2048,
        },
    },
}
local parsed, err = Update._parseRelease(release)
Assert.not_nil(parsed, err)
Assert.eq(parsed.version, "1.2.4")
Assert.eq(parsed.sha256, hash)
Assert.eq(parsed.size, 2048)
Assert.is_true(parsed.available)
Assert.matches(parsed.notes, "hello")
Assert.is_nil(parsed.notes:find(":sparkles:", 1, true))

release.assets[1].digest = nil
local missing, missing_err = Update._parseRelease(release)
Assert.is_nil(missing)
Assert.matches(missing_err, "checksum")

release.assets[2] = {
    name = "book.koplugin-v1.2.4.zip.sha256",
    browser_download_url = "https://github.com/AnkioTomas/moon/releases/download/v1.2.4/book.koplugin-v1.2.4.zip.sha256",
}
parsed, err = Update._parseRelease(release)
Assert.not_nil(parsed, err)
Assert.eq(parsed.checksum_url, release.assets[2].browser_download_url)

-- 同名资产若跳到任意主机，不能拿来更新。
release.assets[1].browser_download_url = "https://example.com/book.koplugin-v1.2.4.zip"
local foreign, foreign_err = Update._parseRelease(release)
Assert.is_nil(foreign)
Assert.matches(foreign_err, "plugin archive")

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
local function headers(length)
    return { get = function() return length and tostring(length) or nil end }
end
local direct = update_release.assets[1].browser_download_url

prompt.buttons_table[1][2].callback()
Assert.eq(closed[2], prompt)
Assert.eq(shown[3].title, "正在下载月读更新…")
Assert.eq(shown[3].progress_max, 4096)

-- 直连 + 5 个随机镜像并发探测；镜像地址 = 前缀 + github.com 之后的路径。
Assert.len(probes, 6)
Assert.eq(probes[1].url, direct)
for i = 2, 6 do
    Assert.matches(probes[i].url, "/AnkioTomas/moon/releases/download/v1%.2%.4/book%.koplugin%-v1%.2%.4%.zip$")
    Assert.is_true(probes[i].url ~= direct)
end

-- 非 200、长度对不上的都不算胜出。
probes[2].handlers.on_headers(302, headers())
probes[3].handlers.on_headers(200, headers(1))
flush()
Assert.is_nil(download_opts)

-- 最先回合格响应头的镜像胜出，其余探测全部取消。
probes[4].handlers.on_headers(200, headers(4096))
probes[5].handlers.on_headers(200, headers())
flush()
Assert.eq(download_opts.url, probes[4].url)
for _, probe in ipairs(probes) do Assert.is_true(probe.cancelled) end
download_opts.on_progress(1024)
Assert.eq(shown[3].progress, 1024)

-- 镜像给的包校验不过：回落直连重下。
download_cb(true)
job_opts.on_failed("install.lua:1: update checksum mismatch")
Assert.eq(download_opts.url, direct)
download_cb(false, "network failed")
Assert.eq(closed[3], shown[3])
Assert.matches(shown[4].text, "network failed")

-- 探测全部失败：直接走直连。
local parsed_update = Update._parseRelease(update_release)
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
