--[[--
全局屏幕旋转：桌面与阅读共用「上次转到的方向」，下次进桌面 / 开书直接用。

落在 KOReader 自己的键上（fm / copt / kopt），文件管理器冷启动与阅读排版都认；
开书前再写进本册 sidecar，盖过旧书各自记的方向。lock_rotation 开启时不动。

@module koplugin.book.utils.rotation
--]]

local Device = require("device")
local Screen = Device.screen

local Rotation = {}

local FM_KEY = "fm_rotation_mode"
local CRE_KEY = "copt_rotation_mode"
local KOPT_KEY = "kopt_rotation_mode"

---@return boolean
local function locked()
    return G_reader_settings:isTrue("lock_rotation")
end

--- 记住当前（或指定）旋转，立刻落盘，杀进程也不丢。
---@param mode number|nil
function Rotation.remember(mode)
    if locked() then return end
    if mode == nil then mode = Screen:getRotationMode() end
    if type(mode) ~= "number" then return end
    G_reader_settings:saveSetting(FM_KEY, mode)
    G_reader_settings:saveSetting(CRE_KEY, mode)
    G_reader_settings:saveSetting(KOPT_KEY, mode)
    G_reader_settings:flush()
end

--- 开书前写入本册设置，让 ReaderView:onReadSettings 读到全局上次方向。
---@param doc_settings table
---@param _document table|nil
function Rotation.injectDocSettings(doc_settings, _document)
    if locked() then return end
    local mode = G_reader_settings:readSetting(FM_KEY)
    if type(mode) ~= "number" then return end
    doc_settings:saveSetting(CRE_KEY, mode)
    doc_settings:saveSetting(KOPT_KEY, mode)
end

--- 桌面侧：屏幕方向与已记的不一致时扳过来（FM 自己的 setRotationMode 也会读 fm 键）。
function Rotation.apply()
    if locked() then return end
    local mode = G_reader_settings:readSetting(FM_KEY)
    if type(mode) ~= "number" or mode == Screen:getRotationMode() then return end
    Screen:setRotationMode(mode)
end

require("utils.extension").add("reader.doc_settings", Rotation.injectDocSettings)

return Rotation
