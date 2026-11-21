--[[--
Grimmory KOReader Plugin

@module koplugin.Grimmory
--]]--
local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local dump = require("dump")
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReadCollection = require("readcollection")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryExecutor = require("grimmory/executor")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmorySettings = require("grimmory/settings")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmorySleepHold = require("grimmory/sleep_hold")
local GrimmorySelfUpdater = require("grimmory/ota/self_updater")
local GithubAPI = require("grimmory/ota/github_api")
local GrimmoryLogger = require("grimmory/logger")
local GrimmoryReadingRecorder = require("grimmory/reading/recorder")
local GrimmoryLocalRepository = require("grimmory/repository")
local GrimmoryReadingAnnotations = require("grimmory/reading/annotations")
local GrimmoryReadingProgressManager = require("grimmory/reading/progress_manager")
local GrimmorySyncReport = require("grimmory/sync_report")


local logger = GrimmoryLogger:new()

local SYNC_STEP_NAMES = {
    ["push-metadata"] = _("push reading data"),
    ["shelves"] = _("sync shelves"),
    ["pull-books"] = _("pull books"),
    ["remove-empty-shelves"] = _("remove empty shelves"),
}

---@class Grimmory
---@field dialog_manager DialogManager
---@field scheduler GrimmoryScheduler
---@field synchronizer GrimmorySynchronize
---@field ui any This is a ReaderUI
local Grimmory = WidgetContainer:extend{
    name = "grimmory",
    is_doc_only = false,
    periodic_sync_cancel = nil,
    periodic_sync_update = nil,
    release_check_cancel = nil,
    menu = nil,
    is_synchronizing = false,
    -- Sleep tracking so a sync killed by wifi dropping on suspend can be retried
    is_suspended = false,
    suspend_count = 0,
    interrupted_sync = nil,
}

function Grimmory:onDispatcherRegisterActions()
  Dispatcher:registerAction("grimmory_sync_foreground", {
    category = "none",
    event = "GrimmorySyncForegound",
    title = _("Grimmory: Sync Library"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_background", {
    category = "none",
    event = "GrimmorySyncBackground",
    title = _("Grimmory: Sync Library in Background"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_check_all_foreground", {
    category = "none",
    event = "GrimmorySyncCheckAllForeground",
    title = _("Grimmory: Sync Library (Check All Books)"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_check_all_background", {
    category = "none",
    event = "GrimmorySyncCheckAllBackground",
    title = _("Grimmory: Sync Library (Check All Books) in Background"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_foreground", {
    category = "none",
    event = "GrimmorySyncOpenBookForeground",
    title = _("Grimmory: Sync This Book"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_background", {
    category = "none",
    event = "GrimmorySyncOpenBookBackground",
    title = _("Grimmory: Sync This Book in Background"),
    general = true,
  })
end

function Grimmory:init()
    self.scheduler = GrimmoryScheduler:new()
    self.settings = GrimmorySettings:new()

    self.repository = GrimmoryLocalRepository:new({
        settings = self.settings,
    })

    self.doc_metadata = GrimmoryDocMetadata:new({
        ui = self.ui,
    })

    self.reading_recorder = GrimmoryReadingRecorder:new({
        repository = self.repository,
        settings = self.settings,
        ui = self.ui,
    })

    self.updater = GrimmorySelfUpdater:new({
        github_api = GithubAPI:new(),
        settings = self.settings,
        scheduler = self.scheduler,
    })

    self.api = GrimmoryAPI:new({
        settings = self.settings
    })

    self.reading_annotations = GrimmoryReadingAnnotations:new(self.doc_metadata)

    self.reading_progress_manager = GrimmoryReadingProgressManager:new({
        ui = self.ui,
        api = self.api,
        settings = self.settings,
        repository = self.repository,
        reading_recorder = self.reading_recorder,
        doc_metadata = self.doc_metadata,
    })

    self.dialog_manager = GrimmoryDialogManager:new({
        settings = self.settings,
        api = self.api,
        updater = self.updater,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.menu = GrimmoryMenu:new({
        ui = self.ui,
        settings = self.settings,
        repository = self.repository,
        dialog_manager = self.dialog_manager,
        updater = self.updater,
    })

    self.synchronizer = GrimmorySynchronize:new({
        settings = self.settings,
        repository = self.repository,
        api = self.api,
        doc_metadata = self.doc_metadata,
        reading_progress_manager = self.reading_progress_manager,
        reading_annotations = self.reading_annotations,
    })

    self.executor = GrimmoryExecutor:new()

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self.menu)

    FileManager:addFileDialogButtons(
        "grimmory_actions",
        function(file, is_file)
            if not is_file then
                return nil
            end

            return {
                {
                    text = _("Sync This Book"),
                    callback = function()
                        local file_chooser = FileManager.instance.file_chooser

                        if file_chooser and file_chooser.file_dialog then
                            UIManager:close(file_chooser.file_dialog)
                        end

                        self:onGrimmorySync(true, file)
                    end,
                },
                {
                    text = _("Re-download This Book"),
                    callback = function()
                        local file_chooser = FileManager.instance.file_chooser

                        if file_chooser and file_chooser.file_dialog then
                            UIManager:close(file_chooser.file_dialog)
                        end

                        -- Mark book for refresh
                        self:onGrimmorySync(true, file, true)
                    end
                }
            }
        end
    )

    self:onDispatcherRegisterActions()

    logger:dbg("Initialized")
end

-- Stop scheduled and running syncs. A sync runs in a separate process, so
-- without this it outlives KOReader and keeps going after a restart.
function Grimmory:stopBackgroundWork()
    self.scheduler:clear()
    self.executor:clear()
    self:cancelOfflineRetry()
end

function Grimmory:onExit()
    logger:dbg("Exiting")

    self:stopBackgroundWork()
end

-- KOReader sends Restart, not Exit, when it restarts (devicelistener.lua).
function Grimmory:onRestart()
    logger:dbg("Restarting, stopping background sync")

    self:stopBackgroundWork()
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    -- A lock should still go through, so cap how long a sync may hold it off.
    GrimmorySleepHold:onSuspend()

    self.is_suspended = true
    self.suspend_count = self.suspend_count + 1

    if self.is_synchronizing then
        logger:info("Suspending while a sync is running, it may be interrupted")
    end

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnSuspend() then
       self:onGrimmorySync(false)
    end
end

function Grimmory:onResume()
    logger:dbg("Device is resuming")

    GrimmorySleepHold:onResume()
    self.is_suspended = false

    if self.settings:getSyncReadingProgress() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()

    self:scheduleInterruptedSyncRetry()
end

-- Wifi takes a few seconds to come back after wake, and the progress pull above
-- runs first; delaying also keeps the retry from racing it.
local INTERRUPTED_SYNC_RETRY_DELAY = 5
-- If another sync is running when the retry is due, wait for it this long
-- between checks, up to this many times, rather than dropping the retry.
local INTERRUPTED_SYNC_BUSY_DELAY = 30
local INTERRUPTED_SYNC_BUSY_ATTEMPTS = 10

function Grimmory:scheduleInterruptedSyncRetry()
    local pending = self.interrupted_sync
    if pending == nil then
        return
    end

    -- Clear up front so each interruption gets one retry at most
    self.interrupted_sync = nil

    local attempts = 0

    local function try_retry()
        if self.is_suspended then
            -- Slept again before the retry fired; keep it for the next wake
            self.interrupted_sync = pending
            return
        end

        if self.is_synchronizing then
            -- Another sync (e.g. sync on suspend after waking) is running.
            -- It may not cover what was interrupted (a check of every
            -- book), so wait for it rather than drop the retry.
            attempts = attempts + 1
            if attempts > INTERRUPTED_SYNC_BUSY_ATTEMPTS then
                logger:info("Giving up retry of interrupted sync, another sync kept running")
                return
            end

            logger:info("Another sync is running, retrying the interrupted one after it")
            UIManager:scheduleIn(INTERRUPTED_SYNC_BUSY_DELAY, try_retry)
            return
        end

        if not self:isReadyToSync() then
            logger:info("Skipping retry of interrupted sync, not ready to sync")
            return
        end

        logger:info("Retrying sync interrupted by sleep")
        self.next_sync_is_retry = true

        -- Run quietly, but show the result if the user asked to see it
        if pending.report then
            self.report_current_sync = true
        end

        -- The 4th argument (check every book) only exists where that sync
        -- mode does; elsewhere it is ignored.
        self:onGrimmorySync(false, pending.book_path, pending.refresh_book, pending.check_every_book)
    end

    UIManager:scheduleIn(INTERRUPTED_SYNC_RETRY_DELAY, try_retry)
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")

    -- Cap the hold as on suspend, so a sync can't delay power-off for long.
    GrimmorySleepHold:onSuspend()

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnPowerOff() then
       self:onGrimmorySync(false)
    end
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")

    if self.settings:getSyncReadingProgress() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
end

function Grimmory:onPageUpdate(page)
    logger:dbg("Page Update", page)

    -- Run after everything else does for a page event.
    -- This prevents issues like the previous page's xpointer being
    -- returned for a given page.
    UIManager:nextTick(function()
        self.reading_recorder:onPageUpdate()
    end)
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnCloseDocument() then
        -- Do not block the UI thread
        UIManager:nextTick(function()
            self:onGrimmorySync(false)
        end)
    end
end

function Grimmory:onAnnotationsModified(annotation_info)
    logger:dbg("Annotations modified", annotation_info)

    local annotation = annotation_info[1]

    local is_modified = false
    if annotation_info.index_modified == nil then
        self.reading_recorder:onAnnotationUpdated()
        is_modified = true
    elseif annotation_info.index_modified < 0 then
        self.reading_recorder:onAnnotationRemoved()
        is_modified = true
    else
        self.reading_recorder:onAnnotationAdded()
    end

    if is_modified and self.ui ~= nil and self.ui.document ~= nil and self.ui.document.file ~= nil then
        if annotation.grimmory_id ~= nil then
            self.doc_metadata:appendModifiedGrimmoryAnnotation(
                self.ui.document.file,
                annotation.grimmory_id
            )
        end
    end
end

function Grimmory:onGrimmorySettingsChanged()
    logger:dbg("Settings Changed")

    self:onSchedulePeriodicPush()
end

function Grimmory:onSchedulePeriodicPush()
    if self.settings:getSyncPeriodically() then
        -- If we want to sync we need to either update
        -- and existing schedule if we already scheduled

        local frequency_seconds = self.settings:getSyncFrequency() * 60

        if self.periodic_sync_update then
            -- We already have an interval set up, so we should update
            -- it with a new frequency
            self.periodic_sync_update(frequency_seconds)
        else
            -- We don't have an existing sync update helper so we need
            -- to schedule a new interval.
            local cancel, update = self.scheduler:interval(
                frequency_seconds,
                function()
                    self:onGrimmorySync(false)
                end
            )

            self.periodic_sync_cancel = cancel
            self.periodic_sync_update = update
        end
    else
        -- We don't want to sync anymore so we need to cancel
        -- if it's defined and clean up the cancel / update props
        if self.periodic_sync_cancel then
            self.periodic_sync_cancel()
        end

        self.periodic_sync_cancel = nil
        self.periodic_sync_update = nil
    end
end

function Grimmory:pullProgressForOpenBook()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        return
    end

    local book_path = self.ui.document.file

    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    self.executor:background(
        function(run)
            local ok, latest_progress = run(
                function()
                    local _, _, latest_progress = self.reading_progress_manager:getNewerProgressForBook(book_path)
                    return latest_progress
                end
            )

            if not ok or not latest_progress then
                return
            end

            self.dialog_manager:showApplyProgressConfirmation(latest_progress)
        end,
        self.settings:getSyncEnableWifi()
    )
end

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    if self.is_synchronizing then
        logger:info("Synchronization is already happening, not ready to sync again")
        return false
    end

    return true
end

function Grimmory:onGrimmorySyncForegound()
    return self:onGrimmorySync(true)
end

function Grimmory:onGrimmorySyncCheckAllForeground()
    return self:onGrimmorySync(true, nil, nil, true)
end

function Grimmory:onGrimmorySyncCheckAllBackground()
    -- Say so if a sync is already running, where that feature is present.
    if self.onGrimmoryWatchSync and self:onGrimmoryWatchSync() then
        return true
    end
    return self:onGrimmorySync(false, nil, nil, true)
end

function Grimmory:onGrimmorySyncBackground()
    -- A background request still comes from the user, so if a sync is
    -- already running, say so rather than doing nothing.
    if self:onGrimmoryWatchSync() then
        return true
    end
    return self:onGrimmorySync(false)
end

function Grimmory:onGrimmorySyncOpenBookForeground()
    return self:onGrimmorySyncOpenBook(true)
end

function Grimmory:onGrimmorySyncOpenBookBackground()
    if self:onGrimmoryWatchSync() then
        return true
    end
    return self:onGrimmorySyncOpenBook(false)
end

-- If a sync is running, tell the user and report its result when it
-- finishes. Returns true when there was one to watch.
function Grimmory:onGrimmoryWatchSync()
    if not self.is_synchronizing then
        return false
    end

    logger:info("Sync requested while one is running, reporting that one")
    self.report_current_sync = true
    self.dialog_manager:toast(
        _("A sync is already in progress. You'll see the result when it finishes."),
        4
    )
    return true
end

-- Close the main menu so a sync result isn't hidden behind it, and so the
-- menu is rebuilt (without "Sync in progress") next time it's opened.
function Grimmory:closeMainMenu()
    local menu = self.ui and self.ui.menu
    if menu == nil then
        return
    end

    pcall(function()
        if menu.onCloseReaderMenu then
            menu:onCloseReaderMenu()
        elseif menu.onCloseFileManagerMenu then
            menu:onCloseFileManagerMenu()
        end
    end)
end

function Grimmory:onGrimmorySyncOpenBook(verbose)
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        logger:info("No open book, skipping sync")
        return
    end

    local book_path = self.ui.document.file

    return self:onGrimmorySync(verbose, book_path)
end

-- What a sync can change in the open book's sidecar: position and
-- annotations. Read from disk, as the sync writes from a subprocess.
function Grimmory:openBookFingerprint()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        return nil
    end

    local file = self.ui.document.file
    local ok, settings = pcall(DocSettings.open, DocSettings, file)
    if not ok or settings == nil then
        return nil
    end

    return {
        file = file,
        state = dump({
            settings:readSetting("percent_finished"),
            settings:readSetting("last_xpointer"),
            settings:readSetting("last_page"),
            settings:readSetting("annotations"),
        }),
    }
end

function Grimmory:refreshUI(before)
   if self.ui == nil then
        return
    end

    if self.ui.document == nil or self.ui.document.file == nil then
        logger:dbg("No file is open, cannot refresh")
        return
    end

    -- Reloading closes and reopens the book, so skip it when the sync
    -- changed nothing for the book that is open.
    if before ~= nil then
        local after = self:openBookFingerprint()

        if after ~= nil and after.file == before.file and after.state == before.state then
            logger:dbg("Open book unchanged by sync, not reloading")
            return
        end
    end

    local settings = self.doc_metadata:getDocSettings(self.ui.document.file, true)

    if self.ui.annotation then
        -- Refresh annotations for any open document
        self.ui.annotation.annotations = settings:readSetting("annotations")
        pcall(self.ui.annotation.updateAnnotations, self.ui.annotation, true, true)
    end

    -- Reload document so any changes apply
    self.ui:reloadDocument()
end

-- Minutes between quiet retries of an automatic sync that found no network.
local OFFLINE_RETRY_MINUTES = { 5, 10, 20 }

function Grimmory:cancelOfflineRetry()
    if self.offline_retry then
        UIManager:unschedule(self.offline_retry)
        self.offline_retry = nil
    end

    self.offline_retry_count = 0
end

---@param book_path string|nil
function Grimmory:scheduleOfflineRetry(book_path)
    local count = (self.offline_retry_count or 0) + 1
    local minutes = OFFLINE_RETRY_MINUTES[count]

    if minutes == nil then
        logger:info("Still no connectivity, waiting for the next automatic sync")
        self:cancelOfflineRetry()
        return
    end

    if self.offline_retry then
        UIManager:unschedule(self.offline_retry)
    end

    logger:info("No connectivity, retrying sync in", minutes, "minute(s)")
    self.offline_retry_count = count
    self.offline_retry = function()
        self.offline_retry = nil
        self:onGrimmorySync(false, book_path)
    end
    UIManager:scheduleIn(minutes * 60, self.offline_retry)
end

function Grimmory:onGrimmorySync(verbose, book_path, refresh_book, check_every_book)
    -- Set by scheduleInterruptedSyncRetry; a flag rather than a parameter
    -- so other branches can add their own parameters.
    local is_retry = self.next_sync_is_retry == true
    self.next_sync_is_retry = false

    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    -- Asked for by the user while another sync (such as one started on
    -- boot or on suspend) is running: say so, and report that sync's
    -- result when it finishes instead of starting a second one.
    if verbose and self:onGrimmoryWatchSync() then
        return
    end

    local open_book_before = self:openBookFingerprint()

    local function background_callback(run, terminate)
        if not self:isReadyToSync() then
            return
        end

        -- Results stay on screen until tapped, so they aren't missed.
        -- report_current_sync is kept until the sync ends (it may be set
        -- before the sync starts, e.g. by a retry), then cleared.
        local function report(text)
            if verbose or self.report_current_sync then
                self:closeMainMenu()
                self.dialog_manager:toast(text, 0)
            end
        end

        logger:info("Synchronizing to Grimmory")

        local terminated_early = false

        local queue_terminate = function()
            logger:dbg("Terminate requested")
            terminated_early = true
            terminate()
        end

        -- Which kind of sync is running, so it can be repeated if needed
        self.sync_check_every_book = check_every_book == true

        -- Compared after the run to tell whether the device slept mid-sync
        local suspend_count_at_start = self.suspend_count
        -- A sync started by locking (sync on suspend) can fail only after
        -- wake, when the network times out, so remember it began asleep.
        local started_while_suspended = self.is_suspended

        local function interruptedBySleep()
            return not is_retry and (
                self.is_suspended
                or started_while_suspended
                or self.suspend_count ~= suspend_count_at_start
            )
        end

        -- Sleep drops wifi, so a failure around it is most likely the
        -- network going away rather than a real error: retry on wake.
        local function markInterrupted(reason)
            logger:warn("Sync interrupted by sleep, will retry on wake", reason)

            -- report_current_sync / sync_check_every_book are set by other
            -- features where present (asked-for results, check every book).
            local report = verbose or self.report_current_sync == true

            self.interrupted_sync = {
                report = report,
                book_path = book_path,
                refresh_book = refresh_book,
                check_every_book = self.sync_check_every_book,
            }
            -- Carried by the retry now, so it doesn't leak to another sync
            self.report_current_sync = false

            if report then
                -- Stays until tapped, like other results the user asked for
                self.dialog_manager:toast(
                    _("Sync interrupted by sleep, will continue on wake"),
                    0
                )
            end

            -- Already awake by the time the failure surfaced, so
            -- onResume has been and gone; schedule the retry here
            if not self.is_suspended then
                self:scheduleInterruptedSyncRetry()
            end
        end

        self.is_synchronizing = true
        self.menu:onGrimmorySyncStart(queue_terminate)

        local update_callback, close_callback
        if verbose then
            update_callback, close_callback = self.dialog_manager:showProgressDialog(
                _("Synchronizing to Grimmory"),
                queue_terminate,
                _("Continue synchronization?")
            )
        end

        local last_progress_step = 0
        local session_count = 0
        local session_error_count = 0
        local book_download_count = 0
        local book_refresh_count = 0
        local sync_report = GrimmorySyncReport:new()

        local update_progress_step = function(progress_step)
            if progress_step <= last_progress_step then
                return
            end

            last_progress_step = progress_step

            if update_callback ~= nil then
                pcall(update_callback, progress_step, 10)
            end
        end

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        self.synchronizer.open_book_path = self.ui and self.ui.document and self.ui.document.file

        local ok, result = run(
            function(progress_callback)
                if book_path then
                    self.synchronizer:synchronizeBook(book_path, refresh_book, progress_callback)
                else
                    self.synchronizer:synchronizeAll(progress_callback, check_every_book)
                end
            end,
            function(progress)
                if type(progress) ~= "table" then
                    return
                end

                sync_report:record(progress)

                if progress.state == "book-push-metadata" then
                    local pushed_books = progress.pushed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        pushed_books = 1
                        total_books = 1
                    end

                    -- Pushing sessions is 1, 2, and 3
                    update_progress_step(math.floor((pushed_books / total_books) * 3))
                end

                if progress.state:find("^shelf-") ~= nil then
                    -- If we are still seeing shelves we are at step 3
                    -- Because complete with shelves is step 4.
                    update_progress_step(3)
                end

                if (
                    progress.state == "book-downloaded" or
                    progress.state == "book-error" or
                    progress.state == "book-pull-metadata"
                ) then
                    local viewed_books = progress.viewed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        viewed_books = 1
                        total_books = 1
                    end

                    -- Step 5, 6, 7, 8, 9 are all pulling books down
                    update_progress_step(4 + math.floor((viewed_books / total_books) * 5))
                end

                if progress.state == "session-recorded" then
                    session_count = session_count + 1
                elseif progress.state == "session-error" then
                    session_error_count = session_error_count + 1
                elseif progress.state == "book-downloaded" then
                    book_download_count = book_download_count + 1

                    if book_download_count % 20 == 0 then
                        -- If we're updating a lot of books we should
                        -- emit a refresh event every once in a while
                        -- so background refresh sees these come
                        -- through quickly
                        UIManager:broadcastEvent(Event:new("RefreshContent"))

                        -- Also refresh collections in this process
                        ReadCollection:_read()
                    end

                elseif progress.state == "book-pull-metadata" then
                    book_refresh_count = book_refresh_count + 1
                end
            end
        )

        self.is_synchronizing = false
        self.menu:onGrimmorySyncComplete()

        if close_callback then
            pcall(close_callback)
        end

        if not ok then
            if terminated_early then
                logger:info("Sync was interrupted by user")

                report(_("Grimmory synchronization has been interrupted"))
            elseif interruptedBySleep() then
                markInterrupted(result)
            elseif result == GrimmoryExecutor.NO_CONNECTIVITY then
                logger:err("Cannot sync without connectivity")

                if verbose or self.report_current_sync then
                    report(_("Failed to Synchronize with Grimmory: No Connectivity"))
                else
                    -- Automatic syncs stay invisible: try again later instead.
                    self:scheduleOfflineRetry(book_path)
                end
            else
                logger:err("Failed sync", result)

                report(_("Failed to Synchronize with Grimmory"))
            end

            self.report_current_sync = false
            return
        end

        self:cancelOfflineRetry()

        -- If we have any books downloaded we need to emit a refresh
        -- event so the file manager knows it should refresh
        UIManager:broadcastEvent(Event:new("RefreshContent"))

        -- Also force refresh collections in this process
        ReadCollection.last_read_time = 0
        ReadCollection:_read()

        if book_path ~= nil then
            logger:info("Invalidating cache for book:", book_path)

            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", book_path))

            if self.ui and self.ui.file_chooser then
                self.ui.file_chooser.resetBookInfoCache(book_path)
                self.ui.file_chooser:init()
            end
        end

        self:refreshUI(open_book_before)

        if sync_report:hasProblems() then
            logger:warn(
                "Sync finished with problems. Failed books:",
                table.concat(sync_report.failed_books, "; "),
                "Failed steps:",
                table.concat(sync_report.failed_steps, ", ")
            )

            -- Steps run independently, so sleep usually shows up here as
            -- failed steps rather than as the whole run failing.
            if interruptedBySleep() then
                markInterrupted(table.concat(sync_report.failed_steps, ", "))
                return
            end
        end

        if verbose or self.report_current_sync then
            local message = {
                sync_report:hasProblems()
                    and _("Grimmory sync finished with problems")
                    or _("Completed Grimmory sync")
            }

            if session_count > 0 then
                table.insert(message, T(_("%1 session(s) recorded"), session_count))
            end

            if session_error_count > 0 then
                table.insert(message, T(_("%1 session(s) failed"), session_error_count))
            end

            if book_download_count > 0 then
                table.insert(message, T(_("%1 book(s) downloaded"), book_download_count))
            end

            if book_refresh_count > 0 then
                table.insert(message, T(_("%1 book(s) refreshed"), book_refresh_count))
            end

            if #sync_report.failed_books > 0 then
                local names, hidden_count = sync_report:getFailedBookNames(5)
                if hidden_count > 0 then
                    names = T(_("%1 and %2 more"), names, hidden_count)
                end
                table.insert(message, T(_("%1 book(s) failed: %2"), #sync_report.failed_books, names))
            end

            if #sync_report.failed_steps > 0 then
                local step_names = {}
                for index = 1, #sync_report.failed_steps do
                    local step = sync_report.failed_steps[index]
                    table.insert(step_names, SYNC_STEP_NAMES[step] or step)
                end
                table.insert(message, T(_("Could not: %1"), table.concat(step_names, ", ")))
            end

            report(table.concat(message, "\n"))
        end

        self.report_current_sync = false
    end

    self.executor:background(
        background_callback,
        self.settings:getSyncEnableWifi()
    )
end

return Grimmory