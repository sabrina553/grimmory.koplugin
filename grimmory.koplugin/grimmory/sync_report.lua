-- Collects what went wrong during a sync, so a partial failure can be
-- reported as such instead of as a failed sync.
---@class GrimmorySyncReport
---@field failed_books string[]
---@field failed_steps string[]
local SyncReport = {}

local BOOK_FAILURE_STATES = {
    ["progress-failed"] = true,
    ["session-error"] = true,
    ["book-error"] = true,
    ["push-error"] = true,
}

function SyncReport:new()
    local o = {
        failed_books = {},
        failed_steps = {},
        seen_books = {},
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function getBookName(progress)
    if type(progress.book_title) == "string" and progress.book_title ~= "" then
        return progress.book_title
    end

    local path = progress.book_path or progress.bookPath
    if type(path) == "string" and path ~= "" then
        local file_name = path:match("([^/]+)$") or path
        return (file_name:gsub("%.[^.]+$", ""))
    end

    if progress.book_id ~= nil then
        return "#" .. tostring(progress.book_id)
    end

    return "?"
end

---@param progress table
function SyncReport:record(progress)
    if type(progress) ~= "table" then
        return
    end

    if progress.state == "step-error" then
        table.insert(self.failed_steps, progress.step)
        return
    end

    if BOOK_FAILURE_STATES[progress.state] then
        local name = getBookName(progress)

        if not self.seen_books[name] then
            self.seen_books[name] = true
            table.insert(self.failed_books, name)
        end
    end
end

---@return boolean
function SyncReport:hasProblems()
    return #self.failed_books > 0 or #self.failed_steps > 0
end

---@param limit integer
---@return string names, integer hidden_count
function SyncReport:getFailedBookNames(limit)
    local shown = {}
    for index = 1, math.min(limit, #self.failed_books) do
        table.insert(shown, self.failed_books[index])
    end

    return table.concat(shown, ", "), math.max(0, #self.failed_books - limit)
end

return SyncReport
