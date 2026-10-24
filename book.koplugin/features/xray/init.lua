--[[--
X-Ray：阅读页人物/地点标注与实体面板。

标注在 marks，面板在 ui，抽取在 fetch。入口在侧栏 Tab、阅读面板与手势。

@module koplugin.book.features.xray.init
--]]

local _ = require("gettext")
local Xray = {}

--- 登记「刷新 X-Ray」手势，事件由下面的 events 接住。
function Xray.onCreate()
    require("dispatcher"):registerAction("book_xray_refresh", {
        category = "none",
        event = "BookXrayRefresh",
        title = _("刷新 X-Ray"),
        reader = true,
    })
end

--- X-Ray 开着且当前不是订阅文章（ephemeral 源不是书，没有可累积的人物 / 地点）。
---@return boolean
function Xray.available()
    if not require("utils.settings").get("features.xray").book_xray_enabled then return false end
    local current = require("reader.session").current()
    return not (current and current.identity.ephemeral)
end

Xray.events = {
    ---@param plugin BookPlugin
    BookXrayRefresh = function(plugin)
        if not plugin.ui.document or not Xray.available() then return false end
        require("features.xray.ui").refresh(plugin.ui)
        return true
    end,
    CloseDocument = function(plugin)
        require("features.xray.marks").release(plugin.ui)
    end,
}

---@param plugin BookPlugin
function Xray.onReaderReady(plugin)
    require("features.xray.marks").install(plugin.ui)
end

return Xray
