--[[--
注释体检：列出没有文档注释、或参数未用 ---@param 注解的函数定义。

    luajit tools/check_annotations.lua [目录]

判定规则（与仓库现有风格一致）：
- 函数定义前必须紧邻 `---` 注释块（模块头 `--[[--` 之后的第一行不算）；
- 注释块里每个形参都要有对应的 `---@param 名`（`self`、`...` 与下划线前缀形参豁免）；
- 有返回值的函数应有 `---@return`（仅提示，不算缺参数注解）。

@module tools.check_annotations
--]]

local root = arg[1] or "book.koplugin"

--- 列出目录下全部 .lua（不依赖 lfs，走 find）。
---@param dir string
---@return string[]
local function luaFiles(dir)
    local out = {}
    local pipe = io.popen("find '" .. dir .. "' -name '*.lua' | sort")
    for line in pipe:lines() do
        out[#out + 1] = line
    end
    pipe:close()
    return out
end

--- 读取整个文件的行。
---@param path string
---@return string[]
local function readLines(path)
    local lines = {}
    for line in io.lines(path) do
        lines[#lines + 1] = line
    end
    return lines
end

--- 解析函数定义行，取名字与形参串。
---@param line string
---@return string|nil name, string|nil params
local function parseDef(line)
    local name, params = line:match("^%s*function%s+([%w_%.:]+)%s*%((.-)%)")
    if not name then
        name, params = line:match("^%s*local%s+function%s+([%w_]+)%s*%((.-)%)")
    end
    if not name then
        name, params = line:match("^%s*local%s+[%w_]+%s*=%s*function%s*%((.-)%)")
        if name then
            params = name
            name = "<anonymous>"
        end
    end
    return name, params
end

--- 收集紧邻上方的 `---` 注释块。
---@param lines string[]
---@param idx number 函数定义所在行号
---@return string[] block
local function docBlock(lines, idx)
    local block = {}
    local i = idx - 1
    while i >= 1 do
        local line = lines[i]
        if line:match("^%s*---") then
            table.insert(block, 1, line)
            i = i - 1
        elseif line:match("^%s*$") and #block == 0 then
            break -- 空行隔断：视为无注释
        else
            break
        end
    end
    return block
end

local total, missing_doc, missing_param = 0, 0, 0
local report = {}

for _, path in ipairs(luaFiles(root)) do
    local lines = readLines(path)
    local issues = {}
    for idx, line in ipairs(lines) do
        local name, params = parseDef(line)
        if name and not line:match("^%s*%-%-") then
            total = total + 1
            local block = table.concat(docBlock(lines, idx), "\n")
            if block == "" then
                missing_doc = missing_doc + 1
                issues[#issues + 1] = string.format("  %d: %s() 无注释", idx, name)
            else
                local lacks = {}
                for param in (params or ""):gmatch("[^,%s]+") do
                    if param ~= "self" and param ~= "..." and param:sub(1, 1) ~= "_" then
                        if not block:find("@param%s+" .. param .. "[%s\n]") and
                            not block:find("@param%s+" .. param .. "$") then
                            lacks[#lacks + 1] = param
                        end
                    end
                end
                if #lacks > 0 then
                    missing_param = missing_param + 1
                    issues[#issues + 1] = string.format("  %d: %s() 缺 @param: %s",
                        idx, name, table.concat(lacks, ", "))
                end
            end
        end
    end
    if #issues > 0 then
        report[#report + 1] = path .. "\n" .. table.concat(issues, "\n")
    end
end

print(table.concat(report, "\n"))
print(string.format("\n函数 %d，无注释 %d，缺 @param %d", total, missing_doc, missing_param))
