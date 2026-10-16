--[[--
月读第三方书源描述：Kavita。契约见月读仓库 examples/moonsource-demo.koplugin/moon_source.lua。
实现在 moonsource_kavita/（带前缀：所有插件共用一个 package.path）。
--]]

local Source = require("moonsource_kavita.source")

return {
    api = 1,
    meta = Source.meta,
    new = Source.new,
    setting = require("moonsource_kavita.setting"),
    home = { require("moonsource_kavita.on_deck") },
}
