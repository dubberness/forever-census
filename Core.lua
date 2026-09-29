local _, NS = ...
local Core = {}
NS.Core = Core

Core.columns = {"schema", "region", "client", "fullName", "observerRealm", "observerFaction", "level", "race", "class", "guild", "zone", "firstSeen", "lastSeen", "build"}
-- The WoW Forever beta stops at 30, so nothing above it is searched or charted. For a
-- full game this is the only line to change.
Core.MAX_LEVEL = 30

-- /who only returns your own faction, so observerFaction is normally right. Race is
-- checked first because it stays correct in a file merged from both factions.
Core.factionByRace = {
    Human = "Alliance", Dwarf = "Alliance", Gnome = "Alliance", ["Night Elf"] = "Alliance",
    Orc = "Horde", Troll = "Horde", Tauren = "Horde", Undead = "Horde", Scourge = "Horde", Forsaken = "Horde",
}

function Core.Faction(record)
    return Core.factionByRace[record.race] or record.observerFaction or "Unknown"
end

-- The name a chart groups a record under. A blank race or class is still somebody.
function Core.Group(value)
    return (value ~= nil and value ~= "") and value or "Unknown"
end

-- Token order follows ClassicEraCensus: race, class, then the level range, then the
-- name. A beta server seen honouring class and race while ignoring a leading level
-- range is reason enough to match the ordering an addon already in wide use sends.
function Core.Query(job)
    local query = ""
    if job.race then query = query .. 'r-"' .. job.race .. '" ' end
    if job.class then query = query .. 'c-"' .. job.class .. '" ' end
    query = query .. job.lo .. "-" .. job.hi
    if job.name then query = query .. ' n-"' .. job.name .. '"' end
    return query
end

-- The last axis available once level, race and class are all pinned down. Names are
-- only a partition where they are Latin, so a leaf split this way is still checked
-- against its parent total: whatever the letters fail to account for stays capped.
Core.nameLetters = {}
for letter = string.byte("a"), string.byte("z") do
    Core.nameLetters[#Core.nameLetters + 1] = string.char(letter)
end

-- The server returns at most this many rows however many characters actually match.
Core.PAGE = 50

-- Seconds between searches. ClassicEraCensus ships a four second default, so ten is
-- still cautious; the floor keeps a slider from ever asking the server faster than
-- an addon already in wide use does.
Core.INTERVAL, Core.MIN_INTERVAL, Core.MAX_INTERVAL = 10, 5, 60

function Core.Interval(settings)
    local value = tonumber(settings and settings.interval) or Core.INTERVAL
    return math.max(Core.MIN_INTERVAL, math.min(Core.MAX_INTERVAL, math.floor(value + 0.5)))
end

-- A capped leaf remains explicitly incomplete; we never pretend 50 is a total.
--
-- `total` is what the server said actually matched. Halving a band that holds 3000
-- characters just buys another capped reply six times over, so the band is cut into
-- roughly as many slices as it needs instead, and we land on a workable size in one
-- step. Without a total we fall back to halving.
function Core.Split(job, classes, races, total, capped)
    local children = {}
    if job.lo < job.hi then
        local levels = job.hi - job.lo + 1
        local slices = 2
        if total and total > Core.PAGE then
            slices = math.max(2, math.min(levels, math.ceil(total / Core.PAGE)))
        end
        local edge = job.lo - 1
        for i = 1, slices do
            local stop = job.lo - 1 + math.floor(levels * i / slices + 0.5)
            if stop > edge then
                children[#children + 1] = {lo = edge + 1, hi = math.min(stop, job.hi)}
                edge = stop
            end
        end
        if edge < job.hi then children[#children + 1] = {lo = edge + 1, hi = job.hi} end
        return children
    end
    -- A single level, still capped. Pick the axis that gets under the cap in the
    -- fewest replies. Only your own faction answers, so race offers about four useful
    -- buckets against nine for class: race when four will do, class when four will
    -- not but nine will, and when neither will do alone the coarser axis goes first
    -- so there are fewer intermediate replies before the leaves.
    local raceBuckets = races.effective or #races
    local raceFirst = not total or total <= raceBuckets * Core.PAGE or total > #classes * Core.PAGE
    if not job.race and (raceFirst or job.class) then
        for _, race in ipairs(races) do
            children[#children + 1] = {lo = job.lo, hi = job.hi, class = job.class, race = race}
        end
    elseif not job.class then
        for _, class in ipairs(classes) do
            children[#children + 1] = {lo = job.lo, hi = job.hi, class = class, race = job.race}
        end
    elseif not job.name and ((total and (total - Core.PAGE) >= #Core.nameLetters)
        or (capped and not total)) then
        -- Twenty-six replies to recover five stragglers is not worth the wait, so with
        -- a real total the alphabet only opens when it averages a character a search.
        -- With no total to go on, a reply that filled the page is all we know: there
        -- are more characters here and this is the last way to reach them, so open it
        -- rather than write the leaf off as incomplete.
        for _, letter in ipairs(Core.nameLetters) do
            children[#children + 1] = {lo = job.lo, hi = job.hi, class = job.class, race = job.race, name = letter}
        end
    end
    return children
end

-- The order searches are queued in, highest levels first. A pass takes days, and a
-- character is only a sighting while it holds still: searching upwards chased players
-- up the levels they were climbing and caught the ones parked at level 1, while
-- searching down meets each of them once, coming the other way. `top` is the highest
-- level anyone has been seen at. Bands wholly above it go last, lowest first, so a
-- server reporting real totals can still retire them unsearched once everything below
-- has accounted for the parent. Jobs at one level keep their order.
local function highRank(job, top)
    if job.lo <= top then return 0, -job.hi end
    return 1, job.lo
end

function Core.HighFirst(jobs, top)
    top = tonumber(top) or 0
    local ranked = {}
    for i, job in ipairs(jobs) do
        local band, level = highRank(job, top)
        ranked[i] = {job = job, band = band, level = level, index = i}
    end
    table.sort(ranked, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.level ~= b.level then return a.level < b.level end
        return a.index < b.index
    end)
    for i, entry in ipairs(ranked) do jobs[i] = entry.job end
    return jobs
end

-- How far a job has been taken apart: a level band, then race or class, then both,
-- then a name. The queue is kept breadth-first by this depth, and highest level first
-- within each. Queuing children behind whatever was already waiting was breadth-first
-- by number of halvings instead, and a level that took one fewer to reach (15, on a
-- 1-30 range) was taken apart a whole depth before its neighbours; its alphabet sweep
-- finished days early and it stood out on the level chart.
function Core.Depth(job)
    if job.name then return 3 end
    if job.race and job.class then return 2 end
    if job.race or job.class then return 1 end
    return 0
end

function Core.Reorder(jobs, top)
    local depths = {}
    for _, job in ipairs(jobs) do
        local depth = Core.Depth(job)
        depths[depth] = depths[depth] or {}
        depths[depth][#depths[depth] + 1] = job
    end
    local ordered = {}
    for depth = 0, 3 do
        for _, job in ipairs(Core.HighFirst(depths[depth] or {}, top)) do ordered[#ordered + 1] = job end
    end
    return ordered
end

-- Queue new jobs into an ordered queue, each behind any already waiting in the same
-- place. Re-sorting a queue of five thousand after every reply took about 9 ms, a hitch
-- every few seconds; finding each child's place takes a dozen comparisons.
local function jobKey(job, top)
    local band, level = highRank(job, top)
    return Core.Depth(job), band, level
end

function Core.Enqueue(queue, jobs, top)
    top = tonumber(top) or 0
    for _, job in ipairs(jobs) do
        local depth, band, level = jobKey(job, top)
        local first, last = 1, #queue + 1
        while first < last do
            local middle = math.floor((first + last) / 2)
            local d, b, l = jobKey(queue[middle], top)
            if depth < d or (depth == d and (band < b or (band == b and level < l))) then
                last = middle
            else
                first = middle + 1
            end
        end
        table.insert(queue, first, job)
    end
    return queue
end

-- A pass on a busy realm outlasts a session, so the searches still to do are written
-- out at logout. Only what a search needs is kept; anything read back is checked as
-- carefully as data from outside, since a hand-edited file could hold anything.
function Core.PackJob(job)
    return {lo = job.lo, hi = job.hi, class = job.class, race = job.race, name = job.name, retries = job.retries}
end

local function jobText(value)
    if value == nil then return true, nil end
    if type(value) ~= "string" or value == "" or #value > 64 or value:find('["%c]') then return false end
    return true, value
end

function Core.UnpackJob(raw)
    if type(raw) ~= "table" then return nil end
    local lo, hi = tonumber(raw.lo), tonumber(raw.hi)
    if not lo or not hi or lo ~= math.floor(lo) or hi ~= math.floor(hi) then return nil end
    -- A pass saved when the range went higher keeps whatever part is still in range.
    if lo > Core.MAX_LEVEL then return nil end
    hi = math.min(hi, Core.MAX_LEVEL)
    if lo < 1 or lo > hi then return nil end
    local job = {lo = lo, hi = hi, retries = tonumber(raw.retries)}
    for _, key in ipairs({"class", "race", "name"}) do
        local ok, value = jobText(raw[key])
        if not ok then return nil end
        job[key] = value
    end
    return job
end

function Core.Matches(job, info)
    return type(info.level) == "number" and info.level >= job.lo and info.level <= job.hi
        and (not job.class or info.classStr == job.class)
        and (not job.race or info.raceStr == job.race)
end

-- How much of a reply honoured each filter we asked for.
function Core.Fit(job, rows)
    local fit = {level = 0, class = 0, race = 0, total = #rows}
    for _, row in ipairs(rows) do
        if type(row.level) == "number" and row.level >= job.lo and row.level <= job.hi then
            fit.level = fit.level + 1
        end
        if not job.class or row.classStr == job.class then fit.class = fit.class + 1 end
        if not job.race or row.raceStr == job.race then fit.race = fit.race + 1 end
    end
    return fit
end

-- A reply is thrown away only when the filters that identify it as ours fail. Class
-- and race do that, and are checked. The level range is not checked on a search that
-- also named a class or race: a server that answers `r-"Tauren" c-"Warrior" 1-1` with
-- Tauren warriors of every level has still handed back real Tauren warriors, each
-- carrying its own level, and discarding them loses good data and 60 seconds with it.
-- On a search where the level range is the only thing we asked for, it must hold.
function Core.Plausible(job, fit)
    if fit.total == 0 then return true end
    if job.class and fit.class * 2 < fit.total then
        return false, string.format("%d of %d rows were not the class asked for", fit.total - fit.class, fit.total)
    end
    if job.race and fit.race * 2 < fit.total then
        return false, string.format("%d of %d rows were not the race asked for", fit.total - fit.race, fit.total)
    end
    if not job.class and not job.race and fit.level * 2 < fit.total then
        return false, string.format("%d of %d rows were outside the level range", fit.total - fit.level, fit.total)
    end
    return true
end

-- What the server did with each filter, accumulated across the session. Turns "the
-- scope of Forever's /who needs verification" into a number that can be read off.
function Core.Observe(filters, job, fit)
    local function count(key, asked)
        if not asked then return end
        local bucket = filters[key] or {asked = 0, honoured = 0}
        bucket.asked = bucket.asked + fit.total
        bucket.honoured = bucket.honoured + fit[key]
        filters[key] = bucket
    end
    count("level", true)
    count("class", job.class ~= nil)
    count("race", job.race ~= nil)
end

function Core.FilterReport(filters)
    local parts = {}
    for _, key in ipairs({"level", "class", "race"}) do
        local bucket = filters[key]
        if bucket and bucket.asked > 0 then
            parts[#parts + 1] = string.format("%s %.0f%%", key, bucket.honoured * 100 / bucket.asked)
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "nothing measured yet"
end

function Core.Record(records, info, context, now)
    if type(info.fullName) ~= "string" or info.fullName == "" then return false end
    local fullName = info.fullName
    if not fullName:find("-", 1, true) then
        fullName = fullName .. "-" .. context.realm:gsub("%s", "")
    end
    local key = context.region .. "|" .. context.client .. "|" .. fullName:lower()
    local old = records[key]
    records[key] = {
        schema = 1, region = context.region, client = context.client, fullName = fullName,
        observerRealm = context.realm, observerFaction = context.faction,
        level = info.level, race = info.raceStr or "", class = info.classStr or "",
        guild = info.fullGuildName or "", zone = info.area or "",
        firstSeen = old and math.min(old.firstSeen, now) or now,
        lastSeen = now, build = context.build,
    }
    return not old, key
end

local function csvCell(value)
    local s = tostring(value or "")
    -- Prevent formula evaluation if opened in spreadsheet software.
    if s:match("^[=+@-]") then s = "'" .. s end
    return '"' .. s:gsub('"', '""') .. '"'
end

function Core.Export(records, page, size)
    local keys = {}
    for key in pairs(records) do keys[#keys + 1] = key end
    table.sort(keys)
    size = size or 500
    local pages = math.max(1, math.ceil(#keys / size))
    page = math.max(1, math.min(pages, page or 1))
    local lines = {table.concat(Core.columns, ",")}
    for i = (page - 1) * size + 1, math.min(page * size, #keys) do
        local values = {}
        for _, column in ipairs(Core.columns) do
            values[#values + 1] = csvCell(records[keys[i]][column])
        end
        lines[#lines + 1] = table.concat(values, ",")
    end
    return table.concat(lines, "\n"), page, pages, #keys
end

-- Sync wire format. One record per addon message, tab separated because no character,
-- guild, realm or zone name may contain a tab. Addon messages cap at 255 bytes.
-- Version 2 adds, after the version, the point up to which we already hold the other
-- side's data, so only what changed since is sent. Version 1 peers ignore the extra
-- field and are simply sent everything, as before. Version 3 (0.7.1) adds partner keys
-- and checkpoints; version 4 (0.8.0) packs several characters to a message (Sync.lua).
Core.SYNC_VERSION = 4
Core.MAX_MESSAGE = 240
-- The longest any one field may be. The real limit is the whole line fitting a single
-- addon message; this only turns nonsense away early. It used to be 64 bytes, but a
-- Korean name runs three bytes a letter, and real names of 62 bytes and guilds of 60
-- are already in the wild.
Core.MAX_FIELD = 128
local SEP = "\t"
Core.syncFields = {"region", "client", "fullName", "observerRealm", "observerFaction",
    "level", "race", "class", "guild", "zone", "firstSeen", "lastSeen", "build"}

local function clean(value, limit)
    local s = tostring(value or "")
    if s:find("[%z\1-\31]") then return nil end
    if #s > limit then return nil end
    return s
end

function Core.Encode(record)
    local values = {}
    for i, field in ipairs(Core.syncFields) do
        local value = clean(record[field], Core.MAX_FIELD)
        if not value then return nil end
        values[i] = value
    end
    local line = table.concat(values, SEP)
    if #line > Core.MAX_MESSAGE then return nil end
    return line
end

-- Everything arriving from outside this client is untrusted, whether it came over the
-- addon channel or was pasted in as CSV. A field that fails its check rejects the whole
-- row rather than letting it land half-formed in the database.
--
-- Names may contain spaces: WoW Forever gives characters a first and a last name, so
-- "Bob Thornwood-ClassicBetaPvP" is an ordinary name and only the realm separator is
-- structural. Character names cannot contain a hyphen, so the last one still marks the
-- realm reliably.
function Core.Adopt(raw)
    if type(raw) ~= "table" then return nil end
    local record = {schema = 1}
    for _, field in ipairs(Core.syncFields) do
        local value = clean(raw[field], Core.MAX_FIELD)
        if not value then return nil end
        record[field] = value
    end
    record.level = tonumber(record.level)
    record.firstSeen = tonumber(record.firstSeen)
    record.lastSeen = tonumber(record.lastSeen)
    if not record.level or record.level < 1 or record.level > 255 then return nil end
    if record.level ~= math.floor(record.level) then return nil end
    if not record.firstSeen or not record.lastSeen then return nil end
    if record.firstSeen <= 0 or record.lastSeen <= 0 or record.firstSeen > record.lastSeen then return nil end
    if record.fullName == "" or record.region == "" or record.client == "" then return nil end
    if not record.fullName:find("-", 1, true) then return nil end
    return record
end

function Core.Decode(line)
    if type(line) ~= "string" or #line > Core.MAX_MESSAGE then return nil end
    local values = {}
    for value in (line .. SEP):gmatch("([^" .. SEP .. "]*)" .. SEP) do
        values[#values + 1] = value
    end
    if #values ~= #Core.syncFields then return nil end
    local raw = {}
    for i, field in ipairs(Core.syncFields) do raw[field] = values[i] end
    return Core.Adopt(raw)
end

-- A CSV reader that handles what Core.Export writes: quoted fields, doubled quotes,
-- commas and newlines inside them, and CRLF from a round trip through a spreadsheet.
function Core.ParseCSV(text)
    if type(text) ~= "string" then return {} end
    local rows, row, field = {}, {}, {}
    local quoted, i, n = false, 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if quoted then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    quoted = false
                end
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            quoted = true
        elseif c == "," then
            row[#row + 1] = table.concat(field)
            field = {}
        elseif c == "\n" then
            row[#row + 1] = table.concat(field)
            field = {}
            rows[#rows + 1] = row
            row = {}
        elseif c ~= "\r" then
            field[#field + 1] = c
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then
        row[#row + 1] = table.concat(field)
        rows[#rows + 1] = row
    end
    return rows
end

-- The exact inverse of the guard csvCell puts on a cell a spreadsheet would evaluate.
local function unguard(value)
    if value:sub(1, 1) == "'" and value:sub(2, 2):match("^[=+@-]") then return value:sub(2) end
    return value
end

-- Read a CSV page, from this addon's own export or from the offline viewer. Columns are
-- located by their headings, so a file whose columns were reordered still reads.
-- `absorbed`, when given, hears the key of every character that was added or changed;
-- `now` stamps them as changed here, so the next sync passes them on.
function Core.ImportCSV(text, records, absorbed, now)
    local result = {rows = 0, new = 0, updated = 0, unchanged = 0, rejected = 0}
    local rows = Core.ParseCSV(text)
    if #rows == 0 then return result, "There is nothing pasted in the box" end
    local index = {}
    for position, heading in ipairs(rows[1]) do index[heading] = position end
    for _, required in ipairs({"region", "client", "fullName", "level", "firstSeen", "lastSeen"}) do
        if not index[required] then
            return result, "This does not look like a Forever Census export: no '" .. required .. "' column"
        end
    end
    for r = 2, #rows do
        local row = rows[r]
        if #row > 1 then
            result.rows = result.rows + 1
            local raw = {}
            for _, field in ipairs(Core.syncFields) do
                local position = index[field]
                raw[field] = position and unguard(row[position] or "") or ""
            end
            local record = Core.Adopt(raw)
            if not record then
                result.rejected = result.rejected + 1
            else
                local outcome, key = Core.Absorb(records, record, now)
                if outcome == "new" then result.new = result.new + 1
                elseif outcome == "updated" then result.updated = result.updated + 1
                else result.unchanged = result.unchanged + 1 end
                if outcome and absorbed then absorbed(key) end
            end
        end
    end
    return result
end

-- Same merge rule as the offline viewer: newest sighting wins the details, earliest
-- sighting is kept, so importing the same data twice changes nothing.
--
-- A record taken in from outside is stamped with when it changed here (`stored`) and,
-- for sync, whose it was (`via`), so an incremental sync can pass it on to anyone else
-- without sending it straight back where it came from. A sighting of our own replaces
-- the whole record, and with it both marks; its lastSeen is then when it changed.
function Core.Absorb(records, incoming, now, via)
    local key = incoming.region .. "|" .. incoming.client .. "|" .. incoming.fullName:lower()
    local old = records[key]
    incoming.stored, incoming.via = now, via
    if not old then
        records[key] = incoming
        return "new", key
    end
    if incoming.lastSeen > old.lastSeen then
        incoming.firstSeen = math.min(old.firstSeen, incoming.firstSeen)
        records[key] = incoming
        return "updated", key
    end
    -- Only the earliest sighting can move. That alone is not stamped as a change: the
    -- sender already has it, and stamping it would send the record straight back.
    old.firstSeen = math.min(old.firstSeen, incoming.firstSeen)
    return nil, key
end

-- When a record last changed in this database.
function Core.ChangedAt(record)
    return math.max(tonumber(record.lastSeen) or 0, tonumber(record.stored) or 0)
end

local function passes(record, filters)
    if filters.minLevel and record.level < filters.minLevel then return false end
    if filters.maxLevel and record.level > filters.maxLevel then return false end
    if filters.faction and filters.faction ~= Core.Faction(record) then return false end
    if filters.realm and filters.realm ~= record.observerRealm then return false end
    if filters.seenSince and (tonumber(record.lastSeen) or 0) < filters.seenSince then return false end
    if filters.search ~= "" then
        local haystack = table.concat({record.fullName, record.class, record.race, record.guild, record.zone, record.region}, " "):lower()
        if not haystack:find(filters.search, 1, true) then return false end
    end
    return true
end

function Core.View(records, filters, sortKey)
    if type(filters) ~= "table" then filters = {search = filters} end
    filters = {search = (filters.search or ""):lower(), minLevel = filters.minLevel,
        maxLevel = filters.maxLevel, faction = filters.faction, realm = filters.realm,
        seenSince = tonumber(filters.seenSince)}
    local rows, total = {}, 0
    for _, record in pairs(records) do
        total = total + 1
        if passes(record, filters) then rows[#rows + 1] = record end
    end
    -- Sorting is half the cost of a view on a big realm, and only a list needs it:
    -- sortKey false leaves the rows in no particular order, for charts and counts.
    if sortKey ~= false then
        table.sort(rows, function(a, b)
            if sortKey == "level" and a.level ~= b.level then return a.level > b.level end
            if sortKey == "lastSeen" and a.lastSeen ~= b.lastSeen then return a.lastSeen > b.lastSeen end
            if a.fullName ~= b.fullName then return a.fullName < b.fullName end
            return a.region < b.region
        end)
    end
    return rows, total, Core.Summarize(rows)
end

-- Every realm that collected any of the stored characters, for the realm filter.
function Core.Realms(records)
    local names, seen = {}, {}
    for _, record in pairs(records) do
        local realm = record.observerRealm
        if type(realm) == "string" and realm ~= "" and not seen[realm] then
            seen[realm] = true
            names[#names + 1] = realm
        end
    end
    table.sort(names)
    return names
end

-- The characters of one class, one race, one guild, or any mix of them, out of an
-- already filtered view. This is all the chart breakdown needs: it reads what is
-- stored and searches nothing.
function Core.Subset(rows, class, race, guild)
    if not class and not race and not guild then return rows end
    local picked = {}
    for _, r in ipairs(rows) do
        if (not class or Core.Group(r.class) == class) and (not race or Core.Group(r.race) == race)
            and (not guild or r.guild == guild) then
            picked[#picked + 1] = r
        end
    end
    return picked
end

Core.DAY = 86400

-- Characters by the day they were first seen, for the last `days` days up to `now`,
-- oldest first. Days are local calendar days. Each step back is taken from local noon,
-- so a daylight-saving change can never skip a date or count one twice.
function Core.NewPerDay(rows, days, now)
    local clock = date("*t", now)
    local noon = now - ((clock.hour * 60 + clock.min) * 60 + clock.sec) + 12 * 3600
    local entries, index = {}, {}
    for i = days - 1, 0, -1 do
        local stamp = noon - i * Core.DAY
        local key = date("%Y-%m-%d", stamp)
        entries[#entries + 1] = {key = key, stamp = stamp, count = 0}
        index[key] = entries[#entries]
    end
    local before, earliest = 0, nil
    local first = entries[1].key
    for _, r in ipairs(rows) do
        local seen = tonumber(r.firstSeen)
        if seen then
            if not earliest or seen < earliest then earliest = seen end
            local entry = index[date("%Y-%m-%d", seen)]
            if entry then entry.count = entry.count + 1
            elseif date("%Y-%m-%d", seen) < first then before = before + 1 end
        end
    end
    -- How many had been seen by the end of each day, counting everything earlier.
    local running = before
    for _, entry in ipairs(entries) do
        running = running + entry.count
        entry.total = running
    end
    return entries, earliest
end

-- What one census pass saw, kept with the pass so later passes can be compared with
-- it: how many of each class and race, and their levels. A few numbers per pass, so
-- a hundred passes add only a few kilobytes to the saved file.
function Core.Mix(records, keys)
    local mix = {n = 0, classes = {}, races = {}, levels = 0, atCap = 0}
    for key in pairs(keys) do
        local r = records[key]
        if r then
            local class, race = Core.Group(r.class), Core.Group(r.race)
            mix.n = mix.n + 1
            mix.classes[class] = (mix.classes[class] or 0) + 1
            mix.races[race] = (mix.races[race] or 0) + 1
            mix.levels = mix.levels + (tonumber(r.level) or 0)
            if r.level == Core.MAX_LEVEL then mix.atCap = mix.atCap + 1 end
        end
    end
    return mix
end

-- One pass over the filtered rows produces everything the charts and lists draw.
function Core.Summarize(rows)
    local summary = {classes = {}, races = {}, levels = {}, byLevel = {}, factions = {},
        guilds = {}, guildNames = {}, zones = {}, totalLevel = 0, maxLevel = 0, guildless = 0,
        peakClass = 0, peakRace = 0, peakLevel = 0, shown = #rows}
    for level = 1, Core.MAX_LEVEL do summary.byLevel[level] = 0 end
    for _, r in ipairs(rows) do
        local class = Core.Group(r.class)
        local race = Core.Group(r.race)
        summary.classes[class] = (summary.classes[class] or 0) + 1
        summary.races[race] = (summary.races[race] or 0) + 1
        if summary.classes[class] > summary.peakClass then summary.peakClass = summary.classes[class] end
        if summary.races[race] > summary.peakRace then summary.peakRace = summary.races[race] end
        local faction = Core.Faction(r)
        summary.factions[faction] = (summary.factions[faction] or 0) + 1
        if r.zone ~= "" then summary.zones[r.zone] = (summary.zones[r.zone] or 0) + 1 end
        local bucket = math.floor((r.level - 1) / 10) * 10 + 1
        summary.levels[bucket] = (summary.levels[bucket] or 0) + 1
        if summary.byLevel[r.level] then
            summary.byLevel[r.level] = summary.byLevel[r.level] + 1
            if summary.byLevel[r.level] > summary.peakLevel then summary.peakLevel = summary.byLevel[r.level] end
        end
        summary.totalLevel = summary.totalLevel + r.level
        if r.level == Core.MAX_LEVEL then summary.maxLevel = summary.maxLevel + 1 end
        if r.guild ~= "" then
            local guild = summary.guilds[r.guild]
            if not guild then
                guild = {name = r.guild, members = 0, totalLevel = 0, maxLevel = 0}
                summary.guilds[r.guild] = guild
                summary.guildNames[#summary.guildNames + 1] = r.guild
            end
            guild.members = guild.members + 1
            guild.totalLevel = guild.totalLevel + r.level
            if r.level == Core.MAX_LEVEL then guild.maxLevel = guild.maxLevel + 1 end
        else
            summary.guildless = summary.guildless + 1
        end
    end
    return summary
end

-- Largest guild first; ties resolved by name so the list never reshuffles itself.
function Core.GuildList(summary)
    local list = {}
    for _, name in ipairs(summary.guildNames) do list[#list + 1] = summary.guilds[name] end
    table.sort(list, function(a, b)
        if a.members ~= b.members then return a.members > b.members end
        return a.name < b.name
    end)
    return list
end

-- The groups a chart draws, in order: every known one, then any the data holds that
-- the client does not know, alphabetically. Given the selection's factions, a race of
-- a faction with nobody in the selection is left out: on a server whose /who only
-- ever answers for one faction, the other's four races are a permanent row of zeros,
-- not a gap in the data.
function Core.ChartKeys(order, counts, factions)
    local keys, seen = {}, {}
    local anyFaction = false
    for _, count in pairs(factions or {}) do
        if count > 0 then anyFaction = true end
    end
    for _, key in ipairs(order or {}) do
        local faction = Core.factionByRace[key]
        local present = not anyFaction or not faction or (factions[faction] or 0) > 0
        if present and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    local extra = {}
    for key in pairs(counts) do
        if not seen[key] then extra[#extra + 1] = key end
    end
    table.sort(extra)
    for _, key in ipairs(extra) do keys[#keys + 1] = key end
    return keys
end

-- Ordered counts for a bar chart: every known key appears, even at zero, so a gap in
-- the data stays visible instead of the chart silently closing up around it.
function Core.Distribution(counts, order, shown)
    local entries, seen = {}, {}
    for _, key in ipairs(order or {}) do
        if not seen[key] then
            seen[key] = true
            entries[#entries + 1] = {key = key, count = counts[key] or 0}
        end
    end
    local extra = {}
    for key in pairs(counts) do
        if not seen[key] then extra[#extra + 1] = key end
    end
    table.sort(extra)
    for _, key in ipairs(extra) do entries[#entries + 1] = {key = key, count = counts[key]} end
    for _, entry in ipairs(entries) do
        entry.percent = shown > 0 and entry.count * 100 / shown or 0
    end
    return entries
end
