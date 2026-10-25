--[[--
在线订阅源目录：社区维护的 OPML 合集（定期清理失效源），经 jsDelivr 取（国内可达，与字典同一套 CDN）。
网页只能选这里的条目，设备端按 id 取地址，不接受网页传来的任意 URL。

上游：
- xiangyugongzuoliu/awesome-rss-feeds-list（CC0，中英文，按主题分文件，持续做死链检测）
- plenaryapp/awesome-rss-feeds（按主题、按国家分类的国际源）
- timqian/chinese-independent-blogs（MIT，中文独立博客，量大）
- tuan3w/awesome-tech-rss（CC0，技术博客）

@module koplugin.book.features.subscribe.catalog
--]]

local Catalog = {}

local XY = "https://cdn.jsdelivr.net/gh/xiangyugongzuoliu/awesome-rss-feeds-list@main/feeds/"
local PL = "https://cdn.jsdelivr.net/gh/plenaryapp/awesome-rss-feeds@master/recommended/with_category/"

local CN, EN, TOPIC, COUNTRY, MISC = "中文精选", "英文精选", "国际分类", "国家与地区", "综合合集"

---@type { id: string, group: string, name: string, url: string }[]
Catalog.sources = {}

local function add(group, prefix, base, ext, list)
    for _idx, item in ipairs(list) do
        Catalog.sources[#Catalog.sources + 1] = {
            id = prefix .. item[1], group = group, name = item[2], url = base .. item[1] .. ext,
        }
    end
end

local THEMES = {
    { "tech-teams", "技术团队" }, { "backend", "后端与系统" }, { "web-frontend", "前端" },
    { "mobile", "移动开发" }, { "dev-tools", "开发工具" }, { "ai-research", "AI 研究" },
    { "ai-tools", "AI 工具" }, { "product-design", "产品设计" }, { "startups", "创业" },
    { "finance", "理财" }, { "essays", "随笔博客" }, { "lifestyle", "生活" },
    { "devops-data", "运维与数据" }, { "newsletters", "邮件通讯" }, { "podcasts", "播客" },
}
local function themed(prefix, group)
    local list = {}
    for _idx, t in ipairs(THEMES) do list[#list + 1] = { prefix .. t[1], t[2] } end
    add(group, "", XY, ".opml", list)
end
themed("cn-", CN)
themed("en-", EN)

local function plenary(group, prefix, base, names)
    local list = {}
    for _idx, name in ipairs(names) do list[#list + 1] = { name, name } end
    local from = #Catalog.sources + 1
    add(group, prefix, base, ".opml", list)
    for i = from, #Catalog.sources do
        Catalog.sources[i].url = Catalog.sources[i].url:gsub(" ", "%%20")
    end
end
local function topics(names) plenary(TOPIC, "plenary-", PL, names) end
topics({ "Tech", "Programming", "Web Development", "Android Development", "iOS Development", "Cyber security",
    "News", "Science", "Space", "Business & Economy", "Personal finance", "Startups", "Gaming", "Movies",
    "Books", "History", "Photography", "UI - UX", "Android", "Apple", "Architecture", "Cars", "Chess",
    "Cryptocurrency", "DIY", "Environment", "Fashion", "Food", "Funny", "Interior design", "Music", "Nature",
    "Sports", "Television", "Travel", "Animal & Wildlife", "Beauty", "Memes", "Football" })

plenary(COUNTRY, "country-", PL:gsub("recommended/with_category/", "countries/with_category/"), {
    "Australia", "Brazil", "Canada", "France", "Germany", "Hong Kong SAR China", "India", "Indonesia", "Ireland",
    "Italy", "Japan", "Mexico", "Poland", "Russia", "South Africa", "Spain", "Ukraine", "United Kingdom",
    "United States" })

Catalog.sources[#Catalog.sources + 1] = {
    id = "indie-blogs", group = MISC, name = "中文独立博客（千余个）",
    url = "https://cdn.jsdelivr.net/gh/timqian/chinese-independent-blogs@master/feed.opml",
}
Catalog.sources[#Catalog.sources + 1] = {
    id = "tech-rss", group = MISC, name = "技术博客合集",
    url = "https://cdn.jsdelivr.net/gh/tuan3w/awesome-tech-rss@main/feeds.opml",
}

--- 按 id 取条目。
---@param id string
---@return { id: string, group: string, name: string, url: string }|nil
function Catalog.find(id)
    for _idx, s in ipairs(Catalog.sources) do
        if s.id == id then return s end
    end
end

return Catalog
