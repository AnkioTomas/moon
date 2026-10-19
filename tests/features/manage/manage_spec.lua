--[[-- features.manage：停用 / 再启用，启动时只把 ITEMS 里已停用的 feature 从 list 去掉（不删文件）。 --]]
local Assert = require("support.assert")
local store = { disabled = {} }
package.loaded["utils.settings"] = {
    get = function() return store end,
    save = function() end,
}
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }

local Manage = require("features.manage")

Assert.is_false(Manage.isMarked("ocr"))
Assert.is_true(Manage.toggle("ocr"))
Assert.is_true(Manage.isMarked("ocr"))

store.disabled[#store.disabled + 1] = "manage" -- 不在 ITEMS 里：篡改配置也不能停用核心
local list = { "manage", "ocr", "ai" }
local off = Manage.apply(list)
Assert.is_true(off.ocr)
Assert.is_nil(off.manage)
Assert.eq(table.concat(list, ","), "manage,ai")

Assert.is_false(Manage.toggle("ocr"), "再点一次取消标记")
Assert.is_false(Manage.isMarked("ocr"))

-- 连带删除：删被引用方带走引用它的（递归），取消时反向恢复
do
    store.disabled = {}
    Assert.eq(table.concat(Manage.closure("lockscreen"), ","), "lockscreen,panel,sidebar,bars,nightmode")
    Assert.is_true(Manage.toggle("lockscreen"))
    for _, id in ipairs({ "lockscreen", "panel", "sidebar", "bars", "nightmode" }) do
        Assert.is_true(Manage.isMarked(id), id)
    end
    Assert.is_false(Manage.toggle("bars"), "恢复 bars 要把它依赖的 panel、lockscreen 也恢复")
    Assert.is_false(Manage.isMarked("panel"))
    Assert.is_false(Manage.isMarked("lockscreen"))
    Assert.is_true(Manage.isMarked("sidebar"), "sidebar 依赖 lockscreen 等，不受 bars 影响")
end

-- DEPENDENTS 与源码一致：features/<a>/ 里（去掉注释）引用了 features.<b> 就必须登记 a 依赖 b
do
    local names = {}
    for _, item in ipairs(Manage.ITEMS) do names[item.id] = true end
    local pipe = assert(io.popen('find book.koplugin/features -mindepth 2 -name "*.lua" -not -path "*/demo/*" | sort'))
    for path in pipe:lines() do
        local owner = path:match("features/([^/]+)/")
        if names[owner] and owner ~= "manage" then
            local f = assert(io.open(path, "r"))
            local src = f:read("*a"):gsub("^%-%-%[%[%-%-.-%-%-%]%]", "")
            f:close()
            for line in (src .. "\n"):gmatch("([^\n]*)\n") do
                if not line:match("^%s*%-%-") then
                    for dep in line:gmatch("features[./]([%w_]+)") do
                        if names[dep] and dep ~= owner then
                            local listed = false
                            for _, d in ipairs(Manage.DEPENDENTS[dep] or {}) do
                                if d == owner then listed = true end
                            end
                            Assert.is_true(listed, path .. " 引用 " .. dep .. "，DEPENDENTS." .. dep .. " 要列 " .. owner)
                        end
                    end
                end
            end
        end
    end
    pipe:close()
end
