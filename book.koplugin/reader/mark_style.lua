--[[--
页内下划线标记的样式配置：段评与 X-Ray 共用同一套四项（样式 / 位置 / 灰度 / 透明度）。

配置值存在各自 feature 的分区里，键名由调用方用 `keys` 传入：
`{ style, gray, opacity, offset }`，含义与取值范围：
- style：dashed 虚线 / solid 实线 / dotted 点状；
- offset：相对默认位置的上下微调（像素，-10–10，负数靠近文字）；
- gray：灰度（深浅，0 白–100 黑）；opacity：不透明度（10–100），与底色混合。

@module koplugin.book.reader.mark_style
--]]

local _ = require("gettext")

local MarkStyle = {}

local STYLES = { "dashed", "solid", "dotted" }

local function styleLabel(style)
    if style == "solid" then return _("实线") end
    if style == "dotted" then return _("点状") end
    return _("虚线")
end

local function nextStyle(style)
    for i, name in ipairs(STYLES) do
        if name == style then return STYLES[i % #STYLES + 1] end
    end
    return STYLES[1]
end

--- 把配置换算成 `PageMark` 的 style / gray / alpha / offset 四个字段值。
---@param conf table
---@param keys table
---@return string style
---@return integer gray 0（黑）–255（白）
---@return integer alpha 0–255
---@return integer offset
function MarkStyle.resolve(conf, keys)
    local gray = math.floor((100 - conf[keys.gray]) * 255 / 100 + 0.5)
    local alpha = math.floor(conf[keys.opacity] * 255 / 100 + 0.5)
    return conf[keys.style], gray, alpha, conf[keys.offset]
end

--- 设置页的四行。
---@param conf table 就地改的配置表
---@param keys table
---@param labels table `{ style, position, position_title, gray, opacity }`，已翻译的标题
---@param changed fun() 任一项改完后：落盘并重画
---@return (fun(iw: integer): table)[]
function MarkStyle.rows(conf, keys, labels, changed)
    local Row = require("ui.themes.widgets.row")
    local function percentRow(icon, title, key, min)
        return function(iw)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = icon, title = title,
                status = conf[key] .. "%",
                callback = function()
                    require("ui.themes.widgets.spin"):new{
                        title = title,
                        fields = { { value = conf[key], min = min, max = 100, step = 5,
                            format = function(v) return v .. "%" end } },
                        callback = function(pct)
                            conf[key] = pct
                            changed()
                        end,
                    }:show()
                end,
            })
        end
    end
    return {
        function(iw)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "border_style", title = labels.style,
                status = styleLabel(conf[keys.style]),
                callback = function()
                    conf[keys.style] = nextStyle(conf[keys.style])
                    changed()
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "vertical_align_center", title = labels.position,
                status = string.format("%+d px", conf[keys.offset]),
                callback = function()
                    require("ui.themes.widgets.spin"):new{
                        title = labels.position_title,
                        fields = { { value = conf[keys.offset], min = -10, max = 10, step = 1,
                            format = function(v) return string.format("%+d px", v) end } },
                        callback = function(px)
                            conf[keys.offset] = px
                            changed()
                        end,
                    }:show()
                end,
            })
        end,
        percentRow("contrast", labels.gray, keys.gray, 0),
        percentRow("opacity", labels.opacity, keys.opacity, 10),
    }
end

return MarkStyle
