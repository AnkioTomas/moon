--[[--
Book 书库插件元数据。

插件名由目录名 ``book.koplugin`` 提供，不能在这里重复声明 ``name``。

@module koplugin.book._meta
--]]

require("l10n").apply()
local _ = require("gettext")

return {
    fullname = _("Book 书库"),
    description = _("图书馆、书城、阅读进度、统计与多源同步。"),
}
