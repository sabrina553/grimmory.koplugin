package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = function() end,
    warn = function() end,
    info = function() end,
    dbg = function() end,
}

local files_on_disk = {}

package.preload["grimmory/logger"] = function()
    return { new = function() return fake_logger end }
end
package.preload["readcollection"] = function() return { write = function() end } end
package.preload["ffi/MD5"] = function() return {} end
package.preload["util"] = function()
    return {
        makePath = function() return true end,
        findFiles = function(_, callback)
            for _, path in ipairs(files_on_disk) do
                callback(path)
            end
        end,
        partialMD5 = function() error("cleanup should not need to hash files") end,
    }
end

local GrimmorySynchronize = require("grimmory/synchronize")

describe("GrimmorySynchronize:pullBooks cleanup", function()
    local removed, unshelved, synchronizer, server_books, tracked

    before_each(function()
        removed, unshelved, server_books = {}, {}, {}
        -- path -> grimmory id, as the database would return by path
        tracked = {}

        synchronizer = setmetatable({
            settings = {
                getDownloadsBooks = function() return true end,
                getDownloadDirectory = function() return "/books" end,
                getDownloadRemoveBooks = function() return true end,
            },
            api = {
                getBooks = function()
                    local index = 0
                    return function()
                        index = index + 1
                        return server_books[index], index, #server_books
                    end
                end,
            },
            repository = {
                findBookByPath = function(_, path)
                    return true, tracked[path] and 1 or nil, tracked[path]
                end,
            },
            isTargetBook = function() return true end,
            pullBook = function(_, book) return book.path, false end,
            removeBook = function(_, path) table.insert(removed, path) end,
            associateWithShelves = function(_, path) table.insert(unshelved, path) end,
        }, { __index = GrimmorySynchronize })
    end)

    local function callback() end

    it("removes a book that left the shelf even if its file changed", function()
        files_on_disk = { "/books/Changed.epub" }
        tracked["/books/Changed.epub"] = 7

        synchronizer:pullBooks(callback)

        assert.are.same({ "/books/Changed.epub" }, removed)
    end)

    it("keeps books still on a synced shelf", function()
        files_on_disk = { "/books/Kept.epub", "/books/Other copy.epub" }
        tracked["/books/Other copy.epub"] = 3
        server_books = { { id = 3, path = "/books/Kept.epub" } }

        synchronizer:pullBooks(callback)

        assert.are.same({}, removed)
    end)

    it("leaves files the plugin never tracked", function()
        files_on_disk = { "/books/My own book.epub", "/books/Book.sdr/metadata.epub.lua" }

        synchronizer:pullBooks(callback)

        assert.are.same({}, removed)
        assert.are.same({}, unshelved)
    end)
end)
