--[[--
Kavita 设置页：服务器 / API Key / 书库 / 漫画缓存 / 进度心跳 / 请求超时 / 连接测试。

@module tests.extensions.kavita.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

local cfg = {}
local saved = 0
local reloaded = 0
local events = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_, value)
            cfg = value
            saved = saved + 1
            events[#events + 1] = "save"
        end,
    }
end
package.preload["source.registry"] = function()
    return { reload = function() reloaded = reloaded + 1 end }
end
-- 源模块只在设置行里读两个默认值；真常量由 client_spec / source_spec 钉住。
-- 「测试连接」还要走 client:request，返回内容由 request_reply 控制。
local request_reply = { version = "0.9.0" }
package.preload["moonsource_kavita.client"] = function()
    return {
        DEFAULT_TIMEOUT = 60,
        new = function()
            return {
                api_key = "k",
                configured = function() return true end,
                request = function(_, _method, _path, _query, _body, callback)
                    callback(request_reply.version, request_reply.err)
                end,
            }
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
-- 同步删除的忙碌窗会先强制重绘再动手；占用统计在下一拍算（03 E），测试里手动 flush。
local repaints = 0
local pending_ticks = {}
local function flush()
    while #pending_ticks > 0 do
        local tick = table.remove(pending_ticks, 1)
        tick()
    end
end
package.preload["ui/uimanager"] = function()
    return {
        forceRePaint = function() repaints = repaints + 1 end,
        nextTick = function(_, fn) pending_ticks[#pending_ticks + 1] = fn end,
    }
end
package.preload["moonsource_kavita.source"] = function()
    return { DEFAULT_HEARTBEAT_INTERVAL = 30 }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.loaded["ui.themes"] = nil
package.preload["ui.themes"] = function()
    return {
        current = function()
            return { space = { md = 8 }, color = { muted = 1, page = 2 } }
        end,
        px = function(n) return n end,
    }
end
package.loaded["ui/geometry"] = nil
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.loaded["ui/widget/container/centercontainer"] = nil
package.preload["ui/widget/container/centercontainer"] = function()
    return { new = function(_, opts) return opts end }
end
package.loaded["ui/themes/widgets/text"] = nil
package.preload["ui/themes/widgets/text"] = function()
    return {
        box = function(_, text, _width, _opts)
            return { text = text, getSize = function() return { h = 10 } end }
        end,
    }
end

-- 缓存适配层：探测 / 详情 / 保存后镜像；真实现由 cache_spec 钉住。
local probe_result = { ok = false, state = "missing" }
local mirror_failed = false
local reprobed = 0
local register_calls, register_ok = {}, true
local available = {}
local summary_result
local summary_all_result
local chapters_result = {}
local delete_calls, delete_all_calls = {}, 0
local delete_ok, delete_code = true, nil
local delete_all_ok, delete_all_code, delete_all_detail = true, nil, nil
-- 占用 / 计划只在详情页各取一次（06 B 的「占用只算一次」）。
local summary_calls, summary_all_calls, chapters_calls = 0, 0, 0
package.preload["moonsource_kavita.cache"] = function()
    return {
        probe = function() return probe_result end,
        reprobe = function()
            reprobed = reprobed + 1
            return probe_result
        end,
        mirrorFailed = function() return mirror_failed end,
        registerServer = function(base_url, api_key)
            register_calls[#register_calls + 1] = { base_url = base_url, api_key = api_key }
            events[#events + 1] = "register"
            if register_ok then return "srv-1" end
            return nil, "settings_write_failed"
        end,
        available = function(cap) return available[cap] == true end,
        summary = function()
            summary_calls = summary_calls + 1
            return summary_result
        end,
        summaryAll = function()
            summary_all_calls = summary_all_calls + 1
            return summary_all_result
        end,
        chapters = function()
            chapters_calls = chapters_calls + 1
            return chapters_result
        end,
        plan = function(entries, filter, toc_read)
            local out = { chapters = 0, bytes = 0, ids = {}, queued = 0, open = false }
            for __, entry in ipairs(entries or {}) do
                local pages = tonumber(entry.pages) or 0
                local server = toc_read and (tonumber(toc_read[tostring(entry.chapterId)]) or 0) or 0
                local read = entry.read == true or (pages > 0 and server >= pages)
                if filter ~= "read" or read then
                    out.chapters = out.chapters + 1
                    out.bytes = out.bytes + (tonumber(entry.bytes) or 0)
                    out.ids[#out.ids + 1] = entry.chapterId
                    if entry.queued then out.queued = out.queued + 1 end
                    if entry.open then out.open = true end
                end
            end
            return out
        end,
        delete = function(ids)
            delete_calls[#delete_calls + 1] = ids
            if not delete_ok then return nil, delete_code, "nope" end
            local wanted = {}
            for __, id in ipairs(ids or {}) do wanted[tostring(id)] = true end
            local kept = {}
            for __, entry in ipairs(chapters_result) do
                if not wanted[tostring(entry.chapterId)] then kept[#kept + 1] = entry end
            end
            chapters_result = kept
            return true
        end,
        deleteAll = function()
            delete_all_calls = delete_all_calls + 1
            if delete_all_ok then return true, nil, nil, delete_all_detail end
            return nil, delete_all_code, "nope"
        end,
        resetShelf = function() end,
        capabilityNames = function(caps, separator)
            local names = {}
            for name, on in pairs(caps or {}) do
                if on == true then names[#names + 1] = tostring(name) end
            end
            table.sort(names)
            return #names > 0 and table.concat(names, separator or ",") or "none"
        end,
        sizeText = function(bytes)
            local value = tonumber(bytes)
            if not value then return "未知" end
            return string.format("%.1f MB", value / (1024 * 1024))
        end,
    }
end
local Themed = require("support.theme_stubs")
Themed.install()

local Config = require("support.config")
local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
package.preload["moonsource_kavita.setting"] = function()
    return dofile(PLUGIN .. "/moonsource_kavita/setting.lua")
end
package.preload["moonsource_kavita.busy"] = function()
    return dofile(PLUGIN .. "/moonsource_kavita/busy.lua")
end

local overlays, shelf_events, overlay_updates = {}, {}, 0
local fake_desktop = {
    settings_overlay = nil,
    onEvent = function(_, event) shelf_events[#shelf_events + 1] = event end,
}
package.preload["desktop.pages.setting.overlay"] = function()
    return {
        push = function(desktop, spec)
            overlays[#overlays + 1] = spec
            desktop.settings_overlay = {
                updateView = function() overlay_updates = overlay_updates + 1 end,
            }
        end,
    }
end

local Setting = require("moonsource_kavita.setting")

local rows = Setting.rows({ path = PLUGIN, desktop = fake_desktop })
-- 顺序用文案钉住（索引不再稳定），「漫画缓存」插在「书库」之后。
local titles = {}
for _idx, make in ipairs(rows) do titles[#titles + 1] = make(600).title end
Assert.eq(#rows, 7, "服务器 / API Key / 书库 / 漫画缓存 / 进度心跳 / 请求超时 / 连接测试")
Assert.eq(table.concat(titles, "|"),
    "服务器地址|API Key|书库|漫画缓存|进度心跳间隔|请求超时|测试连接",
    "「漫画缓存」紧跟「书库」")

-- 03 原型的三块分组：连接 / 缓存与同步 / 诊断。
local sections = Setting.sections({ path = PLUGIN, desktop = fake_desktop })
Assert.eq(#sections, 3, "设置页分三块")
local grouped = {}
for _idx, section in ipairs(sections) do
    local names = {}
    for _row_idx, make in ipairs(section.rows) do names[#names + 1] = make(600).title end
    grouped[#grouped + 1] = section.title .. ":" .. table.concat(names, ",")
end
Assert.eq(table.concat(grouped, "|"),
    "连接:服务器地址,API Key,书库|缓存与同步:漫画缓存,进度心跳间隔,请求超时|诊断:测试连接",
    "分组与原型一致，扁平的 rows 顺序不变")

--- 按标题找行（索引会随增删漂移）。
---@param title string
---@return table
local function rowAt(title)
    for _idx, make in ipairs(rows) do
        local row = make(600)
        if row.title == title then return row end
    end
    error("没有这一行: " .. title)
end

Assert.eq(Setting.remote[1].key, "base_url")
Assert.eq(Setting.remote[2].key, "api_key")
Assert.is_true(Setting.remote[2].secret)
-- 远程管理网页表单只含连接配置；开关要在设备上调。
Assert.len(Setting.remote, 2, "远程管理表单只有服务器地址与 API Key")

-- 进度心跳：默认 30 秒，可调；0 = 关闭阅读期心跳。
local hb = rowAt("进度心跳间隔")
Assert.eq(hb.kind, "nav")
Assert.eq(hb.status, "30 秒")
Assert.is_true(hb.status_on)
-- 副标题单行截断（行里有状态 + 箭头，文字位很窄），必须短到放得下；「为什么」在输入框提示里。
Assert.eq(hb.subtitle, "阅读时补推进度，0 关闭")
hb.callback()
local input = Themed.last("input")
Assert.eq(input.fields[1].text, "30")
Assert.eq(input.fields[1].input_type, "number")
input.callback("120")
Assert.eq(cfg.heartbeat_interval, 120)
Assert.eq(rowAt("进度心跳间隔").status, "120 秒")
Assert.eq(input.shown and saved, 1, "保存一次")

input.callback("0")
Assert.eq(cfg.heartbeat_interval, 0, "0 落盘成关闭")
local off = rowAt("进度心跳间隔")
Assert.eq(off.status, "已关闭")
Assert.is_false(off.status_on)

input.callback("")
Assert.is_nil(cfg.heartbeat_interval, "空输入回默认值")

-- 请求超时：默认 60 秒，可调大（慢设备拉书架）。
local to = rowAt("请求超时")
Assert.eq(to.status, "60 秒")
Assert.is_false(to.status_on, "默认值不高亮")
to.callback()
input = Themed.last("input")
input.callback("180")
Assert.eq(cfg.timeout, 180)
Assert.eq(rowAt("请求超时").status, "180 秒")
Assert.is_true(rowAt("请求超时").status_on)

Assert.eq(saved, 4)
Assert.eq(reloaded, 4, "每次保存都重建源实例，新配置立即生效")

----------------------------------------------------------------------
-- 漫画缓存：七态（含旧接口/镜像失败）+ 只读详情 + 09 手动安装说明。
----------------------------------------------------------------------
local function checkStatus(probe, expected, on, mirror)
    probe_result = probe
    mirror_failed = mirror == true
    local row = rowAt("漫画缓存")
    Assert.eq(row.kind, "nav")
    Assert.eq(row.status, expected)
    Assert.eq(row.status_on, on, expected)
end

checkStatus({ ok = false, state = "missing" }, "未安装 / 未启用", false)
checkStatus({ ok = false, state = "official" }, "官方版（无缓存接口）", false)
checkStatus({ ok = false, state = "incompatible", api_version = 2 }, "版本不兼容", false)
checkStatus({ ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { chapters = true, delete = true, delete_all = true } },
    "增强版 v0.10.0-dev", true)
-- 旧接口：有 kamarecache 但没有 chapters / delete，清理不可用，不高亮。
checkStatus({ ok = true, state = "enhanced", api_version = 1, version = "0.9.22",
    capabilities = { status = true, summary = true } },
    "增强版 v0.9.22（旧接口）", false)
checkStatus({ ok = true, state = "enhanced", api_version = 1 }, "增强版（旧接口）", false)
checkStatus({ ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev" },
    "配置同步失败", false, true)

-- 详情页：状态 → 清理 → 维护；增强态不显示安装说明。
local MB = 1024 * 1024
cfg.base_url, cfg.api_key = "http://kav", "k"
local cache_path = "/fake/plugins/kamare.koplugin/src/kamarecache.lua"
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { open = true, index = true, status = true, summary = true,
        chapters = true, delete = true, delete_all = true },
    path = cache_path,
}
mirror_failed = false
available = { summary = true }
summary_result = { used = 3 * MB, available = 9 * MB, chapters = 12 }
summary_all_result = { used = 4 * MB, available = 9 * MB, chapters = 15 }
chapters_result = {
    { chapterId = 1, pages = 10, bytes = 1 * MB, read = false, queued = false, open = false },
    { chapterId = 2, pages = 10, bytes = 2 * MB, read = true, queued = false, open = false },
}

local function findSection(sections, title)
    for __, section in ipairs(sections or {}) do
        if section.title == title then return section end
    end
end

local function sectionRows(sections, title)
    local section = findSection(sections, title)
    local out = {}
    for i, make in ipairs(section and section.rows or {}) do out[i] = make(600) end
    return out
end

local function statusOf(rows_list, title)
    for __, row in ipairs(rows_list) do
        if row.title == title then return row end
    end
end

--- 最近一次详情页的最终 sections：先取一拍（触发占用统计），flush 后再取一次。
---@return BookThemeSection[]
local function currentSections()
    overlays[#overlays].sections()
    flush()
    return overlays[#overlays].sections()
end

rowAt("漫画缓存").callback()
local page = overlays[#overlays]
Assert.not_nil(page, "详情走叠层，不再用 ConfirmBox")
Assert.eq(page.title, "漫画缓存")
summary_calls, summary_all_calls, chapters_calls = 0, 0, 0
overlay_updates = 0
local pending_sections = page.sections()
Assert.eq(summary_calls + summary_all_calls, 0, "先画「正在统计…」，不在这一拍走盘")
Assert.eq(statusOf(sectionRows(pending_sections, "状态"), "缓存占用").subtitle, "正在统计…")
Assert.eq(chapters_calls, 1, "清理计划一次 chapters() 取全")
flush()
Assert.eq(summary_calls, 1, "下一拍算本服务器占用")
Assert.eq(summary_all_calls, 1, "「清理全部」的合计也算出来")
Assert.eq(overlay_updates, 1, "算完刷新叠层")
local sections = page.sections()
Assert.eq(chapters_calls, 2, "重画不重算占用，只重取计划")
local status_rows = sectionRows(sections, "状态")
Assert.eq(statusOf(status_rows, "版本").status, "0.10.0-dev")
Assert.eq(statusOf(status_rows, "增强版功能").subtitle,
    "缓存（离线阅读与清理） · 双页拆分 · 裁切边框")
Assert.eq(statusOf(status_rows, "加载路径").subtitle, cache_path)
Assert.eq(statusOf(status_rows, "缓存占用").status, "12 章")
Assert.matches(statusOf(status_rows, "缓存占用").subtitle, "已用 3.0 MB，可用 9.0 MB")

local cleanup_rows = sectionRows(sections, "清理")
Assert.eq(cleanup_rows[1].title, "清理已读")
Assert.matches(cleanup_rows[1].subtitle, "1 章")
Assert.eq(cleanup_rows[2].title, "清理本服务器")
Assert.matches(cleanup_rows[2].subtitle, "2 章")
Assert.eq(cleanup_rows[3].title, "清理全部")
Assert.matches(cleanup_rows[3].subtitle, "含未关联服务器 · 15 章", "全部清理用合计，不用本服务器")
Assert.is_nil(findSection(sections, "获取增强版"), "增强态不显示安装说明")

-- 重新检测：原地重建叠层。
sectionRows(sections, "维护")[1].callback()
Assert.eq(reprobed, 1, "重新检测")

-- 清理已读：确认 → 忙碌窗 → 删除 → 复查 → 刷新。
delete_calls = {}
cleanup_rows[1].callback()
local read_confirm = Themed.last("confirm")
Assert.not_nil(read_confirm)
Assert.matches(read_confirm.text, "将删除 1 章")
local repaints_before = repaints
read_confirm.ok_callback()
local busy = Themed.last("progress_dialog")
Assert.not_nil(busy, "同步删除先弹忙碌窗")
Assert.eq(busy.title, "清理已读")
Assert.eq(busy.text, "正在清理…")
Assert.is_true(busy.dismissable == false, "忙碌窗不可关")
Assert.is_true(busy.shown, "先显示再删除")
Assert.is_true(busy.closed, "删完关闭")
Assert.eq(repaints, repaints_before + 1, "删除前强制重绘一次")
Assert.eq(#delete_calls, 1, "清理已读调用一次批量删除")
Assert.eq(#delete_calls[1], 1, "只删已读完的那一章")
Assert.matches(Themed.last("toast").text, "已清理 1 章")
Assert.eq(shelf_events[#shelf_events], "shelf_changed", "删除后刷新书架")

-- 删除后占用必须重算（03 E）：只 updateView 会留下删前的数字。
summary_result = { used = 2 * MB, available = 9 * MB, chapters = 11 }
summary_all_result = { used = 3 * MB, available = 9 * MB, chapters = 14 }
local usage_calls_before = summary_calls + summary_all_calls
local after_cleanup = page.sections()
Assert.eq(statusOf(sectionRows(after_cleanup, "状态"), "缓存占用").subtitle,
    "正在统计…", "删除后先画「正在统计…」")
flush()
Assert.eq(summary_calls + summary_all_calls, usage_calls_before + 2, "删除后重算本服务器与合计")
Assert.eq(statusOf(sectionRows(page.sections(), "状态"), "缓存占用").status,
    "11 章", "占用数字跟着删除刷新")
Assert.matches(sectionRows(page.sections(), "清理")[3].subtitle,
    "含未关联服务器 · 14 章", "清理全部的数字也刷新")

-- 空缓存：三项都置灰（03 待确认 3），清理全部不再可点。
cfg.base_url, cfg.api_key = "http://kav", "k"
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { summary = true, chapters = true, delete = true, delete_all = true },
    path = cache_path,
}
available = { summary = true }
local saved_chapters = chapters_result
chapters_result = {}
summary_result = { used = 0, available = 9 * MB, chapters = 0 }
summary_all_result = { used = 0, available = 9 * MB, chapters = 0 }
rowAt("漫画缓存").callback()
local empty_rows = sectionRows(currentSections(), "清理")
for idx = 1, 3 do
    Assert.is_false(empty_rows[idx].enabled, "空缓存置灰：" .. empty_rows[idx].title)
    Assert.is_false(empty_rows[idx].chevron, "空缓存不显示箭头：" .. empty_rows[idx].title)
    Assert.eq(empty_rows[idx].subtitle, "没有可清理的缓存", "空缓存文案：" .. empty_rows[idx].title)
end
chapters_result = saved_chapters
summary_result = { used = 3 * MB, available = 9 * MB, chapters = 12 }
summary_all_result = { used = 4 * MB, available = 9 * MB, chapters = 15 }

-- 旧接口：不出清理项，只写升级说明；设置行也不承诺清理。
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.9.22",
    capabilities = { status = true, summary = true }, path = cache_path,
}
Assert.eq(rowAt("漫画缓存").subtitle, "状态与获取增强版", "旧接口不承诺清理")
Assert.eq(rowAt("漫画缓存").status, "增强版 v0.9.22（旧接口）")
rowAt("漫画缓存").callback()
local old_rows = sectionRows(currentSections(), "清理")
Assert.eq(#old_rows, 1, "旧接口只有一段说明")
Assert.eq(old_rows[1].title, "当前 kamare 没有清理接口")
Assert.matches(old_rows[1].subtitle, "chapters / delete_all", "说明要升级到什么")
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { open = true, index = true, status = true, summary = true,
        chapters = true, delete = true, delete_all = true },
    path = cache_path,
}

-- 清理全部：没有服务器也能用，确认文案含未关联。
cfg.base_url, cfg.api_key = "", ""
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { summary = true, chapters = true, delete = true, delete_all = true },
    path = cache_path,
}
available = { summary = true }
rowAt("漫画缓存").callback()
summary_all_calls, summary_calls = 0, 0
local unconfigured = currentSections()
Assert.eq(sectionRows(unconfigured, "清理")[1].title, "未配置服务器")
Assert.eq(summary_all_calls, 1, "没有服务器时占用取合计")
Assert.eq(summary_calls, 0, "没有服务器时不查单服务器")
Assert.matches(statusOf(sectionRows(unconfigured, "状态"), "缓存占用").subtitle, "含未关联服务器")
sectionRows(unconfigured, "清理")[2].callback()
local all_confirm = Themed.last("confirm")
Assert.matches(all_confirm.text, "含未关联服务器")
Assert.matches(all_confirm.text, "共 15 章", "确认框用所有服务器的合计，不用本服务器")
all_confirm.ok_callback()
Assert.eq(Themed.last("progress_dialog").title, "清理全部缓存", "全部清理同样有忙碌窗")
Assert.eq(delete_all_calls, 1, "清理全部走 deleteAll")

-- 未安装：安装说明；路径归一；不显示占用。
probe_result = { ok = false, state = "missing" }
available = {}
cfg.base_url = ""
rowAt("漫画缓存").callback()
local missing = currentSections()
local install = findSection(missing, "获取增强版")
Assert.not_nil(install, "非增强态显示安装说明")
local install_text = install.rows[1](600).text or ""
Assert.matches(install_text, "releases/latest")
Assert.matches(install_text, "kamarecache.lua")
Assert.matches(install_text, "增强版提供：缓存")
Assert.matches(install_text, Config.root() .. "/extensions", "moon 自己的插件目录")
Assert.is_nil(findSection(missing, "清理"), "未安装不显示清理")

-- 版本不兼容：安装说明前先讲清 API 不兼容（03 原型）。
probe_result = { ok = false, state = "incompatible", api_version = 2 }
rowAt("漫画缓存").callback()
local incompatible = sectionRows(currentSections(), "版本与获取")
Assert.eq(incompatible[1].title, "版本不兼容")
Assert.matches(incompatible[1].subtitle, "API v2")
Assert.not_nil(incompatible[2].text, "后面仍是安装说明")

-- 镜像失败：状态区给出警告 + 重试同步。
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { summary = true, chapters = true, delete = true, delete_all = true },
    path = "/fake/plugins//kamare.koplugin/kamarecache.lua",
}
mirror_failed = true
available = { summary = true }
rowAt("漫画缓存").callback()
local mirrored = currentSections()
local mirror_row = statusOf(sectionRows(mirrored, "状态"), "配置同步失败")
Assert.not_nil(mirror_row, "镜像失败在状态区")
Assert.eq(mirror_row.status, "重试同步")
Assert.is_nil(statusOf(sectionRows(mirrored, "状态"), "加载路径").subtitle:find("//", 1, true),
    "加载路径归一成单斜杠")
mirror_failed = false

-- 保存后镜像：先落 moon 自己的配置，再 register_server；失败 toast 但不阻断。
cfg.base_url, cfg.api_key = "http://kav", "k"
probe_result = { ok = true, state = "enhanced", api_version = 1, version = "0.10.0" }
register_calls, register_ok, events = {}, true, {}
local before = saved
rowAt("进度心跳间隔").callback()
Themed.last("input").callback("75")
Assert.eq(saved, before + 1)
Assert.eq(register_calls[1].base_url, "http://kav")
Assert.eq(register_calls[1].api_key, "k")
Assert.eq(events[#events - 1], "save", "先存 moon 自己的配置")
Assert.eq(events[#events], "register", "镜像失败也不影响 moon 保存")

register_ok = false
before = saved
rowAt("进度心跳间隔").callback()
Themed.last("input").callback("60")
Assert.eq(Themed.last("toast").text, "无法同步配置到 kamare", "用户主动保存失败要提示")
Assert.eq(saved, before + 1, "toast 不阻断 moon 自己的保存")

-- 未安装：不假装能镜像。
probe_result = { ok = false, state = "missing" }
register_calls = {}
rowAt("进度心跳间隔").callback()
Themed.last("input").callback("30")
Assert.len(register_calls, 0, "没有缓存接口时跳过镜像")

----------------------------------------------------------------------
-- 测试连接：服务器连得上 ≠ 缓存可用，顺手报 kamare 状态。
----------------------------------------------------------------------
Assert.eq(rowAt("测试连接").kind, "action")
Assert.eq(rowAt("测试连接").subtitle, "同时检查漫画缓存插件")

---@param probe table
---@param mirror boolean|nil
---@param version string|nil
---@param err string|nil
---@return string
local function connectToast(probe, mirror, version, err)
    probe_result = probe
    mirror_failed = mirror == true
    request_reply = { version = version, err = err }
    rowAt("测试连接").callback()
    return Themed.last("toast").text
end

local enhanced = { ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { chapters = true, delete = true, delete_all = true } }
Assert.eq(connectToast(enhanced, false, "0.9.0"),
    "连接正常\nKavita 0.9.0\nkamare 增强版 v0.10.0-dev")
Assert.eq(connectToast({ ok = true, state = "enhanced", api_version = 1, version = "0.9.22" },
        false, "0.9.0"),
    "连接正常\nKavita 0.9.0\nkamare 增强版 v0.9.22（旧接口）")
Assert.eq(connectToast(enhanced, true, "0.9.0"),
    "连接正常\nKavita 0.9.0\nkamare 配置同步失败")
Assert.eq(connectToast({ ok = false, state = "missing" }, false, "0.9.0"),
    "连接正常\nKavita 0.9.0\nkamare 未安装 / 未启用")
Assert.eq(connectToast({ ok = false, state = "official" }, false, "0.9.0"),
    "连接正常\nKavita 0.9.0\nkamare 官方版（无缓存接口）")
Assert.eq(connectToast({ ok = false, state = "incompatible", api_version = 2 }, false, "0.9.0"),
    "连接正常\nKavita 0.9.0\nkamare 版本不兼容")
-- 版本过旧 / 请求失败仍报真正原因，不能让缓存状态盖过去。
Assert.eq(connectToast(enhanced, false, "0.8.9"),
    "连接正常\nKavita 0.8.9 过旧，需要 0.9 及以上")
Assert.eq(connectToast(enhanced, false, nil, "HTTP 401"), "连接失败\nHTTP 401")
Assert.eq(connectToast(enhanced, false, nil, nil), "连接正常\n无法识别 Kavita 版本")
