--[[--
测试用：在 require("chapters") 前注入 UI / Store 最小替身。

@module tests.support.chapter_fakes
--]]

local M = {}

function M.install(opts)
    opts = opts or {}
    package.preload["ui/widget/infomessage"] = function()
        return { new = function(o) return o end }
    end
    package.preload["ui/widget/buttondialog"] = function()
        return { new = function(o) return o end }
    end
    package.preload["ui/network/manager"] = function()
        return {
            runWhenOnline = function(_, fn) fn() end,
        }
    end
    package.preload["ui/event"] = function()
        return {
            new = function(_, name, ...)
                return { name = name, args = { ... } }
            end,
        }
    end
    if opts.readerui ~= false then
        local switched = opts.switched or {}
        package.preload["apps/reader/readerui"] = function()
            return {
                instance = {
                    document = { file = opts.current_file or "" },
                    switchDocument = function(_, path)
                        switched[#switched + 1] = path
                    end,
                },
                showReader = function(_, path)
                    switched[#switched + 1] = path
                end,
            }
        end
        M.switched = switched
    end
    if opts.store ~= false then
        package.preload["book.store"] = function()
            return opts.store_impl or {
                chapterPath = function(book_key, idx)
                    return "/tmp/moon-ch-" .. tostring(book_key) .. "-" .. tostring(idx) .. ".html"
                end,
                getToc = function() return nil end,
                putTocAsync = function() end,
                remember = function() end,
                touchAsync = function() end,
            }
        end
    end
end

return M
