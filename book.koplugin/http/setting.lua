--[[--
网络请求的配置声明（settings/http.lua，经 `utils.settings.get("http")` 读写）。

@module koplugin.book.http.setting
--]]

return {
    defaults = {
        -- 网络超时（秒）：普通请求的默认超时，其余请求按倍率 × 它；30 = 原先的缺省。见 http/timeout.lua。
        network_timeout = 30,
        -- 备选 DNS（与系统 DNS 竞速）：ali / tencent，见 http/dns.lua PROVIDERS。
        dns = "ali",
        -- 上次下载成功的默认源模板，下次优先尝试。
        mirror_last = "",
        -- 竞速 / 回落中失败过的源 → 失败时间；Mirror.DEAD_TTL 内不再尝试。
        mirror_dead = {},
    },
}
