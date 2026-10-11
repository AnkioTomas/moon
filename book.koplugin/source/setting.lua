--[[--
书源选择的配置声明（settings/source.lua，经 `utils.settings.get("source")` 读写）。

@module koplugin.book.source.setting
--]]

return {
    defaults = {
        active_source = "local",
        -- 书库/首页/统计等展示是否跨已启用源混合（阅读仍按书的 source_id）。
        library_mixed = false,
    },
    -- enabled_sources 为 nil = 全部启用，见 source.registry。
    keys = { "enabled_sources" },
}
