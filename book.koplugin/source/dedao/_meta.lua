--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

得到 PC（www.dedao.cn）支持短信和 App 扫码。书架是「已购 - 电子书」，正文为加密 SVG。

@module source.dedao._meta
--]]

local _ = require("l10n").get("source.dedao")

return {
    id = "dedao",
    name = _("得到阅读"),
    type = "chapter",
    description = _("得到电子书书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("书评"), _("手机号验证码登录"), _("扫码登录"), _("浏览器登录") },
}
