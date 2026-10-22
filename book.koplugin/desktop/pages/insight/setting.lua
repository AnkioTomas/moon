--[[--
统计页的配置声明（settings/insight.lua，经 `utils.settings.get("desktop.pages.insight")` 读写）。

只记被关掉的页面与卡片（卡片键 = `<页面 id>.<卡片 id>`），新增的默认显示。目录见 layout.lua。

@module koplugin.book.desktop.pages.insight.setting
--]]

return {
    defaults = {
        hidden_pages = {},
        hidden_cards = {},
    },
}
