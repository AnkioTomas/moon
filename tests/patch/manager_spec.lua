--[[--
patch.manager：锚点插入、备份/恢复、幂等与失败不落盘。

不碰真实 KOReader 安装目录与真实 .moon：install/backups/patches 全指向临时
目录，补丁定义与负载复用真实 features/animation/patches。

@module tests.patch.manager_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

Stubs.install()
Stubs.reset()

local Manager = require("patch.manager")

local DIR = Config.root() .. "/book.koplugin/features/animation/patches"

local FAKE_TARGET = table.concat({
    'local Device = require("device")',
    "local Screen = Device.screen",
    "",
    "function UIManager:_repaint()",
    "    local dirty = false",
    "",
    "    -- execute refreshes:",
    "    for _, refresh in ipairs(self._refresh_stack) do",
    "        refresh_methods[refresh.mode](Screen, 0, 0, 0, 0, false)",
    "    end",
    "end",
    "",
}, "\n")

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

local function write(path, content)
    os.execute("mkdir -p " .. (path:match("(.+)/[^/]+$") or ""))
    local f = io.open(path, "wb")
    f:write(content)
    f:close()
end

--- 建立一套独立临时目录并初始化 Manager。
---@param target string|nil uimanager.lua 内容；nil 表示不创建目标文件
---@return table paths
local function setup(target)
    local base = os.tmpname() .. ".patch-test"
    os.execute("mkdir -p " .. base)
    local install = base .. "/koreader"
    if target ~= nil then
        write(install .. "/frontend/ui/uimanager.lua", target)
    end
    Manager.configure({
        install_dir = install,
        backups_root = base .. "/backups",
        patches_dir = base .. "/patches",
    })
    return {
        base = base,
        install = install,
        target = install .. "/frontend/ui/uimanager.lua",
        backups = base .. "/backups/page_turn_animation",
        patches = base .. "/patches",
    }
end

local function count(text, sub)
    local n = 0
    local pos = 1
    while true do
        local p = text:find(sub, pos, true)
        if not p then break end
        n = n + 1
        pos = p + 1
    end
    return n
end

-- 正常安装：内容插到锚点前，补丁文件分发到位
do
    local paths = setup(FAKE_TARGET)
    local res = Manager.install(DIR)
    Assert.is_true(res.ok, res.err)
    Assert.eq(res.changed, true)

    local patched = read(paths.target)
    Assert.is_true(patched:find("-- Execute the software wipe animation", 1, true) ~= nil)
    local sentinel_pos = patched:find("-- Execute the software wipe animation", 1, true)
    local anchor_pos = patched:find("    -- execute refreshes:", 1, true)
    Assert.is_true(sentinel_pos < anchor_pos)
    Assert.eq(count(patched, "-- Execute the software wipe animation"), 1)

    for _, name in ipairs({ "2-swipe-animation-core.lua", "2-swipe-animation-enable.lua", "2-pdf-animation.lua" }) do
        Assert.is_true(read(paths.patches .. "/" .. name) ~= nil, name .. " should be copied")
    end

    Assert.is_true(Manager.isApplied(DIR))
end

-- 幂等：重复安装不二次插入
do
    local paths = setup(FAKE_TARGET)
    Assert.is_true(Manager.install(DIR).ok)
    local second = Manager.install(DIR)
    Assert.is_true(second.ok, second.err)
    Assert.eq(second.changed, false)
    Assert.eq(count(read(paths.target), "-- Execute the software wipe animation"), 1)
end

-- 负载内容变了：重拷运行时补丁，不再插 uimanager
do
    local paths = setup(FAKE_TARGET)
    Assert.is_true(Manager.install(DIR).ok)
    local core = paths.patches .. "/2-swipe-animation-core.lua"
    write(core, "-- stale payload\n")
    local again = Manager.install(DIR)
    Assert.is_true(again.ok, again.err)
    Assert.eq(again.changed, true)
    Assert.is_true(read(core):find("require(\"logger\")", 1, true) ~= nil)
    Assert.eq(count(read(paths.target), "-- Execute the software wipe animation"), 1)
end

-- 备份→恢复：文件回到逐字节原样，补丁文件被清掉
do
    local paths = setup(FAKE_TARGET)
    Assert.is_true(Manager.install(DIR).ok)
    local restore = Manager.restore(DIR)
    Assert.is_true(restore.ok, restore.err)
    Assert.eq(read(paths.target), FAKE_TARGET)
    Assert.is_nil(read(paths.patches .. "/2-swipe-animation-core.lua"))
    Assert.is_false(Manager.isApplied(DIR))
end

-- 锚点缺失：失败且不落盘
do
    local no_anchor = "local Screen = Device.screen\n"
    local paths = setup(no_anchor)
    local res = Manager.install(DIR)
    Assert.is_false(res.ok)
    Assert.is_true((res.err or ""):find("anchor not found", 1, true) ~= nil)
    Assert.eq(read(paths.target), no_anchor)
    Assert.is_nil(read(paths.backups .. "/frontend/ui/uimanager.lua"))
end

-- 补丁分发失败触发回滚；回滚写回也失败时，错误必须点名需要手动恢复的文件
do
    local paths = setup(FAKE_TARGET)
    local real_open = io.open
    local target_writes = 0
    io.open = function(path, mode)
        if mode == "wb" and path:sub(1, #paths.patches) == paths.patches then
            return nil, "patches dir denied"
        end
        if mode == "wb" and path == paths.target .. ".tmp" then
            target_writes = target_writes + 1
            if target_writes > 1 then return nil, "target denied" end
        end
        return real_open(path, mode)
    end
    local res = Manager.install(DIR)
    io.open = real_open
    Assert.is_false(res.ok)
    Assert.eq(target_writes, 2)
    Assert.is_true(res.err:find("copy failed: patches dir denied", 1, true) ~= nil, res.err)
    Assert.is_true(res.err:find("rollback failed, restore manually: frontend/ui/uimanager.lua (target denied)", 1, true) ~= nil, res.err)
end

-- 回滚成功时错误只保留原因，目标回到原样
do
    local paths = setup(FAKE_TARGET)
    local real_open = io.open
    io.open = function(path, mode)
        if mode == "wb" and path:sub(1, #paths.patches) == paths.patches then
            return nil, "patches dir denied"
        end
        return real_open(path, mode)
    end
    local res = Manager.install(DIR)
    io.open = real_open
    Assert.eq(res.err, "copy failed: patches dir denied")
    Assert.eq(read(paths.target), FAKE_TARGET)
end

-- 目标文件缺失：失败
do
    local paths = setup(nil)
    local res = Manager.install(DIR)
    Assert.is_false(res.ok)
    Assert.is_true((res.err or ""):find("cannot read", 1, true) ~= nil)
end

-- 无备份恢复：失败且不写目标
do
    local paths = setup(FAKE_TARGET)
    Assert.is_true(Manager.install(DIR).ok)
    os.remove(paths.backups .. "/frontend/ui/uimanager.lua")
    local patched = read(paths.target)
    local res = Manager.restore(DIR)
    Assert.is_false(res.ok)
    Assert.is_true((res.err or ""):find("no backup", 1, true) ~= nil)
    Assert.eq(read(paths.target), patched)
end

-- 升级后（目标已不含标记）恢复：不用陈旧备份覆盖新文件，只清理补丁文件
do
    local paths = setup(FAKE_TARGET)
    Assert.is_true(Manager.install(DIR).ok)
    -- 模拟 KOReader 升级：目标被覆盖成无标记的新版本
    local upgraded = FAKE_TARGET .. "\n-- upgraded\n"
    write(paths.target, upgraded)
    local res = Manager.restore(DIR)
    Assert.is_true(res.ok, res.err)
    Assert.eq(read(paths.target), upgraded)
    Assert.is_nil(read(paths.patches .. "/2-swipe-animation-core.lua"))
end

-- definition.name 拼进备份路径：路径穿越之类的名字直接拒绝，不落盘。
do
    local paths = setup(FAKE_TARGET)
    local bad = paths.base .. "/bad"
    write(bad .. "/definition.lua", 'return { name = "../escape", files = {}, patches = {} }')
    local res = Manager.install(bad)
    Assert.is_false(res.ok)
    Assert.matches(res.err, "invalid definition.name")
    Assert.eq(read(paths.target), FAKE_TARGET)
end
