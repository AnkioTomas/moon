--[[-- update.init：版本比较、Release 资产约束与更新日志展示。 --]]

local Assert = require("support.assert")

local shown, closed = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget) closed[#closed + 1] = widget end,
    }
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
package.preload["http.request"] = function()
    return {
        get = function(_, _, cb)
            check_cb = cb
            return { cancel = function() end }
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
package.preload["workers.job"] = function() return {} end
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
prompt.buttons_table[1][2].callback()
Assert.eq(closed[2], prompt)
Assert.eq(shown[3].title, "正在下载月读更新…")
Assert.eq(shown[3].progress_max, 4096)
download_opts.on_progress(1024)
Assert.eq(shown[3].progress, 1024)
download_cb(false, "network failed")
Assert.eq(closed[3], shown[3])
Assert.matches(shown[4].text, "network failed")

return true
