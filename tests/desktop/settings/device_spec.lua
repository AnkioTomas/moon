--[[-- 设备设置：根页头像行、我的设备页的本机信息与关于动作。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.themes.widgets.input"] = function() return {} end

local built = {}
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts)
            built[#built + 1] = opts
            return opts
        end,
    }
end

local qr
package.preload["ui.themes.widgets.qr"] = function()
    return {
        new = function(_, opts)
            qr = opts
            return { show = function() end }
        end,
    }
end

local opened_page, pushed, pushed_desk
package.preload["desktop.pages.setting.overlay"] = function()
    return {
        open = function(_desktop, page) opened_page = page end,
        push = function(_desktop, page) pushed = page end,
    }
end

local sheet
package.preload["ui.themes.widgets.sheet"] = function()
    return {
        new = function(_, opts)
            sheet = opts
            return { show = function() end }
        end,
    }
end

local store = { device_name = "书房", device_logo = "" }
package.preload["utils.settings"] = function()
    return { get = function() return store end, save = function() end }
end

local rev = "v2026.07-1"
package.preload["version"] = function()
    return { getCurrentRevision = function() return rev end }
end

local opened_url
local hw = {
    model = "Paperwhite",
    firmware_rev = "5.16.2",
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
        getDPI = function() return 300 end,
    },
    hasBattery = function() return true end,
    powerd = {
        getCapacity = function() return 42.2 end,
        isCharging = function() return true end,
    },
    canOpenLink = function() return true end,
    openLink = function(_, url) opened_url = url end,
}
package.preload["device"] = function() return hw end

local Page = require("desktop.pages.setting.device")

local function take()
    local rows = built
    built = {}
    return rows
end

local profile = Page.profileRow({}, { id = "device" })(400)
local row = take()[1]
Assert.eq(profile, row)
Assert.eq(row.title, "书房")
Assert.eq(row.image, "logo.png")
Assert.eq(row.image_w, 40)
Assert.eq(row.subtitle, "点按修改名称与头像")
row.callback()
Assert.eq(opened_page.id, "device")

store.device_name = "  "
Page.profileRow({}, { id = "device" })(400)
Assert.eq(take()[1].title, "月读 - Paperwhite")

local function rowsOf(sections)
    local out = {}
    for _, section in ipairs(sections) do
        local titles = {}
        for _, build in ipairs(section.rows) do
            titles[#titles + 1] = build(400)
        end
        out[#out + 1] = { title = section.title, rows = titles }
    end
    take()
    return out
end

local checks = {}
local Ext = require("utils.extension")
Ext.add("setting.version_check", function(path, force)
    checks[#checks + 1] = { path = path, force = force }
end)
Ext.add("setting.device_section", {
    id = "battery",
    icon = "battery_android_full",
    title = "电池",
    refresh_seconds = 15,
    right_icon = "swap_vert",
    right_callback = function(target) pushed_desk = target end,
    sections = function()
        return { { title = "电池", rows = {
            function(iw)
                return require("ui.themes.widgets.row").widget({
                    width = iw, icon = "battery_android_full", title = "健康度", status = "90.0%",
                })
            end,
        } } }
    end,
})
local desk = { plugin = { path = "/moon" } }
local sections = rowsOf(Page.infoSections(desk))
Assert.eq(sections[1].title, "本机")
Assert.eq(sections[2].title, "月读")
local facts = {}
for _, item in ipairs(sections[1].rows) do
    Assert.is_true(item.icon ~= nil and item.icon ~= "", item.title)
    facts[item.title] = item.status
end
Assert.eq(facts["型号"], "Paperwhite")
Assert.eq(sections[1].rows[1].icon, "devices")
Assert.eq(facts["屏幕"], "1072×1448 · 300 dpi")
Assert.eq(facts["固件"], "5.16.2")
Assert.is_nil(facts["健康度"])
Assert.eq(sections[1].rows[4].title, "电池")
Assert.eq(sections[1].rows[4].kind, "nav")
Assert.eq(sections[1].rows[4].icon, "battery_android_full")
sections[1].rows[4].callback()
Assert.eq(pushed.id, "battery")
Assert.eq(pushed.title, "电池")
Assert.eq(pushed.refresh_seconds, 15)
Assert.eq(pushed.right_icon, "swap_vert")
pushed.right_callback()
Assert.eq(pushed_desk, desk)
Assert.eq(pushed.sections()[1].title, "电池")
Assert.eq(pushed.sections()[1].rows[1](400).title, "健康度")
Assert.eq(sections[1].rows[5].title, "KOReader")
Assert.is_nil(facts["电量"])
Assert.eq(facts["KOReader"], "v2026.07-1")
Assert.eq(sections[2].rows[1].title, "版本")
Assert.eq(sections[2].rows[1].icon, "system_update")
Assert.eq(sections[2].rows[1].status, "0.0.0-dev")
sections[2].rows[1].callback()
sections[2].rows[1].hold_callback()
Assert.eq(checks[1].path, "/moon")
Assert.is_nil(checks[1].force)
Assert.eq(checks[2].force, true)

local function find(title)
    for _, section in ipairs(sections) do
        for _, item in ipairs(section.rows) do
            if item.title == title then return item end
        end
    end
end

for _, item in ipairs(sections[2].rows) do
    Assert.is_true(item.icon ~= nil and item.icon ~= "", item.title)
end
Assert.eq(sections[2].rows[2].title, "书友交流群")
Assert.eq(sections[2].rows[3].title, "Bug 反馈群")
Assert.eq(sections[2].rows[4].title, "关于")
Assert.is_nil(find("作者"))
Assert.is_nil(find("打开 GitHub"))
find("关于").callback()
Assert.eq(sheet.title, "关于")
local about_icons = {}
for _, item in ipairs(sheet.items) do
    if item.icon then about_icons[item.icon] = item end
end
Assert.is_nil(about_icons.qr_code)
Assert.is_nil(about_icons.bug_report)
Assert.eq(about_icons.person.text, "作者  AnkioTomas")
Assert.eq(about_icons.gavel.text, "许可证  GNU GPLv3")
about_icons.link.callback()
Assert.eq(opened_url, "https://github.com/AnkioTomas/moon")
Assert.is_nil(qr)

hw.canOpenLink = function() return false end
find("书友交流群").callback()
Assert.eq(qr.text, "https://qm.qq.com/q/Q9FHByplqC")
find("Bug 反馈群").callback()
Assert.eq(qr.text, "https://qm.qq.com/q/btmL9F4Cl2")

hw.model = nil
hw.firmware_rev = 34
hw.hasBattery = function() return false end
hw.screen.getDPI = function() return 0 end
rev = nil
local bare = {}
for _, item in ipairs(rowsOf(Page.infoSections(desk))[1].rows) do bare[item.title] = item.status end
Assert.eq(bare["屏幕"], "1072×1448")
Assert.is_nil(bare["型号"])
Assert.is_nil(bare["固件"])
Assert.is_nil(bare["电量"])
Assert.is_nil(bare["KOReader"])

return true
