--[[--
Kavita 设置页：服务器 / API Key / 书库 / 进度心跳间隔 / 请求超时 / 连接测试。

@module tests.extensions.kavita.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

local cfg = {}
local saved = 0
local reloaded = 0
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_, value) cfg = value; saved = saved + 1 end,
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
local Themed = require("support.theme_stubs")
Themed.install()

local Config = require("support.config")
local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
package.preload["moonsource_kavita.setting"] = function()
    return dofile(PLUGIN .. "/moonsource_kavita/setting.lua")
end

local Setting = require("moonsource_kavita.setting")

local rows = Setting.rows()
Assert.len(rows, 6, "服务器 / API Key / 书库 / 进度心跳 / 请求超时 / 连接测试")
Assert.eq(Setting.remote[1].key, "base_url")
Assert.eq(Setting.remote[2].key, "api_key")
Assert.is_true(Setting.remote[2].secret)

-- 进度心跳：默认 30 秒，可调；0 = 关闭阅读期心跳。
local hb = rows[4](600)
Assert.eq(hb.title, "进度心跳间隔")
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
Assert.eq(rows[4](600).status, "120 秒")
Assert.eq(input.shown and saved, 1, "保存一次")

input.callback("0")
Assert.eq(cfg.heartbeat_interval, 0, "0 落盘成关闭")
local off = rows[4](600)
Assert.eq(off.status, "已关闭")
Assert.is_false(off.status_on)

input.callback("")
Assert.is_nil(cfg.heartbeat_interval, "空输入回默认值")

-- 请求超时：默认 60 秒，可调大（慢设备拉书架）。
local to = rows[5](600)
Assert.eq(to.title, "请求超时")
Assert.eq(to.status, "60 秒")
Assert.is_false(to.status_on, "默认值不高亮")
to.callback()
input = Themed.last("input")
input.callback("180")
Assert.eq(cfg.timeout, 180)
Assert.eq(rows[5](600).status, "180 秒")
Assert.is_true(rows[5](600).status_on)

Assert.eq(saved, 4)
Assert.eq(reloaded, 4, "每次保存都重建源实例，新配置立即生效")
