local _ = require("gettext")
local T = require("ffi/util").template

local Device = require("device")
local Event = require("ui/event")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local util = require("util")

local PluginMetadata = require("grimmory/plugin_metadata")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class GrimmoryMenu
---@field ui any This is a ReaderUI
---@field settings GrimmorySettings
---@field dialog_manager DialogManager
---@field updater GrimmorySelfUpdater
---@field interrupt_sync function
local GrimmoryMenu = {}

function GrimmoryMenu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function GrimmoryMenu:onGrimmorySyncStart(interrupt_sync_callback)
    self.interrupt_sync = interrupt_sync_callback
end

function GrimmoryMenu:onGrimmorySyncComplete()
    self.interrupt_sync = nil
end

function GrimmoryMenu:getAboutMenu()
    -- These won't change after the plugin starts up
    local repository = PluginMetadata.getRepository()
    local version = PluginMetadata.getVersion()

    return {
        {
            text = repository,
            keep_menu_open = true,
        },
        {
            text = T(_("Version %1"), version),
            keep_menu_open = true,
            separator = true,
        },
        {
            text_func = function()
                if self.updater:isPendingRestart() then
                    return _("Update Pending Restart")
                end

                if self.updater:isUpdateAvailable() then
                    local latest_version = self.updater:getLatestReleaseVersion()
                    return T(_("Update to %1"), latest_version)
                end

                return _("Check for Updates")
            end,
            callback = function()
                if self.updater:isPendingRestart() then
                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                else
                    self.dialog_manager:showPluginUpdateCheck()
                end
            end,
        },
    }
end

function GrimmoryMenu:getAutomaticSyncOptionsMenu()
    return {
        {
            text = _("On Close Document"),
            checked_func = function()
                return self.settings:getSyncOnCloseDocument()
            end,
            callback = function()
                self.settings:toggleSyncOnCloseDocument()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text = _("On Suspend"),
            checked_func = function()
                return self.settings:getSyncOnSuspend()
            end,
            callback = function()
                self.settings:toggleSyncOnSuspend()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text = _("On Power Off"),
            checked_func = function()
                return self.settings:getSyncOnPowerOff()
            end,
            callback = function()
                self.settings:toggleSyncOnPowerOff()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
            separator = true,
        },
        {
            text = _("Periodically Sync"),
            checked_func = function()
                return self.settings:getSyncPeriodically()
            end,
            callback = function()
                self.settings:toggleSyncPeriodically()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                local frequency = self.settings:getSyncFrequency()
                return T(_("Frequency: %1 minutes"), frequency)
            end,
            callback = function()
                self.dialog_manager:showSyncFrequencySettings()
            end,
            separator = true,
        },
        {
            text = _("Enable WiFi"),
            enabled = Device:hasWifiToggle(),
            checked_func = function()
                return self.settings:getSyncEnableWifi()
            end,
            callback = function()
                self.settings:toggleSyncEnableWifi()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
    }
end

function GrimmoryMenu:getSyncOptionsMenu()
    return {
        {
            text = _("Sync Reading Sessions"),
            checked_func = function()
                return self.settings:getSyncReadingSessions()
            end,
            callback = function()
                self.settings:toggleSyncReadingSessions()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Reading Session Thresholds"),
            callback = function()
                self.dialog_manager:showSessionThresholdSettings()
            end,
            separator = true,
        },
        {
            text = _("Sync Annotations"),
            checked_func = function()
                return self.settings:getSyncAnnotations()
            end,
            callback = function()
                self.settings:toggleSyncAnnotations()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            separator = true,
        },
        {
            text = _("Sync Reading Progress"),
            checked_func = function()
                return self.settings:getSyncReadingProgress()
            end,
            callback = function()
                self.settings:toggleSyncReadingProgress()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            separator = true,
        },
        {
            text = _("Sync Shelves"),
            checked_func = function()
                return self.settings:getSyncShelves()
            end,
            callback = function()
                self.settings:toggleSyncShelves()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Sync Empty Shelves"),
            enabled_func = function()
                return self.settings:getSyncShelves()
            end,
            checked_func = function()
                return self.settings:getSyncShelves() and self.settings:getSyncRetainEmptyShelves()
            end,
            callback = function()
                self.settings:toggleSyncRetainEmptyShelves()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
    }
end

function GrimmoryMenu:getDownloadOptionsMenu()
    return {
        {
            text = _("Set Download Directory"),
            callback = function()
                self.dialog_manager:showDownloadDirectorySettings()
            end,
        },
        {
            text_func = function()
                local targetDescription = "All"

                local targetShelves = self.settings:getDownloadTargetShelves()

                local count = 0
                for _, shelf in ipairs(targetShelves) do
                    if count == 0 then
                        targetDescription = shelf.name
                    else
                        targetDescription = targetDescription .. ", " .. shelf.name
                    end
                    count = count + 1
                end

                return T(_("Source Shelves: %1"), targetDescription)
            end,
            enabled_func = function()
                if self.settings:getBaseUri() == "" then
                    logger:info("BaseURI is not configured, cannot fetch shelves")
                    return false
                end

                return true
            end,
            callback = function()
                self.dialog_manager:showTargetShelvesSettings()
            end,
            separator = true,
        },
        {
            text = _("Permanently Delete Removed Books"),
            checked_func = function()
                return self.settings:getDownloadRemoveBooks()
            end,
            callback = function()
                self.settings:toggleDownloadRemoveBooks()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Re-download Books Changed on the Server"),
            help_text = _("When a full sync finds that Grimmory no longer recognises a downloaded book's file, download it again. Reading position, highlights and statistics are kept. A backup of KOReader's statistics database is made before it is changed."),
            checked_func = function()
                return self.settings:getDownloadRefreshChangedBooks()
            end,
            callback = function()
                self.settings:toggleDownloadRefreshChangedBooks()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Merge Split Reading Statistics"),
            help_text = _("Books downloaded again before Grimmory kept their statistics together can have their reading history split over several records. Merge records with the same title and authors whose old file is gone. Asks first; a backup is made."),
            enabled_func = function()
                return self.interrupt_sync == nil
            end,
            keep_menu_open = true,
            callback = function()
                self.dialog_manager:showMergeSplitStatistics()
            end,
        },
    }
end

-- Sent sessions older than this can be pruned from the local database.
local PRUNE_AFTER_DAYS = 90

function GrimmoryMenu:getDatabaseMenu()
    local function is_idle()
        return self.interrupt_sync == nil
    end

    return {
        {
            text_func = function()
                local size = self.repository:getDatabaseSize()
                return T(_("Database Size: %1"), size and util.getFriendlySize(size) or _("unknown"))
            end,
            keep_menu_open = true,
            callback = function() end,
            separator = true,
        },
        {
            text = _("Prune Old Data"),
            help_text = T(_("Remove reading sessions already sent to Grimmory that are older than %1 days, and records of books no longer on this device with nothing left to send. A backup copy of the database is made first."), PRUNE_AFTER_DAYS),
            enabled_func = is_idle,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new({
                    text = T(_("Prune old data?\n\nWhat it's for: Grimmory keeps a record of every reading session and every book it has seen. Over months this grows and slows syncs down. Pruning removes sessions already sent to Grimmory that are older than %1 days, and records of books no longer on this device.\n\nNothing still waiting to be sent is removed, and a backup is made first. Run it now and then if syncs feel slow or the database size above is large."), PRUNE_AFTER_DAYS),
                    ok_text = _("Prune"),
                    ok_callback = function()
                        local cutoff = os.time() - PRUNE_AFTER_DAYS * 24 * 60 * 60
                        local ok, result = self.repository:pruneOldData(cutoff, util.fileExists)
                        if ok then
                            self.dialog_manager:toast(T(
                                _("Pruned %1 event(s), %2 session(s) and %3 book record(s)"),
                                result.events, result.sessions, result.books
                            ))
                        else
                            self.dialog_manager:toast(_("Could not prune the database; nothing was changed"))
                        end
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                }))
            end,
        },
        {
            text = _("Clear Database"),
            help_text = _("Remove all of the plugin's local data. Books are recorded again on the next sync. A backup copy of the database is made first."),
            enabled_func = is_idle,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new({
                    text = _("Clear all of Grimmory's local data?\n\nWhat it's for: starting over when the plugin's database is broken or confused, for example after errors that pruning doesn't fix. Books are recorded again on the next sync.\n\nReading sessions and progress not yet sent to Grimmory will be lost. Your books and KOReader's own data, including its reading statistics, are not affected. A backup is made first."),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        if self.repository:clearAllData() then
                            self.dialog_manager:toast(_("Grimmory database cleared"))
                        else
                            self.dialog_manager:toast(_("Could not clear the database; nothing was changed"))
                        end
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                }))
            end,
        },
    }
end

function GrimmoryMenu:getTopMenu()
    local menu = {
        {
            text = _("Connection Settings"),
            callback = function()
                self.dialog_manager:showConnectionSettings()
            end,
        },
        {
            text = _("Automatic Sync"),
            sub_item_table = self:getAutomaticSyncOptionsMenu()
        },
        {
            text = _("Sync Configuration"),
            sub_item_table = self:getSyncOptionsMenu(),
            separator = true,
        },
        {
            text = _("Download Books"),
            checked_func = function()
                return self.settings:getDownloadsBooks()
            end,
            callback = function()
                self.settings:toggleDownloadsBooks()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Download Configuration"),
            sub_item_table = self:getDownloadOptionsMenu(),
            separator = true,
        },
        {
            text = _("Database"),
            sub_item_table = self:getDatabaseMenu(),
            separator = true,
        },
        {
            text = _("About Grimmory Sync"),
            sub_item_table = self:getAboutMenu(),
        },
    }

    if self.interrupt_sync == nil then
        table.insert(
            menu, 1,
            {
                text = _("Sync Everything Now"),
                enabled_func = function()
                    return self.settings:getBaseUri() ~= ""
                end,
                callback = function()
                    UIManager:broadcastEvent(Event:new("GrimmorySync", true))
                end,
                separator = true,
            }
        )
    else
        table.insert(
            menu, 1,
            {
                text = _("Interrupt Current Sync"),
                callback = function()
                    if self.interrupt_sync ~= nil then
                        local dialog = ConfirmBox:new({
                            text = _("Are you sure you want to interrupt synchronization?"),
                            ok_callback = function()
                                pcall(self.interrupt_sync)
                            end,
                        })
                        UIManager:show(dialog)
                    end
                end,
                separator = true,
            }
        )
    end

    if self.ui ~= nil and self.ui.document ~= nil then
        table.insert(
            menu, 1,
            {
                text = _("Sync Open Book Now"),
                enabled_func = function()
                    return self.settings:getBaseUri() ~= "" and self.interrupt_sync == nil
                end,
                callback = function()
                    UIManager:broadcastEvent(Event:new("GrimmorySyncOpenBook", true))
                end,
            }
        )
    end

    return menu
end

function GrimmoryMenu:addToMainMenu(menu_items)
    menu_items.grimmory = {
        text = "Grimmory",
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getTopMenu()
        end,
    }
end

return GrimmoryMenu