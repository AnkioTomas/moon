--[[--
Kavita 设置页：服务器 / API Key / 书库 / 漫画缓存 / 进度心跳 / 请求超时 / 多设备统计合并 / 连接测试。

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
package.preload["moonsource_kavita.client"] = function()
    return { DEFAULT_TIMEOUT = 60, new = function() return {} end }
end
package.preload["moonsource_kavita.source"] = function()
    return { DEFAULT_HEARTBEAT_INTERVAL = 30 }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

-- 缓存适配层：探测 / 详情 / 保存后镜像；真实现由 cache_spec 钉住。
local probe_result = { ok = false, state = "missing" }
local mirror_failed = false
local reprobed = 0
local register_calls, register_ok = {}, true
local available = {}
local summary_result
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
        summary = function() return summary_result end,
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

local Setting = require("moonsource_kavita.setting")

local rows = Setting.rows({ path = PLUGIN })
-- 行数 7 → 8；顺序用文案钉住（索引不再稳定），「漫画缓存」插在「书库」之后。
local titles = {}
for _idx, make in ipairs(rows) do titles[#titles + 1] = make(600).title end
Assert.eq(#rows, 8, "服务器 / API Key / 书库 / 漫画缓存 / 进度心跳 / 请求超时 / 多设备统计合并 / 连接测试")
Assert.eq(table.concat(titles, "|"),
    "服务器地址|API Key|书库|漫画缓存|进度心跳间隔|请求超时|多设备统计合并|测试连接",
    "「漫画缓存」紧跟「书库」")

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

-- 多设备统计合并：默认关（键缺失 = 关）；打开后核心合并 SQL 按天取云端与本地较大值，补上离线阅读。
local merge = rowAt("多设备统计合并")
Assert.eq(merge.kind, "toggle")
-- 行右侧还有开 / 关状态（toggle 行由 Row.widget 画），副标题必须短到放得下。
Assert.eq(merge.subtitle, "按天取较大值，补上离线阅读")
Assert.is_false(merge.toggle, "默认关")
Assert.is_nil(cfg.merge_local_stats, "默认不落盘")
merge.callback()
Assert.eq(cfg.merge_local_stats, true, "打开写 true（核心只认 == true）")
Assert.is_true(rowAt("多设备统计合并").toggle, "重开设置页保持打开")
rowAt("多设备统计合并").callback()
Assert.eq(cfg.merge_local_stats, false, "关闭写 false")
Assert.is_false(rowAt("多设备统计合并").toggle, "重开设置页保持关闭")

Assert.eq(saved, 6)
Assert.eq(reloaded, 6, "每次保存都重建源实例，新配置立即生效")

----------------------------------------------------------------------
-- 漫画缓存：五态 + 只读详情 + 09 手动安装说明。
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
checkStatus({ ok = false, state = "incompatible", api_version = 2 }, "版本不兼容（API 2，需要 1）", false)
checkStatus({ ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev" },
    "增强版 v0.10.0-dev（API 1）", true)
checkStatus({ ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev" },
    "配置同步失败", false, true)

-- 详情：路径 / 版本 / 能力 / 占用 + 09 说明；「重新检测」原地重开。
local MB = 1024 * 1024
cfg.base_url, cfg.api_key = "http://kav", "k"
local cache_path = "/fake/plugins/kamare.koplugin/src/kamarecache.lua"
probe_result = {
    ok = true, state = "enhanced", api_version = 1, version = "0.10.0-dev",
    capabilities = { open = true, index = true, status = true },
    path = cache_path,
}
mirror_failed = false
available = { summary = true }
summary_result = { used = 3 * MB, available = 9 * MB, chapters = 12 }
rowAt("漫画缓存").callback()
local detail = Themed.last("confirm")
Assert.not_nil(detail)
Assert.eq(detail.title, "漫画缓存")
Assert.eq(detail.ok_text, "重新检测")
Assert.eq(detail.cancel_text, "关闭")
Assert.matches(detail.text, cache_path, "实际加载路径")
Assert.matches(detail.text, "API 版本：1")
Assert.matches(detail.text, "kamare 版本：0.10.0%-dev")
Assert.matches(detail.text, "能力：.*index")
Assert.matches(detail.text, "缓存占用：已用 3.0 MB，可用 9.0 MB，共 12 章")
-- 09：仓库 / 发布页 / 三步 / kamarecache.lua 判据 / 实际插件目录 / 共存提醒。
Assert.matches(detail.text, "github.com/backtracker/kamare.koplugin")
Assert.matches(detail.text, "releases/latest")
Assert.matches(detail.text, "在电脑上下载 kamare.koplugin.zip")
Assert.matches(detail.text, "kamarecache.lua")
Assert.matches(detail.text, "重启 KOReader")
Assert.matches(detail.text, "/fake/plugins", "kamare 已装：用它所在的 plugins/")
Assert.matches(detail.text, "不能共存")
Assert.matches(detail.text, "数据目录")

local confirms = #Themed.all("confirm")
detail.ok_callback()
Assert.eq(reprobed, 1, "重新检测")
Assert.eq(#Themed.all("confirm"), confirms + 1, "重开后仍能看到详情")

-- 未安装：插件目录取 moon 自己所在目录；未配置服务器时不显示占用。
probe_result = { ok = false, state = "missing" }
available = {}
cfg.base_url = ""
rowAt("漫画缓存").callback()
local missing_detail = Themed.last("confirm")
Assert.matches(missing_detail.text, Config.root() .. "/extensions", "实际插件目录")
Assert.is_nil(missing_detail.text:find("缓存占用", 1, true), "未配置服务器不显示占用")

-- 只读详情（02 A8 / 09 A3）：不能为了判断可写性往插件目录写探针文件；
-- 备选目录说明无条件给出，用户自己判断。
local temp_plugin = Config.dir() .. "/setting_plugins/kamare.koplugin"
os.execute("mkdir -p '" .. temp_plugin .. "'")
local temp_row
for _idx, make in ipairs(Setting.rows({ path = temp_plugin })) do
    local row = make(600)
    if row.title == "漫画缓存" then temp_row = row end
end
temp_row.callback()
local readonly_detail = Themed.last("confirm")
Assert.is_true(readonly_detail.text:find(Config.dir() .. "/setting_plugins", 1, true) ~= nil,
    "用传入插件目录的父目录")
Assert.is_true(readonly_detail.text:find("如该目录不可写，可改用", 1, true) ~= nil)
Assert.is_true(readonly_detail.text:find(require("datastorage"):getDataDir() .. "/plugins", 1, true) ~= nil,
    "备选目录")
Assert.is_nil(io.open(Config.dir() .. "/setting_plugins/.moon-cache-write-check", "rb"),
    "详情不写探针文件：只读、无副作用")

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
