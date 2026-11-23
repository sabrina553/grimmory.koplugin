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

local SyncReport = require("grimmory/sync_report")
local GrimmorySynchronize = require("grimmory/synchronize")

describe("GrimmorySyncReport", function()
    it("has no problems when nothing failed", function()
        local report = SyncReport:new()
        report:record({ state = "session-recorded", bookPath = "/books/A.epub" })
        report:record({ state = "book-downloaded", book_path = "/books/B.epub" })

        assert.is_false(report:hasProblems())
    end)

    it("names failed books from title, path or id, once each", function()
        local report = SyncReport:new()
        report:record({ state = "progress-failed", book_path = "/books/Salt Lakes.epub" })
        report:record({ state = "session-error", bookPath = "/books/Salt Lakes.epub" })
        report:record({ state = "book-error", book_id = 7, book_title = "The City of Brass" })
        report:record({ state = "push-error", book_id = 12 })

        assert.is_true(report:hasProblems())
        assert.are.same({ "Salt Lakes", "The City of Brass", "#12" }, report.failed_books)
    end)

    it("limits the names shown and counts the rest", function()
        local report = SyncReport:new()
        for index = 1, 7 do
            report:record({ state = "book-error", book_title = "Book " .. index })
        end

        local names, hidden_count = report:getFailedBookNames(5)

        assert.are.equal("Book 1, Book 2, Book 3, Book 4, Book 5", names)
        assert.are.equal(2, hidden_count)
    end)

    it("records failed steps", function()
        local report = SyncReport:new()
        report:record({ state = "step-error", step = "pull-books" })

        assert.is_true(report:hasProblems())
        assert.are.same({ "pull-books" }, report.failed_steps)
    end)
end)

describe("GrimmorySynchronize:synchronizeAll", function()
    local calls, events, synchronizer

    local function make_synchronizer(failing_step)
        calls, events = {}, {}

        local function step(name)
            return function()
                table.insert(calls, name)
                if name == failing_step then
                    error(name .. " broke")
                end
            end
        end

        return setmetatable({
            checkForHealthyServer = function() return true end,
            pushAllPendingBookMetadata = step("push-metadata"),
            synchronizeShelves = step("shelves"),
            pullBooks = step("pull-books"),
            removeEmptyShelves = step("remove-empty-shelves"),
        }, { __index = GrimmorySynchronize })
    end

    local function callback(progress)
        table.insert(events, progress)
    end

    it("keeps going after a failed step and reports it", function()
        synchronizer = make_synchronizer("shelves")

        synchronizer:synchronizeAll(callback)

        assert.are.same({ "push-metadata", "shelves", "pull-books", "remove-empty-shelves" }, calls)
        assert.are.equal(1, #events)
        assert.are.equal("step-error", events[1].state)
        assert.are.equal("shelves", events[1].step)
    end)

    it("skips removing empty shelves when pulling books failed", function()
        synchronizer = make_synchronizer("pull-books")

        synchronizer:synchronizeAll(callback)

        assert.are.same({ "push-metadata", "shelves", "pull-books" }, calls)
        assert.are.equal("pull-books", events[1].step)
    end)

    it("fails the sync when no step succeeded", function()
        synchronizer = make_synchronizer(nil)
        for _, name in ipairs({ "pushAllPendingBookMetadata", "synchronizeShelves", "pullBooks" }) do
            synchronizer[name] = function() error("down") end
        end

        assert.has_error(function()
            synchronizer:synchronizeAll(callback)
        end)
    end)
end)
