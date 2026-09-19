--[[--
番茄正文：PUA 字体解码 + 目录归一化。章缓存走 source.chapter。

@module koplugin.book.source.fanqie.content
--]]

local Content = {}

local PUA_CODE = { { 58344, 58715 }, { 58345, 58716 } }
local PUA_CHARSET = {
    { "D","在","主","特","家","军","然","表","场","4","要","只","v","和","?","6","别","还","g","现","儿","岁","?","?","此","象","月","3","出","战","工","相","o","男","直","失","世","F","都","平","文","什","V","O","将","真","T","那","当","?","会","立","些","u","是","十","张","学","气","大","爱","两","命","全","后","东","性","通","被","1","它","乐","接","而","感","车","山","公","了","常","以","何","可","话","先","p","i","叫","轻","M","士","w","着","变","尔","快","l","个","说","少","色","里","安","花","远","7","难","师","放","t","报","认","面","道","S","?","克","地","度","I","好","机","U","民","写","把","万","同","水","新","没","书","电","吃","像","斯","5","为","y","白","几","日","教","看","但","第","加","候","作","上","拉","住","有","法","r","事","应","位","利","你","声","身","国","问","马","女","他","Y","比","父","x","A","H","N","s","X","边","美","对","所","金","活","回","意","到","z","从","j","知","又","内","因","点","Q","三","定","8","R","b","正","或","夫","向","德","听","更","?","得","告","并","本","q","过","记","L","让","打","f","人","就","者","去","原","满","体","做","经","K","走","如","孩","c","G","给","使","物","?","最","笑","部","?","员","等","受","k","行","一","条","果","动","光","门","头","见","往","自","解","成","处","天","能","于","名","其","发","总","母","的","死","手","入","路","进","心","来","h","时","力","多","开","已","许","d","至","由","很","界","n","小","与","Z","想","代","么","分","生","口","再","妈","望","次","西","风","种","带","J","?","实","情","才","这","?","E","我","神","格","长","觉","间","年","眼","无","不","亲","关","结","0","友","信","下","却","重","己","老","2","音","字","m","呢","明","之","前","高","P","B","目","太","e","9","起","稜","她","也","W","用","方","子","英","每","理","便","四","数","期","中","C","外","样","a","海","们","任" },
    { "s","?","作","口","在","他","能","并","B","士","4","U","克","才","正","们","字","声","高","全","尔","活","者","动","其","主","报","多","望","放","h","w","次","年","?","中","3","特","于","十","入","要","男","同","G","面","分","方","K","什","再","教","本","己","结","1","等","世","N","?","说","g","u","期","Z","外","美","M","行","给","9","文","将","两","许","张","友","0","英","应","向","像","此","白","安","少","何","打","气","常","定","间","花","见","孩","它","直","风","数","使","道","第","水","已","女","山","解","d","P","的","通","关","性","叫","儿","L","妈","问","回","神","来","S","","四","望","前","国","些","O","v","l","A","心","平","自","无","军","光","代","是","好","却","c","得","种","就","意","先","立","z","子","过","Y","j","表","","么","所","接","了","名","金","受","J","满","眼","没","部","那","m","每","车","度","可","R","斯","经","现","门","明","V","如","走","命","y","6","E","战","很","上","f","月","西","7","长","夫","想","话","变","海","机","x","到","W","一","成","生","信","笑","但","父","开","内","东","马","日","小","而","后","带","以","三","几","为","认","X","死","员","目","位","之","学","远","人","音","呢","我","q","乐","象","重","对","个","被","别","F","也","书","稜","D","写","还","因","家","发","时","i","或","住","德","当","o","l","比","觉","然","吃","去","公","a","老","亲","情","体","太","b","万","C","电","理","?","失","力","更","拉","物","着","原","她","工","实","色","感","记","看","出","相","路","大","你","候","2","和","?","与","p","样","新","只","便","最","不","进","T","r","做","格","母","总","爱","身","师","轻","知","往","加","从","?","天","e","H","?","听","场","由","快","边","让","把","任","8","条","头","事","至","起","点","真","手","这","难","都","界","用","法","n","处","下","又","Q","告","地","5","k","t","岁","有","会","果","利","民" }
}

local function utf8_codepoint(str, i)
    local b1 = str:byte(i)
    if not b1 then return nil, i end
    if b1 < 0x80 then
        return b1, i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
        local b2 = str:byte(i + 1)
        if not b2 then return nil, i end
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        if not b2 or not b3 then return nil, i end
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), i + 3
    elseif b1 >= 0xF0 and b1 <= 0xF4 then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        local b4 = str:byte(i + 3)
        if not b2 or not b3 or not b4 then return nil, i end
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), i + 4
    end
    return nil, i
end

function Content.decode_pua_content(content)
    if not content then return "" end
    local result = {}
    local i = 1
    while i <= #content do
        local code, next_i = utf8_codepoint(content, i)
        if not code then
            table.insert(result, content:sub(i, i))
            i = i + 1
            goto continue
        end
        local decoded = false
        for mode = 1, 2 do
            local range = PUA_CODE[mode]
            if code >= range[1] and code <= range[2] then
                local bias = code - range[1]
                local charset = PUA_CHARSET[mode]
                if bias + 1 <= #charset and charset[bias + 1] ~= "?" then
                    table.insert(result, charset[bias + 1])
                    decoded = true
                end
                break
            end
        end
        if not decoded then
            table.insert(result, content:sub(i, next_i - 1))
        end
        i = next_i
        ::continue::
    end
    return table.concat(result)
end


local function to_precise_id(value)
    if value == nil then return nil end
    if type(value) == "string" then return value, false, false end
    if type(value) == "number" then
        local s = string.format("%.0f", value)
        -- 检查是否精度丢失: 转回数字再转回字符串，看是否一致
        if tonumber(s) ~= value then
            return s, true, true
        end
        return s, true, false
    end
    return tostring(value), false, false
end

-- 递归处理chapter中的ID字段，转为字符串
local function fix_chapter_ids(chapter)
    if type(chapter) ~= "table" then return chapter end
    local fixed = {}
    for k, v in pairs(chapter) do
        if k == "itemId" or k == "item_id" or k == "bookId" or k == "book_id" then
            local sid = to_precise_id(v)
            if sid then
                fixed[k] = sid
            else
                fixed[k] = v
            end
        else
            fixed[k] = v
        end
    end
    return fixed
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end
    -- Official API returns chapterListWithVolume as a 2D array:
    -- [[chapter1, chapter2, ...], [chapter101, ...]]
    -- Each volume is directly an array of chapters, not an object with chapterList property
    if type(records.chapterListWithVolume) == "table" then
        local flattened = {}
        for _, volume in ipairs(records.chapterListWithVolume) do
            if type(volume) == "table" then
                for _, ch in ipairs(volume) do
                    if type(ch) == "table" and ch.itemId then
                        table.insert(flattened, fix_chapter_ids(ch))
                    end
                end
            end
        end
        if #flattened > 0 then
            return flattened
        end
    end
    -- Direct chapter list fields (official + third-party variants)
    if type(records.chapterList) == "table" then
        local out = {}
        for _, ch in ipairs(records.chapterList) do
            table.insert(out, fix_chapter_ids(ch))
        end
        return out
    end
    -- Try extracting chapters from allItemIds if chapterListWithVolume/chapterList is empty
    if type(records.allItemIds) == "table" and #records.allItemIds > 0 then
        local chapters = {}
        for i, item_id in ipairs(records.allItemIds) do
            local sid = to_precise_id(item_id) or tostring(item_id)
            table.insert(chapters, {
                itemId = sid,
                title = "第" .. tostring(i) .. "章",
                index = i - 1,
            })
        end
        return chapters
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            local list = record.updated or record.chapterInfos or record.chapters
                or record.item_list or record.list or record.chapterList or {}
            local out = {}
            for _, ch in ipairs(list) do
                table.insert(out, fix_chapter_ids(ch))
            end
            return out
        end
    end
    return records
end

function Content.readable_chapters(chapters)
    local out = {}
    for _, chapter in ipairs(chapters or {}) do
        if tostring(chapter.title or "") ~= "封面" then
            out[#out + 1] = chapter
        end
    end
    return out
end

return Content