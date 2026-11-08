--[[--
得到书城：服务器分类、子分类、排序、分页和旧目录离线兼容。

@module tests.source.dedao.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Json = require("support.json_stub")
local queries, pages = {}, {}
local progress, pushed, read_cancelled, write_cancelled, async_progress = nil, nil, false, false, true
local cached = { { uid = "legacy-chapter", title = "旧目录" } }

package.preload["json"] = function() return Json end
package.preload["source.base"] = function()
    return {
        loadMeta = function() return { id = "dedao", name = "得到阅读", type = "chapter" } end,
        defer = function(done, ...)
            done(...)
            return { cancel = function() end }
        end,
    }
end
package.preload["source.shelf"] = function() return {} end
package.preload["source.toc"] = function() return { read = function() return cached end } end
package.preload["source.dedao.client"] = function()
    return {
        loggedIn = function() return true end,
        progressAsync = function(_id, done)
            progress = done
            if not async_progress then done({ findex = "legacy-chapter" }) end
            return { cancel = function() read_cancelled = true end }
        end,
        putProgressAsync = function(_id, _chapter, _title, done)
            pushed = done
            return { cancel = function() write_cancelled = true end }
        end,
        browseFiltersAsync = function(query, done)
            queries[#queries + 1] = query
            done({
                request = { navigation_id = query.navigation_id or "novel", label_id = query.label_id or "all",
                    sort_strategy = query.sort_strategy or "HOT", tags_ids = {} },
                filter = {
                    navigations = { title = "分类", options = {
                        { name = "小说", value = "novel", sub_options = {
                            { name = "全部", value = "all" }, { name = "推理", value = "mystery" },
                        } },
                        { name = "历史", value = "history" },
                    } },
                    sort_strategy = { title = "排序", options = {
                        { name = "最热", value = "HOT" }, { name = "最新", value = "NEW" },
                    } },
                    buy_strategy = { is_hide = true, options = {} },
                },
            })
            return { cancel = function() error("cancelled completed filter request") end }
        end,
        browsePageAsync = function(query, page, done)
            pages[#pages + 1] = { query = query, page = page }
            local rows = {}
            for idx = 1, 20 do
                rows[#rows + 1] = {
                    id_out = tostring((page - 1) * 20 + idx), item_type = 2,
                    name = "测试书", author_list = { "甲", "乙" }, index_img = "https://example.test/cover",
                }
            end
            done({ product_list = rows, is_more = 1, request_id = "public-page-session" })
            return { cancel = function() end }
        end,
        searchAsync = function(_keyword, done, page)
            done({ data = { isMore = page < 2, moduleList = { { layerDataList = {
                { type = 2, title = "搜索书", extra = { enid = "search-" .. page } },
            } } } } })
            return { cancel = function() end }
        end,
    }
end

local source = require("source.dedao").new()
local result, err
source:browseAsync({}, function(value, reason) result, err = value, reason end)
Assert.is_nil(err)
Assert.len(result.data, 60)
Assert.len(pages, 3)
Assert.len(result.groups, 3)
Assert.eq(result.data[1].authors, "甲、乙")
Assert.eq(result.groups[1].chips[1].title, "小说")
Assert.eq(result.groups[2].chips[2].title, "推理")
Assert.eq(result.groups[3].chips[2].title, "最新")
Assert.eq(pages[2].query.request_id, "public-page-session")
Assert.is_nil(pages[1].query.tags_ids)

local latest = result.groups[3].chips[2].id
source:browseAsync({ node = latest }, function(value) result = value end)
Assert.eq(queries[#queries].sort_strategy, "NEW")
Assert.eq(queries[#queries].navigation_id, "novel")
Assert.eq(queries[#queries].product_types, "2")

source:browseAsync({ node = "invalid json" }, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "响应无效")

source:searchAsync("test", function(value) result = value end)
Assert.len(result.data, 2)

source:loadTocAsync({ stable_id = "legacy-book" }, function(value) result = value end)
Assert.eq(result, cached)

local progress_result
local job = source:getProgressAsync({ stable_id = "legacy-book" }, function(value) progress_result = value end)
job.cancel()
Assert.is_true(read_cancelled, "读进度的第一步异步请求可取消")
progress({ findex = "legacy-chapter" })
Assert.is_nil(progress_result)

local toc_callback, toc_cancelled
source.loadTocAsync = function(_source, _identity, done)
    toc_callback = done
    return { cancel = function() toc_cancelled = true end }
end
async_progress, read_cancelled = false, false
job = source:getProgressAsync({ stable_id = "legacy-book" }, function(value) progress_result = value end)
job.cancel()
Assert.is_true(toc_cancelled, "同步读进度后应取消异步目录，不是已完成的读进度")
Assert.is_true(not read_cancelled)
toc_callback(cached)
Assert.is_nil(progress_result)

toc_cancelled = false
job = source:putProgressAsync({ stable_id = "legacy-book" }, { chapter_idx = 1 }, function(value) progress_result = value end)
job.cancel()
Assert.is_true(toc_cancelled, "推送前的异步目录可取消")
toc_callback(cached)
Assert.is_nil(pushed)

source.loadTocAsync = function(_source, _identity, done)
    done(cached)
    return { cancel = function() toc_cancelled = true end }
end
toc_cancelled = false
job = source:putProgressAsync({ stable_id = "legacy-book" }, { chapter_idx = 1 }, function(value) progress_result = value end)
job.cancel()
Assert.is_true(write_cancelled, "同步目录后应取消真正的进度写请求")
Assert.is_true(not toc_cancelled)
pushed(true)
Assert.is_nil(progress_result)
