--[[--
HTTP 文件下载（直写磁盘，.part → rename）

@module koplugin.book.http.download
--]]

local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Header = require("http.header")
local Request = require("http.request")
local _ = require("gettext")
local T = require("ffi/util").template

local Download = {}

--- 下载到 dest（先写 dest.part，成功再 rename）
---@param url string
---@param dest string
---@param opts { headers: table|nil, on_progress: fun(bytes: number)|nil, timeout: number|nil, block_timeout: number|nil }|nil
---@return boolean|nil, string|nil err
function Download.toFile(url, dest, opts)
    opts = opts or {}
    local tmp = dest .. ".part"
    os.remove(tmp)
    local file, open_err = io.open(tmp, "wb")
    if not file then
        return nil, open_err or _("无法创建本地文件")
    end
    local sink = ltn12.sink.file(file)
    if opts.on_progress and socketutil.chainSinkWithProgressCallback then
        sink = socketutil.chainSinkWithProgressCallback(sink, opts.on_progress)
    end
    local code, _headers, err = Request.send({
        url = url,
        method = "GET",
        headers = Header.forDownload(opts.headers),
        sink = sink,
    }, opts.timeout or 15, opts.block_timeout or 300)
    -- sink.file 已关闭 file
    if err then
        os.remove(tmp)
        return nil, err
    end
    if not Request.ok(code) then
        os.remove(tmp)
        return nil, T(_("HTTP %1"), tostring(code))
    end
    os.remove(dest)
    if not os.rename(tmp, dest) then
        os.remove(tmp)
        return nil, _("无法保存文件")
    end
    return true
end

return Download
