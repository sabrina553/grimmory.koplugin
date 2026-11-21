local ffi = require("ffi")
local Device = require("device")
local UIManager = require("ui/uimanager")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- PocketBook firmware suspends on its own (auto-lock timer, power button) and
-- drops wifi straight away, which UIManager:preventStandby() cannot stop.
-- hw_ban_suspend() delays the suspend itself, so we renew a short ban while a
-- sync runs; if we stop renewing for any reason the ban lapses by itself.
-- It does not stop the auto-lock timer, so before the user locks we also
-- restart that countdown with iv_rise_keylock_timer(), as a touch would
-- (tested on a Verse Pro 2026-11-21: kept a 1-minute auto-lock off for 4 min).
local BAN_SECONDS = 15
local RENEW_SECONDS = 10
-- Once the user locks the device, never hold it for longer than this.
local SUSPEND_CAP_SECONDS = 30

local GrimmorySleepHold = {
    holders = 0,
    suspended_at = nil,
    renewing = false,
}

local inkview = nil
local load_attempted = false

local function getInkview()
    if load_attempted then
        return inkview
    end
    load_attempted = true

    if not (Device.isPocketBook and Device:isPocketBook()) then
        logger:dbg("Sleep hold unavailable: not a PocketBook")
        return nil
    end

    local ok, lib = pcall(function()
        ffi.cdef("void hw_ban_suspend(int seconds); void iv_rise_keylock_timer(void);")
        local loaded = ffi.load("inkview")
        -- Index them now so a missing symbol fails here, not mid-sync.
        local _ = loaded.hw_ban_suspend
        _ = loaded.iv_rise_keylock_timer
        return loaded
    end)

    if ok then
        inkview = lib
    else
        logger:dbg("Sleep hold unavailable:", lib)
    end

    return inkview
end

local function renew()
    local self = GrimmorySleepHold
    if self.holders <= 0 then
        self.renewing = false
        return
    end

    -- After a lock, only renew while the new ban still ends within the cap.
    if self.suspended_at and os.time() - self.suspended_at + BAN_SECONDS > SUSPEND_CAP_SECONDS then
        logger:dbg("Sleep hold cap reached after suspend, letting the device sleep")
        self.renewing = false
        return
    end

    pcall(inkview.hw_ban_suspend, BAN_SECONDS)

    -- Only before a lock: once the user has locked, let it go through.
    if self.suspended_at == nil then
        pcall(inkview.iv_rise_keylock_timer)
    end
    UIManager:scheduleIn(RENEW_SECONDS, renew)
end

local function startRenewing()
    if GrimmorySleepHold.renewing or not getInkview() then
        return
    end
    GrimmorySleepHold.renewing = true
    renew()
end

--- Hold off firmware suspend while a job runs. Calls nest; pair each with stop().
function GrimmorySleepHold:start()
    self.holders = self.holders + 1
    if self.holders == 1 then
        logger:dbg("Sleep hold started")
    end
    startRenewing()
end

function GrimmorySleepHold:stop()
    if self.holders <= 0 then
        return
    end
    self.holders = self.holders - 1
    if self.holders == 0 and self.renewing then
        UIManager:unschedule(renew)
        self.renewing = false
        logger:dbg("Sleep hold stopped")
    end
end

--- The device has started suspending: start the cap countdown.
function GrimmorySleepHold:onSuspend()
    self.suspended_at = os.time()
end

function GrimmorySleepHold:onResume()
    self.suspended_at = nil
    if self.holders > 0 then
        startRenewing()
    end
end

return GrimmorySleepHold
