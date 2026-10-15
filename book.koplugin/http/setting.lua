--[[--
网络请求的配置声明（settings/http.lua，经 `utils.settings.get("http")` 读写）。

@module koplugin.book.http.setting
--]]

return {
    defaults = {
        -- 网络超时（秒）：普通请求的默认超时，其余请求按倍率 × 它；30 = 原先的缺省。见 http/timeout.lua。
        network_timeout = 30,
        -- 上次下载成功的默认源模板，下次优先尝试。
        mirror_last = "",
    },
}
