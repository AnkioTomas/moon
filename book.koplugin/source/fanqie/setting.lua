local M={}
function M.rowTitle() return '番茄账号与登录' end
function M.rowStatus()
    local ok=require('source.fanqie.settings'):new():is_cookie_configured()
    return ok and '已读取原番茄登录' or '未登录',ok
end
function M.open()
    local settings=require('source.fanqie.settings'):new()
    local client=require('source.fanqie.client'):new(settings)
    local UI=require('ui/uimanager')
    local owner={}
    function owner:closeBusy()
        if self.busy then UI:close(self.busy); self.busy=nil end
    end
    function owner:showBusy(text)
        self:closeBusy()
        self.busy=require('ui/widget/infomessage'):new{text=text}
        UI:show(self.busy)
    end
    require('ui/network/manager'):runWhenOnline(function()
        require('source.fanqie.qrlogin'):new(client,settings,owner):start()
    end)
end
return M
