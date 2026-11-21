local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local PathChooser = require("ui/widget/pathchooser")
local ProgressbarDialog = require("ui/widget/progressbardialog")

local GrimmoryLogger = require("grimmory/logger")
local DocMetadata = require("grimmory/doc_metadata")
local KOReaderStatistics = require("grimmory/koreader_statistics")

local logger = GrimmoryLogger:new()

---@class DialogManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field updater GrimmorySelfUpdater
---@field reading_progress_manager ReadingProgressManager
local DialogManager = {}

function DialogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function DialogManager:toast(text, timeout)
    if self.info_message then
        UIManager:close(self.info_message)
    end

    if timeout == nil then
        timeout = 2
    elseif timeout <= 0 then
        timeout = nil
    end

    local info_message = InfoMessage:new({
        text = text,
        timeout = timeout,
    })

    UIManager:show(info_message)
    self.info_message = info_message

    return function() UIManager:close(info_message) end
end

function DialogManager:showConnectionSettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Grimmory Connection"),
        fields = {
            {
                text = self.settings:getBaseUri(),
                description = _("Server URL"),
                hint = _("http://example.com:port"),
            },
            {
                text = self.settings:getUsername(),
                description = _("Username"),
            },
            {
                text = self.settings:getPassword(),
                description = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Test"),
                callback = function()
                    local fields = dialog:getFields()

                    local ok, version = self.api:testConnection(
                        fields[1],
                        fields[2],
                        fields[3]
                    )

                    if ok then
                        self:toast(T(_("Connection successful\nGrimmory (%1)"), tostring(version)))
                    else
                        self:toast(T(_("Unable to connect to Grimmory\nError: %1"), tostring(version)))
                    end
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = dialog:getFields()

                    self.settings:setBaseUri(fields[1])
                    self.settings:setUsername(fields[2])
                    self.settings:setPassword(fields[3])

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DialogManager:showTargetShelvesSettings()
    local dialog
    local ok, result = self.api:getShelves()

    if not ok or type(result) == "string" then
        logger:err("Something went wrong loading shelves", result)
        self:toast(T(_("Could not load shelves: %1"), result))
        return
    end

    local buttons = {
        {
            {
                text = _("Cancel Selection"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }
        },
        {
            {
                text = _("All Shelves"),
                callback = function()
                    logger:dbg("Set target shelves to All Shelves")
                    self.settings:setDownloadTargetShelves({})

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            }
        }
    }

    local shelfNameToId = {}

    for _, shelf in ipairs(result) do
        local shelfName = shelf.name
        local shelfId = shelf.id

        local uniqueShelfName = shelfName
        local uniqueShelfIndex = 0
        while shelfNameToId[uniqueShelfName] do
            uniqueShelfIndex = uniqueShelfIndex + 1
            uniqueShelfName = shelfName .. " " .. uniqueShelfIndex
        end

        table.insert(
            buttons,
            {
                {
                    text = uniqueShelfName,
                    callback = function()
                        logger:dbg("Set target shelves to shelf ID", shelfId)
                        self.settings:setDownloadTargetShelves({ { id = shelfId, name = uniqueShelfName } })

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(dialog)
                    end
                }
            }
        )
    end

    dialog = ButtonDialog:new({
        title = _("Target Shelf"),
        buttons = buttons,
    })

    UIManager:show(dialog)
end

function DialogManager:showSyncFrequencySettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Periodic Sync Frequency"),
        fields = {
            {
                text = self.settings:getSyncFrequency(),
                description = _("Minutes between synchronization"),
                input_type = "number"
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = dialog:getFields()

                        self.settings:setSyncFrequency(math.max(1, fields[1]))

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

function DialogManager:showSessionThresholdSettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Session Thresholds"),
        fields = {
            {
                text = self.settings:getSessionThresholdSeconds(),
                description = _("Minimum Session Seconds"),
                input_type = "number",
            },
            {
                text = self.settings:getSessionThresholdPages(),
                description = _("Minimum Session Pages"),
                input_type = "number",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = dialog:getFields()

                    self.settings:setSessionThresholdSeconds(math.max(0, fields[1]))
                    self.settings:setSessionThresholdPages(math.max(0, fields[2]))

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DialogManager:showDownloadDirectorySettings()
    local dialog
    dialog = PathChooser:new({
        title = "Download Directory",
        select_file = false,
        show_files = false,
        path = self.settings:getDownloadDirectory(),
        onConfirm = function(newPath)
            self.settings:setDownloadDirectory(newPath)
        end,
    })

    UIManager:show(dialog)
end

function DialogManager:showPluginUpdateCheck(skip_version_check)
    if not skip_version_check then
        -- Refresh the latest version on open.
        local close_message = self:toast(_("Checking for Updates"), 0)
        self.updater:fetchLatestVersion()
        pcall(close_message)
    end

    local dialog
    local latest_version = self.updater:getLatestReleaseVersion()
    local is_update_available = self.updater:isUpdateAvailable()

    local update_button_text = _("No update available")
    local title = _("Grimmory.koplugin is currently up-to-date.")

    if is_update_available then
        update_button_text = T(_("Update to %1"), latest_version)
        title = _("Update available for Grimmory.koplugin.")
    end

    dialog = ButtonDialog:new({
        title = title,
        buttons = {
            {
                {
                    text = update_button_text,
                    callback = function()
                        if is_update_available then
                            UIManager:close(dialog)

                            self:showPluginUpdater()
                        end
                    end,
                },
                {
                    text = _("Check for Updates"),
                    callback = function()
                        self.updater:fetchLatestVersion()
                        UIManager:close(dialog)
                        self:showPluginUpdateCheck(true)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

function DialogManager:showPluginUpdater()
    local dialog = ProgressbarDialog:new({
        title = _("Updating Grimmory Plugin"),
        progress_max = 100,
        refresh_time_seconds = 3,
        dismissable = false,
    })

    UIManager:show(dialog)

    UIManager:nextTick(function()
        self.updater:update(
            function(state, progress, message)
                dialog:reportProgress(progress)

                if state == "complete" then
                    UIManager:close(dialog)

                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                elseif state == "failed" then
                    UIManager:close(dialog)

                    self:toast(T(_("Failed to update\n%1"), message), 0)
                end
            end
        )
    end)
end

function DialogManager:showProgressDialog(title, dismiss_callback, dismiss_text)
    local dialog
    local is_external_closing = false

    if dismiss_text == nil then
        dismiss_text = _("Terminate this task?")
    end

    dialog = ProgressbarDialog:new({
        title = _(title),
        progress_max = 100,
        refresh_time_seconds = 3,
        dismiss_text = dismiss_text,
        dismissable = dismiss_callback ~= nil,
        dismiss_callback = function ()
            if not is_external_closing then
                -- Only call the dismiss callback if we are closing
                -- from the progress bar dialog itself.
                pcall(dismiss_callback)
            end
        end
    })

    dialog:show()

    local close_callback = function()
        is_external_closing = true
        dialog:close()
    end

    local function update_callback(progress, total_progress)
        dialog.progress_max = total_progress
        dialog:reportProgress(progress)
    end

    return update_callback, close_callback
end

---@param progress ReadingSessionProgress
function DialogManager:showApplyProgressConfirmation(progress)
    -- TODO:

    -- Reading Progress is Available from Grimmory
    -- Go to page 25 from 25 minutes ago?

    local dialog = ConfirmBox:new({
        text = T(
            _("Go to latest location %1% from Grimmory?"),
            tostring(progress.end_progress)
        ),
        ok_callback = function()
            self.reading_progress_manager:applyProgress(progress)
        end,
    })

    UIManager:show(dialog)
end


-- Titles shown in the confirmation; the rest are counted.
local MERGE_LIST_LIMIT = 8

function DialogManager:showMergeSplitStatistics()
    local close_checking = self:toast(_("Looking for split reading statistics…"), 0)
    UIManager:forceRePaint()

    local present = KOReaderStatistics.findPresentBooks(self.settings:getDownloadDirectory())
    local find_ok, split_books = KOReaderStatistics.findSplitBooks(present, function(path)
        return DocMetadata:readFileProps(path)
    end)
    close_checking()

    if not find_ok then
        logger:err("Could not read statistics database:", split_books)
        self:toast(_("Could not read KOReader's statistics; nothing was changed"))
        return
    end

    if #split_books == 0 then
        self:toast(_("No split reading statistics found"))
        return
    end

    local lines = {}
    for i, book in ipairs(split_books) do
        if i > MERGE_LIST_LIMIT then
            table.insert(lines, T(_("…and %1 more"), #split_books - MERGE_LIST_LIMIT))
            break
        end
        if book.repoint_md5 then
            table.insert(lines, T(_("• %1 (%2 records, linked to the current file)"), book.title, #book.merge_ids + 1))
        else
            table.insert(lines, T(_("• %1 (%2 records)"), book.title, #book.merge_ids + 1))
        end
    end

    UIManager:show(ConfirmBox:new({
        text = T(
            _("Merge the reading statistics of %1 book(s) split over several records?\n\n%2\n\nBooks with the same title and authors are treated as one; a different edition you read separately would be merged too. A backup of the statistics database is made first."),
            #split_books, table.concat(lines, "\n")
        ),
        ok_text = _("Merge"),
        ok_callback = function()
            local ok, result = KOReaderStatistics.mergeSplitBooks(split_books)
            if ok then
                logger:info("Merged split reading statistics:", result, "record(s)")
                self:toast(T(_("Merged %1 record(s)"), result))
            else
                logger:err("Could not merge reading statistics:", result)
                self:toast(_("Could not merge reading statistics; nothing was changed"))
            end
        end,
    }))
end

return DialogManager