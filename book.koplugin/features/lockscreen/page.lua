--[[-- 锁屏设置项（组合壁纸）。
@module koplugin.book.features.lockscreen.page
--]]

local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Confirm = require("ui.themes.widgets.confirm")
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
local Poster = require("features.lockscreen.poster")
local Image = require("utils.image")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local ADS_URL = "https://moon.ankio.net/jailbreak/ads"

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
        UIManager:tickAfterNext(require("ui.guard").wrap("lockscreen refresh", function()
            LockScreen.refresh(function(ok, err)
                updateOverlay(desktop)
                Toast:new{
                    text = ok and _("锁屏图已更新")
                        or T(_("生成失败: %1"), tostring(err or "")),
                    timeout = 2,
                }:show()
            end, nil, "settings")
            if LockScreen.running() then updateOverlay(desktop) end
        end))
    end
    if Compose.plan().offline then
        refresh()
    else
        NetworkMgr:runWhenConnected(refresh)
    end
end

--- 导航行；opts 即 Row.widget 参数（宽度在绘制时补上）。
---@param opts table
---@return fun(iw: number): table
local function navRow(opts)
    return function(iw)
        opts.width, opts.kind = iw, "nav"
        return Row.widget(opts)
    end
end

--- 单选行：点开列表，选中新值写配置并重出图；apply 返回 false 表示还没定（如另开了选择器），不重出图。
---@param desktop table
---@param opts { icon: string, title: string, status: string, items: table[], current: string, apply: fun(value: string): boolean|nil }
---@return fun(iw: number): table
local function choiceRow(desktop, opts)
    return navRow{
        icon = opts.icon, title = opts.title, status = opts.status,
        callback = function()
            List:new{
                title = opts.title, items = opts.items, current = opts.current, centered = true,
                on_select = function(value)
                    if not value or value == opts.current then return end
                    if opts.apply(value) == false then return end
                    refreshAfterChange(desktop)
                end,
            }:show()
        end,
    }
end

--- 用主题路径选择器选图片（is_file）或文件夹。
---@param desktop table
---@param current string 当前路径；所在目录不存在时从主目录开始
---@param is_file boolean
---@param apply fun(path: string)
local function choosePath(desktop, current, is_file, apply)
    local dir = is_file and current:match("^(.*)/") or current
    local start = lfs.attributes(dir, "mode") == "directory" and current
        or require("apps/filemanager/filemanagerutil").getHomeFolder()
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = is_file,
        filter = is_file and function(name) return Image.suffix(name) ~= nil end or nil,
        on_select = function(path)
            apply(path)
            refreshAfterChange(desktop)
        end,
    }:show()
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
    if not path or (lfs.attributes(path, "size") or 0) < 8 then
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
                width = iw, chevron = false,
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
    if Settings.hasAds() then
        rows[#rows + 1] = navRow{
            icon = "info", title = _("去除锁屏广告"),
            subtitle = _("广告版 Kindle 上锁屏壁纸不会生效，点击一键去除"),
            callback = function()
                Confirm:new{
                    title = _("去除锁屏广告"),
                    text = _("将删除本机广告缓存并关闭广告开关，完成后 Kindle 会自动重启。不影响书籍和账号。"),
                    ok_text = _("去除并重启"),
                    ok_callback = function()
                        if not Settings.removeAds() then
                            return Toast:new{ text = _("去除失败，请按教程手动操作：") .. ADS_URL, timeout = 5 }:show()
                        end
                        Toast:new{ text = _("广告已去除，5 秒后重启"), timeout = 5 }:show()
                        G_reader_settings:flush()
                        UIManager:scheduleIn(5, function() os.execute("reboot") end)
                    end,
                }:show()
            end,
        }
    end
    if not enabled then
        return rows
    end

    local plan = Compose.plan()
    local component = plan.component
    local background = plan.background_mode
    rows[#rows + 1] = choiceRow(desktop, {
        icon = "image", title = _("背景"), status = Background.label(background),
        items = Background.options(), current = background, apply = Settings.setBackgroundMode,
    })
    if background == "custom" then
        local path = Background.customImage()
        local w, h = Layout.portraitSize()
        rows[#rows + 1] = navRow{
            icon = "image", title = _("选择图片"),
            subtitle = string.format("%s · %d × %d", path, w, h),
            callback = function() choosePath(desktop, path, true, Settings.setCustomImage) end,
        }
    elseif background == "folder" then
        local path = Background.folder()
        rows[#rows + 1] = navRow{
            icon = "folder", title = _("选择文件夹"), subtitle = path,
            callback = function() choosePath(desktop, path, false, Settings.setFolder) end,
        }
    elseif background == "poster" then
        local style = Poster.style()
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "view_module", title = _("海报风格"), status = Poster.styleLabel(style),
            items = Poster.styleOptions(), current = style, apply = Settings.setPosterStyle,
        })
    elseif background == "insight" then
        local Insight = require("features.lockscreen.insight")
        local page = Insight.page()
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "bar_chart", title = _("统计页面"), status = Insight.pageLabel(page),
            items = Insight.pageOptions(), current = page, apply = Settings.setInsightPage,
        })
    elseif background == "typo" then
        local Typo = require("features.lockscreen.typo")
        local style = Typo.style()
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "view_module", title = _("海报版式"), status = Typo.styleLabel(style),
            items = Typo.styleOptions(), current = style, apply = Settings.setTypoStyle,
        })
        -- 海报字体：自动（优先宋体）或从字体选择器里挑（在线 / 用户 / 本地 / 系统）
        local auto = Typo.fontId() == ""
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "text_fields", title = _("海报字体"), status = Typo.fontLabel(),
            items = {
                { text = _("自动（优先宋体）"), value = "auto" },
                { text = _("选择字体…"), value = "pick" },
            },
            current = auto and "auto" or nil,
            apply = function(value)
                if value == "auto" then return Settings.setTypoFont("") end
                require("ui.widgets.fontpicker").open{
                    title = _("海报字体"),
                    current_id = Typo.fontId,
                    on_select = function(_item, id, name)
                        Settings.setTypoFont(id, name)
                        refreshAfterChange(desktop)
                    end,
                }
                return false
            end,
        })
    end

    local component_label = _("无")
    for _idx, item in ipairs(Components.options()) do
        if item.value == component.id then component_label = item.text end
    end
    rows[#rows + 1] = choiceRow(desktop, {
        icon = "widgets", title = _("主体组件"), status = component_label,
        items = Components.options(), current = component.id, apply = Settings.setComponent,
    })

    if component.supports_position ~= false then
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "open_in_full", title = _("主体位置"), status = Layout.label(plan.position),
            items = Layout.options(), current = plan.position, apply = Settings.setPosition,
        })
        if plan.supports_narrow then
            rows[#rows + 1] = choiceRow(desktop, {
                icon = "aspect_ratio", title = _("主体形态"), status = plan.wide and _("宽屏") or _("窄屏"),
                items = { { text = _("宽屏"), value = "wide" }, { text = _("窄屏"), value = "narrow" } },
                current = plan.wide and "wide" or "narrow",
                apply = function(value) Settings.setWide(value == "wide") end,
            })
        end
    end

    if component.id == "bill" then
        local period = Settings.billPeriod()
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "date_range", title = _("账单周期"), status = Bill.periodLabel(period),
            items = Bill.periodOptions(), current = period, apply = Settings.setBillPeriod,
        })
    elseif component.id == "message" then
        local text = Settings.customMessage()
        local preview = Text.truncateUtf8(text, 18)
        rows[#rows + 1] = navRow{
            icon = "chat", title = _("自定义留言"),
            status = preview ~= text and preview .. "…" or preview,
            callback = function() editMessage(desktop) end,
        }
    end

    local path = generatedPath()
    if path then
        rows[#rows + 1] = navRow{
            icon = "share", title = _("分享锁屏图"),
            callback = function() require("features.remote.screenshot").share(path) end,
        }
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
    local pw, ph = Layout.portraitSize()
    local viewer = Modal:new{
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
    local pw, ph = Layout.portraitSize()
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
