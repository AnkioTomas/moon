--[[-- features.marketplace.meta：静态解析 _meta.lua，不执行，不臆造翻译。 --]]

local Assert = require("support.assert")
local Meta = require("features.marketplace.meta")

local parsed, err = Meta.parse([[
local _ = require("gettext")
return {
    name = "stats",
    fullname = _("阅读统计"),
    description = _("统计你的阅读时长"),
    version = "1.2.3",
}
]])
Assert.is_nil(err)
Assert.eq(parsed.name, "stats")
Assert.eq(parsed.fullname, "阅读统计")
Assert.eq(parsed.description, "统计你的阅读时长")
Assert.eq(parsed.version, "1.2.3")
Assert.eq(Meta.displayTitle(parsed), "阅读统计")
Assert.eq(Meta.displayDescription(parsed), "统计你的阅读时长")

parsed = Meta.parse([[
return {
    name = "hello",
    title = "Hello",
    description = "A plugin",
    version = "0.1.0",
    zh = { title = "你好", description = "一个插件" },
}
]])
Assert.eq(Meta.displayTitle(parsed), "你好")
Assert.eq(Meta.displayDescription(parsed), "一个插件")

-- 英文源文没有中文翻译时不得编造。
parsed = Meta.parse([[
return { name = "clock", fullname = _("Clock"), description = _("Shows time"), version = "1.0.0" }
]])
Assert.eq(Meta.displayTitle(parsed), "Clock")
Assert.eq(Meta.displayDescription(parsed), "Shows time")

local bad, bad_err = Meta.parse("os.execute('rm')")
Assert.is_nil(bad)
Assert.not_nil(bad_err)

return true
