---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- reader.end_dialog：读完删书先确认，关书回桌面后再删，成功刷新书架 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()
local Themed = require("support.theme_stubs")
Themed.install()

local order = {}
local desk = { events = {} }
function desk:onEvent(name) self.events[#self.events + 1] = name end
package.preload["desktop"] = function()
    return { open = function() order[#order + 1] = "open_desktop" end }
end
package.preload["apps/filemanager/filemanager"] = function()
    return { instance = { book = { desktop = desk } } }
end
for _, name in ipairs({ "desktop", "apps/filemanager/filemanager", "reader.end_dialog" }) do
    package.loaded[name] = nil
end
local EndDialog = require("reader.end_dialog")

local result = { true }
local source = {}
function source:deleteBookAsync(_, cb)
    order[#order + 1] = "delete"
    cb(result[1], result[2])
end
local identity = { source_id = "moon", stable_id = "a.epub", book = { title = "A" }, source = source }

local function deleteItem()
    for _, item in ipairs(Themed.last("sheet").items) do
        if item.text == "删除本书" then return item end
    end
end

-- 点「删除本书」只弹确认，不删
do
    EndDialog.show({}, identity)
    deleteItem().callback()
    Assert.len(order, 0)
    local confirm = Themed.last("confirm")
    Assert.matches(confirm.text, "A")
    -- 确认：先关书回桌面再删，成功后刷新书架
    confirm.ok_callback()
    Assert.eq(order[1], "open_desktop")
    Assert.eq(order[2], "delete")
    Assert.eq(desk.events[1], "shelf_changed")
end

-- 删除失败：提示错误，不刷新书架
do
    order, desk.events, result = {}, {}, { false, "坏了" }
    EndDialog.show({}, identity)
    deleteItem().callback()
    Themed.last("confirm").ok_callback()
    Assert.eq(Themed.last("toast").text, "坏了")
    Assert.len(desk.events, 0)
end

-- 没有属主源：直接提示，不弹确认
do
    local made = #Themed.made
    EndDialog.show({}, { source_id = "x", stable_id = "y" })
    deleteItem().callback()
    Assert.eq(Themed.last("toast").text, "当前数据源不支持删除本书")
    Assert.eq(#Themed.made, made + 2, "只多了 sheet 与 toast")
end

for _, name in ipairs({ "desktop", "apps/filemanager/filemanager", "reader.end_dialog" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
