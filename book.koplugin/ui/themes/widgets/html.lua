--[[--
主题 HTML 正文：KOReader HtmlBoxWidget（MuPDF 排版）外包一层，套上与 DictQuickLookup 相同的词典基础 CSS
（Noto Sans、行高 1.3、列表缩进）+ 词典自带 css，字号跟主题正文字号。固定宽高，按高度分页，
页码交给调用方的 Pager；点到链接回调 on_link(link)。

  local box = Html.widget({ width = w, height = h, html = def, css = dict_css, dir = res_dir,
      on_link = function(link) … end })
  box.page_count; box:setPageNumber(2)

@module koplugin.book.ui.themes.widgets.html
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local Theme = require("ui.themes")

---@class BookThemeHtml
local Html = {}

local BASE_CSS = [[
@page { margin: 0; font-family: 'Noto Sans'; }
body { margin: 0; line-height: 1.3; }
blockquote, dd { margin: 0 1em; }
ol, ul, menu { margin: 0; padding: 0 1.7em; }
]]

--- MuPDF 默认字号（像素）：主题正文逻辑字号 → Font 字号 → 屏幕像素，与 Text 正文同大。
---@return integer
function Html.fontPx()
    return Device.screen:scaleBySize(Theme.fontSize(Theme.current().font.body))
end

---@param opts { width: integer, height: integer, html: string, css: string|nil, dir: string|nil, on_link: fun(link: table)|nil }
---@return table HtmlBoxWidget
function Html.widget(opts)
    -- 用到才加载（MuPDF FFI），纯文字查词不付这份开销。
    local box = require("ui/widget/htmlboxwidget"):new{
        dimen = Geom:new{ x = 0, y = 0, w = opts.width, h = opts.height },
        html_link_tapped_callback = opts.on_link,
    }
    box:setContent(opts.html, BASE_CSS .. (opts.css or ""), Html.fontPx(), nil, nil, opts.dir)
    return box
end

return Html
