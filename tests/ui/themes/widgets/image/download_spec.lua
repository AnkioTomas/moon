--[[--
Gzip-encoded image responses must be decoded before entering the image cache.

@module tests.ui.themes.widgets.image.download_spec
--]]

local Assert = require("support.assert")
require("support.config")
require("support.stubs").install()

local pending, destination
package.loaded["http.request"] = {
    download = function(_opts, path, cb)
        pending, destination = cb, path
        return { cancel = function() end }
    end,
    header = function(response, _name) return response.encoding end,
}
package.loaded["ui.themes.widgets.image.download"] = nil
local Download = require("ui.themes.widgets.image.download")
local plain = "\137PNG\r\n\26\nimage"
local compressed = "\31\139\8\0\0\0\0\0\2\255\235\12\240\115\231\229\146\226\202\204\77\76\79\5\0\122\245\13\237\13\0\0\0"

local function fetch(name, body, encoding)
    local result, reason
    local download = Download.new("https://example.invalid/" .. name .. ".png", nil, function(path, err)
        result, reason = path, err
    end):start()
    local file = assert(io.open(destination, "wb"))
    assert(file:write(body))
    file:close()
    pending(true, nil, { encoding = encoding })
    return result, reason, download
end

local path, err = fetch("gzip-image", compressed, "GZip")
Assert.is_nil(err)
Assert.is_true(path ~= nil)
local file = assert(io.open(path, "rb"))
Assert.eq(file:read("*a"), plain)
file:close()
os.remove(path)

path, err = fetch("plain-image", plain)
Assert.is_nil(err)
file = assert(io.open(path, "rb"))
Assert.eq(file:read("*a"), plain)
file:close()
os.remove(path)

path, err = fetch("truncated-image", compressed:sub(1, -5), "gzip")
Assert.is_nil(path, "Truncated gzip must not enter the cache")
Assert.is_true(type(err) == "string" and #err > 0)
Assert.is_nil(io.open(destination, "rb"), "Failed download must clean its temporary file")
