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
package.preload["readcollection"] = function() return {} end
package.preload["ffi/MD5"] = function() return {} end
package.preload["util"] = function() return {} end

local GrimmorySynchronize = require("grimmory/synchronize")

describe("GrimmorySynchronize progress pull skipping", function()
    local status, synchronizer
    local now = os.time()
    local book_id = 24 -- offset of 0 hours, so the full check is exactly 7 days

    before_each(function()
        status = {}
        synchronizer = setmetatable({
            repository = {
                getBookSyncTimestamp = function(_, id, sync_type)
                    return true, status[id .. sync_type] or 0
                end,
                updateBookSyncTimestamp = function(_, id, sync_type, timestamp)
                    status[id .. sync_type] = timestamp
                end,
            },
        }, { __index = GrimmorySynchronize })
    end)

    it("pulls a book it has never pulled", function()
        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = nil }))
    end)

    it("pulls when the book has no local id", function()
        assert.is_true(synchronizer:shouldPullProgress(nil, {}))
    end)

    it("skips a book with no new reading since the last pull", function()
        synchronizer:recordProgressPull(book_id, { last_read_time = 1000 })

        assert.is_false(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000 }))
    end)

    it("skips a never-read book after its first pull", function()
        synchronizer:recordProgressPull(book_id, { last_read_time = nil })

        assert.is_false(synchronizer:shouldPullProgress(book_id, { last_read_time = nil }))
    end)

    it("pulls when Grimmory reports newer reading", function()
        synchronizer:recordProgressPull(book_id, { last_read_time = 1000 })

        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 2000 }))
    end)

    it("pulls again once the last pull is over a week old", function()
        synchronizer:recordProgressPull(book_id, { last_read_time = 1000 })
        status[book_id .. "progress-pull"] = now - 7 * 24 * 60 * 60 - 1

        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000 }))
    end)
end)
