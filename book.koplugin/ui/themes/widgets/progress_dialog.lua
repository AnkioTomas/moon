--[[--
主题进度弹窗（替代 ProgressbarDialog）：
标题 + 当前步骤 + 进度条，随后台事件原地更新。

  +----------------------+
  | 正在导入             |
  | a.epub（3/9）        |
  | [██████·········]    |
  | [ 取消 ] [后台运行]  |   给了 on_cancel / on_background 才有按钮行
  +----------------------+

点按一律不关窗（面板内外都不关），只能经按钮或返回键离开；返回键等同「后台运行」（没给则只关窗），
传 dismissable = false 连返回键也吞掉。
两个按钮都先关窗再回调；关窗本身不影响后台任务，任务归调用方。

  local dialog = ProgressDialog:new{ title = "…", close_callback = fn }
  dialog:show()
  dialog:update("正在上传 a.epub", 3, 9)   -- done/total 可省略，省略时进度条不动
  dialog:bytes(512 * 1024, 2 * 1048576)     -- 下载类：说明行显示「0.5 / 2.0 MB」，进度条按比例
  dialog:set("已格式化的文案", 40)          -- 文案原样显示；percent 省略时进度条不动

  ProgressDialog:new{ title = "…", on_background = fn, on_cancel = fn }   -- 可转后台 / 可取消

@module koplugin.book.ui.themes.widgets.progress_dialog
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Modal = require("ui.themes.widgets.modal")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookThemeProgressDialog : BookThemeModal
---@field title string
---@field on_background fun()|nil 给了就出「后台运行」按钮；返回键同此
---@field on_cancel fun()|nil 给了就出「取消」按钮
local ProgressDialog = Modal:extend{
    title = nil,
    on_background = nil,
    on_cancel = nil,
}

function ProgressDialog:init()
    local buttons = {}
    if self.on_cancel then
        buttons[#buttons + 1] = { text = _("取消"), callback = function()
            self:close()
            self.on_cancel()
        end }
    end
    if self.on_background then
        buttons[#buttons + 1] = { text = _("后台运行"), variant = "primary", callback = function() self:dismiss() end }
    end
    Modal.init(self)
    local t = self.theme
    local width = self:innerWidth()
    self.detail = Text.line("body", _("正在准备…"), { width = width, color = t.color.muted })
    self.bar = Progress:new{ width = width }
    self:setDialog{
        title = self.title,
        body = VerticalGroup:new{
            align = "left",
            self.detail,
            VerticalSpan:new{ width = Theme.px(t.space.sm) },
            self.bar,
        },
        buttons = buttons,
    }
end

--- 返回键：关窗，给了 on_background 就转后台。
function ProgressDialog:dismiss()
    self:close()
    if self.on_background then self.on_background() end
end

--- 吞掉全部点按：误触遮罩不能关窗（关窗会触发调用方的取消 / 转后台）。按钮先于此处理。
---@return boolean
function ProgressDialog:onTapModal()
    return true
end

--- 换文案；给了 percent（0..100）时进度条跟着走，否则保持不动。
---@param text string
---@param percent number|nil
function ProgressDialog:set(text, percent)
    self.detail:setText(text)
    if percent then self.bar:setPercent(percent) end
    UIManager:setDirty(self, function() return "fast", self[1].dimen end)
end

--- 换成当前步骤；给了 total 时进度条按 done/total 走，否则保持不动。
---@param text string
---@param done integer|nil
---@param total integer|nil
function ProgressDialog:update(text, done, total)
    if total and total > 0 then
        done = math.min(done or 0, total)
        self:set(T(_("%1（%2/%3）"), text, done, total), done * 100 / total)
        return
    end
    self:set(text)
end

--- 按字节推进：说明行显示已下 / 总量（MB），进度条按比例。
---@param done number
---@param total number 大于 0
function ProgressDialog:bytes(done, total)
    done = math.min(done, total)
    self:set(string.format("%.1f / %.1f MB", done / 1048576, total / 1048576), done * 100 / total)
end

return ProgressDialog
