--[[--
翻页动画（软件擦除渐显）补丁定义。

只在 KOReader 的 UIManager:_repaint 中插入一段动画钩子，并把运行时补丁分发到
`DataStorage:getPatchesDir()`。本文件只描述「改哪里、在哪个锚点前插什么」，
由 patch.manager 统一执行，不做任何 UI。

@module koplugin.book.patches.page_turn_animation.definition
--]]

return {
    name = "page_turn_animation",
    files = {
        {
            -- 相对 KOReader 安装目录（lfs.currentdir()）。
            path = "frontend/ui/uimanager.lua",
            -- 新页 paintTo 完成、刷新队列执行前的位置。
            anchor = "    -- execute refreshes:",
            -- 唯一标记：用于幂等判断与「已打补丁」检测。
            sentinel = "-- Execute the software wipe animation whenever the frontend requested one.",
            -- 插入到锚点前的内容（不含首尾换行，manager 会在其后补一个换行）。
            content = [[    -- Execute the software wipe animation whenever the frontend requested one.
    -- This runs on every device: the flag is cleared below so the underlying
    -- (e.g., MTK) hardware animation is replaced by this software effect
    -- instead of running on top of it.
    local software_animate = Screen.swipe_animations

    if software_animate then
        -- Disable hardware swipe animations and take over refresh counting manually
        Screen.swipe_animations = false
        self.refresh_counted = true

        -- The wipe animation and its full-refresh/clearing decisions live in
        -- the startup patch module; if it failed to load, fall back to no
        -- animation for this repaint.
        if SwipeAnimation then
            SwipeAnimation.runSwipeAnimation(self)
        end
    end]],
        },
    },
    patches = {
        "2-swipe-animation-core.lua",
        "2-swipe-animation-enable.lua",
        "2-pdf-animation.lua",
    },
}
