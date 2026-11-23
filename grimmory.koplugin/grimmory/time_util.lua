-- Conversions between Unix timestamps and the two text formats the plugin
-- handles: ISO 8601 from the Grimmory API, and KOReader's annotation
-- datetimes, which are local time with no zone ("2026-11-20 18:20:00").
local TimeUtil = {}

-- Days since 1970-01-01 for a proleptic Gregorian date, so UTC fields can be
-- turned into a timestamp without os.time, which assumes local time.
-- Algorithm: https://howardhinnant.github.io/date_algorithms.html#days_from_civil
local function days_from_civil(year, month, day)
    if month <= 2 then
        year = year - 1
    end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local shifted_month = (month + 9) % 12
    local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    return era * 146097 + day_of_era - 719468
end

function TimeUtil.utcFieldsToTimestamp(year, month, day, hour, min, sec)
    return days_from_civil(year, month, day) * 86400 + hour * 3600 + min * 60 + sec
end

---@param value string | nil e.g. 2026-11-20T18:20:00Z, 2026-11-20T19:20:00.123+01:00
---@return number | nil timestamp
function TimeUtil.fromISO8601(value)
    if type(value) ~= "string" then
        return nil
    end

    local year, month, day, hour, min, sec, rest = value:match(
        "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$"
    )
    if not year then
        return nil
    end

    rest = rest:gsub("^%.%d+", "")

    local offset_seconds = 0
    if rest ~= "" and rest ~= "Z" and rest ~= "z" then
        local sign, offset_hours, offset_minutes = rest:match("^([+-])(%d%d):?(%d?%d?)$")
        if not sign then
            return nil
        end
        offset_seconds = tonumber(offset_hours) * 3600 + (tonumber(offset_minutes) or 0) * 60
        if sign == "-" then
            offset_seconds = -offset_seconds
        end
    end

    -- No zone is read as UTC: Grimmory sends Instants, which are UTC.
    return TimeUtil.utcFieldsToTimestamp(
        tonumber(year), tonumber(month), tonumber(day),
        tonumber(hour), tonumber(min), tonumber(sec)
    ) - offset_seconds
end

---@param timestamp number | nil
---@return string | nil
function TimeUtil.toISO8601(timestamp)
    if timestamp == nil then
        return nil
    end

    return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
end

---@param value string | nil local time as KOReader writes it; a trailing Z means UTC
---@return number | nil timestamp
function TimeUtil.fromKOReaderDatetime(value)
    if type(value) ~= "string" then
        return nil
    end

    local year, month, day, hour, min, sec, zone = value:match(
        "^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)(Z?)$"
    )
    if not year then
        return nil
    end

    -- Older plugin versions wrote UTC with a Z suffix.
    if zone == "Z" then
        return TimeUtil.utcFieldsToTimestamp(
            tonumber(year), tonumber(month), tonumber(day),
            tonumber(hour), tonumber(min), tonumber(sec)
        )
    end

    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
        isdst = nil,
    })
end

---@param timestamp number | nil
---@return string | nil local time in KOReader's format
function TimeUtil.toKOReaderDatetime(timestamp)
    if timestamp == nil then
        return nil
    end

    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

return TimeUtil
