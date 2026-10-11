--[[-- 锁屏设置项（组合壁纸）。
@module koplugin.book.features.lockscreen.page
--]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Input = require("ui.themes.widgets.input")
local List = require("ui.themes.widgets.list")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
local LockScreen = require("features.lockscreen")
local Settings = require("features.lockscreen.settings")
local Compose = require("features.lockscreen.compose")
local Background = require("features.lockscreen.background")
local Components = require("features.lockscreen.components.base")
local Layout = require("features.lockscreen.layout")
local Bill = require("features.lockscreen.components.bill")
local Poster = require("features.lockscreen.components.poster")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsLockscreen
local Lockscreen = {}

--- 只重建锁屏设置叠层（含预览）；叠层已关则无事可做。
---@param desktop table 桌面实例
local function updateOverlay(desktop)
    if desktop.settings_overlay then desktop.settings_overlay:updateView() end
end

--- 设置项变更后重建设置页，并重新合成锁屏图。
--- 只有当前配置能离线出图时才直接生成，否则等联网——不然壁纸源拉不到会白跑一次。
---@param desktop table 桌面实例
local function refreshAfterChange(desktop)
    desktop:updateView()
    --- 合成一次锁屏图并提示结果，完成后刷新预览。
    local function refresh()
        Toast:new{ text = _("正在生成锁屏图…"), timeout = 2 }:show()
        -- 合成在主线程同步绘制；nextTick 仍排在重绘之前，必须隔一帧才能先把选中态和提示画出来。
        UIManager:tickAfterNext(function()
            LockScreen.refresh(function(ok, err)
                updateOverlay(desktop)
                Toast:new{
                    text = ok and _("锁屏图已更新")
                        or T(_("生成失败: %1"), tostring(err or "")),
                    timeout = 2,
                }:show()
            end, nil, "settings")
            if LockScreen.running() then updateOverlay(desktop) end
        end)
    end
    if Compose.plan().offline then
        refresh()
    else
        NetworkMgr:runWhenOnline(refresh)
    end
end

--- 弹输入框编辑锁屏自定义留言，保存后立刻重出图。
---@param desktop table 桌面实例
local function editMessage(desktop)
    Input:new{
        title = _("自定义留言"),
        fields = { { text = Settings.customMessage() } },
        ok_text = _("保存"),
        callback = function(text)
            Settings.setCustomMessage(text)
            refreshAfterChange(desktop)
        end,
    }:show()
end

--- 当前配置已合成的锁屏图路径；生成中 / 未生成返回 nil。
--- 改配置会清空 lock_screen_day，成功生成才写回；为空时盘上的图属于旧配置。
---@return string|nil
local function generatedPath()
    if LockScreen.running() or not require("utils.settings").get("features.lockscreen").lock_screen_day then
        return nil
    end
    local path = Compose.plan().output_path
    local attr = type(path) == "string" and path ~= "" and require("libs/libkoreader-lfs").attributes(path)
    if not attr or attr.mode ~= "file" or attr.size < 8 then
        return nil
    end
    return path
end

---@param desktop table
---@return table
function Lockscreen:rows(desktop)
    local enabled = Settings.isCompose()
    local rows = {
        function(iw)
            return Row.widget({
    width = iw,
    chevron = false,
                kind = "toggle", icon = "wallpaper", title = _("替代系统锁屏"),
                status = enabled and _("开") or _("关"), status_on = enabled,
                callback = function()
                    Settings.setMode(enabled and "ko" or "compose")
                    if enabled then
                        desktop:updateView()
                    else
                        refreshAfterChange(desktop)
                    end
                end,
            })
        end,
    }
    if not enabled then
        return rows
    end

    local plan = Compose.plan()
    local component_config = plan.component
    local component = component_config.id
    if component_config.uses_background ~= false then
        rows[#rows + 1] = function(iw)
            local background = plan.background_mode
            return Row.widget({
    width = iw,
    chevron = true,
                kind = "nav", icon = "image", title = _("背景"),
                status = Background.label(background),
                subtitle = Background.hint(background),
                callback = function()
                    List:new{
                        title = _("背景"),
                        items = Background.options(),
                        current = background, centered = true,
                        on_select = function(value)
                            if not value or value == background then return end
                            Settings.setBackgroundMode(value)
                            refreshAfterChange(desktop)
                        end,
                    }:show()
                end,
            })
        end
    end

    rows[#rows + 1] = function(iw)
        local label = _("无")
        for _idx, item in ipairs(Components.options()) do
            if item.value == component then
                label = item.text
                break
            end
        end
        return Row.widget({
    width = iw,
    chevron = true,
            kind = "nav", icon = "widgets", title = _("主体组件"),
            status = label,
            callback = function()
                List:new{
                    title = _("主体组件"),
                    items = Components.options(),
                    current = component, centered = true,
                    on_select = function(value)
                        if not value or value == component then return end
                        Settings.setComponent(value)
                        refreshAfterChange(desktop)
                    end,
                }:show()
            end,
        })
    end

    if component_config and component_config.supports_position ~= false then
        rows[#rows + 1] = function(iw)
            local position = plan.position
            return Row.widget({
    width = iw,
    chevron = true,
                kind = "nav", icon = "open_in_full", title = _("主体位置"),
                status = Layout.label(position),
                callback = function()
                    List:new{
                        title = _("主体位置"), items = Layout.options(), current = position,
                        centered = true,
                        on_select = function(value)
                            if not value or value == position then return end
                            Settings.setPosition(value)
                            refreshAfterChange(desktop)
                        end,
                    }:show()
                end,
            })
        end

        if plan.supports_narrow then
            rows[#rows + 1] = function(iw)
                local wide = plan.wide
                return Row.widget({
    width = iw,
    chevron = true,
                    kind = "nav", icon = "aspect_ratio", title = _("主体形态"),
                    status = wide and _("宽屏") or _("窄屏"),
                    callback = function()
                        List:new{
                            title = _("主体形态"),
                            items = {
                                { text = _("宽屏"), value = "wide" },
                                { text = _("窄屏"), value = "narrow" },
                            },
                            current = wide and "wide" or "narrow",
                            centered = true,
                            on_select = function(value)
                                if not value then return end
                                local next_wide = value == "wide"
                                if next_wide == wide then return end
                                Settings.setWide(next_wide)
                                refreshAfterChange(desktop)
                            end,
                        }:show()
                    end,
                })
            end
        end
    end

    if component == "bill" then
        rows[#rows + 1] = function(iw)
            local period = Settings.billPeriod()
            return Row.widget({
    width = iw,
    chevron = true,
                kind = "nav", icon = "date_range", title = _("账单周期"),
                status = Bill.periodLabel(period),
                callback = function()
                    List:new{
                        title = _("账单周期"),
                        items = Bill.periodOptions(),
                        current = period, centered = true,
                        on_select = function(value)
                            if not value or value == period then return end
                            Settings.setBillPeriod(value)
                            refreshAfterChange(desktop)
                        end,
                    }:show()
                end,
            })
        end
    end

    if component == "poster" then
        rows[#rows + 1] = function(iw)
            local style = Poster.style()
            return Row.widget({
    width = iw,
    chevron = true,
                kind = "nav", icon = "view_module", title = _("海报风格"),
                status = Poster.styleLabel(style),
                callback = function()
                    List:new{
                        title = _("海报风格"),
                        items = Poster.styleOptions(),
                        current = style, centered = true,
                        on_select = function(value)
                            if not value or value == style then return end
                            Settings.setPosterStyle(value)
                            refreshAfterChange(desktop)
                        end,
                    }:show()
                end,
            })
        end
    end

    if component == "message" then
        rows[#rows + 1] = function(iw)
            local text = Settings.customMessage()
            local preview = Text.truncateUtf8(text, 18)
            if preview ~= text then preview = preview .. "…" end
            return Row.widget({
    width = iw,
    chevron = true,
                kind = "nav", icon = "chat", title = _("自定义留言"),
                status = preview,
                callback = function() editMessage(desktop) end,
            })
        end
    end

    local path = generatedPath()
    if path then
        rows[#rows + 1] = function(iw)
            return Row.widget({
    width = iw,
    chevron = true,
                kind = "nav", icon = "share", title = _("分享锁屏图"),
                callback = function() require("features.remote.screenshot").share(path) end,
            })
        end
    end

    return rows
end

--- 全屏看锁屏图；点任意处（或返回键）退出。
---@param path string
local function showFullscreen(path)
    local ImageWidget = require("ui/widget/imagewidget")
    local Theme = require("ui.themes")
    local Box = require("ui.themes.widgets.box")
    local Modal = require("ui.themes.widgets.modal")
    local pw, ph = require("features.lockscreen.layout").portraitSize()
    local viewer = Modal:new{
        mask = false,
        close_on_tap = true,
        covers_fullscreen = true,
        close_callback = function() UIManager:setDirty(nil, "full") end,
    }
    local w, h = viewer.dimen.w, viewer.dimen.h
    viewer:setPanel(Box:new{
        style = { bg = Theme.current().color.page },
        width = w,
        height = h,
        ImageWidget:new{
            file = path, file_do_cache = false,
            scale_factor = math.min(w / pw, h / ph),
        },
    })
    viewer:show()
end

--- 已合成图缩略居中，点击全屏查看；关 / 生成中 / 未生成走同一高度空框。
---@param width number
---@return table
function Lockscreen.preview(width)
    local Overlay = require("desktop.pages.setting.overlay")
    local Theme = require("ui.themes")
    local preview_h = Theme.px(144)
    if not Settings.isCompose() then
        return Overlay.previewPlaceholder(width, preview_h, _("关"))
    end
    if LockScreen.running() then
        return Overlay.previewPlaceholder(width, preview_h, _("生成中…"))
    end
    local path = generatedPath()
    if not path then
        return Overlay.previewPlaceholder(width, preview_h, _("未生成"))
    end
    local Geom = require("ui/geometry")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local inner_w = math.max(1, width - 2)
    local inner_h = math.max(1, preview_h - 2)
    local tap = require("ui.widgets.book").tappable(width, preview_h, function()
        showFullscreen(path)
    end)
    local pw, ph = require("features.lockscreen.layout").portraitSize()
    tap[1] = Overlay.previewBox(width, CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        -- 不给 width/height：否则控件是整框，夜间模式整框反色，两侧留白变成白条。
        ImageWidget:new{
            file = path,
            scale_factor = math.min(inner_w / pw, inner_h / ph),
            -- compose.png 原地覆写，ImageCache 按路径命中会一直显示旧图。
            file_do_cache = false,
        },
    }, preview_h)
    return tap
end

return Lockscreen
