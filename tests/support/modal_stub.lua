--[[--
主题 Modal 的最小桩：给继承 Modal 的窗口（任务列表、翻译弹窗、侧栏……）做离线用例，
不拉起主题渲染链。只模拟子类依赖的契约：new 调 init；init 给全屏 dimen、当前主题令牌 theme 与空的
key_events / ges_events；setPanel 放进 self[1]；show / close / onClose 走 ui/uimanager。
Modal 自身行为（遮罩、定位、guard）见 tests/ui/themes/widgets/modal_spec.lua。

  require("support.modal_stub").install()   -- require 被测模块之前

@module tests.support.modal_stub
--]]

local ModalStub = {}

function ModalStub.install()
    package.loaded["ui.themes.widgets.modal"] = nil
    package.preload["ui.themes.widgets.modal"] = function()
        local UIManager = require("ui/uimanager")
        local Modal = {}
        Modal.__index = Modal
        function Modal:extend(cls)
            cls = cls or {}
            cls.__index = cls
            return setmetatable(cls, self)
        end
        function Modal:new(o)
            o = setmetatable(o or {}, self)
            o:init()
            return o
        end
        function Modal:init()
            local size = require("device").screen:getSize()
            self.dimen = { x = 0, y = 0, w = size.w, h = size.h }
            self.key_events, self.ges_events = {}, {}
            self.theme = require("ui.themes").current()
        end
        function Modal:setPanel(panel) self[1] = panel end
        function Modal:show() UIManager:show(self, "ui") end
        function Modal:close() UIManager:close(self, "ui") end
        function Modal:onClose()
            self:close()
            return true
        end
        function Modal:onCloseWidget() end
        return Modal
    end
end

return ModalStub
