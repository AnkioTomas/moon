--[[--
把当前文档 sidecar 中的 annotations 作为完整快照上报。

@module koplugin.book.annotations.sync
--]]

local logger = require("logger")

local AnnotationSync = {}

local function deviceId()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then
        return id
    end
    id = string.format(
        "book-%08x%08x",
        math.floor(math.random() * 0xffffffff),
        os.time() % 0xffffffff
    )
    G_reader_settings:saveSetting("device_id", id)
    return id
end

local function clean(items, total_pages)
    local result = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.datetime and (item.page or item.pageref) then
            result[#result + 1] = {
                datetime = item.datetime,
                datetime_updated = item.datetime_updated,
                drawer = item.drawer,
                color = item.color,
                text = item.text,
                note = item.note,
                chapter = item.chapter,
                pageno = item.pageno,
                page = item.page or item.pageref,
                total_pages = total_pages,
                pos0 = item.pos0,
                pos1 = item.pos1,
            }
        end
    end
    return result
end

--- 上报当前书的完整注解快照；空数组也必须发送，用于传播删除。
---@param ui table|nil
---@param source BookSource|nil
---@param ref BookRef|nil
function AnnotationSync.push(ui, source, ref)
    if not ui or not ui.doc_settings or not source or not source.syncAnnotationsAsync then
        return
    end
    if not ref or ref.source_id ~= source.id or type(ref.stable_id) ~= "string" then
        return
    end

    ui.doc_settings:flush()
    local items = ui.doc_settings:readSetting("annotations") or {}
    local total_pages = ui.document and ui.document.getPageCount
        and tonumber(ui.document:getPageCount())
        or tonumber(ui.doc_settings:readSetting("doc_pages"))
        or 0
    local payload = {
        filename = ref.stable_id,
        device_id = deviceId(),
        annotations = clean(items, total_pages),
    }

    require("ui/network/manager"):runWhenOnline(function()
        source:syncAnnotationsAsync(payload, function(res, err)
            if not res then
                logger.warn("book annotation sync failed", err)
                return
            end
            logger.info("book annotation sync ok", ref.stable_id, #payload.annotations)
        end)
    end)
end

return AnnotationSync
