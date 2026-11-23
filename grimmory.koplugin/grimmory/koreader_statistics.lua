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

return KOReaderStatistics
