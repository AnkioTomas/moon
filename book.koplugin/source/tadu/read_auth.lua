--[[--
塔读官方 App 扫码阅读授权。二维码、票据和轮询归本次开章操作所有。

@module source.tadu.read_auth
--]]

local _ = require("l10n").get("source.tadu")

---@class TaduReadAuth
---@field session TaduReading
---@field callback fun(html: string|nil, err: string|nil)
---@field generation integer
---@field deadline integer
---@field done boolean|nil
---@field timer function|nil
---@field dialog BookThemeQR|BookThemeConfirm|nil
---@field ticket table|nil
local ReadAuth = {}
ReadAuth.__index = ReadAuth

function ReadAuth:clear()
    self.generation = self.generation + 1
    self.session:stop()
    if self.timer then require("ui/uimanager"):unschedule(self.timer); self.timer = nil end
    if self.dialog then
        local dialog = self.dialog
        self.dialog = nil
        dialog:close()
    end
    self.ticket = nil
end

function ReadAuth:cancel()
    if self.done then return end
    self.done = true
    self:clear()
end

function ReadAuth:finish(html, err)
    if self.done then return end
    self:cancel()
    self.callback(html, err)
end

function ReadAuth:retry(err)
    self:clear()
    self.dialog = require("ui.themes.widgets.confirm"):new{
        text = err, ok_text = _("重新获取"),
        ok_callback = function()
            self.dialog = nil
            self:start()
        end,
        cancel_callback = function() self:finish(nil, err) end,
    }
    self.dialog:show()
end

function ReadAuth:poll(gen)
    if self.done or gen ~= self.generation then return end
    if os.time() >= self.deadline then self:retry(_("二维码已过期")); return end
    self.session:qrPollAsync(self.ticket, function(status, err)
        if self.done or gen ~= self.generation then return end
        if status == 200 then
            self.session:contentAsync(function(html, reason) self:finish(html, reason) end, false)
        elseif status == 0 or status == 1 then
            self.timer = function()
                self.timer = nil
                self:poll(gen)
            end
            require("ui/uimanager"):scheduleIn(1, self.timer)
        else
            self:retry(err or _("二维码已过期"))
        end
    end)
end

function ReadAuth:start()
    if self.done then return end
    self:clear()
    local gen = self.generation
    self.deadline = os.time() + 300
    self.session:qrCreateAsync(function(ticket, err)
        if self.done or gen ~= self.generation then return end
        local image = ticket and require("ui/renderimage"):renderImageData(ticket.image, #ticket.image, false)
        if not image then self:retry(err or _("获取二维码失败")); return end
        self.ticket = ticket
        self.dialog = require("ui.themes.widgets.qr"):new{
            title = _("塔读 App 扫码阅读"), image = image, close_on_tap = false,
            caption = _("打开塔读小说 App，在「我的」页面点扫一扫；授权后自动继续阅读"),
            actions = {
                { text = _("取消"), callback = function() self:finish(nil, _("已取消")) end },
                { text = _("刷新"), callback = function() self:start() end },
            },
            close_callback = function()
                if self.dialog and gen == self.generation then self:finish(nil, _("已取消")) end
            end,
        }
        self.dialog:show()
        self:poll(gen)
    end)
end

function ReadAuth.new(session, cb)
    local self = setmetatable({ session = session, callback = cb, generation = 0 }, ReadAuth)
    self:start()
    return self
end

return ReadAuth
