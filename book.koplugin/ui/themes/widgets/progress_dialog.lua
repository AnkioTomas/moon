--[[--
主题进度弹窗（替代 ProgressbarDialog / ui.components.progress_dialog）：
标题 + 当前步骤 + 进度条，随后台事件原地更新。点任意处收起，收起只关窗、不影响后台任务。

  +----------------------+
  | 正在导入             |
  | a.epub（3/9）        |
  | [██████·········]    |
  +----------------------+

  local dialog = ProgressDialog:new{ title = "…", close_callback = fn }
  dialog:show()
  dialog:update("正在上传 a.epub", 3, 9)   -- done/total 可省略，省略时进度条不动

@module koplugin.book.ui.themes.widgets.progress_dialog
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes.init")
local Modal = require("ui.themes.widgets.modal")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookThemeProgressDialog : BookThemeModal
---@field title string
local ProgressDialog = Modal:extend{
    close_on_tap = true,
    title = nil,
}

function ProgressDialog:init()
    Modal.init(self)
    local t = self.theme
    local width = self:innerWidth()
    self.detail = Text.line(t, "body", _("正在准备…"), { width = width, color = t.color.muted })
    self.bar = Progress:new{ width = width }
    self:setDialog{
        title = self.title,
        body = VerticalGroup:new{
            align = "left",
            self.detail,
            VerticalSpan:new{ width = Theme.px(t.space.sm) },
            self.bar,
        },
    }
end

--- 换成当前步骤；给了 total 时进度条按 done/total 走，否则保持不动。
---@param text string
---@param done integer|nil
---@param total integer|nil
function ProgressDialog:update(text, done, total)
    if total and total > 0 then
        done = math.min(done or 0, total)
        self.detail:setText(T(_("%1（%2/%3）"), text, done, total))
        self.bar:setPercent(done * 100 / total)
    else
        self.detail:setText(text)
    end
    UIManager:setDirty(self, function() return "fast", self[1].dimen end)
end
return ProgressDialog
