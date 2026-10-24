--[[--
书源选择的配置声明（settings/source.lua，经 `utils.settings.get("source")` 读写）。

@module koplugin.book.source.setting
--]]

return {
    defaults = {
        active_source = "local",
        -- 书库/首页/统计等展示是否跨已启用源混合（阅读仍按书的 source_id）。
        library_mixed = false,
        -- 本地加入书架的书是否上传到云书架（关掉只同步进度 / 笔记 / 统计）。
        push_local_shelf = true,
    },
    -- enabled_sources 为 nil = 全部启用，见 source.registry。
    keys = { "enabled_sources" },
}
