--[[--
知音漫客短信登录窗口：手机号 → 官网点字验证 → 短信码 → 账号兑换。
验证码由用户按官网示例顺序点选，不自动识别或绕过验证。

@module source.zymk.phone_login
--]]

local Text = require("utils.text")
local _ = require("l10n").get("source.zymk")

---@class ZymkPhoneLogin
---@field session ZymkLogin
---@field on_user fun()
---@field phone string|nil
---@field done boolean|nil
---@field dialog table|nil
---@field waiting table|nil
local Phone = {}
Phone.__index = Phone

function Phone.new(on_user)
    return setmetatable({ session = require("source.zymk.login").new(), on_user = on_user }, Phone)
end

function Phone:cancel()
    self.done = true
    self.session:cancel()
    if self.waiting then self.waiting:close(); self.waiting = nil end
    if self.dialog then local dialog = self.dialog; self.dialog = nil; dialog:close() end
end

function Phone:showCaptcha(captcha)
    local raw = Text.base64Decode(captcha.image)
    local bitmap = raw and require("ui/renderimage"):renderImageData(raw, #raw, false)
    if not bitmap then
        self:cancel()
        require("ui.themes.widgets.toast"):new{ text = _("图形验证码加载失败") }:show(); return
    end
    local Modal = require("ui.themes.widgets.modal")
    local ImageWidget = require("ui/widget/imagewidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local ThemeText = require("ui.themes.widgets.text")
    local T = require("ffi/util").template
    local owner, points = self, {}
    local Captcha = Modal:extend{}
    function Captcha:init()
        Modal.init(self)
        local width = self:innerWidth()
        local height = math.floor(width * captcha.height / captcha.width)
        local TapImage = InputContainer:extend{}
        function TapImage:init()
            self.ges_events = { TapCaptcha = {
                GestureRange:new{ ges = "tap", range = function() return self.dimen end },
            } }
        end
        function TapImage:onTapCaptcha(_event, gesture)
            if #points < 2 then
                points[#points + 1] = {
                    x = math.floor((gesture.pos.x - self.dimen.x) / width * captcha.width),
                    y = math.floor((gesture.pos.y - self.dimen.y) / height * captcha.height),
                }
                require("ui.themes.widgets.toast"):new{
                    text = T(_("已选择 %1/2 个位置"), #points), timeout = 1,
                }:show()
            end
            return true
        end
        self:setDialog{
            title = _("图形验证码"),
            body = require("ui/widget/verticalgroup"):new{
                align = "left",
                ThemeText.box("body", _("按顺序点选图片中的文字：") .. captcha.content, width, { transparent = true }),
                TapImage:new{ ImageWidget:new{
                    image = bitmap, width = width, height = height, scale_factor = 0, alpha = true,
                } },
            },
            buttons = {
                { text = _("取消"), callback = function() owner:cancel() end },
                { text = _("刷新"), callback = function()
                    self:close(); owner.dialog = nil; owner:send(nil, true)
                end },
                { text = _("重新选择"), callback = function()
                    points = {}
                    require("ui.themes.widgets.toast"):new{ text = _("请重新点选图片中的文字") }:show()
                end },
                { text = _("确定"), variant = "primary", callback = function()
                    if #points ~= 2 then
                        require("ui.themes.widgets.toast"):new{ text = _("请按顺序选择两个文字位置") }:show(); return
                    end
                    self:close(); owner.dialog = nil; owner:send(points, false)
                end },
            },
        }
    end
    function Captcha:dismiss() owner:cancel() end
    self.dialog = Captcha:new{}
    self.dialog:show()
end

function Phone:send(points, refresh)
    if self.done then return end
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi") }:show(); return
    end
    self.waiting = require("ui.themes.widgets.progress_dialog"):new{
        title = _("短信验证码登录"), text = _("正在获取验证码…"),
        on_cancel = function() self:cancel() end,
    }
    self.waiting:show()
    self.session:sendSmsAsync(self.phone, points, refresh, function(data, err)
        if self.done then return end
        self.waiting:close(); self.waiting = nil
        if not data then
            require("ui.themes.widgets.toast"):new{ text = err, timeout = 3 }:show()
            if not self.dialog then self:start() end
        else
            if self.dialog then self.dialog:close(); self.dialog = nil end
            if data.sent then
                require("ui.themes.widgets.toast"):new{ text = _("短信已发送") }:show()
                self:enterCode()
            else
                self:showCaptcha(data)
            end
        end
    end)
end

function Phone:enterCode()
    self.dialog = require("ui.themes.widgets.input"):new{
        title = _("短信验证码登录"),
        fields = { { label = _("验证码"), input_type = "number" } },
        actions = { { text = _("获取验证码"), callback = function() self:send(nil, false) end } },
        cancel_callback = function() self:cancel() end,
        callback = function(code)
            self.dialog = nil
            if not require("ui/network/manager"):isConnected() then
                require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi") }:show()
                self:enterCode(); return
            end
            self.waiting = require("ui.themes.widgets.progress_dialog"):new{
                title = _("短信验证码登录"), text = _("正在校验登录…"),
                on_cancel = function() self:cancel() end,
            }
            self.waiting:show()
            self.session:codeAsync(self.phone, code, function(account, err)
                if self.done then return end
                self.waiting:close(); self.waiting = nil
                if account then self:cancel(); self.on_user()
                else
                    require("ui.themes.widgets.toast"):new{ text = err, timeout = 3 }:show()
                    self:enterCode()
                end
            end)
        end,
    }
    self.dialog:show()
end

function Phone:start()
    if self.done then return end
    self.dialog = require("ui.themes.widgets.input"):new{
        title = _("短信验证码登录"),
        fields = { { label = _("手机号"), text = self.phone or "", input_type = "number" } },
        ok_text = _("获取验证码"),
        cancel_callback = function() self:cancel() end,
        callback = function(phone)
            self.dialog = nil
            self.phone = Text.trim(phone)
            self:send(nil, false)
        end,
    }
    self.dialog:show()
end

return Phone
