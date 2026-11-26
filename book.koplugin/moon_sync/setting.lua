--[[--
月读同步的配置声明（settings/moon_sync.lua，经 `utils.settings.get("moon_sync")` 读写）。

WebDAV 连接是这里的键。首次打开从旧分区，以及原来的本地源 settings/local.lua 搬过来。
没有默认值：空串是用户清掉的地址，补成 "" 会挡住搬迁。

@module koplugin.book.moon_sync.setting
--]]

return {
    defaults = {
        sync_fonts = false,
    },
    keys = { "webdav_url", "webdav_username", "webdav_password", "webdav_path" },
    adopt_sources = { "local" },
}
