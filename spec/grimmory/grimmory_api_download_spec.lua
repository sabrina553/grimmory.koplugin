package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = function() end,
    warn = function() end,
    info = function() end,
    dbg = function() end,
}

package.preload["grimmory/logger"] = function()
    return { new = function() return fake_logger end }
end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["socket.http"] = function() return {} end
package.preload["ssl.https"] = function() return {} end
package.preload["json"] = function() return {} end
package.preload["ltn12"] = function() return { sink = {}, source = {} } end
package.preload["grimmory/plugin_metadata"] = function() return {} end

local GrimmoryAPI = require("grimmory/grimmory_api")

local function exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

describe("GrimmoryAPI:downloadBook", function()
    local destination

    before_each(function()
        destination = os.tmpname()
        os.remove(destination)
    end)

    after_each(function()
        os.remove(destination)
        os.remove(destination .. ".part")
    end)

    local function api_with_request(request)
        return setmetatable({ request = request }, { __index = GrimmoryAPI })
    end

    it("moves a complete download to the destination", function()
        local api = api_with_request(function(_, _, _, _, _, sink)
            sink("book ")
            sink("content")
            sink(nil)
            return true, 200, nil
        end)

        local ok, path = api:downloadBook(1, destination)

        assert.is_true(ok)
        assert.are.equal(destination, path)
        assert.are.equal("book content", read(destination))
        assert.is_false(exists(destination .. ".part"))
    end)

    it("leaves no file when the request fails", function()
        local api = api_with_request(function(_, _, _, _, _, sink)
            sink("partial")
            return false, 500, "Server error"
        end)

        local ok, message = api:downloadBook(1, destination)

        assert.is_false(ok)
        assert.are.equal("Server error", message)
        assert.is_false(exists(destination))
        assert.is_false(exists(destination .. ".part"))
    end)

    it("leaves no file when the request raises an error", function()
        local api = api_with_request(function(_, _, _, _, _, sink)
            sink("partial")
            error("connection reset")
        end)

        local ok = api:downloadBook(1, destination)

        assert.is_false(ok)
        assert.is_false(exists(destination))
        assert.is_false(exists(destination .. ".part"))
    end)

    it("leaves no file when the server sends an empty body", function()
        local api = api_with_request(function(_, _, _, _, _, sink)
            sink(nil)
            return true, 200, nil
        end)

        local ok, message = api:downloadBook(1, destination)

        assert.is_false(ok)
        assert.are.equal("Downloaded file is empty", message)
        assert.is_false(exists(destination))
        assert.is_false(exists(destination .. ".part"))
    end)
end)
