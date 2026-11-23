package.path = "grimmory.koplugin/?.lua;" .. package.path

local TimeUtil = require("grimmory/time_util")

-- Reference values from Python's calendar.timegm.
local NOV_20_2026_18_20_UTC = 1795198800
local FEB_29_2024_12_00_UTC = 1709208000
local JUL_1_2026_09_30_15_UTC = 1782898215

describe("TimeUtil ISO 8601", function()
    it("reads UTC with a Z", function()
        assert.are.equal(0, TimeUtil.fromISO8601("1970-01-01T00:00:00Z"))
        assert.are.equal(NOV_20_2026_18_20_UTC, TimeUtil.fromISO8601("2026-11-20T18:20:00Z"))
        assert.are.equal(FEB_29_2024_12_00_UTC, TimeUtil.fromISO8601("2024-02-29T12:00:00Z"))
    end)

    it("applies offsets in every common form", function()
        assert.are.equal(NOV_20_2026_18_20_UTC, TimeUtil.fromISO8601("2026-11-20T19:20:00+01:00"))
        assert.are.equal(NOV_20_2026_18_20_UTC, TimeUtil.fromISO8601("2026-11-20T13:50:00-0430"))
        assert.are.equal(NOV_20_2026_18_20_UTC, TimeUtil.fromISO8601("2026-11-20T23:50:00+05:30"))
        assert.are.equal(NOV_20_2026_18_20_UTC, TimeUtil.fromISO8601("2026-11-21T03:20:00+09"))
    end)

    it("ignores fractional seconds", function()
        assert.are.equal(JUL_1_2026_09_30_15_UTC, TimeUtil.fromISO8601("2026-07-01T09:30:15.22458634Z"))
        assert.are.equal(JUL_1_2026_09_30_15_UTC, TimeUtil.fromISO8601("2026-07-01T10:30:15.5+01:00"))
    end)

    it("reads a value without a zone as UTC", function()
        assert.are.equal(JUL_1_2026_09_30_15_UTC, TimeUtil.fromISO8601("2026-07-01T09:30:15"))
    end)

    it("rejects malformed values", function()
        assert.is_nil(TimeUtil.fromISO8601(nil))
        assert.is_nil(TimeUtil.fromISO8601("yesterday"))
        assert.is_nil(TimeUtil.fromISO8601("2026-07-01T09:30:15 nonsense"))
    end)

    it("writes UTC and round-trips", function()
        assert.are.equal("2026-11-20T18:20:00Z", TimeUtil.toISO8601(NOV_20_2026_18_20_UTC))
        assert.are.equal(
            JUL_1_2026_09_30_15_UTC,
            TimeUtil.fromISO8601(TimeUtil.toISO8601(JUL_1_2026_09_30_15_UTC))
        )
        assert.is_nil(TimeUtil.toISO8601(nil))
    end)
end)

describe("TimeUtil KOReader datetimes", function()
    it("writes local time without a zone, as KOReader does", function()
        assert.are.equal(
            os.date("%Y-%m-%d %H:%M:%S", NOV_20_2026_18_20_UTC),
            TimeUtil.toKOReaderDatetime(NOV_20_2026_18_20_UTC)
        )
    end)

    it("round-trips local time in winter and summer", function()
        for _, timestamp in ipairs({ NOV_20_2026_18_20_UTC, JUL_1_2026_09_30_15_UTC }) do
            assert.are.equal(timestamp, TimeUtil.fromKOReaderDatetime(TimeUtil.toKOReaderDatetime(timestamp)))
        end
    end)

    it("reads the UTC values older plugin versions wrote", function()
        assert.are.equal(NOV_20_2026_18_20_UTC, TimeUtil.fromKOReaderDatetime("2026-11-20 18:20:00Z"))
    end)

    it("rejects malformed values", function()
        assert.is_nil(TimeUtil.fromKOReaderDatetime(nil))
        assert.is_nil(TimeUtil.fromKOReaderDatetime("2026-11-20T18:20:00"))
    end)
end)
