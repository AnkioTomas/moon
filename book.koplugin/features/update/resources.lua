--[[--
在线词库更新提醒：已装的注音词库、输入法词库，远端 manifest 版本和本地不同就提示一次。

只对已经下载过的词库查（没装的不打扰）；只比 manifest 的 built_at，不下分片。
随插件的「自动检查更新」开关，每天最多一次；用户确认后才下载，逐个装、前台进度窗。
离线 / 查询失败静默，等下次。

@module koplugin.book.features.update.resources
--]]

local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

local Resources = {}

local CHECK_INTERVAL = 24 * 60 * 60

--- 已安装的词库：{ label, spec }。自制注音词库没有远端，不查。
---@return { label: string, spec: BookDictSpec }[]
function Resources.installed()
    local Catalog = require("features.rare.catalog")
    local Download = require("features.ime.download")
    local out = {}
    for _idx, item in ipairs(Catalog.remote()) do
        if Catalog.installed(item.id) then
            out[#out + 1] = { label = T(_("注音词库：%1"), item.label), spec = Catalog.spec(item.id) }
        end
    end
    local Paths = require("utils.paths")
    local lfs = require("libs/libkoreader-lfs")
    local built = MoonSettings.get("features.ime").ime_dict_built_at
    for _idx, method in ipairs({ "pinyin", "wubi", "cangjie", "zhuyin" }) do
        if built[method] and lfs.attributes(Paths.imeDictPath(method), "mode") == "file" then
            out[#out + 1] = { label = T(_("输入法词库：%1"), method), spec = Download.imeSpec(method) }
        end
    end
    return out
end

--- 逐个查版本；cb(有更新的项数组)。
---@param items { label: string, spec: BookDictSpec }[]
---@param cb fun(stale: { label: string, spec: BookDictSpec }[])
function Resources.findStale(items, cb)
    local Download = require("features.ime.download")
    local stale = {}
    local function step(i)
        if i > #items then
            cb(stale)
            return
        end
        Download.outdated(items[i].spec, function(outdated)
            if outdated then stale[#stale + 1] = items[i] end
            step(i + 1)
        end)
    end
    step(1)
end

--- 在一个任务里依次更新；单项失败不拦后面的，结束时提示结果。
---@param stale { label: string, spec: BookDictSpec }[]
function Resources.updateAll(stale)
    local Download = require("features.ime.download")
    local Toast = require("ui.themes.widgets.toast")
    require("workers.ui.task_dialog").start{
        key = "resources:update",
        kind = "download",
        title = _("更新词库"),
        run = function(report, done)
            local failed = {}
            local function step(i)
                if i > #stale then
                    done({ failed = failed })
                    return
                end
                local item = stale[i]
                Download.install(item.spec, function(ok)
                    if not ok then failed[#failed + 1] = item.label end
                    step(i + 1)
                end, function(stage, bytes, total)
                    report(item.label, stage == "part" and bytes or nil, stage == "part" and total or nil)
                end)
            end
            step(1)
        end,
        on_done = function(result)
            require("features.rare.overlay").invalidate()
            Toast:new{
                text = #result.failed == 0 and _("词库已更新")
                    or T(_("更新失败：%1"), table.concat(result.failed, "、")),
                timeout = 3,
            }:show()
        end,
    }
end

--- 按天静默检查；有更新才弹确认。没连网 / 正在下载不查。
function Resources.autoCheck()
    local settings = MoonSettings.get("features.update")
    if not settings.auto_update_check then return end
    if os.time() - settings.resource_last_checked_at < CHECK_INTERVAL then return end
    if not require("ui/network/manager"):isConnected() then return end
    if require("features.ime.download").downloading() then return end
    local items = Resources.installed()
    settings.resource_last_checked_at = os.time()
    MoonSettings.save("features.update", settings)
    if #items == 0 then return end
    Resources.findStale(items, function(stale)
        if #stale == 0 then return end
        local names = {}
        for _idx, item in ipairs(stale) do names[#names + 1] = item.label end
        require("ui.themes.widgets.confirm"):new{
            title = _("词库有更新"),
            text = table.concat(names, "\n"),
            ok_text = _("更新"),
            ok_callback = function() Resources.updateAll(stale) end,
        }:show()
    end)
end

return Resources
