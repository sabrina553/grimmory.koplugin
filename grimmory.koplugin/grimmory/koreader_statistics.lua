local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- KOReader's statistics plugin keys each book by (title, authors, md5),
-- where md5 is the sidecar's partial_md5_checksum. When a book file is
-- replaced, its reading history only follows if that md5 is moved over.
local KOReaderStatistics = {}

function KOReaderStatistics.getDatabasePath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

function KOReaderStatistics.getBackupPath()
    return KOReaderStatistics.getDatabasePath() .. ".before-grimmory-refresh"
end

local function databaseIsHealthy(database_path)
    local open_ok, conn = pcall(SQ3.open, database_path, "ro")
    if not open_ok or not conn then
        return false
    end

    local check_ok, result = pcall(function()
        return conn:rowexec("PRAGMA quick_check;")
    end)
    conn:close()

    return check_ok and result == "ok"
end

---@param old_md5 string
---@param new_md5 string
---@return boolean ok
---@return string | number moved_books_or_error
function KOReaderStatistics.moveBookHash(old_md5, new_md5, database_path)
    database_path = database_path or KOReaderStatistics.getDatabasePath()

    if not util.fileExists(database_path) then
        return true, 0
    end

    -- Back up before every write, so the newest backup always predates it.
    local backup_path = database_path .. ".before-grimmory-refresh"
    local copy_error = ffiUtil.copyFile(database_path, backup_path)
    if copy_error then
        return false, "Could not back up statistics database: " .. tostring(copy_error)
    end

    local open_ok, conn = pcall(SQ3.open, database_path, "rw")
    if not open_ok or not conn then
        return false, "Could not open statistics database: " .. tostring(conn)
    end

    local update_ok, moved_or_error = pcall(function()
        conn:exec("BEGIN IMMEDIATE;")

        -- Skip rows that would collide with an entry KOReader already made
        -- for the new file; those need merging by hand.
        local stmt = conn:prepare([[
            UPDATE OR IGNORE book SET md5 = ? WHERE md5 = ?
        ]])
        stmt:bind(new_md5, old_md5)
        stmt:step()
        stmt:close()

        local moved = tonumber(conn:rowexec("SELECT changes();")) or 0
        conn:exec("COMMIT;")
        return moved
    end)

    if not update_ok then
        pcall(conn.exec, conn, "ROLLBACK;")
    end
    conn:close()

    if not update_ok or not databaseIsHealthy(database_path) then
        logger:err("Statistics update failed, restoring backup:", moved_or_error)
        ffiUtil.copyFile(backup_path, database_path)
        return false, tostring(moved_or_error or "Statistics database failed integrity check")
    end

    return true, moved_or_error
end


-- Copies the database aside, runs `change(conn)` in one transaction, and
-- restores the copy if anything fails or the database is left unhealthy.
local function changeWithBackup(database_path, change)
    local backup_path = database_path .. ".before-grimmory-refresh"
    local copy_error = ffiUtil.copyFile(database_path, backup_path)
    if copy_error then
        return false, "Could not back up statistics database: " .. tostring(copy_error)
    end

    local open_ok, conn = pcall(SQ3.open, database_path, "rw")
    if not open_ok or not conn then
        return false, "Could not open statistics database: " .. tostring(conn)
    end

    local change_ok, result = pcall(function()
        conn:exec("BEGIN IMMEDIATE;")
        local value = change(conn)
        conn:exec("COMMIT;")
        return value
    end)

    if not change_ok then
        pcall(conn.exec, conn, "ROLLBACK;")
    end
    conn:close()

    if not change_ok or not databaseIsHealthy(database_path) then
        logger:err("Statistics update failed, restoring backup:", result)
        ffiUtil.copyFile(backup_path, database_path)
        return false, tostring(result or "Statistics database failed integrity check")
    end

    return true, result
end

local function findBookId(conn, title, authors, md5)
    local stmt = conn:prepare("SELECT id FROM book WHERE title = ? AND authors = ? AND md5 = ?;")
    local row = stmt:reset():bind(title, authors, md5):step()
    stmt:close()
    return row and tonumber(row[1]) or nil
end

-- Moves every reading record of `from_id` onto `into_id`, then drops `from_id`.
-- Totals are recomputed the same way KOReader does when it merges duplicates.
local function mergeBookInto(conn, from_id, into_id)
    conn:exec(string.format(
        "UPDATE OR IGNORE page_stat_data SET id_book = %d WHERE id_book = %d;", into_id, from_id))
    -- Left behind only where both rows recorded the same page at the same moment.
    conn:exec(string.format("DELETE FROM page_stat_data WHERE id_book = %d;", from_id))
    conn:exec(string.format("DELETE FROM book WHERE id = %d;", from_id))
    conn:exec(string.format([[
        UPDATE book SET (total_read_pages, total_read_time) =
            (SELECT count(DISTINCT page), coalesce(sum(duration), 0)
             FROM page_stat_data WHERE id_book = book.id)
        WHERE id = %d;
    ]], into_id))
end

-- KOReader's statistics key a book by (title, authors, md5), so a book whose
-- title or authors change on the server would start a second, empty record
-- the next time it's opened. Rename the record instead, merging into one
-- KOReader may already have started under the new name.
---@return boolean ok
---@return string | number renamed_books_or_error
function KOReaderStatistics.renameBook(md5, old_title, old_authors, new_title, new_authors, database_path)
    database_path = database_path or KOReaderStatistics.getDatabasePath()

    if not util.fileExists(database_path) then
        return true, 0
    end

    return changeWithBackup(database_path, function(conn)
        local old_id = findBookId(conn, old_title, old_authors, md5)
        if not old_id then
            return 0
        end

        local new_id = findBookId(conn, new_title, new_authors, md5)
        if new_id then
            mergeBookInto(conn, old_id, new_id)
        else
            local stmt = conn:prepare("UPDATE book SET title = ?, authors = ? WHERE id = ?;")
            stmt:reset():bind(new_title, new_authors, old_id):step()
            stmt:close()
        end

        return 1
    end)
end


-- Case, spacing and punctuation vary between downloads of the same book
-- ("S.A. Chakraborty" / "S. A. Chakraborty"), so compare without them.
local function normalise(text)
    return (tostring(text or "")):lower():gsub("[^%w]", "")
end

-- With no record's file left, the book may still be on the device as a
-- newer download whose md5 KOReader hasn't recorded yet (it was never opened).
-- Find it by name first, then confirm with the file's own title and authors,
-- so the merged record carries on when the book is next opened.
---@return string|nil md5
local function findReplacementFile(files, group, read_props)
    local title_key = normalise(group.title)
    local authors_key = normalise(group.authors)
    local found = nil

    for _, file in ipairs(files) do
        if file.name:find(title_key, 1, true) then
            local read_ok, props = pcall(read_props, file.path)
            if read_ok and props and normalise(props.title) == title_key and normalise(props.authors) == authors_key then
                -- Two matching files: can't tell which one is read, so leave it.
                if found then
                    return nil
                end
                found = file.md5
            end
        end
    end

    return found
end

---@class GrimmorySplitBook
---@field title string
---@field keep_id number
---@field merge_ids number[]
---@field repoint_md5 string|nil md5 of the file now on the device, when the record has none

-- Finds books whose reading history is split over several records because
-- the file was replaced. A group is only merged when exactly one record's
-- file is still on the device (or none is), so two copies kept on purpose,
-- and the book that is open, keep their own records.
---@param present GrimmoryPresentBooks
---@param read_props function(path): table|nil Reads a book file's own title and authors
---@return boolean ok
---@return GrimmorySplitBook[] | string groups_or_error
function KOReaderStatistics.findSplitBooks(present_books, read_props, database_path)
    local present_files = present_books.files
    database_path = database_path or KOReaderStatistics.getDatabasePath()

    if not util.fileExists(database_path) then
        return true, {}
    end

    local open_ok, conn = pcall(SQ3.open, database_path, "ro")
    if not open_ok or not conn then
        return false, "Could not open statistics database: " .. tostring(conn)
    end

    local read_ok, rows = pcall(function()
        return conn:exec("SELECT id, title, authors, md5, last_open FROM book ORDER BY last_open DESC, id DESC;")
    end)
    conn:close()

    if not read_ok then
        return false, tostring(rows)
    end

    local groups, order = {}, {}
    if rows and rows[1] then
        for i = 1, #rows[1] do
            local key = normalise(rows[2][i]) .. "|" .. normalise(rows[3][i])
            if not groups[key] then
                groups[key] = { title = rows[2][i], authors = rows[3][i], records = {} }
                table.insert(order, key)
            end
            table.insert(groups[key].records, {
                id = tonumber(rows[1][i]),
                present = present_books.md5[rows[4][i]] == true,
            })
        end
    end

    local split_books = {}
    for _, key in ipairs(order) do
        local group = groups[key]
        -- Untitled records can't be told apart, so leave them alone.
        if #group.records > 1 and key ~= "|" and key:sub(1, 1) ~= "|" then
            local present = {}
            for _, record in ipairs(group.records) do
                if record.present then
                    table.insert(present, record)
                end
            end

            if #present <= 1 then
                -- Newest first, so with no file left the latest record is kept.
                local keep = present[1] or group.records[1]
                local merge_ids = {}
                for _, record in ipairs(group.records) do
                    if record.id ~= keep.id then
                        table.insert(merge_ids, record.id)
                    end
                end
                local split_book = { title = group.title, keep_id = keep.id, merge_ids = merge_ids }
                if #present == 0 then
                    split_book.repoint_md5 = findReplacementFile(present_files, group, read_props)
                end
                table.insert(split_books, split_book)
            end
        end
    end

    return true, split_books
end

---@param split_books GrimmorySplitBook[]
---@return boolean ok
---@return string | number merged_records_or_error
function KOReaderStatistics.mergeSplitBooks(split_books, database_path)
    database_path = database_path or KOReaderStatistics.getDatabasePath()

    return changeWithBackup(database_path, function(conn)
        local merged = 0
        for _, book in ipairs(split_books) do
            for _, merge_id in ipairs(book.merge_ids) do
                mergeBookInto(conn, merge_id, book.keep_id)
                merged = merged + 1
            end
            if book.repoint_md5 then
                local stmt = conn:prepare("UPDATE OR IGNORE book SET md5 = ? WHERE id = ?;")
                stmt:reset():bind(book.repoint_md5, book.keep_id):step()
                stmt:close()
            end
        end
        return merged
    end)
end


-- The book files on the device: everything under the download directory,
-- plus books opened from elsewhere (from KOReader's history).
---@class GrimmoryPresentBooks
---@field md5 table<string, boolean>
---@field files { path: string, md5: string, name: string }[] Download directory files
---@param download_directory string|nil
---@return GrimmoryPresentBooks
function KOReaderStatistics.findPresentBooks(download_directory)
    local DocSettings = require("docsettings")
    local DocumentRegistry = require("document/documentregistry")
    local ReadHistory = require("readhistory")

    local present = { md5 = {}, files = {} }

    -- KOReader's statistics look a book up by the md5 saved with its
    -- settings, so prefer that over hashing the file.
    local function bookMd5(path)
        local saved = DocSettings:hasSidecarFile(path)
            and DocSettings:open(path):readSetting("partial_md5_checksum")
        return saved or util.partialMD5(path)
    end

    if download_directory and download_directory ~= "" then
        util.findFiles(download_directory, function(path, name)
            if DocumentRegistry:hasProvider(path) then
                local md5 = bookMd5(path)
                if md5 then
                    present.md5[md5] = true
                    table.insert(present.files, { path = path, md5 = md5, name = normalise(name) })
                end
            end
        end)
    end

    for _, entry in ipairs(ReadHistory.hist or {}) do
        if entry.file and util.fileExists(entry.file) then
            local md5 = bookMd5(entry.file)
            if md5 then
                present.md5[md5] = true
            end
        end
    end

    return present
end

return KOReaderStatistics
