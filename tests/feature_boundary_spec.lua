-- 架构 lint：features/ 之外的插件代码不得依赖 features/*（静态 require、延迟 require、
-- 拼字符串的模块路径、package.loaded、全局都算）。main.lua 只许不点名地 require("features") 调加载器。
-- 下层不得出现「<feature 名>.xxx」端口式字符串；扩展点名必须在 utils/extension.lua 的 POINTS 里声明，
-- 且以下层命名空间开头、不含 feature 名。旧的 utils.ports / main.lua ports 段不得回来。
local Assert = ...

local ROOT = "book.koplugin"

--- 去掉 Lua 注释（--[[ ]] / --[==[ ]==] 块与行注释），保留字符串与行号。
local function stripComments(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == "-" and src:sub(i, i + 1) == "--" then
            local eq = src:match("^%[(=*)%[", i + 2)
            if eq then
                local close = "]" .. eq .. "]"
                local e = src:find(close, i + 4 + #eq, true) or n
                local body = src:sub(i, e + #close - 1)
                out[#out + 1] = body:gsub("[^\n]", "")
                i = e + #close
            else
                local e = src:find("\n", i, true) or n + 1
                i = e
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c or d == "\n" then break
                else j = j + 1 end
            end
            out[#out + 1] = src:sub(i, j)
            i = j + 1
        elseif c == "[" and src:match("^%[=*%[", i) then
            local eq = src:match("^%[(=*)%[", i)
            local close = "]" .. eq .. "]"
            local e = src:find(close, i + 2 + #eq, true) or n
            out[#out + 1] = src:sub(i, e + #close - 1)
            i = e + #close
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local PATTERNS = {
    { "[\"']features[%./][%w_]", "features.* 模块路径" },
    { "[\"']features[\"']", "require(\"features\")" },
    { "[\"']features%.[\"']", "拼接 features. 前缀" },
    { "[\"']features/[\"']", "拼接 features/ 前缀" },
    { "[%w_]*Features%s*[%.:%[]", "Features 全局 / 局部" },
    { "_G%s*%[%s*[\"']Features", "Features 全局" },
}

--- 返回 { "line: 说明" }。
local function violations(src)
    local out, lineno = {}, 0
    for line in (stripComments(src) .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        for _idx, p in ipairs(PATTERNS) do
            if line:find(p[1]) then out[#out + 1] = lineno .. ": " .. p[2] .. " — " .. line:gsub("^%s+", "") end
        end
    end
    return out
end

-- ── 检查器自测：每种绕法都要被抓到，注释不算 ──
do
    Assert.eq(#violations('local F = require("features.panel")'), 1)
    Assert.eq(#violations('local function f() return require("features.ocr").x() end'), 1, "延迟 require")
    Assert.eq(#violations('local m = require("features." .. name .. ".topbar")'), 1, "拼路径")
    Assert.eq(#violations("local m = require('features/' .. name)"), 1, "斜杠拼路径")
    Assert.is_true(#violations('local s = Settings.get("features.baike")') >= 1, "设置分区串")
    Assert.is_true(#violations('local F = require("features")') >= 1)
    Assert.is_true(#violations('Features.emit("x")') >= 1, "全局")
    Assert.is_true(#violations('local x = package.loaded["features.bars"]') >= 1)
    Assert.eq(#violations('-- require("features.x")\nlocal a = 1 --[[ features.y ]]'), 0, "注释不算")
    Assert.eq(#violations('local s = "a -- b" local t = Ext.call("quickpanel.show")'), 0)
end

-- ── feature 名单（features/ 下的目录，demo 除外；同名核心模块如 ai/ 不算端口串）──
local FEATURES = {}
do
    local pipe = assert(io.popen('ls -d ' .. ROOT .. '/features/*/'))
    for dir in pipe:lines() do
        local name = dir:match("([^/]+)/$")
        local core = io.open(ROOT .. "/" .. name .. ".lua") or io.open(ROOT .. "/" .. name .. "/init.lua")
        if core then core:close() elseif name ~= "demo" then FEATURES[#FEATURES + 1] = name end
    end
    pipe:close()
end
Assert.is_true(#FEATURES > 10, "扫到 feature 目录")

--- 端口式 feature 名字符串（"update.autoCheck"、'ocr.fill' 之类），返回 { "line: 说明" }。
local function portStrings(src)
    local out, lineno = {}, 0
    for line in (stripComments(src) .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        for _idx, name in ipairs(FEATURES) do
            for _q, q in ipairs({ '"', "'" }) do
                if line:find(q .. name .. "%.[%a_]") then
                    out[#out + 1] = lineno .. ": 端口式 feature 名 " .. name .. ".* — " .. line:gsub("^%s+", "")
                end
            end
        end
    end
    return out
end

do
    Assert.eq(#portStrings('Ports.call("update.autoCheck")'), 1, "端口串")
    Assert.eq(#portStrings("x('ocr.fillSelection')"), 1, "单引号")
    Assert.eq(#portStrings('local id = "update"'), 0, "页签 id 本身不算端口串")
    Assert.eq(#portStrings('-- "bars.injectStatusLine"'), 0, "注释不算")
end

-- ── 全插件扫描 ──
local files = {}
do
    local pipe = assert(io.popen('find ' .. ROOT .. ' -type f -name "*.lua" -not -path "' .. ROOT .. '/features/*" | sort'))
    for path in pipe:lines() do files[#files + 1] = path end
    pipe:close()
end
Assert.is_true(#files > 50, "扫到插件文件")

local found = {}
for _idx, path in ipairs(files) do
    local f = assert(io.open(path, "r"))
    local src = f:read("*a")
    f:close()
    if path == ROOT .. "/main.lua" then
        -- 组合根只许 require("features") 本身（加载器 / 生命周期分发），不许点名子模块。
        src = src:gsub('require%("features"%)', "require(F)")
        for _i, v in ipairs(violations(src)) do
            if not v:find("Features 全局", 1, true) then found[#found + 1] = path .. ":" .. v end
        end
    else
        for _i, v in ipairs(violations(src)) do found[#found + 1] = path .. ":" .. v end
    end
    for _i, v in ipairs(portStrings(src)) do found[#found + 1] = path .. ":" .. v end
    if src:find("utils.ports", 1, true) or src:find("ports:begin", 1, true) then
        found[#found + 1] = path .. ": 旧端口 utils.ports / ports 段"
    end
end
Assert.eq(#found, 0, "下层依赖了 feature（改成下层声明通用扩展点、feature 在自己 init 里登记）：\n" .. table.concat(found, "\n"))

-- ── 扩展点：用到的名字都已声明；声明的名字以下层命名空间开头、不含 feature 名 ──
package.path = ROOT .. "/?.lua;" .. package.path
local Ext = require("utils.extension")
local NAMESPACES = { desktop = true, topbar = true, setting = true, reader = true, highlight = true, note = true, quickpanel = true,
    web = true } -- web.*：远程管理网页的接口挂点（提供者登记 /api/<name>/*，不含 feature 名）
local bad = {}
for point in pairs(Ext.POINTS) do
    local ns = point:match("^([%w_]+)%.")
    if not NAMESPACES[ns] then bad[#bad + 1] = "命名空间不对: " .. point end
    for token in point:gmatch("[^%._]+") do
        for _idx, name in ipairs(FEATURES) do
            if token == name then bad[#bad + 1] = "扩展点名含 feature 名: " .. point end
        end
    end
end
local all = {}
do
    local pipe = assert(io.popen('find ' .. ROOT .. ' -type f -name "*.lua" | sort'))
    for path in pipe:lines() do all[#all + 1] = path end
    pipe:close()
end
local used = 0
for _idx, path in ipairs(all) do
    local f = assert(io.open(path, "r"))
    local src = stripComments(f:read("*a"))
    f:close()
    for _i, pat in ipairs({ 'Ext%.%a+%(%s*"([^"]+)"', 'utils%.extension"%)%.%a+%(%s*"([^"]+)"' }) do
        for point in src:gmatch(pat) do
            used = used + 1
            if not Ext.POINTS[point] then bad[#bad + 1] = path .. " → 未声明扩展点 " .. point end
        end
    end
end
Assert.is_true(used > 15, "扫到扩展点调用")
Assert.eq(#bad, 0, table.concat(bad, "\n"))

-- 远程管理是通用外壳：features/remote 下任何文件（含 html/js/css、网页文案）都不得出现具体功能的字眼，
-- 订阅、公众号、微信等一律经 web.routes 由各自 feature 注册（含注释，防止再写死回来）。
do
    local FORBID = { "subscri", "%f[%w]mp%f[%W]", "%f[%w]mp_", "wechat", "weixin", "weread", "feed", "opml", "rss",
        "订阅", "公众号", "微信" }
    local bad = {}
    local pipe = assert(io.popen('find ' .. ROOT .. '/features/remote -type f | sort'))
    for path in pipe:lines() do
        if not path:match("%.png$") and not path:match("%.jpg$") and not path:match("%.ico$") then
            local f = assert(io.open(path, "rb"))
            local lineno = 0
            for line in f:lines() do
                lineno = lineno + 1
                local low = line:lower()
                for _i, p in ipairs(FORBID) do
                    if low:find(p) then bad[#bad + 1] = path .. ":" .. lineno .. " 含「" .. p .. "」" end
                end
            end
            f:close()
        end
    end
    pipe:close()
    Assert.eq(#bad, 0, table.concat(bad, "\n"))
end
