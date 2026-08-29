--[[--
Worker 入口门面。

@module koplugin.book.workers
--]]

return {
    Master = require("workers.master"),
    Protocol = require("workers.protocol"),
}
