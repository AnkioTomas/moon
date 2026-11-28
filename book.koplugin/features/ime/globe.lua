--[[--
长按地球键选择中文键盘布局。

点按地球键仍是 KOReader 的中英文切换。输入法开着时，长按改为弹出布局列表
（拼音 / 九宫格 / 五笔 / …）。选中后切到 zh_CN，并按新方法重建键帽。
松手不再当成一次点按，否则列表还在时布局就被切走。

@module koplugin.book.features.ime.globe
--]]

local Guard = require("ui.guard")
local _ = require("gettext")
require("l10n").apply()

local Globe = { _hooked = false }

--- 把这个键盘上的地球键长按改成布局选择。键位每次重建都要再挂一次。
---@param kb table VirtualKeyboard
function Globe.attach(kb)
    local marks = kb.utf8mode_keys
    if not marks then return end
    for _idx, row in ipairs(kb.layout or {}) do
        for _idx, key in ipairs(row) do
            local label = key.label
            -- 空键位的 label 是 nil，拿去索引会抛，后面的地球键就挂不上。
            if type(label) == "string" and marks[label] then
                key.hold_callback = function()
                    key.ignore_key_release = true
                    Globe.pick(kb)
                end
                key.hold_cb_is_popup = true
            end
        end
    end
end

--- 弹出布局列表。与当前相同的项只关窗。
---@param kb table VirtualKeyboard
function Globe.pick(kb)
    local IME = require("features.ime")
    local items = {}
    for _idx, method in ipairs(IME.layouts()) do
        items[#items + 1] = { text = method.label, value = method.id }
    end
    require("ui.themes.widgets.list"):new{
        title = _("键盘布局"),
        items = items,
        current = IME.layout(),
        centered = true,
        on_select = function(id)
            if id == IME.layout() then return end
            if not IME.setLayout(id) then return end
            require("features.ime.candidate_bar").abandon()
            kb:onSwitchingKeyboardLayout()
            kb:setKeyboardLayout("zh_CN")
            local Registry = require("features.ime.registry")
            if not Registry.fileExists(id) then
                require("ui.themes.widgets.toast"):new{
                    text = id == "pinyin"
                        and _("候选用 KOReader 自带词库，下载月读词库后更全")
                        or require("ffi/util").template(_("%1词库未下载"), Registry.current().label),
                    timeout = 2,
                }:show()
            end
        end,
    }:show()
end

function Globe.onCreate()
    if Globe._hooked then return end
    Globe._hooked = true
    local VK = require("ui/widget/virtualkeyboard")
    local orig = VK.addKeys
    VK.addKeys = function(self, ...)
        local result = orig(self, ...)
        if require("features.ime").isEnabled() then
            Guard.call("ime globe", Globe.attach, self)
        end
        return result
    end
end

return Globe
