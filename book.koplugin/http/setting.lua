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
        -- 主机名（小写）→ IPv4 或 IPv6。命中后不再查询 DNS，给内网主机用。见 http/dns.lua Dns.binding。
        dns_bind = {},
        -- 休眠（按电源键 / 自动休眠）时替用户关闭 Wi-Fi，见 http/wifi.lua。
        wifi_off_on_suspend = false,
        -- 上次下载成功的仓库文件镜像模板，下次优先使用。
        mirror_last = "",
        -- 从 api.ankio.net/gh/mirrors 拉回的仓库文件镜像模板（jsdelivr + raw），长期缓存。
        mirror_files = {},
        -- 上次下载成功的 Release 加速前缀，下次优先使用。
        mirror_release_last = "",
        -- 从 api.ankio.net/gh/mirrors 拉回的 Release 加速前缀，长期缓存。
        mirror_release = {},
        -- 竞速 / 回落中失败过的源 → 失败时间；Github.DEAD_TTL 内不再尝试。
        mirror_dead = {},
    },
}
