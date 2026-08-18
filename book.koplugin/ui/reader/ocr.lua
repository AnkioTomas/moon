--[[--
OCR 语言数据安装器：从 Tesseract 官方 tessdata_fast 下载 traineddata，
原子落位到 KOReader 的 data/tessdata 目录，并切换当前固定版式文档语言。

KOReader 当前版本会动态扫描该目录，不需要也不允许修改 defaults.lua。

@module koplugin.book.ui.reader.ocr
--]]

require("l10n").apply()

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Popup = require("ui.components.popup")
local Request = require("http.request")
local _ = require("gettext")
local T = require("ffi/util").template

local OCR = {}

-- jsDelivr 镜像 GitHub 官方仓库，适合设备端直接下载大体积 traineddata。
local BASE_URL = "https://cdn.jsdelivr.net/gh/tesseract-ocr/tessdata_fast@main"

-- 常用 Tesseract 5 语言。代码固定在插件内，不能把任意输入拼进下载 URL/路径。
local LANGUAGES = {
    "eng", "chi_sim", "chi_tra", "jpn", "kor", "deu", "fra", "spa",
    "ita", "por", "rus", "ukr", "ara", "hin", "tha", "vie", "nld",
    "pol", "tur", "heb", "ind", "ces", "swe", "dan", "fin", "nor",
}

---@return string
local function dataDir()
    local configured = require("document/koptinterface").tessocr_data
    if configured then
        return configured
    end
    local env = os.getenv("TESSDATA_PREFIX")
    if env and env ~= "" then
        local nested = env .. "/tessdata"
        return lfs.attributes(nested, "mode") == "directory" and nested or env
    end
    return DataStorage:getDataDir() .. "/data/tessdata"
end

---@return table<string, boolean>
local function installedSet()
    local out = {}
    for _, code in ipairs(require("ui/data/ocr").getOCRLangs()) do
        out[code] = true
    end
    return out
end

---@param ui table|nil
---@return boolean
local function supportsOCR(ui)
    local document = ui and ui.document
    return document ~= nil and document.koptinterface ~= nil
end

---@return string
function OCR.status()
    local langs = require("ui/data/ocr").getOCRLangs()
    if #langs == 0 then
        return _("未安装")
    end
    return T(_("已安装 %1 种语言"), #langs)
end

---@param ui table|nil
---@param code string
local function selectLanguage(ui, code)
    if not supportsOCR(ui) or not ui.document.configurable then
        return
    end
    ui.document.configurable.doc_language = code
    ui:handleEvent(require("ui/event"):new("DocLangUpdate", code))
end

---@param ui table|nil
---@param code string
---@param name string
local function install(ui, code, name)
    NetworkMgr:runWhenOnline(function()
        local dir = dataDir()
        local ok, err = require("util").makePath(dir)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("OCR 安装失败：%1"), tostring(err)) })
            return
        end
        local dest = dir .. "/" .. code .. ".traineddata"
        local tmp = dest .. ".part"
        os.remove(tmp)
        local progress = InfoMessage:new{
            text = T(_("正在安装 OCR 语言：%1"), name),
        }
        UIManager:show(progress)
        Request.download({
            url = BASE_URL .. "/" .. code .. ".traineddata",
            method = "GET",
            timeout = 300,
            allow_redirects = true,
        }, tmp, function(downloaded, download_err)
            UIManager:close(progress)
            local attr = downloaded and lfs.attributes(tmp)
            if not attr or attr.mode ~= "file" or (attr.size or 0) < 1024 then
                os.remove(tmp)
                UIManager:show(InfoMessage:new{
                    text = T(_("OCR 安装失败：%1"), tostring(download_err or _("语言数据无效"))),
                })
                return
            end
            local renamed, rename_err = os.rename(tmp, dest)
            if not renamed then
                os.remove(tmp)
                UIManager:show(InfoMessage:new{
                    text = T(_("OCR 安装失败：%1"), tostring(rename_err)),
                })
                return
            end
            selectLanguage(ui, code)
            UIManager:show(InfoMessage:new{
                text = T(_("OCR 语言已安装：%1"), name),
                timeout = 3,
            })
        end)
    end)
end

---@param ui table|nil
function OCR.open(ui)
    local installed = installedSet()
    local current
    if supportsOCR(ui) and ui.document.configurable then
        current = ui.document.configurable.doc_language
    end
    local iso = require("ui/data/isolanguage")
    local items = {}
    for _i, code in ipairs(LANGUAGES) do
        local name = iso:getLocalizedLanguage(code)
        local ready = installed[code] == true
        local lang_code, lang_name, is_ready = code, name, ready
        items[#items + 1] = {
            text = name,
            value = code,
            checked = code == current,
            mandatory = ready and _("已安装") or _("下载"),
            icon = ready and "download_done" or "cloud_download",
            callback = function()
                if is_ready then
                    selectLanguage(ui, lang_code)
                else
                    install(ui, lang_code, lang_name)
                end
            end,
        }
    end
    Popup.list{
        title = _("OCR 语言数据"),
        subtitle = _("来自 Tesseract 官方 tessdata_fast；当前 KOReader 会自动识别，无需修改 defaults.lua"),
        items = items,
        current = current,
        choice_icons = true,
    }
end

return OCR
