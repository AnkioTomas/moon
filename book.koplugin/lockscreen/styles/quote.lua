--[[--
用户高亮 / 一言锁屏。

@module koplugin.book.lockscreen.styles.quote
--]]

local Background = require("lockscreen.background")
local Context = require("lockscreen.context")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local JSON = require("json")
local _ = require("gettext")

local M = { id = "quote", label = _("一言与高亮"), local_render = true }
local FALLBACK = "读书不觉已春深，一寸光阴一寸金。"

---@param payload table|nil 一言接口返回对象
---@return string|nil 作者与作品来源文案
local function attribution(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local who = type(payload.from_who) == "string" and payload.from_who ~= "" and payload.from_who or nil
    local work = type(payload.from) == "string" and payload.from ~= "" and payload.from or nil
    if who and work then
        return who .. " · " .. work
    end
    return who or work
end

---@return string 一言图片缓存路径
function M.path()
    return Paths.screensaverDir() .. "/quote.png"
end

---@return string 当前日期 YYYY-MM-DD
function M.dayKey()
    return require("lockscreen.styles.base").dayKey()
end

---@param text string 要绘制的正文
---@param source string 来源文案
---@param bg string|nil 背景图片路径
---@param cb fun(ok: boolean, err: any) 完成回调
local function draw(text, source, bg, cb)
    local Render = require("lockscreen.render")
    local settings = MoonSettings.get()
    if (settings.lock_screen_quote_mode or "highlight") == "none" then
        local ok, err = Render.write(M.path(), bg, {})
        cb(ok, err)
        return
    end
    local w, h = Render.size()
    local margin = math.floor(w * 0.07)
    local wide = settings.lock_screen_quote_wide ~= false
    local panel_width = wide and w - margin * 2 or math.floor(w * 0.5)
    local vertical, horizontal = (settings.lock_screen_quote_position or "center-center"):match("^(%w+)%-(%w+)$")
    vertical, horizontal = vertical or "center", horizontal or "center"
    local panel_x = horizontal == "left" and margin
        or horizontal == "right" and w - margin - panel_width
        or math.floor((w - panel_width) / 2)
    local text_x = panel_x + margin
    local text_width = panel_width - margin * 2
    local font_size = wide and 34 or 30
    local max_text_height = wide and math.floor(h * 0.52) or math.floor(h * 0.5)
    local text_height = Render.measureText(text, text_width, font_size, true)
    while text_height > max_text_height and font_size > 24 do
        font_size = font_size - 2
        text_height = Render.measureText(text, text_width, font_size, true)
    end

    local top_space = math.floor(h * 0.12)
    local bottom_space = math.floor(h * 0.13)
    local panel_height = math.max(math.floor(h * 0.32), text_height + top_space + bottom_space)
    panel_height = math.min(panel_height, math.floor(h * 0.88))
    local panel_y = vertical == "top" and margin
        or vertical == "bottom" and h - margin - panel_height
        or math.floor((h - panel_height) / 2)
    local rule_y = panel_y + panel_height - math.floor(h * 0.09)
    -- DESIGN：白底圆角浅卡 + 轻阴影；引号/来源走灰阶，分割线默认 #55
    local radius = math.max(8, math.floor(w * 0.02))
    local Blitbuffer = require("ffi/blitbuffer")
    local ok, err = Render.write(M.path(), bg, {
        {
            kind = "panel", x = panel_x, y = panel_y, width = panel_width, height = panel_height,
            radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = "“", x = text_x, y = panel_y + math.floor(h * 0.025),
            width = text_width, size = 56, bold = true, box = false, color = Blitbuffer.COLOR_GRAY_4,
        },
        {
            text = text, x = text_x, y = panel_y + math.floor(h * 0.11),
            width = text_width, size = font_size, bold = true, box = false,
        },
        { kind = "rule", x = text_x, y = rule_y, width = text_width, height = 1 },
        {
            text = source, x = text_x, y = rule_y + math.floor(h * 0.025),
            width = text_width, size = 16, align = "right", box = false, color = Blitbuffer.COLOR_GRAY_3,
        },
    })
    cb(ok, err)
end

---@param cb fun(ok: boolean, err: any)
---@return table|nil 可取消的一言与背景任务
function M.fetch(cb)
    local cancelled = false
    local finished = false
    local background_ready = false
    local text_ready = false
    local bg
    local text
    local source
    local background_job
    local quote_job
    local job = {
        cancel = function()
            cancelled = true
            if background_job and background_job.cancel then background_job.cancel() end
            if quote_job and quote_job.cancel then quote_job.cancel() end
        end,
    }
    ---@param ok boolean
    ---@param err any
    local function finish(ok, err)
        if cancelled or finished then return end
        finished = true
        cb(ok, err)
    end
    --- 两个异步输入都就绪后执行一次渲染。
    local function renderWhenReady()
        if cancelled or finished or not background_ready or not text_ready then
            return
        end
        draw(text, source, bg, finish)
    end
    background_job = Background.ensure(function(path)
        if cancelled then return end
        bg = path
        background_ready = true
        renderWhenReady()
    end)

    local c = MoonSettings.get()
    local quote_mode = c.lock_screen_quote_mode or "highlight"
    if quote_mode == "none" then
        text = ""
        source = ""
        text_ready = true
        renderWhenReady()
    elseif quote_mode == "highlight" then
        local highlight = Context.highlight()
        text = highlight or FALLBACK
        source = highlight and _("来自当前书籍高亮") or _("默认句子")
        text_ready = true
        renderWhenReady()
    elseif not require("ui/network/manager"):isOnline() then
        text = c.lock_screen_quote_cache or FALLBACK
        source = c.lock_screen_quote_source_cache or _("一言")
        text_ready = true
        renderWhenReady()
    else
        quote_job = Request.get("https://api.ankio.net/hitokoto", { timeout = 20 }, function(body)
            if cancelled then return end
            local fetched
            local fetched_source
            if body then
                local ok, data = pcall(JSON.decode, body)
                if ok and type(data) == "table" then
                    local payload = type(data.data) == "table" and data.data or data
                    fetched = payload.hitokoto or payload.content or payload.text
                    fetched_source = attribution(payload)
                elseif body:match("%S") then
                    fetched = body
                end
            end
            if type(fetched) == "string" and fetched ~= "" then
                text = fetched
                c.lock_screen_quote_cache = fetched
                c.lock_screen_quote_source_cache = fetched_source or _("一言")
                MoonSettings.save()
            else
                text = c.lock_screen_quote_cache or FALLBACK
            end
            source = fetched_source or c.lock_screen_quote_source_cache or _("一言")
            text_ready = true
            renderWhenReady()
        end)
    end
    return finished and nil or job
end

return M
