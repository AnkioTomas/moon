--[[--
功能开关：用户可以停用不用的 feature（不加载，省内存与启动时间），文件不动，随时可再启用。

被别的 feature 引用的 feature 一起停用：`DEPENDENTS[x]` 列出直接引用 x 的 feature，停 x 就连带停它们（递归）；
再启用时反过来，启用 x 要把 x 依赖的那些也一并启用。表由 `tests/features/manage/manage_spec.lua` 扫源码校验，
新增跨 feature 引用必须同步改这里。`update` 不开放停用，保证用户始终能自更新。

设置里只记「停用谁」（`features.manage.disabled`，已含连带项），下次启动加载器按它跳过这些 feature：
当前进程里已加载的模块还在用，不能当场卸载。

@module koplugin.book.features.manage
--]]

require("l10n").apply()
local _ = require("gettext")

local Manage = {}

---@class BookRemovableFeature
---@field id string features 下的目录名
---@field label string
---@field subtitle string

---@type BookRemovableFeature[]
Manage.ITEMS = {
    { id = "ai", label = _("AI 阅读助手"), subtitle = _("AI 解释、问书、章节摘要") },
    { id = "animation", label = _("翻页动画"), subtitle = _("需要给 KOReader 打补丁") },
    { id = "azw3", label = _("AZW3 支持"), subtitle = _("打开 AZW3 / KF8 书籍") },
    { id = "baike", label = _("百科"), subtitle = _("划词查百科") },
    { id = "bars", label = _("阅读状态栏"), subtitle = _("阅读页上下进度条") },
    { id = "bluetooth", label = _("蓝牙"), subtitle = _("联动蓝牙守护进程") },
    { id = "clock", label = _("时间与日期"), subtitle = _("时区与网络校时") },
    { id = "cookie", label = _("Cookie 存储"), subtitle = _("接收浏览器扩展同步的 Cookie") },
    { id = "dictionary", label = _("词典"), subtitle = _("多词典查词") },
    { id = "extensions", label = _("拓展页签"), subtitle = _("桌面底栏的其它插件入口") },
    { id = "ime", label = _("中文输入法"), subtitle = _("拼音、五笔、仓颉、注音") },
    { id = "keyboard", label = _("键盘增强"), subtitle = _("虚拟键盘的收起键") },
    { id = "lockscreen", label = _("锁屏显示"), subtitle = _("组合壁纸与锁屏主体") },
    { id = "nightmode", label = _("自动夜间与亮度"), subtitle = _("按时间或天气调整") },
    { id = "ocr", label = _("OCR 识字"), subtitle = _("图片文字识别") },
    { id = "panel", label = _("快捷面板"), subtitle = _("桌面与阅读页的快捷开关") },
    { id = "passcode", label = _("锁屏密码"), subtitle = _("唤醒后需要输入 PIN") },
    { id = "rare", label = _("生僻字注音"), subtitle = _("拼音、英语音标") },
    { id = "reflow", label = _("重新排版"), subtitle = _("整本书转成 EPUB 重排") },
    { id = "remote", label = _("远程管理"), subtitle = _("浏览器管理文件与设置") },
    { id = "reviews", label = _("他人段评"), subtitle = _("页内显示微信读书段评") },
    { id = "sidebar", label = _("阅读侧栏"), subtitle = _("阅读页右滑打开") },
    { id = "storage", label = _("存储空间"), subtitle = _("占用查看与清理") },
    { id = "subscribe", label = _("订阅"), subtitle = _("RSS 与网页订阅") },
    { id = "translate", label = _("翻译"), subtitle = _("划词翻译与双语对照") },
    { id = "wallpaper", label = _("壁纸"), subtitle = _("每日壁纸") },
    { id = "xray", label = _("X-Ray"), subtitle = _("人物与地点标注") },
}

--- 依赖 → 直接引用它的 feature：删前者必须连带删后者。
---@type table<string, string[]>
Manage.DEPENDENTS = {
    ai = { "rare" },
    baike = { "rare" },
    dictionary = { "rare" },
    ime = { "rare" },
    lockscreen = { "panel", "sidebar" },
    panel = { "bars", "nightmode", "sidebar" },
    passcode = { "remote" },
    rare = { "ai", "baike", "dictionary", "translate" },
    reflow = { "xray" },
    remote = { "lockscreen", "sidebar" },
    subscribe = { "storage" },
    translate = { "rare" },
    xray = { "sidebar" },
}

--- 删 id 时要一起删的 feature（含 id 自己，id 在最前，其余按发现顺序）。
---@param id string
---@return string[]
function Manage.closure(id)
    local out, seen = { id }, { [id] = true }
    local idx = 1
    while idx <= #out do
        for _i, dep in ipairs(Manage.DEPENDENTS[out[idx]] or {}) do
            if not seen[dep] then
                seen[dep] = true
                out[#out + 1] = dep
            end
        end
        idx = idx + 1
    end
    return out
end

---@param id string
---@return boolean
local function removable(id)
    for _idx, item in ipairs(Manage.ITEMS) do
        if item.id == id then return true end
    end
    return false
end

---@return string[]
local function marked()
    return require("utils.settings").get("features.manage").disabled
end

---@param id string
---@return boolean
function Manage.isMarked(id)
    for _idx, name in ipairs(marked()) do
        if name == id then return true end
    end
    return false
end

---@param id string
---@return string
function Manage.label(id)
    for _idx, item in ipairs(Manage.ITEMS) do
        if item.id == id then return item.label end
    end
    return id
end

--- 标记 / 取消标记；返回现在是否已标记。标记连带删它的依赖方；取消则连带恢复它依赖的那些
--- （即所有「删了就会删到 id」的 feature）。
---@param id string
---@return boolean
function Manage.toggle(id)
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.manage")
    local was = Manage.isMarked(id)
    local drop = {}
    if was then
        for _idx, item in ipairs(Manage.ITEMS) do
            for _i, member in ipairs(Manage.closure(item.id)) do
                if member == id then drop[item.id] = true end
            end
        end
    end
    local keep = {}
    for _idx, name in ipairs(s.disabled) do
        if not drop[name] then keep[#keep + 1] = name end
    end
    if not was then
        for _idx, name in ipairs(Manage.closure(id)) do
            if not Manage.isMarked(name) then keep[#keep + 1] = name end
        end
    end
    s.disabled = keep
    MoonSettings.save("features.manage", s)
    return not was
end

--- 加载器在 require 任何 feature 之前调：把已停用的从 list 里去掉，返回停用集合（目录扫描用）。
---@param list string[] Features.list（就地修改）
---@return table<string, boolean>
function Manage.apply(list)
    local off = {}
    for _idx, id in ipairs(marked()) do
        if removable(id) then
            off[id] = true
            for i = #list, 1, -1 do
                if list[i] == id then table.remove(list, i) end
            end
        end
    end
    return off
end

return Manage
