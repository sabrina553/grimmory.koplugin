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

return KOReaderStatistics
