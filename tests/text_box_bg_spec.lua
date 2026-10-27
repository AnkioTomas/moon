-- 架构 lint：Text.box 默认拿页面白铺满整个文字矩形，落在任何表面上都会多出一块底
-- （段评弹窗的原句在真机上显出一块矩形，就是这么来的）。所有调用必须显式表态：
-- 直接落在表面上不铺底的传 transparent（首页一言、英雄卡、段评等），弹窗正文按弹窗惯例传 bg。
-- 只测量的探针也要表态，免得日后被顺手拿来显示又踩一遍。
local Assert = require("support.assert")

local ROOT = "book.koplugin"
local DEFINITION = ROOT .. "/ui/themes/widgets/text.lua"

--- 取从 pos 处 '(' 起到配对 ')' 的整段调用文本（跳过字符串里的括号）。
local function callText(src, pos)
    local depth, i, n = 0, pos, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c then break
                else j = j + 1 end
            end
            i = j + 1
        elseif c == "(" then
            depth = depth + 1
            i = i + 1
        elseif c == ")" then
            depth = depth - 1
            i = i + 1
            if depth == 0 then return src:sub(pos, i - 1) end
        else
            i = i + 1
        end
    end
    return src:sub(pos)
end

--- opts 以变量传进来时，回溯它最近一次表字面量赋值，底色可能写在那里。
---@param src string
---@param pos integer 调用位置
---@param call string 调用文本
---@return string
local function withOptsTable(src, pos, call)
    local var = call:match(",%s*([%a_][%w_]*)%s*%)$")
    if not var then return call end
    local at
    for start in src:sub(1, pos):gmatch("()" .. var .. "%s*=%s*{") do at = start end
    if not at then return call end
    local brace = src:find("{", at, true)
    local depth, i, n = 0, brace, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == "{" then depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return call .. " " .. src:sub(brace, i) end
        end
        i = i + 1
    end
    return call
end

--- 返回 { "行号: 调用首行" }：Text.box 调用里既没 transparent 也没 bg 的。
local function violations(src)
    local out = {}
    for pos in src:gmatch("()%.box%(%s*\"") do
        local call = withOptsTable(src, pos, callText(src, src:find("(", pos, true)))
        if not call:find("transparent", 1, true) and not call:find("bg%s*=") then
            local lineno = select(2, src:sub(1, pos):gsub("\n", ""))
            out[#out + 1] = (lineno + 1) .. ": " .. call:match("^[^\n]*")
        end
    end
    return out
end

-- ── 检查器自测 ──
Assert.eq(#violations('Text.box("body", t, w)'), 1, "没表态要抓")
Assert.eq(#violations('Text.box("body", t, w, { transparent = true })'), 0)
Assert.eq(#violations('Text.box("body", t, w, { bg = t.dialog.bg })'), 0)
Assert.eq(#violations('Text.box("body", "括号(在字符串里", w, { transparent = true })'), 0, "字符串里的括号不算")
Assert.eq(#violations('Text.box("body", t, w, {\n    max_lines = 2,\n})'), 1, "多行调用也要抓")
Assert.eq(#violations('local opts = { bg = t.dialog.bg }\nText.box("body", t, w, opts)'), 0, "变量 opts 里的 bg 算数")
Assert.eq(#violations('local opts = { height = 9 }\nText.box("body", t, w, opts)'), 1, "变量 opts 没交代底色要抓")

-- ── 全插件扫描（text.lua 是定义与文档示例，不算调用方）──
local files = {}
do
    local pipe = assert(io.popen('find ' .. ROOT .. ' -type f -name "*.lua" | sort'))
    for path in pipe:lines() do files[#files + 1] = path end
    pipe:close()
end
Assert.is_true(#files > 50, "扫到插件文件")

local sites, found = 0, {}
for _idx, path in ipairs(files) do
    if path ~= DEFINITION then
        local f = assert(io.open(path, "r"))
        local src = f:read("*a")
        f:close()
        for _pos in src:gmatch("()%.box%(%s*\"") do sites = sites + 1 end
        for _i, v in ipairs(violations(src)) do found[#found + 1] = path .. ":" .. v end
    end
end
Assert.is_true(sites > 15, "扫到 Text.box 调用")
Assert.eq(#found, 0, "Text.box 没交代底色（落在表面上不铺底传 transparent，弹窗正文传 bg）：\n"
    .. table.concat(found, "\n"))
