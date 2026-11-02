--[[--
GitHub Release 资产下载地址选择：直连与公益镜像并发探测，最先回 200 且长度对得上的胜出。

镜像不可信：只负责搬运字节，调用方必须用 Release 接口给的 sha256 校验；
选中前会核对 Content-Length 与 Content-Type，避免死镜像回自家首页。

@module koplugin.book.http.release
--]]

local Request = require("http.request")
local Mirror = require("http.mirror")
local logger = require("utils.log")

local Release = {}

local GITHUB = "https://github.com"
local PROBE_MIRRORS = 5
local PROBE_TIMEOUT_RATIO = 1 / 3 -- × 「网络超时」，缺省 10 秒

--- 并发探测直连与随机几个镜像：最先回 200 且长度对得上的胜出，全部失败回落直连。
--- 选中结果一律 nextTick 回调，不在 turbo 回调栈里取消自己那条流。
---@param release { url: string, size: number|nil }
---@param cb fun(url: string)
---@return table handle { cancel }
function Release.pick(release, cb)
    local UIManager = require("ui/uimanager")
    local path = release.url:sub(#GITHUB + 1)
    local pool = {}
    for _idx, prefix in ipairs(Mirror.RELEASE_PROXIES) do
        if not Mirror.isDead(prefix) then pool[#pool + 1] = prefix end
    end
    local prefixes = { GITHUB }
    for i = 1, math.min(PROBE_MIRRORS, #pool) do
        local j = math.random(i, #pool)
        pool[i], pool[j] = pool[j], pool[i]
        prefixes[#prefixes + 1] = pool[i]
    end
    local jobs, pending, settled = {}, #prefixes, false
    local bad, flagged = {}, {}
    local function flag(i)
        if i > 1 and not settled and not flagged[i] then
            flagged[i] = true
            bad[#bad + 1] = prefixes[i]
        end
    end
    local function cancelAll()
        settled = true
        for _idx, job in ipairs(jobs) do job:cancel() end
    end
    local function settle(url)
        if settled then return end
        cancelAll()
        -- 有源胜出说明网络通：同场已确定失败的镜像（不含直连）落盘拉黑
        if url ~= release.url then Mirror.markDead(bad) end
        logger.dbg("book.release download from", url)
        cb(url)
    end
    for i, prefix in ipairs(prefixes) do
        local url = prefix .. path
        jobs[i] = Request.stream({
            url = url,
            timeout = require("http.timeout").net(PROBE_TIMEOUT_RATIO),
            allow_redirects = true,
        }, {
            on_headers = function(code, headers)
                local function reject() flag(i) end
                if code ~= 200 then return reject() end
                local length = tonumber((headers:get("Content-Length", true)))
                if length and release.size and length ~= release.size then return reject() end
                -- 死镜像常回 200 + 自家首页且不带长度，只凭长度拦不住。
                local mime = headers:get("Content-Type", true)
                if mime and mime:lower():find("text/html", 1, true) then return reject() end
                UIManager:nextTick(require("ui.guard").wrap("release settle", function() settle(url) end))
            end,
            on_done = function(err)
                if err then flag(i) end
                pending = pending - 1
                if pending == 0 then
                    UIManager:nextTick(require("ui.guard").wrap("release settle",
                        function() settle(release.url) end))
                end
            end,
        })
    end
    return { cancel = cancelAll }
end

return Release
