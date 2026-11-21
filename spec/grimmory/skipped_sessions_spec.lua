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

describe("GrimmorySynchronize:pushBookSessions marker", function()
    local now = os.time()
    local marker, sent, writes, synchronizer, sessions, fail_send

    -- A session of the given length (seconds) ending `ago` seconds ago
    local function session(length, ago)
        return {
            grimmory_id = 9,
            book_path = "/books/Book.epub",
            start_time = now - ago - length,
            end_time = now - ago,
            start_page = 1,
            end_page = 5,
        }
    end

    before_each(function()
        marker, sent, writes, fail_send = nil, {}, 0, false
        synchronizer = setmetatable({
            settings = {
                getSyncReadingSessions = function() return true end,
                getSessionThresholdPages = function() return 0 end,
                getSessionThresholdSeconds = function() return 30 end,
            },
            repository = {
                SESSION_COLLAPSE_THRESHOLD = 180,
                getPendingSessions = function() return sessions end,
                updateBookSyncTimestamp = function(_, _, sync_type, timestamp)
                    assert.are.equal("sessions", sync_type)
                    marker = timestamp
                    writes = writes + 1
                end,
            },
            api = {
                recordSession = function(_, _, start_time)
                    if fail_send then
                        return false, "server down"
                    end
                    table.insert(sent, start_time)
                    return true
                end,
            },
        }, { __index = GrimmorySynchronize })
    end)

    local function callback() end

    it("moves the marker past finished short sessions, with one write", function()
        sessions = { session(5, 3000), session(10, 2000) }

        synchronizer:pushBookSessions(1, callback)

        assert.are.equal(sessions[2].end_time, marker)
        assert.are.equal(1, writes)
        assert.are.same({}, sent)
    end)

    it("leaves a short session that may still be growing", function()
        sessions = { session(5, 3000), session(10, 60) }

        synchronizer:pushBookSessions(1, callback)

        assert.are.equal(sessions[1].end_time, marker)
    end)

    it("still sends long sessions and ends at the latest one", function()
        sessions = { session(5, 3000), session(600, 2000), session(5, 1000) }

        synchronizer:pushBookSessions(1, callback)

        assert.are.same({ sessions[2].start_time }, sent)
        assert.are.equal(sessions[3].end_time, marker)
    end)

    it("stops at a failed send, keeping earlier skips but not later ones", function()
        sessions = { session(5, 3000), session(600, 2000), session(5, 1000) }
        fail_send = true

        synchronizer:pushBookSessions(1, callback)

        assert.are.equal(sessions[1].end_time, marker)
    end)
end)
