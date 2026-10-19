--[[--
核心扩展点注册表：下层（桌面、顶栏、设置树、阅读器、划词菜单、会话）声明通用挂点，
上层（features/、第三方）往里登记实现。下层只按挂点名取用，不知道谁登记、也不写任何 feature 名。

挂点名一律以下层自己的命名空间开头（desktop.* / modal.* / topbar.* / setting.* / reader.* / highlight.* / note.* / web.*），
完整清单与各项形状见下方 `POINTS`；登记未声明的挂点直接报错，防止拼错名静默失效。

    Ext.add("desktop.activated", function(desktop) ... end)   -- 追加一项
    for _, fn in ipairs(Ext.list("desktop.activated")) do ... end
    Ext.call("quickpanel.show", "desktop")                     -- 单一提供者：取最后登记的那项调用
    Ext.emit("reader.ready", plugin)                           -- 逐项调用（经 ui.guard 隔离）

@module koplugin.book.utils.extension
--]]

local Ext = {}

--- 已声明的挂点：名字 → 说明。新增挂点 = 在这里加一行，并在下层取用处写清形状。
Ext.POINTS = {
    ["desktop.tabs"] = "底栏页签 { id, text, icon, after?, enabled():bool, create?(opts):page, tap?(desktop, rect, cell_id?), cells?(room):{id,text,icon}[]|nil（按屏宽剩余空格数换成多个格子，nil = 仍是一格） }",
    ["desktop.backdrop"] = "单一提供者：桌面背景 { content(page, tab), tabbar(bar, tab), wrap(w, h, child, tab) -> widget }（tab 为当前页签 id；透底 / 垫在三层之下）",
    ["modal.backdrop"] = "单一提供者：主题弹窗在遮罩之下先画背景 fn(modal, bb, x, y)",
    ["desktop.activated"] = "桌面回到前台 fn(desktop)",
    ["desktop.opened"] = "桌面打开并显示后 fn(desktop)",
    ["quickpanel.show"] = "单一提供者：打开快捷面板 fn(scope)",
    ["topbar.light_percent"] = "单一提供者：前光读数 fn(kind) -> number",
    ["topbar.items"] = "顶栏项来源 fn() -> BookTopBarItem[]（after 指定插在哪个核心项后）",
    ["setting.entries"] = "设置条目来源 { owner, entries = fn(desktop) -> BookSettingEntry[] }",
    ["setting.groups"] = "设置根页分组 { id, title, after? }",
    ["highlight.relabel"] = "划词菜单按钮改名 fn(key) -> string|nil（按钮行为已由提供者接管时给新名字）",
    ["highlight.fill_selection"] = "单一提供者：划词无文字时补选区 fn(menu) -> bool",
    ["reader.ready"] = "阅读页就绪 fn(plugin)",
    ["reader.doc_settings"] = "开书前改文档设置 fn(doc_settings, document)",
    ["reader.preferences"] = "开书后套用偏好 fn(ui)",
    ["web.routes"] = "远程管理接口 { name, handle(method, action, params, cb(status, table)), download?(action) -> { ctype, filename, body }|nil, dir?: string, assets?: string[], page?: { href, title, title_long?, desc?, icon, tile? }, l10n?: string }（/api/<name>/<action>；assets 为 dir 下开放的静态文件；page 进顶栏与首页；l10n 为网页文案模块前缀）",
    ["note.markup_classes"] = "页内插入的译文类元素 class（字符串）；划线端点落在其中时回退到原文",
}

local points = {}

local function check(point)
    assert(Ext.POINTS[point], "unknown extension point: " .. tostring(point))
end

--- 登记一项（追加在已有项之后）。
---@param point string
---@param item any
function Ext.add(point, item)
    check(point)
    assert(item ~= nil, "Ext.add: item is nil")
    local list = points[point]
    if not list then
        list = {}
        points[point] = list
    end
    list[#list + 1] = item
end

--- 某挂点的全部项（按登记顺序，返回副本）。
---@param point string
---@return any[]
function Ext.list(point)
    check(point)
    local out = {}
    for i, item in ipairs(points[point] or {}) do out[i] = item end
    return out
end

--- 单一提供者挂点：最后登记的那项；没有返回 nil。
---@param point string
---@return any
function Ext.last(point)
    check(point)
    local list = points[point]
    return list and list[#list]
end

--- 调单一提供者；没人登记返回 nil。
---@param point string
---@return any
function Ext.call(point, ...)
    local fn = Ext.last(point)
    if fn then return fn(...) end
end

--- 逐项调用，每项经 ui.guard 隔离（一项出错不影响其余）。
---@param point string
function Ext.emit(point, ...)
    local Guard = require("ui.guard")
    for _idx, fn in ipairs(Ext.list(point)) do Guard.call("extension " .. point, fn, ...) end
end

--- 测试用：清空全部登记。
function Ext.reset()
    points = {}
end

return Ext
