--[[--
安装完整性自检：发布包带 manifest.txt（每行一个模块名，与 utils.modules 的索引键同写法），
启动时对照实际扫到的模块，缺文件就不加载业务代码，直接提示重装。
解压中断、覆盖解压漏文件、只拷了一部分目录，都会落到这里；开发树没有 manifest.txt，不检查。
多出来的旧文件（旧版本残留）不拦：它们只是占地方，拦了反而让用户进不去。

目录名必须是 `book.koplugin`：PluginLoader 用目录名挂实例（ui.book）。叫错（例如
fontmap.koplugin）时 ui.book 是 nil，关书回桌面会 Desktop.open(nil) 崩，错误页还误报成「其它插件」。

@module koplugin.book.install_check
--]]

local M = {}

M.REQUIRED_DIR = "book.koplugin"

--- 插件根目录名是否正确。
---@param root string
---@return string|nil wrong 错误的目录名；正确返回 nil
function M.dirName(root)
    if type(root) ~= "string" or root == "" then return "?" end
    local name = root:gsub("[/\\]+$", ""):match("([^/\\]+)$") or "?"
    if name == M.REQUIRED_DIR then return nil end
    return name
end

--- 对照 manifest.txt 与扫描到的模块表。
---@param root string 插件根目录
---@param index table<string, string> utils.modules.install 的结果
---@return string[]|nil missing 缺失模块（排序）；没有 manifest 或不缺返回 nil
function M.check(root, index)
    local file = io.open(root .. "/manifest.txt", "r")
    if not file then return nil end
    local missing = {}
    for line in file:lines() do
        if line ~= "" and not index[line] then missing[#missing + 1] = line end
    end
    file:close()
    if #missing == 0 then return nil end
    table.sort(missing)
    return missing
end

--- 缺文件时 main.lua 直接返回的占位插件：只弹一次提示。
---@param WidgetContainer table
---@param missing string[]
---@return table
function M.stub(WidgetContainer, missing)
    local shown = false
    return WidgetContainer:extend{
        name = "book",
        init = function()
            if shown then return end
            shown = true
            local _ = require("gettext")
            local T = require("ffi/util").template
            local InfoMessage = require("ui/widget/infomessage")
            require("ui/uimanager"):show(InfoMessage:new{
                text = T(_("月读安装不完整，缺少 %1 个文件，例如：\n%2.lua\n\n请删除整个 book.koplugin 目录，重新解压最新版本（不要覆盖解压）。"),
                    #missing, missing[1]),
            })
        end,
    }
end

--- 目录名错误时的占位插件：只弹一次，说明必须叫 book.koplugin。
---@param WidgetContainer table
---@param wrong string 实际目录名
---@return table
function M.wrongDir(WidgetContainer, wrong)
    local shown = false
    return WidgetContainer:extend{
        name = "book",
        init = function()
            if shown then return end
            shown = true
            local _ = require("gettext")
            local T = require("ffi/util").template
            local InfoMessage = require("ui/widget/infomessage")
            require("ui/uimanager"):show(InfoMessage:new{
                text = T(_("月读目录名必须是 book.koplugin，当前是「%1」。\n\n请把该文件夹改名为 book.koplugin 后重启 KOReader。目录名不对时关书回桌面会崩溃，并被误报成其它插件出错。"),
                    wrong),
            })
        end,
    }
end

return M
