local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local BookHash = require("grimmory/book_hash")

local GrimmoryLogger = require("grimmory/logger")
local PluginMetadata = require("grimmory/plugin_metadata")

local logger = GrimmoryLogger:new()

local SESSION_COLLAPSE_THRESHOLD = 180.0

---@generic T
---@param database_path string
---@param callback (fun(database: any) | fun(database: any): `T`)
---@param flags? "ro" | "rw" | "rwc"
---@return boolean ok
---@return T result
-- Connections kept open for the length of a sync, by database path.
local shared_connections = {}

local function with_database(database_path, callback, flags)
    if flags == nil then
        flags = "ro"
    end

    local shared = shared_connections[database_path]
    if shared then
        local ok, result = pcall(callback, shared)
        if not ok then
            -- Closing a connection rolls back an unfinished transaction; a
            -- shared one stays open, so roll back here instead.
            pcall(shared.exec, shared, "ROLLBACK")
        end
        return ok, result
    end

    local open_ok, database = pcall(SQ3.open, database_path, flags)

    if not open_ok then
        return false, database
    end

    database:set_busy_timeout(1000)

    local ok, result = pcall(callback, database)

    database:close()

    return ok, result
end

---@class GrimmoryLocalBook
---@field id integer
---@field book_md5 string
---@field book_path string
---@field grimmory_id integer | nil

---@alias ReadingSessionEventType
---| "page"
---| "session-start"
---| "session-end"
---| "annotation-added"
---| "annotation-removed"
---| "annotation-updated"

---@class ReadingSession
---@field grimmory_id number | nil
---@field book_md5 string
---@field book_path string
---@field start_time number
---@field end_time number
---@field start_page number
---@field end_page number
---@field page_count number
---@field start_progress number
---@field end_progress number
---@field start_xpointer string | nil
---@field end_xpointer string | nil

---@class ReadingSessionEvent
---@field session_id number
---@field event_type ReadingSessionEventType
---@field grimmory_id number | nil
---@field book_md5 string
---@field book_path string
---@field timestamp number
---@field page number
---@field page_count number
---@field xpointer string | nil

---@class ReadingSessionProgress
---@field grimmory_id number | nil
---@field book_md5 string
---@field book_path string
---@field end_time number
---@field end_progress number
---@field end_page number | nil
---@field end_xpointer string | nil

---@class GrimmoryLocalRepository
---@field migrations_path string
---@field database_path string
local GrimmoryLocalRepository = {
    migrations_path = PluginMetadata:getPluginPath() .. "/grimmory/migrations/",
    database_path =  DataStorage:getSettingsDir() .. "/grimmory.sqlite3",
}

function GrimmoryLocalRepository:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryLocalRepository:getMigrations()
    if not util.directoryExists(self.migrations_path) then
        return {}
    end

    local sql_files = {}

    util.findFiles(
        self.migrations_path,
        function(sql_file)
            table.insert(sql_files, sql_file)
        end
    )

    table.sort(sql_files)

    return sql_files
end

function GrimmoryLocalRepository:runMigrations()
    local sql_files = self:getMigrations()

    for _, sql_filepath in ipairs(sql_files) do
        local sql = util.readFromFile(sql_filepath, "r")
        logger:dbg("Running SQL file path:", sql_filepath)

        if sql ~= nil then
            with_database(
                self.database_path,
                function(database)
                    database:exec(sql)
                end,
                "rwc"
            )
        end
    end
end

function GrimmoryLocalRepository:hasDuplicateBookRows()
    local ok, found = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT 1 FROM book GROUP BY book_path HAVING COUNT(*) > 1 LIMIT 1
            ]])
            local row = stmt:step()
            stmt:close()
            return row ~= nil
        end
    )

    return ok and found
end

function GrimmoryLocalRepository:init()
    -- The merge migration deletes rows, so keep a copy of the database the
    -- first time it has anything to merge.
    if util.fileExists(self.database_path) and self:hasDuplicateBookRows() then
        local backup_path = self.database_path .. ".before-merge"
        if not util.fileExists(backup_path) then
            logger:info("Backing up database before merging book rows:", backup_path)
            ffiUtil.copyFile(self.database_path, backup_path)
        end
    end

    logger:dbg("Running migrations")
    self:runMigrations()
end

-- Events whose session and progress have both been pushed to Grimmory.
-- Shared by pruning so nothing still waiting to be sent is ever deleted.
local SENT_EVENTS_SQL = [[
    SELECT book_event.id
    FROM book_event
    JOIN book_session ON book_session.id = book_event.session_id
    JOIN book ON book.id = book_session.book_id
    LEFT JOIN book_sync_status AS sync_sessions
        ON sync_sessions.book_id = book.id AND sync_sessions.sync_type = 'sessions'
    LEFT JOIN book_sync_status AS sync_progress
        ON sync_progress.book_id = book.id AND sync_progress.sync_type = 'progress'
    WHERE
        book.grimmory_id IS NOT NULL
        AND book_event.created_at <= COALESCE(sync_sessions.last_synced_at, 0)
        AND book_event.created_at <= COALESCE(sync_progress.last_synced_at, 0)
]]

---@return number | nil size_bytes
function GrimmoryLocalRepository:getDatabaseSize()
    local file = io.open(self.database_path, "rb")
    if not file then
        return nil
    end
    local size = file:seek("end")
    file:close()
    return size
end

---@param suffix string
---@return boolean ok
function GrimmoryLocalRepository:backupDatabase(suffix)
    local backup_path = self.database_path .. "." .. suffix
    local copy_error = ffiUtil.copyFile(self.database_path, backup_path)
    if copy_error then
        logger:err("Could not back up database to", backup_path, "-", copy_error)
        return false
    end
    return true
end

local function vacuum(database_path)
    local ok, message = with_database(database_path, function(conn)
        conn:exec("VACUUM")
    end, "rw")
    if not ok then
        logger:warn("Could not compact database:", message)
    end
end

-- Delete data that is already on Grimmory and no longer needed locally:
-- sent events older than the cutoff (keeping each book's newest session,
-- which progress checks read), sessions left empty, and rows for book files
-- that no longer exist and either have nothing left to send or were never
-- matched to Grimmory (matching needs the file, so they never can be).
---@param cutoff number events created before this timestamp may go
---@param file_exists fun(path: string): boolean
---@return boolean ok
---@return table | string counts_or_error { events, sessions, books }
function GrimmoryLocalRepository:pruneOldData(cutoff, file_exists)
    if not self:backupDatabase("before-prune") then
        return false, "Could not back up the database"
    end

    local ok, counts = with_database(self.database_path, function(conn)
        local function changes()
            return tonumber(conn:rowexec("SELECT changes()")) or 0
        end

        conn:exec("BEGIN IMMEDIATE")

        local result = { events = 0, sessions = 0, books = 0 }

        local events_stmt = conn:prepare([[
            DELETE FROM book_event WHERE id IN (]] .. SENT_EVENTS_SQL .. [[
                AND book_event.created_at < ?
                AND book_session.id <> (
                    SELECT MAX(newest.id) FROM book_session AS newest
                    WHERE newest.book_id = book.id
                )
            )
        ]])
        events_stmt:bind(cutoff)
        events_stmt:step()
        events_stmt:close()
        result.events = changes()

        conn:exec([[
            DELETE FROM book_session
            WHERE NOT EXISTS (SELECT 1 FROM book_event WHERE book_event.session_id = book_session.id)
        ]])
        result.sessions = changes()

        local missing = {}
        local books_stmt = conn:prepare("SELECT id, book_path, grimmory_id FROM book")
        local row = books_stmt:step()
        while row do
            if not file_exists(tostring(row[2])) then
                table.insert(missing, { id = tonumber(row[1]), unmatched = row[3] == nil })
            end
            row = books_stmt:step()
        end
        books_stmt:close()

        local unsent_stmt = conn:prepare([[
            SELECT COUNT(*) FROM book_event
            JOIN book_session ON book_session.id = book_event.session_id
            WHERE book_session.book_id = ? AND book_event.id NOT IN (]] .. SENT_EVENTS_SQL .. [[)
        ]])
        local delete_statements = {
            conn:prepare("DELETE FROM book_event WHERE session_id IN (SELECT id FROM book_session WHERE book_id = ?)"),
            conn:prepare("DELETE FROM book_session WHERE book_id = ?"),
            conn:prepare("DELETE FROM book_sync_status WHERE book_id = ?"),
            conn:prepare("DELETE FROM book WHERE id = ?"),
        }

        for _, book in ipairs(missing) do
            local book_id = book.id
            local unsent = book.unmatched and 0 or tonumber(unsent_stmt:reset():bind(book_id):step()[1]) or 0
            if unsent == 0 then
                for _, stmt in ipairs(delete_statements) do
                    stmt:reset():bind(book_id):step()
                end
                result.books = result.books + 1
            end
        end

        unsent_stmt:close()
        for _, stmt in ipairs(delete_statements) do
            stmt:close()
        end

        conn:exec("COMMIT")
        return result
    end, "rw")

    if not ok then
        logger:err("Pruning failed, database left unchanged:", counts)
        return false, tostring(counts)
    end

    vacuum(self.database_path)
    logger:info("Pruned database:", counts.events, "events,", counts.sessions, "sessions,", counts.books, "books")
    return true, counts
end

-- Remove all local data. Anything not yet sent to Grimmory is lost.
---@return boolean ok
function GrimmoryLocalRepository:clearAllData()
    if not self:backupDatabase("before-clear") then
        return false
    end

    local ok, message = with_database(self.database_path, function(conn)
        conn:exec("BEGIN IMMEDIATE")
        conn:exec("DELETE FROM book_event")
        conn:exec("DELETE FROM book_session")
        conn:exec("DELETE FROM book_sync_status")
        conn:exec("DELETE FROM book")
        conn:exec("COMMIT")
    end, "rw")

    if not ok then
        logger:err("Clearing failed, database left unchanged:", message)
        return false
    end

    vacuum(self.database_path)
    logger:info("Cleared database")
    return true
end

---@param book_path string
---@param grimmory_id number | nil
---@return boolean ok
---@return integer | nil book_id
---@return integer | nil grimmory_id
function GrimmoryLocalRepository:upsertBook(book_path, grimmory_id)
    -- Resolve path for file.
    local absolute_book_path = ffiUtil.realpath(book_path)

    local partial_md5 = BookHash.partialMD5(absolute_book_path)

    -- Most calls are for books already recorded. Even no-op write statements
    -- cost a commit on e-reader flash (~25 ms each), so look first and only
    -- open for writing when something actually changes.
    local found_ok, existing = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT id, grimmory_id FROM book WHERE book_path = ? AND partial_md5 = ?
            ]])
            stmt:bind(absolute_book_path, partial_md5)
            local row = stmt:step()
            stmt:close()

            if not row then
                return nil
            end

            return { id = tonumber(row[1]), grimmory_id = tonumber(row[2]) }
        end
    )

    if found_ok and existing and (grimmory_id == nil or grimmory_id == existing.grimmory_id) then
        return true, existing.id, existing.grimmory_id
    end

    local ok, book = with_database(
        self.database_path,
        function(conn)
            -- A changed file keeps its row (and so its reading history),
            -- taking the new hash, rather than gaining a second row.
            local rehash_stmt = conn:prepare([[
                UPDATE book
                SET
                    partial_md5 = ?
                WHERE
                    id = (SELECT MAX(id) FROM book WHERE book_path = ?)
                    AND NOT EXISTS (
                        SELECT 1 FROM book WHERE book_path = ? AND partial_md5 = ?
                    )
            ]])

            rehash_stmt:bind(partial_md5, absolute_book_path, absolute_book_path, partial_md5)
            rehash_stmt:step()
            rehash_stmt:close()

            -- Remember that `OR IGNORE` will ignore almost all
            -- data type or constraint failures.
            local insert_stmt = conn:prepare([[
                INSERT OR IGNORE INTO book
                    (
                        book_path,
                        partial_md5
                    )
                VALUES (?, ?);
            ]])

            insert_stmt:bind(absolute_book_path, partial_md5)
            insert_stmt:step()
            insert_stmt:close()

            -- Cannot use last row ID because it's possible this book
            -- already had existed.
            local select_stmt = conn:prepare([[
                SELECT
                    id,
                    grimmory_id
                FROM book
                WHERE book_path = ? AND partial_md5 = ?
            ]])

            select_stmt:bind(absolute_book_path, partial_md5)
            local row = select_stmt:step()
            select_stmt:close()

            if not row then
                return error("Error during re-select insert")
            end

            local book_id = tonumber(row[1])
            local existing_grimmory_id = tonumber(row[2])

            if grimmory_id == nil then
                grimmory_id = existing_grimmory_id
            elseif existing_grimmory_id ~= grimmory_id then
                local update_stmt = conn:prepare([[
                    UPDATE book
                    SET
                        grimmory_id = ?
                    WHERE
                        id = ?
                ]])

                update_stmt:bind(grimmory_id, book_id)
                update_stmt:step()
                update_stmt:close()
            end

            return {
                id = book_id,
                grimmory_id = grimmory_id,
            }
        end,
        "rw"
    )

    if not ok or not book then
        logger:err("Failed to upsert book:", absolute_book_path, "-", book)
        return false, nil, nil
    end

    return true, book.id, book.grimmory_id
end

---@param book_id integer
---@param partial_md5 string
---@return boolean ok
---@return string | nil message
function GrimmoryLocalRepository:updateBook(book_id, partial_md5)
    local ok, message = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                UPDATE
                    book
                SET
                    partial_md5 = ?
                WHERE
                    id = ?;
            ]])

            stmt:bind(partial_md5, book_id)

            stmt:step()
            stmt:close()
        end,
        "rw"
    )

    if not ok then
        logger:err("Failed to update book:", book_id, "-", message)
        return ok, message
    end

    return ok, nil
end

---@param book_path string
---@return boolean ok
---@return integer | nil book_id
---@return integer | nil grimmory_id
function GrimmoryLocalRepository:findBookByPath(book_path)
    local absolute_book_path = ffiUtil.realpath(book_path) or book_path

    local ok, book = with_database(
        self.database_path,
        function(conn)
            -- Newest row wins, as older rows for a path are stale file versions.
            local stmt = conn:prepare([[
                SELECT id, grimmory_id FROM book WHERE book_path = ? ORDER BY id DESC LIMIT 1
            ]])
            stmt:bind(absolute_book_path)
            local row = stmt:step()
            stmt:close()

            if not row then
                return nil
            end

            return { id = tonumber(row[1]), grimmory_id = tonumber(row[2]) }
        end
    )

    if not ok then
        logger:err("Failed to find book by path:", absolute_book_path, "-", book)
        return false, nil, nil
    end

    if not book then
        return true, nil, nil
    end

    return true, book.id, book.grimmory_id
end

---@param book_path string
---@param partial_md5 string
---@return boolean ok
---@return integer | nil book_id
---@return integer | nil grimmory_id
function GrimmoryLocalRepository:findBookByFile(book_path, partial_md5)
    -- Resolve path for file.
    local absolute_book_path = ffiUtil.realpath(book_path)

    local ok, book = with_database(
        self.database_path,
        function(conn)
            local select_stmt = conn:prepare([[
                SELECT
                    id,
                    grimmory_id
                FROM book
                WHERE
                    book_path = ?
                    AND
                    partial_md5 = ?
            ]])

            select_stmt:bind(absolute_book_path, partial_md5)
            local row = select_stmt:step()
            select_stmt:close()

            if not row then
                return nil
            end

            return {
                id = tonumber(row[1]),
                grimmory_id = tonumber(row[2]),
            }
        end
    )

    if not ok then
        logger:err("Failed to find book:", absolute_book_path, partial_md5, "-", book)
        return false, nil, nil
    end

    if not book then
        logger:dbg("Book query succees but did not find book:", absolute_book_path, partial_md5)
        return true, nil, nil
    end

    return true, book.id, book.grimmory_id
end

---@param grimmory_id number
---@return boolean ok
---@return GrimmoryLocalBook[] books
function GrimmoryLocalRepository:findBooksByGrimmoryId(grimmory_id)
    local ok, books = with_database(
        self.database_path,
        function(conn)
            local select_stmt = conn:prepare([[
                SELECT
                    id,
                    book_path,
                    partial_md5
                FROM book
                WHERE
                    grimmory_id = ?
            ]])

            select_stmt:bind(grimmory_id)

            local books = {}

            for row in select_stmt:rows() do
                table.insert(
                    books,
                    {
                        id = tonumber(row[1]),
                        book_path = row[2],
                        book_md5 = row[3],
                    }
                )
            end

            select_stmt:close()

            return books
        end
    )

    if not ok then
        logger:err("Failed to find book:", grimmory_id, "-", books)
        return false, {}
    end

    return true, books
end

---@param book_id number
---@return boolean ok
---@return integer | nil session_id
function GrimmoryLocalRepository:insertSession(book_id)
    local ok, session_id = with_database(
        self.database_path,
        function(conn)
            local insert_stmt = conn:prepare([[
                INSERT INTO book_session
                    (
                        book_id
                    )
                VALUES (?);
            ]])

            insert_stmt:bind(book_id)
            insert_stmt:step()
            insert_stmt:close()

            local row_id = conn:rowexec("SELECT last_insert_rowid();")

            return tonumber(row_id)
        end,
        "rw"
    )

    if not ok or not session_id then
        logger:err("Failed to create session:", session_id)
        return false, nil
    end

    return true, session_id
end

---@param session_id number
---@param event_type ReadingSessionEventType
---@param current_page number
---@param page_count number
---@param xpointer string | nil
function GrimmoryLocalRepository:insertBookEvent(session_id, event_type, current_page, page_count, xpointer)
    local ok, result = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                INSERT INTO book_event
                    (
                        session_id,
                        created_at,
                        event_type,
                        current_page,
                        page_count,
                        xpointer
                    )
                VALUES (?, ?, ?, ?, ?, ?)
            ]])

            stmt:bind(
                session_id,
                os.time(),
                event_type,
                current_page,
                page_count,
                xpointer
            )

            stmt:step()

            stmt:close()
        end,
        "rw"
    )

    if not ok then
        logger:err("Failed to create session event:", result)
    end
end

---@param book_id number
---@param cutoff number | nil
---@return boolean ok
---@return ReadingSessionProgress | nil progress
function GrimmoryLocalRepository:getReadingProgress(book_id, cutoff)
    local ok, result = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    book.grimmory_id,
                    book.book_path,
                    book.partial_md5,

                    book_event.created_at,
                    book_event.current_page,
                    book_event.page_count,
                    book_event.xpointer
                FROM (
                    SELECT
                        s.book_id,
                        MAX(e.id) AS event_id
                    FROM book_event e
                    JOIN book_session s ON s.id = e.session_id
                    WHERE
                        e.created_at < ?
                    GROUP BY s.book_id
                ) AS last_event
                JOIN book_event ON last_event.event_id = book_event.id
                JOIN book_session ON book_event.session_id = book_session.id
                JOIN book ON book_session.book_id = book.id
                WHERE
                    book.id = ?
            ]])

            if cutoff == nil then
                cutoff = os.time()
            end

            stmt:bind(cutoff, book_id)

            local row = stmt:step()
            stmt:close()

            if row == nil then
                return nil
            end

            local end_time = tonumber(row[4], 10) or 0
            local end_page = tonumber(row[5]) or 0
            local page_count = tonumber(row[6]) or 0

            local end_progress = 0

            if page_count > 0 then
                end_progress = (end_page / page_count) * 100
            end

            return {
                grimmory_id = tonumber(row[1]),
                book_path = row[2],
                book_md5 = row[3],
                end_time = end_time,
                end_page = end_page,
                end_progress = end_progress,
                end_xpointer = row[7]
            }
        end
    )

    if not ok then
        logger:err("Failed to get reading progress:", book_id, "-", result)
        return ok, nil
    end

    return ok, result
end

---@param book_id integer
---@return ReadingSessionEvent[]
function GrimmoryLocalRepository:getPendingSessionEvents(book_id)
    local ok, results = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    b.grimmory_id,
                    b.book_path,
                    b.partial_md5,

                    e.session_id,
                    e.event_type,
                    e.created_at,
                    e.current_page,
                    e.page_count,
                    e.xpointer
                FROM book AS b
                LEFT JOIN book_sync_status AS bss
                    ON bss.book_id = b.id AND bss.sync_type = 'sessions'
                JOIN book_session AS s ON s.book_id = b.id
                JOIN book_event AS e ON e.session_id = s.id
                WHERE
                    e.created_at > COALESCE(bss.last_synced_at, 0)
                    AND
                    b.id = ?
                ORDER BY b.id ASC, e.created_at ASC
            ]])

            stmt:bind(book_id)

            ---@type ReadingSessionEvent[]
            local results = {}

            for row in stmt:rows() do
                ---@type ReadingSessionEvent
                local event = {
                    grimmory_id = tonumber(row[1]),
                    book_path = row[2],
                    book_md5 = row[3],
                    session_id = row[4],
                    event_type = row[5],
                    timestamp = tonumber(row[6]) or 0,
                    page = tonumber(row[7]) or 0,
                    page_count = tonumber(row[8]) or 0,
                    xpointer = row[9],
                }

                table.insert(results, event)
            end

            stmt:close()

            return results
        end
    )

    if not ok then
        logger:err("Failed to read sessions", results)
        return {}
    end

    return results
end

---@param session ReadingSession
---@param event ReadingSessionEvent
---@return boolean
local function isPartOfSession(session, event)
    if event.book_md5 ~= session.book_md5 then
        logger:dbg("Book changed, cannot collapse session:", session.book_md5, "!=", event.book_md5)
        return false
    elseif math.abs(event.timestamp - session.end_time) > SESSION_COLLAPSE_THRESHOLD then
        logger:dbg("Outside collapse session:", event.book_md5)
        return false
    elseif event.page_count ~= session.page_count then
        logger:dbg("Page count changed, cannot combine sessions")
        return false
    elseif event.xpointer == nil and session.start_xpointer ~= nil then
        logger:dbg("Cannot mix xpointer / non-xpointer sessions")
        return false
    elseif event.xpointer ~= nil and session.start_xpointer == nil then
        logger:dbg("Cannot mix xpointer / non-xpointer sessions")
        return false
    else
        return true
    end
end

---@param book_id integer
---@return ReadingSession[]
function GrimmoryLocalRepository:getPendingSessions(book_id)
    ---@type ReadingSession[]
    local sessions = {}

    for _, event in ipairs(self:getPendingSessionEvents(book_id)) do
        -- Eventually we could figure out progress from start of page
        -- to end of page?  But for now the simplest is to count
        -- progress as a point-in-time.

        -- Percentage read via page count.
        local read_progress = 0
        if event.page_count > 0 then
            read_progress = (event.page / event.page_count) * 100
        end

        -- If existing session, we should update.
        -- We can make the assumption that these are in
        -- order by book ID and start time to simplify.
        local collapsedSession = false

        if #sessions > 0 then

            if isPartOfSession(sessions[#sessions], event) then
                logger:dbg("Collapsed session for book", event.book_md5)
                collapsedSession = true

                -- set the end of this session to whatever the last event is
                sessions[#sessions].end_time = event.timestamp
                sessions[#sessions].end_page = event.page
                sessions[#sessions].end_progress = read_progress
                sessions[#sessions].end_xpointer = event.xpointer
            end
        end

        if not collapsedSession then
            logger:dbg("New Session found for book", event.book_md5)

            -- If new session, create a new session record
            ---@type ReadingSession
            local new_session = {
                grimmory_id = event.grimmory_id,
                book_md5 = event.book_md5,
                book_path = event.book_path,
                start_time = event.timestamp,
                end_time = event.timestamp,
                start_page = event.page,
                end_page = event.page,
                page_count = event.page_count,
                start_progress = read_progress,
                end_progress = read_progress,
                start_xpointer = event.xpointer,
                end_xpointer = event.xpointer,
            }

            table.insert(sessions, new_session)
        end
    end

    table.sort(
        sessions,
        function (a, b)
            return a.end_time < b.end_time
        end
    )

    return sessions
end

---@alias RepositorySyncType
---| "progress"
---| "sessions"
---| "metadata"
---| "metadata-v2"
---| "metadata-stale"
---| "metadata-file-checked"

---@param book_id number
---@param sync_type RepositorySyncType
---@param timestamp number
function GrimmoryLocalRepository:updateBookSyncTimestamp(book_id, sync_type, timestamp)
    local ok, message = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                INSERT INTO book_sync_status
                    (book_id, sync_type, last_synced_at)
                VALUES (
                    ?,
                    ?,
                    ?
                )
                ON CONFLICT (book_id, sync_type)
                DO UPDATE SET
                    last_synced_at = excluded.last_synced_at
            ]])

            stmt:bind(
                book_id,
                sync_type,
                timestamp
            )
            stmt:step()
            stmt:close()
        end,
        "rw"
    )

    if not ok then
        logger:err("Failed to update book synced at:", book_id, "-", message)
        return false
    end

    return true
end

---@param book_id number
---@param sync_type RepositorySyncType
---@return boolean ok
---@return integer timestamp
function GrimmoryLocalRepository:getBookSyncTimestamp(book_id, sync_type)
    local ok, timestamp = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    last_synced_at
                FROM book_sync_status
                WHERE
                    book_id = ?
                    AND
                    sync_type = ?
            ]])

            stmt:bind(book_id, sync_type)
            local row = stmt:step()
            stmt:close()

            if row == nil then
                return 0
            end

            return tonumber(row[1]) or 0
        end
    )

    if not ok then
        logger:err("Failed to get book sync status:", book_id, "-", timestamp)
        return false, nil
    end

    return true, timestamp
end

---@param book_id integer
---@return boolean ok
---@return table<string, number> statuses sync_type to last_synced_at
function GrimmoryLocalRepository:getBookSyncStatuses(book_id)
    local ok, statuses = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT sync_type, last_synced_at FROM book_sync_status WHERE book_id = ?
            ]])
            stmt:bind(book_id)

            local result = {}
            local row = stmt:step()
            while row ~= nil do
                result[tostring(row[1])] = tonumber(row[2]) or 0
                row = stmt:step()
            end
            stmt:close()

            return result
        end
    )

    if not ok then
        logger:err("Failed to get book sync statuses:", book_id, "-", statuses)
        return false, {}
    end

    return true, statuses
end

---@param book_id integer
---@param statuses table<string, number> sync_type to last_synced_at
function GrimmoryLocalRepository:updateBookSyncStatuses(book_id, statuses)
    local ok, message = with_database(
        self.database_path,
        function(conn)
            conn:exec("BEGIN;")
            local stmt = conn:prepare([[
                INSERT INTO book_sync_status (book_id, sync_type, last_synced_at)
                VALUES (?, ?, ?)
                ON CONFLICT (book_id, sync_type)
                DO UPDATE SET last_synced_at = excluded.last_synced_at
            ]])
            for sync_type, value in pairs(statuses) do
                stmt:reset():bind(book_id, sync_type, value)
                stmt:step()
            end
            stmt:close()
            conn:exec("COMMIT;")
        end,
        "rw"
    )

    if not ok then
        logger:err("Failed to update book sync statuses:", book_id, "-", message)
    end

    return ok
end

---@param with_sessions boolean
---@param with_progress boolean
---@return number[] book_ids
function GrimmoryLocalRepository:getBooksPendingSync(
    with_sessions,
    with_progress
)
    local ok, book_ids = with_database(
        self.database_path,
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    book.id
                FROM book
                JOIN book_session ON book.id = book_session.book_id
                JOIN book_event ON book_session.id = book_event.session_id
                LEFT JOIN book_sync_status AS sync_sessions
                    ON book.id = sync_sessions.book_id AND sync_sessions.sync_type = 'sessions'
                LEFT JOIN book_sync_status AS sync_progress
                    ON book.id = sync_progress.book_id AND sync_progress.sync_type = 'progress'
                WHERE
                    grimmory_id IS NOT NULL
                    AND
                    (
                        (
                            ? = 1
                            AND
                            book_event.created_at > COALESCE(sync_sessions.last_synced_at, 0)
                        )
                        OR
                        (
                            ? = 1
                            AND
                            book_event.created_at > COALESCE(sync_progress.last_synced_at, 0)
                        )
                    )
                GROUP BY book.id
            ]])

            stmt:bind(with_sessions and 1 or 0, with_progress and 1 or 0)

            ---@type number[]
            local results = {}

            for row in stmt:rows() do
                local book_id = tonumber(row[1])

                if book_id then
                    table.insert(results, book_id)
                end
            end

            stmt:close()

            return results
        end
    )

    if not ok or not book_ids then
        logger:err("Failed to get books for sync", book_ids)
        return {}
    end

    return book_ids
end

--- Whether the reading position changed in any event after `since`.
--- Opening a book records its position even if no page is turned.
---@param book_id integer
---@param since integer
---@return boolean ok
---@return boolean moved
function GrimmoryLocalRepository:hasPositionMovedSince(book_id, since)
    local ok, moved = with_database(
        self.database_path,
        function(conn)
            -- xpointer survives font and layout changes that renumber pages;
            -- fixed-layout documents have no xpointer, so fall back to the page.
            local stmt = conn:prepare([[
                SELECT COUNT(DISTINCT COALESCE(book_event.xpointer, book_event.current_page))
                FROM book_event
                JOIN book_session ON book_session.id = book_event.session_id
                WHERE
                    book_session.book_id = ?
                    AND book_event.created_at > ?
            ]])

            stmt:bind(book_id, since)
            local row = stmt:step()
            stmt:close()

            return row ~= nil and tonumber(row[1]) > 1
        end
    )

    if not ok then
        logger:err("Failed to check reading position for book:", book_id, "-", moved)
        return false, false
    end

    return true, moved
end

-- Events further apart than this start a new session, so a session whose
-- last event is older than this can no longer grow.
GrimmoryLocalRepository.SESSION_COLLAPSE_THRESHOLD = SESSION_COLLAPSE_THRESHOLD

-- Run fn with one database connection reused by every query, instead of
-- opening and closing the database per query (each open re-reads the schema).
-- Writes still commit as they go. Nested calls reuse the outer connection.
---@param fn function
---@return any ...
function GrimmoryLocalRepository:withSharedConnection(fn, ...)
    local path = self.database_path

    if shared_connections[path] then
        return fn(...)
    end

    local open_ok, connection = pcall(SQ3.open, path, "rw")
    if not open_ok then
        logger:warn("Could not open a shared database connection, using one per query:", connection)
        return fn(...)
    end

    connection:set_busy_timeout(1000)
    shared_connections[path] = connection

    local function finish(ok, ...)
        shared_connections[path] = nil
        connection:close()

        if not ok then
            error((...), 0)
        end

        return ...
    end

    return finish(pcall(fn, ...))
end

return GrimmoryLocalRepository
