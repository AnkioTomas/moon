--[[--
兼容入口：安装逻辑已下移到 utils.plugin_install。

source/ 等下层模块不能依赖 features/；features/update 仍从这里 require，保持旧调用点不变。

@module koplugin.book.features.update.install
--]]

return require("utils.plugin_install")
