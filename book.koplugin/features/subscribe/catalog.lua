--[[--
在线订阅源目录：社区维护的 OPML 合集（定期清理失效源），经 jsDelivr 取（国内可达，与字典同一套 CDN）；
另有本插件维护的精选清单（`feeds` 内嵌，不依赖外站 OPML，打开即用）。

网页只能选这里的条目，设备端按 id 取地址，不接受网页传来的任意 URL。

上游：
- 本插件精选（全文 / 科技生活，条目实测仍在更新才收录；FeedX 是全文代理）
- xiangyugongzuoliu/awesome-rss-feeds-list（CC0，中英文，按主题分文件，持续做死链检测）
- plenaryapp/awesome-rss-feeds（按主题、按国家分类的国际源）
- timqian/chinese-independent-blogs（MIT，中文独立博客，量大）
- tuan3w/awesome-tech-rss（CC0，技术博客）
- ginobefun/BestBlogs（微信公众号 → RSS 合集）
- arch3rPro/SecurityRSS（安全资讯精简版）

@module koplugin.book.features.subscribe.catalog
--]]

local Catalog = {}

local XY = "https://cdn.jsdelivr.net/gh/xiangyugongzuoliu/awesome-rss-feeds-list@main/feeds/"
local PL = "https://cdn.jsdelivr.net/gh/plenaryapp/awesome-rss-feeds@master/recommended/with_category/"

local PICK, CN, EN, TOPIC, COUNTRY, MISC =
    "精选", "中文精选", "英文精选", "国际分类", "国家与地区", "综合合集"

---@type { id: string, group: string, name: string, url?: string, feeds?: { title: string, url: string }[] }[]
Catalog.sources = {}

local function add(group, prefix, base, ext, list)
    for _idx, item in ipairs(list) do
        Catalog.sources[#Catalog.sources + 1] = {
            id = prefix .. item[1], group = group, name = item[2], url = base .. item[1] .. ext,
        }
    end
end

--- 本插件维护的精选：内嵌清单，不拉外站 OPML。
local function curated(id, group, name, feeds)
    Catalog.sources[#Catalog.sources + 1] = { id = id, group = group, name = name, feeds = feeds }
end

-- FeedX 全文：只收实测仍更新的；知乎日报 / 华尔街日报 / 苹果日报等死链不进。
curated("fulltext-news-cn", PICK, "中文新闻（全文）", {
    { title = "BBC中文", url = "https://feedx.net/rss/bbc.xml" },
    { title = "德国之声", url = "https://feedx.net/rss/dw.xml" },
    { title = "纽约时报中文网", url = "https://feedx.net/rss/nytimes.xml" },
    { title = "法广", url = "https://feedx.net/rss/rfi.xml" },
    { title = "加拿大国际广播电台", url = "https://feedx.net/rss/rci.xml" },
    { title = "中国日报", url = "https://feedx.net/rss/chinadaily.xml" },
    { title = "中央社", url = "https://feedx.net/rss/cna.xml" },
    { title = "朝鲜日报网", url = "https://feedx.net/rss/chosun.xml" },
    { title = "俄罗斯卫星通讯社", url = "https://feedx.net/rss/sputnik.xml" },
    { title = "联合早报", url = "https://feedx.net/rss/zaobao.xml" },
    { title = "日经中文网", url = "https://feedx.net/rss/nikkei.xml" },
    { title = "澳大利亚广播公司", url = "https://feedx.net/rss/abc.xml" },
})

curated("fulltext-mag-cn", PICK, "杂志与专栏（全文）", {
    { title = "ONE · 一个", url = "https://feedx.net/rss/one.xml" },
    { title = "The New Yorker", url = "https://feedx.net/rss/newyorker.xml" },
    { title = "梨视频", url = "https://feedx.net/rss/pearvideo.xml" },
})

curated("cn-tech-life", PICK, "中文科技与生活", {
    { title = "摸鱼日报", url = "https://api.ankio.net/myrl/rss" },
    { title = "今日要闻", url = "https://api.ankio.net/paper/rss" },
    { title = "少数派", url = "https://sspai.com/feed" },
    { title = "奇客Solidot", url = "https://www.solidot.org/index.rss" },
    { title = "小众软件", url = "https://feed.appinn.com/" },
    { title = "IT之家", url = "https://www.ithome.com/rss/" },
    { title = "爱范儿", url = "https://www.ifanr.com/feed" },
    { title = "阮一峰的网络日志", url = "https://www.ruanyifeng.com/blog/atom.xml" },
    { title = "机核", url = "https://www.gcores.com/rss" },
    { title = "游研社", url = "https://www.yystv.cn/rss/feed" },
    { title = "豆瓣最受欢迎的书评", url = "https://www.douban.com/feed/review/book" },
    { title = "FT中文网", url = "https://www.ftchinese.com/rss/news" },
    { title = "BBC Chinese（官方）", url = "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml" },
})

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
Catalog.sources[#Catalog.sources + 1] = {
    id = "bestblogs-wechat", group = MISC, name = "微信公众号精选（BestBlogs）",
    url = "https://cdn.jsdelivr.net/gh/ginobefun/BestBlogs@main/opml/bestblogs_wechat2rss_opml_all.opml",
}
Catalog.sources[#Catalog.sources + 1] = {
    id = "security-rss", group = MISC, name = "安全资讯（精简）",
    url = "https://cdn.jsdelivr.net/gh/arch3rPro/SecurityRSS@main/SecurityRSS-Lite.opml",
}

--- 按 id 取条目。
---@param id string
---@return { id: string, group: string, name: string, url?: string, feeds?: { title: string, url: string }[] }|nil
function Catalog.find(id)
    for _idx, s in ipairs(Catalog.sources) do
        if s.id == id then return s end
    end
end

return Catalog
