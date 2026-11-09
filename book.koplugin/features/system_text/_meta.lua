--[[--
feature 元信息：桌面 / WSL 的系统文本输入后端。

@module koplugin.book.features.system_text._meta
--]]

local _ = require("gettext")

return {
    name = _("系统文本输入"),
    description = _("桌面 / WSL 上使用系统输入法（SDL 文本输入）"),
    abilities = { _("系统输入法上屏"), _("候选窗锚点"), _("WSL fcitx5 检测") },
    -- 后端由 features.ime 惰性 require；功能开关页的停用对它没有效果。
    removable = false,
}
