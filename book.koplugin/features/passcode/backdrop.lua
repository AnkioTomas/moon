--[[--
解锁页背景：仅在组合锁屏开启、且壁纸选了「纯图类」时铺底——
自定义 / 必应 / 封面 / 文件夹 / 海报墙。只画背景本身，绝不碰 compose.png
（那是背景+主体组件的合成图）。其它壁纸（摸鱼日报、报纸、统计页、无…）解锁页用纯色。

路径类直接解文件；海报墙是自绘 blocks，当场铺到离屏位图（结果按模式+尺寸缓存）。

@module koplugin.book.features.passcode.backdrop
--]]

local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local MoonSettings = require("utils.settings")
local logger = require("utils.log")

local Backdrop = {}

-- 解锁页允许铺底的锁屏壁纸；其余模式（含 none / 统计页 / 摸鱼日报）不画。
local IMAGE_MODES = {
    custom = true,
    bing = true,
    cover = true,
    folder = true,
}
local BLOCK_MODES = {
    poster = true,
}

---@param path string|nil
---@return boolean
local function fileOk(path)
    if type(path) ~= "string" or path == "" then return false end
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 8
end

--- 当前锁屏壁纸模式；组合锁屏关着或非法值返回 nil。
---@return string|nil
function Backdrop.mode()
    local conf = MoonSettings.get("features.lockscreen")
    if conf.lock_screen ~= "compose" then return nil end
    local mode = conf.lock_screen_background or "bing"
    if IMAGE_MODES[mode] or BLOCK_MODES[mode] then return mode end
    return nil
end

--- 路径类壁纸的文件；海报墙 / 未启用返回 nil。
---@return string|nil
function Backdrop.path()
    local mode = Backdrop.mode()
    if not mode or not IMAGE_MODES[mode] then return nil end
    local Background = require("features.lockscreen.background")
    local path = Background.resolve(Background.background(mode))
    return fileOk(path) and path or nil
end

--- 铺满裁切 / 海报墙自绘的位图层；同模式+尺寸复用，避免按键刷新反复解码。
---@class BookPasscodeBackdrop : Widget
local Cover = Widget:extend{
    mode = nil,
    path = nil,
    width = 0,
    height = 0,
}

function Cover:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Cover:free()
    if self._bb and self._bb.free then self._bb:free() end
    self._bb, self._key = nil, nil
end

--- 海报墙：只跑背景 blocks，不画主体组件。
---@param bb BlitBuffer
---@param w number
---@param h number
local function paintPoster(bb, w, h)
    local Background = require("features.lockscreen.background")
    local asset = Background.background("poster")
    local blocks = asset.blocks and asset.blocks({ x = 0, y = 0, w = w, h = h }) or {}
    local Render = require("features.lockscreen.render")
    for _idx, block in ipairs(blocks) do
        Render.paintBlock(bb, block, w, h)
    end
end

---@return BlitBuffer|nil
function Cover:surface()
    local key = table.concat({ tostring(self.mode), tostring(self.path), self.width, self.height }, "|")
    if self._key == key then return self._bb end
    self:free()
    local w, h = self.width, self.height
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local Screen = require("device").screen
        local bb = Blitbuffer.new(w, h, (Screen.isColorEnabled and Screen:isColorEnabled())
            and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8) --[[@as BlitBuffer]]
        bb:fill(Blitbuffer.COLOR_WHITE)
        if self.mode == "poster" then
            paintPoster(bb, w, h)
        else
            if not fileOk(self.path) then error("missing image") end
            local source = require("ui/renderimage"):renderImageFile(self.path, false)
            if not source then error("decode failed") end
            local iw, ih = source:getWidth(), source:getHeight()
            if not iw or not ih or iw <= 0 or ih <= 0 then
                source:free()
                error("empty image")
            end
            local ImageWidget = require("ui/widget/imagewidget")
            local image = ImageWidget:new{
                image = source,
                image_disposable = true,
                width = w,
                height = h,
                scale_factor = math.max(w / iw, h / ih),
                alpha = false,
            }
            image:paintTo(bb, 0, 0)
            image:free()
        end
        self._bb, self._key = bb, key
    end)
    if not ok then
        logger.warn("passcode backdrop failed", self.mode, self.path, err)
        self:free()
        return nil
    end
    return self._bb
end

---@param bb BlitBuffer
---@param x number
---@param y number
function Cover:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local src = self:surface()
    if not src then return end
    bb:blitFrom(src, x, y, 0, 0, self.width, self.height)
end

--- 铺满整屏的背景控件；当前壁纸不在白名单或解码失败返回 nil。
---@param w number
---@param h number
---@return BookPasscodeBackdrop|nil
function Backdrop.widget(w, h)
    local mode = Backdrop.mode()
    if not mode then return nil end
    if IMAGE_MODES[mode] then
        local path = Backdrop.path()
        if not path then return nil end
        return Cover:new{ mode = mode, path = path, width = w, height = h }
    end
    if BLOCK_MODES[mode] then
        return Cover:new{ mode = mode, width = w, height = h }
    end
    return nil
end

return Backdrop
