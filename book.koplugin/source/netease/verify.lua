--[[--
电脑端密码登录的图形验证码，与登录窗口共用匿名会话。

@module source.netease.verify
--]]

local Text = require("utils.text")
local _ = require("l10n").get("source.netease")

local Verification = {}
Verification.__index = Verification

function Verification:cancel()
    if self.done then return end
    self.done = true
    self.session:cancel()
    if self.waiting then self.waiting:close(); self.waiting = nil end
    if self.dialog then self.dialog:close(); self.dialog = nil end
end

function Verification:finish(code)
    if self.done then return end
    self:cancel()
    self.callback(code)
end

function Verification:load()
    if self.done then return end
    if self.dialog then self.dialog:close(); self.dialog = nil end
    self.waiting = require("ui.themes.widgets.progress_dialog"):new{
        title = _("网易云阅读图形验证码"), text = _("正在加载…"),
        on_cancel = function() self:finish() end,
    }
    self.waiting:show()
    self.session:captchaAsync(function(raw, err)
        if self.done then return end
        self.waiting:close()
        self.waiting = nil
        local bitmap = raw and require("ui/renderimage"):renderImageData(raw, #raw, false)
        if not bitmap then
            require("ui.themes.widgets.toast"):new{ text = err or _("图形验证码加载失败") }:show()
            self:finish()
            return
        end
        local Theme = require("ui.themes")
        self.dialog = require("ui.themes.widgets.input"):new{
            title = _("网易云阅读图形验证码"),
            header_widget = require("ui/widget/imagewidget"):new{
                image = bitmap, width = Theme.px(180), height = Theme.px(90), scale_factor = 0, alpha = true,
            },
            fields = { { label = _("请输入图形码"), text = "" } },
            ok_text = _("登录"),
            cancel_callback = function() self:finish() end,
            actions = { { text = _("刷新"), callback = function() self:load() end } },
            validate = function(code)
                if Text.trim(code) ~= "" then return not self.done end
                require("ui.themes.widgets.toast"):new{ text = _("请输入图形码") }:show()
                return false
            end,
            callback = function(code) self:finish(Text.trim(code)) end,
        }
        self.dialog:show()
    end)
end

function Verification.new(session, cb)
    local self = setmetatable({ session = session, callback = cb }, Verification)
    self:load()
    return self
end

return Verification
