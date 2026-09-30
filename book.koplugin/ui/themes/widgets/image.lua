--[[--
主题图片：image 表面令牌画底色 / 边框，占位文案用 caption + muted；
下载、磁盘缓存、分帧解码、位图缓存在 ui.themes.widgets.image.core。未出图时透出令牌底色。

  +------------+
  |  封面 / 图  |   外框 width × height（物理像素），图按边框内缩
  +------------+

  local img = Image.widget({
      width = w, height = h,
      src = "https://…" | "/abs/path.png" | "logo.png"（插件相对）,
      fallback = "书名",     -- 未就绪 / 失败时的文案
      style = theme.card,    -- 可选：换一种表面，缺省 theme.image
      -- 其余原样交给内核：headers / alpha / on_ready / fallback_src / invert_in_night
  })
  img[1]:cancel()            -- 只取消这一张的下载

  Image.fetchAsync / invalidate / await 见内核。

image 表面半径保持 0。封面走 raised，圆角由 Box 在绘制后裁掉四角圆外的像素。

@module koplugin.book.ui.themes.widgets.image
--]]

local Core = require("ui.themes.widgets.image.core")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Text = require("ui.themes.widgets.text")

---@class BookThemeImage
local ThemeImage = {
    fetchAsync = Core.fetchAsync,
    invalidate = Core.invalidate,
    await = Core.await,
}

---@param opts table 见模块头
---@return table Box
function ThemeImage.widget(opts)
    local t = Theme.current()
    local style = opts.style or t.image
    local inset = Theme.px(style.border or 0) * 2
    local w, h = opts.width - inset, opts.height - inset
    local fallback = opts.fallback and opts.fallback ~= "" and Text.line("caption", opts.fallback,
        { width = w - Theme.px(t.space.xs) * 2, color = t.color.muted }) or nil
    return Box:new{
        style = style,
        width = opts.width,
        height = opts.height,
        Core.widget{
            src = opts.src,
            headers = opts.headers,
            width = w,
            height = h,
            alpha = opts.alpha,
            fallback = fallback,
            fallback_src = opts.fallback_src,
            invert_in_night = opts.invert_in_night,
            on_ready = opts.on_ready,
        },
    }
end

return ThemeImage
