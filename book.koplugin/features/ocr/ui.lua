--[[--
OCR 识别模型下载、管理弹窗，以及识别失败时的提示。

@module koplugin.book.features.ocr.ui
--]]

require("l10n").apply()

local Confirm = require("ui.themes.widgets.confirm")
local List = require("ui.themes.widgets.list")
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template

local Ui = {}

---@param text string
local function info(text)
    Toast:new{ text = text, timeout = 3 }:show()
end

--- 语言码显示名：清单名优先，其次常见语言，最后原样。
---@param code string
---@param fallback string|nil
---@return string
function Ui.label(code, fallback)
    if type(fallback) == "string" and fallback ~= "" then return fallback end
    local names = {
        chi_sim = _("简体中文"),
        chi_tra = _("繁体中文"),
        eng = _("英语"),
        jpn = _("日语"),
        chi_sim_vert = _("简体中文（竖排）"),
        chi_tra_vert = _("繁体中文（竖排）"),
    }
    return names[code] or code
end

--- 下载安装一个模型（资源下载任务，前台进度可转后台）；成功后设为当前书的识别语言（若开着扫描书）。
---@param item table
local function install(item)
    local Manager = require("features.ocr.manager")
    local dir = Manager.dataDir()
    require("workers.ui.task_dialog").start{
        key = "ocr\0" .. item.id,
        kind = "download",
        title = Ui.label(item.id, item.name),
        run = function(report, done)
            Manager.install(item, dir, function(ok, err)
                done({ ok = ok, err = err })
            end, function(stage, bytes, total)
                report(stage == "install" and _("正在校验安装…") or nil, bytes, total)
            end)
        end,
        on_done = function(result)
            if not result.ok then info(T(_("识别语言安装失败：%1"), tostring(result.err))); return end
            if not Manager.defaultLanguage() then Manager.setDefaultLanguage(item.id) end
            if Manager.applyToOpenDocument(item.id) then
                info(_("识别语言已安装，并用于当前书"))
            else
                info(_("识别语言已安装"))
            end
        end,
    }
end

--- 拉取模型目录并弹出下载列表。
function Ui.download()
    require("ui/network/manager"):runWhenOnline(function()
        local loading = require("ui.themes.widgets.progress_dialog"):new{
            title = _("下载识别语言"), text = _("正在获取识别语言目录…"), dismissable = false,
        }
        loading:show()
        local Manager = require("features.ocr.manager")
        Manager.catalog(function(items, err)
            loading:close()
            if not items then info(T(_("获取识别语言目录失败：%1"), tostring(err))); return end
            local dir = Manager.dataDir()
            local rows = {}
            for _idx, item in ipairs(items) do
                local installed = Manager.isInstalled(dir, item.id)
                local name = Ui.label(item.id, item.name)
                rows[#rows + 1] = {
                    text = name,
                    mandatory = installed and _("已安装") or string.format("%.1f MB", item.size / 1048576),
                    icon = installed and "download_done" or "cloud_download",
                    enabled = not installed,
                    callback = function()
                        Confirm:new{
                            text = T(_("下载并安装识别语言“%1”？"), name),
                            ok_text = _("下载"),
                            ok_callback = function() install(item) end,
                        }:show()
                    end,
                }
            end
            List:new{
                title = _("下载识别语言"),
                subtitle = _("Tesseract 识别模型，用于扫描版 PDF / DjVu"),
                items = rows,
            }:show()
        end)
    end)
end

--- 已安装模型列表：设为默认、用于当前书、删除（仅本插件安装的）。
function Ui.manage()
    local Manager = require("features.ocr.manager")
    local dir = Manager.dataDir()
    local codes = Manager.installed(dir)
    if #codes == 0 then info(_("尚未安装识别语言")); return end
    local default = Manager.defaultLanguage()
    local current = Manager.currentLanguage()
    local owned = Manager.owned(dir)
    local rows = {}
    for _idx, code in ipairs(codes) do
        local name = Ui.label(code)
        local tags = {}
        if code == current then tags[#tags + 1] = _("当前书") end
        if code == default then tags[#tags + 1] = _("默认") end
        if not owned[code] then tags[#tags + 1] = _("自行安装") end
        rows[#rows + 1] = {
            text = name,
            mandatory = table.concat(tags, " · "),
            icon = "translate",
            callback = function()
                local actions = {
                    {
                        text = _("设为默认识别语言"),
                        callback = function()
                            Manager.setDefaultLanguage(code)
                            info(_("已设为默认识别语言"))
                        end,
                    },
                }
                if Manager.koptReader() then
                    actions[#actions + 1] = {
                        text = _("用于当前书"),
                        callback = function()
                            Manager.applyToOpenDocument(code)
                            info(_("已用于当前书"))
                        end,
                    }
                end
                if owned[code] then
                    actions[#actions + 1] = {
                        text = _("删除识别语言"),
                        callback = function()
                            Confirm:new{
                                text = T(_("删除识别语言“%1”？"), name),
                                ok_text = _("删除"),
                                ok_callback = function()
                                    local ok, err = Manager.remove(dir, code)
                                    info(ok and _("识别语言已删除") or T(_("删除失败：%1"), tostring(err)))
                                end,
                            }:show()
                        end,
                    }
                end
                Sheet:new{ title = name, items = actions }:show()
            end,
        }
    end
    List:new{
        title = _("管理识别语言"),
        subtitle = _("只能删除月读安装的识别语言"),
        items = rows,
    }:show()
end

--- 没识别出文字：提示原因，没装任何模型时给「去下载」。
function Ui.promptMissing()
    local Manager = require("features.ocr.manager")
    if #Manager.installed(Manager.dataDir()) == 0 then
        Confirm:new{
            text = _("没有识别语言，无法识别扫描页上的文字。现在下载？"),
            ok_text = _("去下载"),
            ok_callback = function() Ui.download() end,
        }:show()
        return
    end
    info(_("没有识别出文字，可在底部菜单「Document Language」换一种识别语言"))
end

return Ui
