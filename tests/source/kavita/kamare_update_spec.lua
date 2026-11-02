--[[--
source.kavita.kamare_update：GitHub Release 查询、版本比较、镜像回落与安装到插件目录。

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
local pick_url = nil
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
            cb(pick_url or release.url)
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
        run = function(archive, root, sha, opts)
            install_args = { archive = archive, root = root, sha = sha, opts = opts }
            return true, "kamare.koplugin"
        end,
    }
end
package.preload["utils.restart"] = function()
    return { now = function() restarted = restarted + 1 end }
end

local Kamare = require("source.kavita.kamare_update")

local hash = string.rep("a", 64)
local function release(tag, digest)
    local asset = {
        name = "kamare.koplugin.zip",
        browser_download_url = "https://github.com/backtracker/kamare.koplugin/releases/download/"
            .. tag .. "/kamare.koplugin.zip",
        size = 2048,
    }
    if digest ~= false then asset.digest = "sha256:" .. hash end
    return {
        tag_name = tag,
        body = "## 新增\n\n- **蓝牙翻页器**\n- 修复 `缓存` 清理\n",
        assets = { asset },
    }
end

---@return table|nil, any
local function check(response)
    local got, got_err
    check_cbs = {}
    Kamare.check(function(r, e) got, got_err = r, e end)
    for _idx, entry in ipairs(check_cbs) do entry.cb(response) end
    flush()
    return got, got_err
end

-- 直连与 API 镜像并发查：任何一个先解析出 Release 就够。
do
    local got
    check_cbs = {}
    Kamare.check(function(r) got = r end)
    Assert.eq(#check_cbs, 4, "直连 + 3 个 API 镜像")
    Assert.matches(check_cbs[1].url, "^https://api%.github%.com/")
    for i = 2, 4 do Assert.matches(check_cbs[i].url, "^https://[^/]+/https://api%.github%.com/") end
    check_cbs[2].cb(release("v0.10.4"))
    flush()
    Assert.not_nil(got)
end

-- 全部失败才报错。
do
    local got_err
    check_cbs = {}
    Kamare.check(function(_r, e) got_err = e end)
    for _idx, entry in ipairs(check_cbs) do entry.cb(nil, "HTTP 403") end
    flush()
    Assert.eq(got_err, "HTTP 403")
end

-- 版本比较：正式版 > 开发版，同版本不重复提示。
probe_result = { ok = true, state = "enhanced", version = "0.10.0-dev" }
local parsed = check(release("v0.10.4"))
Assert.not_nil(parsed)
Assert.eq(parsed.version, "0.10.4")
Assert.eq(parsed.sha256, hash)
Assert.eq(parsed.size, 2048)
Assert.eq(parsed.installed, "0.10.0-dev")
Assert.is_true(parsed.available)
probe_result = { ok = true, state = "enhanced", version = "0.10.4" }
Assert.is_false(check(release("v0.10.4")).available)
Assert.is_true(check(release("v0.10.5")).available)
probe_result = { ok = true, state = "enhanced", version = "0.10.4-dev" }
Assert.is_true(check(release("v0.10.4")).available, "开发版低于同号正式版")

-- 官方版 / 不兼容 / 未安装：同版本也要提示安装增强版。
probe_result = { ok = false, state = "official", version = "0.10.4" }
Assert.is_true(check(release("v0.10.4")).available)

-- 校验值可选；地址不在本仓库 Release 下就拒绝。
Assert.is_nil(check(release("v0.10.4", false)).sha256)
local foreign = release("v0.10.4")
foreign.assets[1].browser_download_url = "https://example.com/kamare.koplugin.zip"
local foreign_release, foreign_err = check(foreign)
Assert.is_nil(foreign_release)
Assert.matches(foreign_err, "plugin archive")
local draft = release("v0.10.4")
draft.draft = true
Assert.matches(select(2, check(draft)), "invalid release response")

----------------------------------------------------------------------
-- 检查 → 确认 → 下载 → 安装 → 重启
----------------------------------------------------------------------
local function startCheck(response)
    shown, closed = {}, {}
    check_cbs = {}
    Kamare.start(nil)
    for _idx, entry in ipairs(check_cbs) do entry.cb(response) end
    flush()
end

-- 没连网不发请求。
connected = false
shown = {}
local before = gets
Kamare.start(nil)
Assert.eq(gets, before)
Assert.matches(shown[1].text, "网络不可用")

connected = true
probe_result = { ok = true, state = "enhanced", version = "0.10.4" }
startCheck(release("v0.10.4"))
Assert.eq(shown[1].title, "检查更新")
Assert.matches(shown[#shown].text, "已是最新版本（kamare 0%.10%.4）")

probe_result = { ok = true, state = "enhanced", version = "0.10.0" }
startCheck(release("v0.10.4"))
Assert.eq(shown[1].text, "正在检查 kamare 更新…")
local prompt = shown[#shown]
Assert.eq(prompt.title, "更新 kamare")
Assert.matches(prompt.text, "kamare 0%.10%.4")
Assert.matches(prompt.text, "当前 0%.10%.0")
Assert.matches(prompt.text, "蓝牙翻页器", "确认框带更新说明")
Assert.matches(prompt.text, "修复 缓存 清理", "更新说明去掉 Markdown 标记")
Assert.is_nil(prompt.text:find("##", 1, true))

probe_result = {
    ok = true, state = "enhanced", version = "0.10.0",
    path = "/mnt/us/koreader/plugins/kamare.koplugin/kamarecache.lua",
}
plugins_dir = "/mnt/us/koreader/plugins"
prompt.buttons[2].callback()
local downloading = shown[#shown]
Assert.eq(downloading.title, "正在下载 kamare 更新…")
Assert.eq(download_opts.url,
    "https://github.com/backtracker/kamare.koplugin/releases/download/v0.10.4/kamare.koplugin.zip")
Assert.eq(download_opts.max_bytes, 100 * 1024 * 1024)
download_opts.on_progress(1024)
Assert.eq(downloading.progress, 1024)
Assert.eq(downloading.progress_max, 2048)

-- 下载完换安装窗；装到 kamare 当前目录，带校验值与目录名。
download_cb(true)
Assert.eq(closed[#closed], downloading)
Assert.eq(shown[#shown].title, "正在安装 kamare 更新…")
job_worker()
Assert.eq(install_args.sha, hash)
Assert.eq(install_args.opts.name, "kamare.koplugin")
Assert.eq(install_args.opts.parent, plugins_dir)
job_opts.on_done()
Assert.eq(shown[#shown].status, "更新完成，正在重启 KOReader…")
flush()
Assert.eq(restarted, 1)

----------------------------------------------------------------------
-- 镜像下载失败 / 校验失败回落直连
----------------------------------------------------------------------
local install_ok, install_err
pick_url = "https://gh-proxy.example/https://github.com/backtracker/kamare.koplugin/releases/download/v0.10.4/kamare.koplugin.zip"
local direct = "https://github.com/backtracker/kamare.koplugin/releases/download/v0.10.4/kamare.koplugin.zip"
local rel = check(release("v0.10.4"))

-- 镜像下载失败：直接换直连。
Kamare.install(rel, nil, function(ok, err) install_ok, install_err = ok, err end)
Assert.eq(download_opts.url, pick_url)
download_cb(false, "mirror reset")
Assert.eq(download_opts.url, direct, "镜像失败回落直连")
download_cb(true)
job_opts.on_done()
Assert.is_true(install_ok)
Assert.is_nil(install_err)

-- 镜像包校验失败：删包后回落直连重下。
Kamare.install(rel, nil, function(ok, err) install_ok, install_err = ok, err end)
download_cb(true)
job_opts.on_failed("update checksum mismatch")
Assert.eq(download_opts.url, direct, "镜像包校验失败回落直连重下")
download_cb(true)
job_opts.on_done()
Assert.is_true(install_ok)
Assert.is_nil(install_err)

-- 直连包校验失败不再重试。
pick_url = nil
Kamare.install(rel, nil, function(ok, err) install_ok, install_err = ok, err end)
download_cb(true)
job_opts.on_failed("update checksum mismatch\nstack traceback: ...")
Assert.is_false(install_ok)
Assert.matches(install_err, "checksum mismatch")

-- 没有 digest：不信任镜像，直接走 GitHub。
local nosha = check(release("v0.10.4", false))
pick_calls = 0
Kamare.install(nosha, nil, function(ok, err) install_ok, install_err = ok, err end)
Assert.eq(pick_calls, 0)
Assert.eq(download_opts.url, direct)
download_cb(false, "direct failed")
Assert.is_false(install_ok)
Assert.eq(install_err, "direct failed")

-- 忙时再点：提示中文原因。
shown = {}
check_cbs = {}
Kamare.check(function() end)
Kamare.start(nil)
Assert.matches(shown[#shown].text, "正在检查或安装更新，请稍候")
for _idx, entry in ipairs(check_cbs) do entry.cb(release("v0.10.4")) end
flush()

return true
