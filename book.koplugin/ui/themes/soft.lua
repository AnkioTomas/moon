--[[--
柔和卡片：浅灰卡片、大圆角、胶囊控件，只有主角卡片和弹窗带浅灰阴影。
与现有桌面观感最接近；间距统一为 4 的倍数。

@module koplugin.book.ui.themes.soft
--]]

return {
    id = "soft",
    color = {
        page = 0xFF,
        ink = 0x00,
        accent = 0x00,
        icons = 0x00,
        headings = 0x00,
        navigation = 0x00,
        stat = 0x00,
        muted = 0x33,
        faint = 0x66,
        disabled = 0x99,
        rule = 0x99,
    },
    card = { bg = 0xEE, border = 0, border_color = 0xEE, radius = 12, shadow = 0, shadow_color = 0xDD },
    raised = { bg = 0xEE, border = 0, border_color = 0xEE, radius = 12, shadow = 2, shadow_color = 0xDD },
    dialog = { bg = 0xFF, border = 1, border_color = 0xCC, radius = 16, shadow = 3, shadow_color = 0xDD },
    image = { bg = 0xEE, border = 0, border_color = 0xEE, radius = 0, shadow = 0, shadow_color = 0xDD },
    control = { height = 40, radius = 999, border = 0, icon = 22 },
    button = {
        normal = { bg = 0xEE, ink = 0x00, border_color = 0xEE },
        primary = { bg = 0x00, ink = 0xFF, border_color = 0x00 },
        ghost = { ink = 0x00 },
    },
    selected = { bg = 0xDD, ink = 0x00, mark = 3 },
    tile = { shape = "circle" },
    progress = { height = 8, radius = 999, border = 0, border_color = 0x00, track = 0xEE, fill = 0x00 },
    font = { caption = 11, body = 14, title = 16, hero = 42 },
    space = { xs = 4, sm = 8, md = 12, lg = 16 },
    row = { height = 48, divider = 0 },
}
