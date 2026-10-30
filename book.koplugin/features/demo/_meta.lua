--[[--
feature 元信息模板：新 feature 复制本目录后改这里。

字段：
  name          功能名（_() 包裹）
  description   一句话说明，显示在功能开关页
  capabilities  能力清单（_() 字符串数组）
  removable     可选，false 表示不开放停用

@module koplugin.book.features.demo._meta
--]]

local _ = require("gettext")

return {
    name = _("示例功能"),
    description = _("演示 feature 的目录约定"),
    abilities = { _("生命周期钩子"), _("设置页条目") },
    removable = false,
}
