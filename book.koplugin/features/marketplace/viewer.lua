--[[--
插件 README 详情窗：沿用主题 TextViewer（标题栏 + 正文分页 + 底栏按钮）。
Markdown 经保守转换后交给 HtmlBox；加载、失败或缺失时用纯文字说明。
点外链不会自动打开浏览器或发起请求，由调用方展示地址。

  Viewer.open({
      title = "…",
      text = "正在加载 README…",
      buttons = { { text = "取消", callback = fn }, { text = "安装", variant = "primary", callback = fn } },
      on_link = fn,
      on_close = fn,
  })

测试可设置 Viewer.impl 拦截真实窗口构造。

@module koplugin.book.features.marketplace.viewer
--]]

require("l10n").apply()

local _ = require("gettext")

local Viewer = {}

--- 外链默认处理：只展示地址，不打开、不请求。
---@param link table|string|nil
function Viewer.defaultLink(link)
    local uri = ""
    if type(link) == "table" then
        uri = tostring(link.uri or link.url or "")
    elseif type(link) == "string" then
        uri = link
    end
    uri = uri:match("^%s*(.-)%s*$") or ""
    if uri == "" then return end
    require("ui.themes.widgets.confirm"):new{
        title = _("链接"),
        text = uri .. "\n\n" .. _("外链不会自动打开。"),
    }:show()
end

--- 打开详情窗。返回带 setContent / dismiss 的窗口对象。
---@param opts { title?: string, text?: string, html?: string, css?: string, buttons?: table[], on_link?: fun(link: any), on_close?: fun() }
---@return table
function Viewer.open(opts)
    opts = opts or {}
    if Viewer.impl then
        return Viewer.impl(opts)
    end
    local dialog = require("ui.themes.widgets.text_viewer"):new{
        title = opts.title,
        text = opts.text or "",
        html = opts.html,
        css = opts.css,
        buttons = opts.buttons,
        on_link = opts.on_link or Viewer.defaultLink,
        on_close = opts.on_close,
    }
    dialog:show()
    return dialog
end

return Viewer
