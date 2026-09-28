--[[--
纸本：白底细线、近直角、无阴影，靠字重、细线和留白分层。
几乎只有黑白两色，局部快刷残影最少，夜间反色后依然干净。

@module koplugin.book.ui.themes.paper
--]]

return {
    id = "paper",
    color = {
        page = 0xFF,     -- 页面与面板底
        ink = 0x00,      -- 主文字、图标
        muted = 0x44,    -- 次要文字
        faint = 0x88,    -- 未选中标签、提示
        disabled = 0xAA, -- 不可用
        rule = 0x99,     -- 分割线
    },
    -- 三级表面：普通卡片 / 主角卡片 / 弹窗面板。shadow 为右下偏移，0 不画。
    card = { bg = 0xFF, border = 1, border_color = 0x99, radius = 2, shadow = 0, shadow_color = 0x00 },
    raised = { bg = 0xFF, border = 1, border_color = 0x00, radius = 2, shadow = 0, shadow_color = 0x00 },
    dialog = { bg = 0xFF, border = 1, border_color = 0x00, radius = 4, shadow = 0, shadow_color = 0x00 },
    image = { bg = 0xEE, border = 1, border_color = 0x99, radius = 0, shadow = 0, shadow_color = 0x99 },
    -- 按钮、筛选 chip、输入框共用几何；radius 超过半高即两端半圆，icon 是按钮内图标的逻辑字号。
    control = { height = 40, radius = 2, border = 1, icon = 22 },
    -- 无 bg 不填底，无 border_color 不画边。
    button = {
        normal = { bg = 0xFF, ink = 0x00, border_color = 0x00 },
        primary = { bg = 0x00, ink = 0xFF, border_color = 0x00 },
        ghost = { ink = 0x00 },
    },
    -- 选中项（Tab、列表当前项）；mark > 0 时在底部画同色指示条。
    selected = { bg = 0xFF, ink = 0x00, mark = 2 },
    progress = { height = 4, radius = 0, border = 0, border_color = 0x00, track = 0xDD, fill = 0x00 },
    font = { caption = 11, body = 14, title = 17, hero = 40 },
    space = { xs = 4, sm = 8, md = 12, lg = 16 },
    row = { height = 48, divider = 1 },
}
