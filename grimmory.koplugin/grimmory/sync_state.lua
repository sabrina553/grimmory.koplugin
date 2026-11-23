-- KOReader creates a separate Grimmory instance for the file browser and for
-- each opened book. A sync, its retries and its menu entry must outlive the
-- instance that started them, so that state lives here, in one table shared
-- through the require cache.
local SyncState = {
    values = {
        is_synchronizing = false,
        is_suspended = false,
        suspend_count = 0,
    },
    -- The most recently initialised instance: the one whose UI is on screen.
    current = nil,
}

-- Fields of a Grimmory instance that are really one value for the process.
SyncState.SHARED_FIELDS = {
    is_synchronizing = true,
    is_suspended = true,
    suspend_count = true,
    interrupted_sync = true,
    next_sync_retries = true,
    report_current_sync = true,
    sync_check_every_book = true,
    offline_retry = true,
    offline_retry_count = true,
    wake_work = true,
    library_wake_work = true,
    library_start_checked = true,
}

-- Route the shared fields of `instance` to SyncState, everything else to
-- the instance and its class as before.
function SyncState.share(instance, class)
    local shared = SyncState.SHARED_FIELDS
    local values = SyncState.values

    setmetatable(instance, {
        __index = function(_, key)
            if shared[key] then
                return values[key]
            end
            return class[key]
        end,
        __newindex = function(object, key, value)
            if shared[key] then
                values[key] = value
            else
                rawset(object, key, value)
            end
        end,
    })

    SyncState.current = instance
end

return SyncState
