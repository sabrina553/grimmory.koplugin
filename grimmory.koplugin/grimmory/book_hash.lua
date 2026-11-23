-- Missing outside KOReader (the specs); hashing then just isn't cached.
local has_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local util = require("util")

-- A sync asks for the same file's partial MD5 several times (progress, the
-- local book lookup, download checks). Each one is a handful of seeks, which
-- are slow on the SD card, so remember the result until the file changes.
local BookHash = {
    cache = {},
    hits = 0,
    misses = 0,
}

-- Size, modification time and inode change whenever a file is rewritten or
-- replaced by a rename, so a matching triple means the same contents.
local function fileIdentity(path)
    if not has_lfs then
        return nil
    end

    local attributes = lfs.attributes(path)
    if attributes == nil or attributes.mode ~= "file" then
        return nil
    end

    return attributes.size .. ":" .. attributes.modification .. ":" .. (attributes.ino or 0)
end

---@param path string
---@return string|nil
function BookHash.partialMD5(path)
    local identity = fileIdentity(path)
    if identity == nil then
        return util.partialMD5(path)
    end

    local cached = BookHash.cache[path]
    if cached and cached.identity == identity then
        BookHash.hits = BookHash.hits + 1
        return cached.md5
    end

    BookHash.misses = BookHash.misses + 1
    local md5 = util.partialMD5(path)
    if md5 ~= nil then
        BookHash.cache[path] = { identity = identity, md5 = md5 }
    end
    return md5
end

---@return integer hits, integer misses
function BookHash.stats()
    return BookHash.hits, BookHash.misses
end

return BookHash
