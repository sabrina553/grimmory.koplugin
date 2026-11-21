package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = function() end,
    warn = function() end,
    info = function() end,
    dbg = function() end,
}

local stats

local function new_connection()
    local connection = { closed = false, executed = {} }
    function connection:set_busy_timeout() end
    function connection:exec(sql) table.insert(self.executed, sql) end
    function connection:close()
        self.closed = true
        stats.closes = stats.closes + 1
    end
    function connection:prepare()
        return {
            bind = function(statement) return statement end,
            step = function() return nil end,
            close = function() end,
        }
    end
    return connection
end

package.preload["grimmory/logger"] = function()
    return { new = function() return fake_logger end }
end
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function()
            stats.opens = stats.opens + 1
            local connection = new_connection()
            stats.last = connection
            return connection
        end,
    }
end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/tmp" end } end
package.preload["ffi/util"] = function() return {} end
package.preload["util"] = function() return { directoryExists = function() return false end } end
package.preload["grimmory/plugin_metadata"] = function() return { getPluginPath = function() return "/tmp" end } end

local GrimmoryLocalRepository = require("grimmory/repository")

describe("GrimmoryLocalRepository:withSharedConnection", function()
    local repository

    before_each(function()
        stats = { opens = 0, closes = 0 }
        repository = GrimmoryLocalRepository:new({ database_path = "/tmp/test.sqlite3" })
    end)

    it("opens one connection for all queries inside it", function()
        repository:withSharedConnection(function()
            for book_id = 1, 3 do
                repository:getBookSyncTimestamp(book_id, "progress")
            end
        end)

        assert.are.equal(1, stats.opens)
        assert.are.equal(1, stats.closes)
    end)

    it("opens per query again afterwards", function()
        repository:withSharedConnection(function() end)
        repository:getBookSyncTimestamp(1, "progress")

        assert.are.equal(2, stats.opens)
        assert.are.equal(2, stats.closes)
    end)

    it("passes return values through, including nils", function()
        local a, b, c = repository:withSharedConnection(function(x) return x, nil, "c" end, "a")

        assert.are.equal("a", a)
        assert.is_nil(b)
        assert.are.equal("c", c)
    end)

    it("closes the connection and re-raises when the work fails", function()
        assert.has_error(function()
            repository:withSharedConnection(function() error("sync broke") end)
        end)

        assert.are.equal(1, stats.closes)
        repository:getBookSyncTimestamp(1, "progress")
        assert.are.equal(2, stats.opens)
    end)

    it("rolls back when a query fails on the shared connection", function()
        repository:withSharedConnection(function()
            stats.last.prepare = function() error("disk I/O error") end
            repository:getBookSyncTimestamp(1, "progress")
        end)

        assert.are.same({ "ROLLBACK" }, stats.last.executed)
    end)

    it("reuses the outer connection when nested", function()
        repository:withSharedConnection(function()
            repository:withSharedConnection(function()
                repository:getBookSyncTimestamp(1, "progress")
            end)
        end)

        assert.are.equal(1, stats.opens)
    end)
end)
