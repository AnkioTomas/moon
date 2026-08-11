--[[--
插件版本号（模块名 bookversion，避免与 KOReader 自带 version 冲突）。

外部打包时注入（任选其一）：
  1) 整文件覆盖：
       printf 'return "%s"\n' "$VERSION" > book.koplugin/bookversion.lua
  2) 占位符替换：
       sed -i.bak "s/@VERSION@/${VERSION}/g" book.koplugin/bookversion.lua

未注入时显示 0.0.0-dev。

@module koplugin.book.bookversion
--]]

local VERSION = "@VERSION@"

if type(VERSION) ~= "string" or VERSION == "" or VERSION == "@VERSION@" then
    return "0.0.0-dev"
end

return VERSION
