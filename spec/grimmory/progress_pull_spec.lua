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
                getBookSyncStatuses = function(_, id)
                    return true, status[id] or {}
                end,
                updateBookSyncStatuses = function(_, id, statuses)
                    status[id] = status[id] or {}
                    for sync_type, value in pairs(statuses) do
                        status[id][sync_type] = value
                    end
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
        status[book_id]["progress-pull"] = now - 7 * 24 * 60 * 60 - 1

        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000 }))
    end)

    it("pulls when the KOReader percentage changed without new reading time", function()
        synchronizer:recordProgressPull(book_id, { last_read_time = 1000, koreader_percentage = 0.25 })

        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000, koreader_percentage = 0.5 }))
    end)

    it("pulls when the file size or cover time changed", function()
        local book = { last_read_time = 1000, file_size_kb = 512, cover_updated_on = 50 }
        synchronizer:recordProgressPull(book_id, book)

        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000, file_size_kb = 513, cover_updated_on = 50 }))
        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000, file_size_kb = 512, cover_updated_on = 60 }))
        assert.is_false(synchronizer:shouldPullProgress(book_id, book))
    end)

    it("pulls every book during a full sync", function()
        synchronizer:recordProgressPull(book_id, { last_read_time = 1000 })
        synchronizer.check_every_book = true

        assert.is_true(synchronizer:shouldPullProgress(book_id, { last_read_time = 1000 }))
    end)
end)
