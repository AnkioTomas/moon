--[[--
阅读位置的纯计算：不访问 KOReader UI、数据库或网络。

@module koplugin.book.progress.position
--]]

local Position = {}

local function clampFraction(raw)
    local n = tonumber(raw) or 0
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

local function wholeFraction(doc_frac, identity, toc, reading_idx)
    local idx = identity and identity.chapter_idx or reading_idx
    if not idx then return clampFraction(doc_frac) end
    local count = toc and #toc or 0
    if count <= 0 then return clampFraction(doc_frac) end
    idx = tonumber(idx) or 1
    return clampFraction(((idx - 1) + clampFraction(doc_frac)) / count)
end

---@param snapshot table|nil
---@param toc table[]|nil
---@return number
function Position.fraction(snapshot, toc)
    if not snapshot then return 0 end
    return wholeFraction(snapshot.doc_fraction, snapshot.identity, toc, snapshot.reading_chapter_idx)
end

---@param snapshot table|nil
---@param toc table[]|nil
---@param chapter_title string|nil
---@return table
function Position.position(snapshot, toc, chapter_title)
    snapshot = snapshot or {}
    local identity = snapshot.identity or {}
    local chapter_idx = identity.chapter_idx or snapshot.reading_chapter_idx
    local chapter_fraction
    if chapter_idx then
        chapter_fraction = clampFraction(snapshot.chapter_fraction or snapshot.doc_fraction)
    end
    local page = tonumber(snapshot.page)
    local total_pages = tonumber(snapshot.total_pages)
    return {
        fraction = Position.fraction(snapshot, toc),
        chapter_idx = chapter_idx,
        chapter_title = chapter_title,
        chapter_fraction = chapter_fraction,
        page = page and page > 0 and math.floor(page) or nil,
        total_pages = total_pages and total_pages > 0 and math.floor(total_pages) or nil,
        locator = snapshot.ui and snapshot.ui.rolling and snapshot.ui.rolling.xpointer or nil,
    }
end

return Position
