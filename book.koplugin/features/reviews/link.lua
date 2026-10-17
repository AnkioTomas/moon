--[[--
关联微信读书书目：按书名搜索、选一本存进本书 sidecar；已关联时可更换或解除。

@module koplugin.book.features.reviews.link
--]]

require("l10n").apply()

local Linked = require("features.reviews.linked")
local UIManager = require("ui/uimanager")
local Toast = require("ui.themes.widgets.toast")
local T = require("ffi/util").template
local _ = require("gettext")

local Link = {}

---@param text string
local function toast(text)
    Toast:new{ text = text, timeout = 2 }:show()
end

--- 改了关联就重画，标记层按新目标重拉。
---@param ui table
local function repaint(ui)
    UIManager:setDirty(ui.dialog, "ui")
end

---@return BookIdentity|nil
local function identityOf()
    local cur = require("reader.session").current()
    return cur and cur.identity
end

--- 章会话（微信读书、京东读书）每章是独立文档，关联按书存；本地书存 doc_settings。
---@param ui table ReaderUI
---@param identity BookIdentity|nil
---@return ReviewLink|nil
local function readLink(ui, identity)
    if identity and identity.chapter_idx then return Linked.getFor(identity) end
    return Linked.get(ui)
end

---@param ui table ReaderUI
---@param identity BookIdentity|nil
---@param link ReviewLink|nil nil = 解除关联
local function writeLink(ui, identity, link)
    if identity and identity.chapter_idx then
        Linked.setFor(identity, link)
    else
        Linked.set(ui, link)
    end
end

---@param ui table
---@param source ParagraphReviewSource
---@param book WechatSearchBook
---@param identity BookIdentity|nil
local function choose(ui, source, book, identity)
    writeLink(ui, identity, { book_id = book.book_id, title = book.title, author = book.author })
    repaint(ui)
    if source:paragraphReviewsEnabled() then
        toast(T(_("已关联「%1」"), book.title))
    else
        toast(_("已关联。在微信读书设置中打开「显示段评」后显示"))
    end
end

--- 输入书名 → 搜索 → 选书。
---@param ui table
---@param source ParagraphReviewSource
---@param identity BookIdentity|nil
local function search(ui, source, identity)
    local props = ui.doc_props or {}
    require("ui.themes.widgets.input"):new{
        title = _("搜索微信读书书目"),
        fields = { { text = props.title or "", hint = _("书名") } },
        callback = function(keyword)
            if not require("ui/network/manager"):isConnected() then
                toast(_("未联网，无法搜索"))
                return
            end
            source:searchBooksAsync(keyword, function(books, err)
                if not books then
                    toast(err or _("搜索失败"))
                    return
                end
                if #books == 0 then
                    toast(_("没有找到这本书"))
                    return
                end
                local items = {}
                for i, book in ipairs(books) do
                    items[i] = {
                        text = book.title,
                        mandatory = book.author,
                        callback = function() choose(ui, source, book, identity) end,
                    }
                end
                require("ui.themes.widgets.list"):new{ title = _("选择微信读书书目"), items = items }:show()
            end)
        end,
    }:show()
end

--- 当前文档能关联：排版引擎文档（EPUB、AZW3、TXT、FB2…，不含 PDF / 漫画）。
--- 微信读书的书也放开：自己上传的书在平台上没有段评，要借正版那本；本章自己有段评时不借。
---@param ui table ReaderUI
---@return boolean
function Link.available(ui)
    local identity = identityOf()
    -- 订阅文章（ephemeral 源）不是书，没有可关联的书目。
    if not identity or identity.ephemeral then return false end
    return Linked.supported(ui.document)
end

--- 快捷面板入口。
---@param ui table ReaderUI
function Link.open(ui)
    local source = require("source.registry").resolve("wechat") --[[@as ParagraphReviewSource]]
    if not source:configured() then
        toast(_("请先扫码登录微信读书"))
        return
    end
    local identity = identityOf()
    local link = readLink(ui, identity)
    if not link then
        search(ui, source, identity)
        return
    end
    require("ui.themes.widgets.list"):new{
        centered = true,
        title = T(_("已关联：%1"), link.title),
        items = {
            { text = _("更换关联"), callback = function() search(ui, source, identity) end },
            { text = _("解除关联"), callback = function()
                writeLink(ui, identity, nil)
                repaint(ui)
                toast(_("已解除关联"))
            end },
        },
    }:show()
end

return Link
