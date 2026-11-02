--[[--
source.kavita.kamare_update：kamare 目标描述（只问 api.github.com、探测已装版本、装到 kamare 目录）。流程本身由 features.update 的 spec 覆盖。

@module tests.source.kavita.kamare_update_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

local shown, closed, ticks = {}, {}, {}
local restarted = 0
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    }
end
local function flush()
    while #ticks > 0 do table.remove(ticks, 1)() end
end
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
package.preload["json"] = function()
    return { decode = function(value) return value end }
end
package.preload["utils.log"] = function()
    return { warn = function() end, dbg = function() end, info = function() end }
end
package.preload["utils.paths"] = function()
    return {
        ensureDir = function() return true end,
        root = function() return "/tmp" end,
    }
end

-- 探测结果与安装根目录由用例控制。
local probe_result = { ok = false, state = "missing" }
local plugins_dir = "/fake/plugins"
package.preload["source.kavita.cache"] = function()
    return {
        probe = function() return probe_result end,
        pluginsDir = function() return plugins_dir end,
    }
end

local function dialogModule()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            function opts:close() closed[#closed + 1] = self end
            return opts
        end,
    }
end
package.preload["ui.themes.widgets.text_viewer"] = dialogModule
package.preload["ui.themes.widgets.toast"] = dialogModule
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            function opts:close() closed[#closed + 1] = self end
            function opts:bytes(done, total)
                self.progress, self.progress_max = done, total
            end
            function opts:set(text, percent)
                self.status, self.percent = text, percent
            end
            return opts
        end,
    }
end

local check_cbs, gets = {}, 0
local download_cb, download_opts
package.preload["http.request"] = function()
    return {
        get = function(url, _, cb)
            gets = gets + 1
            check_cbs[#check_cbs + 1] = { url = url, cb = cb }
            return { cancel = function() end }
        end,
        download = function(opts, _, cb)
            download_opts, download_cb = opts, cb
            return { cancel = function() end }
        end,
    }
end
local pick_calls = 0
package.preload["http.release"] = function()
    return {
        pick = function(release, cb)
            pick_calls = pick_calls + 1
            cb(release.url)
            return { cancel = function() end }
        end,
    }
end

local job_opts, job_worker
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            job_worker, job_opts = worker, opts
            return { cancel = function() end }
        end,
    }
end
local install_args
package.preload["utils.plugin_install"] = function()
    return {
        run = function(archive, parent, sha, opts)
            install_args = { archive = archive, parent = parent, sha = sha, opts = opts }
            return true, "kamare.koplugin"
        end,
    }
end
package.preload["utils.restart"] = function()
    return { now = function() restarted = restarted + 1 end }
end

local Kamare = require("source.kavita.kamare_update")

local hash = string.rep("a", 64)
local direct = "https://github.com/backtracker/kamare.koplugin/releases/download/v0.10.4/kamare.koplugin.zip"
local function release(tag, digest)
    local asset = {
        name = "kamare.koplugin.zip",
        browser_download_url = "https://github.com/backtracker/kamare.koplugin/releases/download/"
            .. tag .. "/kamare.koplugin.zip",
        size = 2048,
    }
    if digest ~= false then asset.digest = "sha256:" .. hash end
    return { tag_name = tag, body = "## 新增\n\n- **蓝牙翻页器**\n", assets = { asset } }
end

---@return table|nil, any
local function check(response)
    local got, got_err
    check_cbs = {}
    Kamare:check(function(r, e) got, got_err = r, e end)
    for _idx, entry in ipairs(check_cbs) do entry.cb(response) end
    flush()
    return got, got_err
end

-- 版本和 digest 先问 api.ankio.net 的转发。
check_cbs = {}
Kamare:check(function() end)
Assert.eq(#check_cbs, 1)
Assert.eq(check_cbs[1].url, "https://api.ankio.net/gh/repos/backtracker/kamare.koplugin/releases/latest")
check_cbs[1].cb(release("v0.10.4"))
flush()

-- 已装版本来自探测；没装 / 官方版同版本也要提示安装。
probe_result = { ok = true, state = "enhanced", version = "0.10.4-dev" }
local parsed = check(release("v0.10.4"))
Assert.eq(parsed.installed, "0.10.4-dev")
Assert.eq(parsed.sha256, hash)
Assert.is_true(parsed.available, "开发版低于同号正式版")
probe_result = { ok = true, state = "enhanced", version = "0.10.4" }
Assert.is_false(check(release("v0.10.4")).available)
probe_result = { ok = false, state = "official", version = "0.10.4" }
Assert.is_true(check(release("v0.10.4")).available)
Assert.is_nil(check(release("v0.10.4", false)).sha256, "kamare 的 digest 可选")

-- 已是最新：toast 带 kamare 前缀；没装：安装提示。
local function startCheck(response)
    shown, closed = {}, {}
    check_cbs = {}
    Kamare:manualCheck(nil)
    for _idx, entry in ipairs(check_cbs) do entry.cb(response) end
    flush()
end
probe_result = { ok = true, state = "enhanced", version = "0.10.4" }
startCheck(release("v0.10.4"))
Assert.matches(shown[#shown].text, "已是最新版本（kamare 0%.10%.4）")
probe_result = { ok = false, state = "missing" }
startCheck(release("v0.10.4"))
local prompt = shown[#shown]
Assert.eq(prompt.title, "更新 kamare")
Assert.matches(prompt.text, "当前未安装可用的 kamare 增强版")

-- 装到 kamare 当前所在目录，带目录名；没有 digest 只直连。
plugins_dir = "/mnt/us/koreader/plugins"
prompt.buttons[2].callback()
Assert.eq(download_opts.url, direct)
download_cb(true)
job_worker()
Assert.eq(install_args.sha, hash)
Assert.eq(install_args.opts.name, "kamare.koplugin")
Assert.eq(install_args.parent, plugins_dir)
job_opts.on_done()
flush()
Assert.eq(restarted, 1)

local nosha = check(release("v0.10.4", false))
pick_calls = 0
Kamare:install(nosha, nil, function() end)
Assert.eq(pick_calls, 0, "没有 digest 不走镜像")

return true
