--[[--
存储空间管理：维护组里的导航页，列出设备空间与月读各类数据的占用（类似手机的存储空间管理）。

统计结果缓存在桌面实例的 `storage_usage` 上（1 分钟内复用），算完后刷新叠层；没算完时显示「计算中…」。

@module koplugin.book.features.storage.setting
--]]

local _ = require("gettext")

local Setting = {}

local FRESH_SECONDS = 60

local function friendly(bytes)
    return require("util").getFriendlySize(bytes) or tostring(bytes)
end

--- 缓存过期或没有就起一次统计（同一时刻只有一个在飞）。
---@param desktop BookDesktop
local function ensureMeasured(desktop)
    local cached = desktop.storage_usage
    if desktop.storage_job or (cached and os.time() - cached.at < FRESH_SECONDS) then return end
    desktop.storage_job = require("features.storage.usage").measureAsync(function(list, total)
        desktop.storage_job = nil
        desktop.storage_usage = { at = os.time(), list = list, total = total }
        if not desktop.closed and desktop.settings_overlay then desktop.settings_overlay:updateView() end
    end)
end

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local Row = require("ui.themes.widgets.row")
    local Usage = require("features.storage.usage")
    ensureMeasured(desktop)
    local disk = require("util").diskUsage(require("datastorage"):getDataDir())
    local device = {}
    if disk.total then
        device[#device + 1] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "storage", title = _("设备总容量"),
                status = friendly(disk.total), status_on = true })
        end
        device[#device + 1] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "hard_drive", title = _("已用"),
                status = friendly(disk.used), status_on = true })
        end
        device[#device + 1] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "sd_card", title = _("可用"),
                status = friendly(disk.available), status_on = true })
        end
    end
    local cached = desktop.storage_usage
    local rows = {}
    if not cached then
        rows[1] = function(iw)
            return Row.widget({ width = iw, chevron = false, icon = "hourglass_empty", title = _("计算中…") })
        end
    else
        for _idx, item in ipairs(cached.list) do
            rows[#rows + 1] = function(iw)
                return Row.widget({ width = iw, chevron = false, icon = "folder", title = Usage.label(item[1]),
                    status = friendly(item[2]), status_on = true })
            end
        end
    end
    local title = cached and _("月读占用") .. " · " .. friendly(cached.total) or _("月读占用")
    return { { title = _("设备"), rows = device }, { title = title, rows = rows } }
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "maintenance",
            order = 10,
            id = "storage", icon = "storage", title = _("存储空间"),
            subtitle = _("查看设备空间与月读各类数据的占用"),
            page = { title = _("存储空间"), sections = function() return sections(desktop) end },
        },
    }
end

return Setting
