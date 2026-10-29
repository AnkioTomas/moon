---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- reader.end_dialog：读完删书先确认，关书回桌面后再删，成功刷新书架 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()
local Themed = require("support.theme_stubs")
Themed.install()

local order = {}
local soft_result = { true }
local running_task
local desk = { events = {} }
function desk:onEvent(name) self.events[#self.events + 1] = name end
package.preload["desktop"] = function()
    return { open = function() order[#order + 1] = "open_desktop" end }
end
package.preload["apps/filemanager/filemanager"] = function()
    return { instance = { book = { desktop = desk } } }
end
package.preload["book.store"] = function()
    return {
        softDelete = function(source_id, stable_id)
            order[#order + 1] = "soft:" .. source_id .. "\0" .. stable_id
            return soft_result[1]
        end,
    }
end
package.preload["workers.tasks"] = function()
    return { get = function(key) if key == "cache\0moon\0a.epub" then return running_task end end }
end
for _, name in ipairs({ "desktop", "apps/filemanager/filemanager", "book.store", "workers.tasks", "reader.end_dialog" }) do
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

local function findItem(text)
    for _, item in ipairs(Themed.last("sheet").items) do
        if item.text == text then return item end
    end
end
local function deleteItem() return findItem("彻底删除（进度、划线与书架一并清除）") end
local function softItem() return findItem("软删除（清本地正文，进度划线可恢复）") end

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

-- 软删除：点选只弹确认；确认后先关书再软删，成功刷新书架
do
    order, desk.events, soft_result, running_task = {}, {}, { true }, nil
    EndDialog.show({}, identity)
    softItem().callback()
    Assert.len(order, 0)
    local confirm = Themed.last("confirm")
    Assert.matches(confirm.text, "软删除《A》")
    Assert.eq(confirm.ok_text, "软删除")
    confirm.ok_callback()
    Assert.eq(order[1], "open_desktop")
    Assert.eq(order[2], "soft:moon\0a.epub")
    Assert.eq(Themed.last("toast").text, "已软删除")
    Assert.eq(desk.events[1], "shelf_changed")
end

-- 软删除失败：提示，不刷新书架
do
    order, desk.events, soft_result = {}, {}, { false }
    EndDialog.show({}, identity)
    softItem().callback()
    Themed.last("confirm").ok_callback()
    Assert.eq(Themed.last("toast").text, "软删除失败")
    Assert.len(desk.events, 0)
end

-- 本书正在后台缓存：确认后中止，不关书不软删
do
    order, running_task = {}, { id = "cache" }
    EndDialog.show({}, identity)
    softItem().callback()
    Themed.last("confirm").ok_callback()
    Assert.eq(Themed.last("toast").text, "本书正在后台缓存，请稍后再试")
    Assert.len(order, 0)
    running_task = nil
end

-- 没有属主源：直接提示，不弹确认
do
    local made = #Themed.made
    EndDialog.show({}, { source_id = "x", stable_id = "y" })
    deleteItem().callback()
    Assert.eq(Themed.last("toast").text, "当前数据源不支持删除本书")
    Assert.eq(#Themed.made, made + 2, "只多了 sheet 与 toast")
end

-- 没有属主源也能软删除：纯本地操作不依赖源
do
    order, desk.events, soft_result = {}, {}, { true }
    EndDialog.show({}, { source_id = "local", stable_id = "y.epub", book = { title = "Y" } })
    softItem().callback()
    Themed.last("confirm").ok_callback()
    Assert.eq(order[1], "open_desktop")
    Assert.eq(order[2], "soft:local\0y.epub")
    Assert.eq(Themed.last("toast").text, "已软删除")
    Assert.eq(desk.events[1], "shelf_changed")
end

for _, name in ipairs({ "desktop", "apps/filemanager/filemanager", "book.store", "workers.tasks", "reader.end_dialog" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
