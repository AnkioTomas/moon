--[[--
高对比：粗黑边框、纯黑硬阴影、直角，选中项整块反色，数字放大。
灰阶差的老屏和强光下最清楚；大面积黑块切换时残影明显，需要全刷。

@module koplugin.book.ui.themes.bold
--]]

return {
    id = "bold",
    color = {
        page = 0xFF,
        ink = 0x00,
        muted = 0x22,
        faint = 0x44,
        disabled = 0x99,
        rule = 0x00,
    },
    card = { bg = 0xFF, border = 2, border_color = 0x00, radius = 0, shadow = 3, shadow_color = 0x00 },
    raised = { bg = 0xFF, border = 2, border_color = 0x00, radius = 0, shadow = 5, shadow_color = 0x00 },
    dialog = { bg = 0xFF, border = 3, border_color = 0x00, radius = 0, shadow = 4, shadow_color = 0x00 },
    image = { bg = 0xFF, border = 2, border_color = 0x00, radius = 0, shadow = 0, shadow_color = 0x00 },
    control = { height = 44, radius = 0, border = 2, icon = 24 },
    button = {
        normal = { bg = 0xFF, ink = 0x00, border_color = 0x00 },
        primary = { bg = 0x00, ink = 0xFF, border_color = 0x00 },
        ghost = { ink = 0x00 },
    },
    selected = { bg = 0x00, ink = 0xFF, mark = 0 },
    progress = { height = 10, radius = 0, border = 2, border_color = 0x00, track = 0xFF, fill = 0x00 },
    font = { caption = 12, body = 15, title = 20, hero = 48 },
    space = { xs = 4, sm = 8, md = 12, lg = 16 },
    row = { height = 52, divider = 2 },
}
