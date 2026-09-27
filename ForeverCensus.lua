local addonName, NS = ...
local Core = NS.Core
local API = C_FriendList
local frame = CreateFrame("Frame")
local db, context, dataPanel
local queue, pending, scan = {}, nil, nil
local nextSend, nextScan, externalUntil, sending = 0, 0, 0, false
local suppressed, routeBefore, routeKnown = {}, nil, false
local suppressionGeneration, lastListeners = 0, "None yet"
local lastMessage = "Waiting for login"
local TIMEOUT, REPEAT_DELAY = 30, 900
local supported, stoppedByError = false, false
local windowHooked = false
-- What a crowded search can be split by; see prepareSplits and learn below.
local classes, races = {}, {}
local ownRaces, otherRaces, knownRaces, knownClasses, learnedRaces = {}, {}, {}, {}, {}
local crossFaction = false
-- About this session only, so none of it is saved: how much was on disk at login, how
-- much the last save lost, and which characters have been added or changed since.
local loadedCount, lostCount = 0, nil
local touched, touchedCount = {}, 0

local function say(message)
    print("|cff64d9c5Forever Census:|r " .. message)
end

local function countRecords()
    local n = 0
    for _ in pairs(db.records) do n = n + 1 end
    return n
end

local function touch(key)
    if key and not touched[key] then
        touched[key] = true
        touchedCount = touchedCount + 1
    end
end

-- New characters, and known ones seen again or updated, since the file was loaded.
local function sinceLogin()
    local new = math.max(0, countRecords() - loadedCount)
    return new, math.max(0, touchedCount - new)
end

local function suppressWhoWindow()
    local listeners = GetFramesRegisteredForEvent and {GetFramesRegisteredForEvent("WHO_LIST_UPDATE")} or {FriendsFrame}
    local names = {}
    for _, target in ipairs(listeners) do
        if target ~= frame and target:IsEventRegistered("WHO_LIST_UPDATE") then
            target:UnregisterEvent("WHO_LIST_UPDATE")
            suppressed[target] = true
        end
    end
    for target in pairs(suppressed) do names[#names + 1] = target:GetName() or "anonymous listener" end
    table.sort(names)
    lastListeners = #names > 0 and table.concat(names, ", ") or "None"
end

local function restoreWhoWindow(deferred)
    if deferred then
        local generation = suppressionGeneration
        C_Timer.After(0, function()
            if generation == suppressionGeneration then restoreWhoWindow() end
        end)
        return
    end
    suppressionGeneration = suppressionGeneration + 1
    for target in pairs(suppressed) do target:RegisterEvent("WHO_LIST_UPDATE") end
    suppressed = {}
    if routeBefore ~= nil then
        local value = routeBefore
        routeBefore = nil
        API.SetWhoToUi(value)
    end
end

-- The races a crowded level is split by: our own faction's first, then any race a
-- reply has shown us that the client does not list (WoW Forever's Windshaper
-- Skyborne), then the other faction's, but only on a server whose /who has ever
-- answered with the other faction. Forever's never has, and asking it about four
-- races that cannot answer cost four searches at every crowded level.
local function rebuildRaces()
    local list = {}
    for _, name in ipairs(ownRaces) do list[#list + 1] = name end
    list.effective = math.max(1, #list)
    if crossFaction then
        for _, name in ipairs(otherRaces) do list[#list + 1] = name end
    end
    races = list
end

-- The client only names the standard races and classes. Anything else a reply has
-- shown us is learned from the data; otherwise its characters could only ever be
-- reached through the first fifty rows of a crowded level.
local function learn(race, class)
    if type(class) == "string" and class ~= "" and #class <= 48 and not class:find('["%c]')
        and not knownClasses[class] then
        knownClasses[class] = true
        classes[#classes + 1] = class
    end
    if type(race) ~= "string" or race == "" or #race > 48 or race:find('["%c]') then return end
    local faction = Core.factionByRace[race]
    if faction then
        if faction ~= context.faction and not crossFaction then
            crossFaction = true
            rebuildRaces()
        end
    elseif not knownRaces[race] then
        knownRaces[race] = true
        learnedRaces[race] = true
        ownRaces[#ownRaces + 1] = race
        rebuildRaces()
    end
end

-- A learned race may not be something this server can search by. If it answers with
-- everyone instead, asking again cannot help: stop asking, and its characters are
-- still reached through level and class searches.
local function dropRace(race)
    learnedRaces[race] = nil
    for i = #ownRaces, 1, -1 do
        if ownRaces[i] == race then table.remove(ownRaces, i) end
    end
    rebuildRaces()
    local kept = {}
    for _, job in ipairs(queue) do
        if job.race ~= race then kept[#kept + 1] = job end
    end
    queue = kept
end

local function prepareSplits()
    classes, ownRaces, otherRaces, knownRaces, knownClasses, learnedRaces = {}, {}, {}, {}, {}, {}
    for _, id in ipairs({1, 2, 3, 4, 5, 7, 8, 9, 11}) do
        local info = C_CreatureInfo and C_CreatureInfo.GetClassInfo(id)
        if info and info.className and not knownClasses[info.className] then
            knownClasses[info.className] = true
            classes[#classes + 1] = info.className
        end
    end
    for _, id in ipairs({1, 2, 3, 4, 5, 6, 7, 8}) do
        local info = C_CreatureInfo and C_CreatureInfo.GetRaceInfo(id)
        if info and info.raceName and not knownRaces[info.raceName] then
            knownRaces[info.raceName] = true
            if Core.factionByRace[info.raceName] == context.faction then
                ownRaces[#ownRaces + 1] = info.raceName
            else
                otherRaces[#otherRaces + 1] = info.raceName
            end
        end
    end
    -- With none of our own faction's races recognised (a client in another language,
    -- or no faction yet) there is no telling which can answer, so every one is asked.
    crossFaction = #ownRaces == 0
    rebuildRaces()
    -- Whatever earlier sessions saw through this faction's /who, in a stable order.
    local seenRaces, seenClasses = {}, {}
    for _, record in pairs(db.records) do
        if record.observerFaction == context.faction and record.client == context.client then
            seenRaces[record.race or ""] = true
            seenClasses[record.class or ""] = true
        end
    end
    local function sorted(set)
        local list = {}
        for name in pairs(set) do list[#list + 1] = name end
        table.sort(list)
        return list
    end
    for _, class in ipairs(sorted(seenClasses)) do learn(nil, class) end
    for _, race in ipairs(sorted(seenRaces)) do learn(race, nil) end
end

local function finishScan()
    if not scan then return end
    scan.finished = GetServerTime()
    scan.unique = 0
    for _ in pairs(scan.seen) do scan.unique = scan.unique + 1 end
    -- The list of who was seen is too big to keep, but what they add up to is not:
    -- the Trends tab compares passes with it.
    scan.mix = Core.Mix(db.records, scan.seen)
    scan.seen = nil
    db.scans[#db.scans + 1] = scan
    if #db.scans > 100 then table.remove(db.scans, 1) end
    lastMessage = string.format("Pass finished: %d observed in %d searches, %d capped groups, %d failed%s",
        scan.unique, scan.queries, scan.capped, scan.failed,
        (scan.pruned or 0) > 0 and string.format(", %d searches skipped as provably empty", scan.pruned) or "")
    scan = nil
    nextScan = GetTime() + REPEAT_DELAY
end

local function startScan()
    queue = {{lo = 1, hi = Core.MAX_LEVEL}}
    scan = {started = GetServerTime(), queries = 0, capped = 0, failed = 0, seen = {}, sessions = 1,
        realm = context.realm, faction = context.faction, region = context.region, build = context.build}
    lastMessage = "Waiting for a world click (outside combat)"
end

-- A pass on a busy realm takes more searches than one session gives it. Restarting at
-- level 1 after every reload meant the crowded low levels were searched over and over
-- while everything above them waited, so what is left to do is written out at logout
-- and picked up at the next login on the same realm and faction.
local function passKey()
    return context.region .. "|" .. context.realm .. "|" .. context.faction
end

local function storePass()
    if not supported or not context then return end
    local store = type(db.resume) == "table" and db.resume or {}
    local key = passKey()
    store[key] = nil
    if scan then
        local jobs = {}
        -- A search sent but not yet answered is simply asked again next time.
        if pending then jobs[#jobs + 1] = Core.PackJob(pending.job) end
        for _, job in ipairs(queue) do
            if not (job.group and job.group.remaining <= 0) then jobs[#jobs + 1] = Core.PackJob(job) end
        end
        local saved = {}
        for field, value in pairs(scan) do saved[field] = value end
        saved.consecutiveTimeouts = nil
        store[key] = {scan = saved, queue = jobs}
    end
    db.resume = next(store) and store or nil
end

local function restorePass()
    local store = db.resume
    local saved = type(store) == "table" and store[passKey()] or nil
    if not saved then return end
    store[passKey()] = nil
    if next(store) == nil then db.resume = nil end
    if type(saved) ~= "table" or type(saved.scan) ~= "table" or not tonumber(saved.scan.started) then return end
    local jobs = {}
    for _, raw in ipairs(type(saved.queue) == "table" and saved.queue or {}) do
        local job = Core.UnpackJob(raw)
        if job then jobs[#jobs + 1] = job end
    end
    scan = saved.scan
    for _, field in ipairs({"queries", "capped", "failed"}) do scan[field] = tonumber(scan[field]) or 0 end
    scan.seen = type(scan.seen) == "table" and scan.seen or {}
    scan.sessions = (tonumber(scan.sessions) or 1) + 1
    queue = jobs
    if #queue == 0 then
        finishScan()
        return
    end
    lastMessage = string.format("Carrying on from last session: %d searches left in this pass", #queue)
end

local function retryPending(reason, deferred)
    if not pending then return end
    local job = pending.job
    pending = nil
    job.retries = (job.retries or 0) + 1
    if job.retries <= 2 then
        table.insert(queue, 1, job)
    elseif scan then
        scan.failed = scan.failed + 1
    end
    nextSend = GetTime() + 60
    lastMessage = reason
    restoreWhoWindow(deferred)
end

local function failClosed(message, deferred)
    retryPending(message, deferred)
    db.settings.enabled = false
    stoppedByError = true
    lastMessage = message
    -- One actionable message, rather than repeated blocked calls while playing.
    say(message .. ". Collection paused; /fc opens the controls.")
end

local function socialWindowOpen()
    return (FriendsFrame and FriendsFrame:IsShown()) or (WhoFrame and WhoFrame:IsShown())
end

local function sendNext(manual)
    if not db or not supported or not db.settings.enabled or stoppedByError then return end
    if pending or InCombatLockdown() or socialWindowOpen() then return end
    local now = GetTime()
    if now < nextSend or now < externalUntil then return end
    if not scan then
        if now < nextScan and not manual then return end
        startScan()
    end
    if #queue == 0 then finishScan(); return end
    local job = table.remove(queue, 1)
    -- Siblings of a parent that is already fully accounted for cannot hold anyone.
    while job and job.group and job.group.remaining <= 0 do
        if scan then scan.pruned = (scan.pruned or 0) + 1 end
        job = table.remove(queue, 1)
    end
    if not job then finishScan(); return end
    pending = {job = job, sent = now}
    suppressionGeneration = suppressionGeneration + 1
    routeBefore = routeKnown
    suppressWhoWindow()
    API.SetWhoToUi(true)
    nextSend = now + Core.Interval(db.settings)
    sending = true
    -- This function is ONLY called directly from a genuine click or slash command.
    -- No timer dispatches queries and no protected-function workaround is used.
    local ok, err = pcall(API.SendWho, Core.Query(job))
    sending = false
    if not ok then
        failClosed("Who request rejected: " .. tostring(err))
    elseif pending then
        lastMessage = "Waiting for /who " .. Core.Query(job)
    end
end

local function plain(value)
    return not issecretvalue or not issecretvalue(value)
end

local function readResults(job)
    local n, total = API.GetNumWhoResults()
    if not plain(n) or not plain(total) or type(n) ~= "number" or type(total) ~= "number" then
        return nil, "Who counts are unavailable or restricted"
    end
    if n < 0 or n > 1000 or total < n then return nil, "Unexpected who counts" end
    local rows = {}
    for i = 1, n do
        local row = API.GetWhoInfo(i)
        if not plain(row) or type(row) ~= "table" then return nil, "Who rows are unavailable or restricted" end
        for _, field in ipairs({"fullName", "level", "classStr", "raceStr", "fullGuildName", "area"}) do
            if not plain(row[field]) then return nil, "Who details are restricted on this client" end
        end
        if type(row.fullName) ~= "string" or row.fullName == "" then
            return nil, "Who response contained a missing name; retrying after 60s"
        end
        rows[#rows + 1] = row
    end
    local fit = Core.Fit(job, rows)
    local fits, reason = Core.Plausible(job, fit)
    if not fits then
        local message = string.format("Reply is not for this search: asked %s; %s. Retry in 60s", Core.Query(job), reason)
        -- A race learned from the data rather than named by the client may be one
        -- this server cannot search by; asking again would get the same answer.
        if job.race and learnedRaces[job.race] and fit.race * 2 < fit.total then
            return nil, message, job.race
        end
        return nil, message
    end
    return rows, n, total, fit
end

local function onWho()
    if not pending then return end
    local job = pending.job
    local ok, rows, n, total, fit = pcall(readResults, job)
    if not ok then failClosed("Could not read who results", true); return end
    if not rows then
        -- On failure readResults hands back its reason, and a race it found unsearchable.
        local problem, ignoredRace = n, total
        if ignoredRace then
            pending = nil
            dropRace(ignoredRace)
            lastMessage = string.format('This server does not search by race "%s"; its characters are still found through level and class searches', ignoredRace)
            restoreWhoWindow(true)
            if #queue == 0 then finishScan() end
            return
        end
        retryPending(problem, true)
        return
    end
    db.filters = db.filters or {}
    Core.Observe(db.filters, job, fit)
    scan.strays = (scan.strays or 0) + (n - fit.level)
    pending = nil
    local stamp = GetServerTime()
    for _, row in ipairs(rows) do
        learn(row.raceStr, row.classStr)
        local _, key = Core.Record(db.records, row, context, stamp)
        if key then
            scan.seen[key] = true
            touch(key)
        end
    end
    if dataPanel then dataPanel.dirty = true end
    scan.queries = scan.queries + 1
    scan.consecutiveTimeouts = 0
    -- A reported total is only worth anything when it exceeds the page: `total == n`
    -- at the cap means "at least fifty", not "exactly fifty", and a server that never
    -- looks past the page reports exactly that for every search.
    local trusted = total > n and total or nil
    if trusted then db.reportsTotals = true end
    -- Account this reply against its parent. Children partition their parent exactly,
    -- so once they add up to the parent's own total the rest are provably empty. A
    -- parent whose own total was untrustworthy has no budget to spend, and pruning is
    -- simply off for its children rather than guessing at one.
    if job.group then job.group.remaining = job.group.remaining - total end
    if n >= Core.PAGE or total > n then
        local children = Core.Split(job, classes, races, trusted, n >= Core.PAGE)
        if #children == 0 then
            scan.capped = scan.capped + 1
        else
            -- Breadth first: every level gets its first look before any one level is
            -- taken apart race by race and name by name, so a pass cut short still
            -- covers the whole range instead of only its bottom few levels.
            local group = trusted and {remaining = trusted} or nil
            for _, child in ipairs(children) do
                child.group = group
                queue[#queue + 1] = child
            end
        end
    end
    lastMessage = string.format("Received %d characters%s; %d queued searches", n,
        n > fit.level and string.format(" (%d outside the level range, kept anyway)", n - fit.level) or "", #queue)
    -- Re-register after the current event dispatch so Blizzard does not open Who.
    restoreWhoWindow(true)
    if #queue == 0 then finishScan() end
end

local function waitText()
    if pending then return "waiting for a reply (times out after " .. math.max(0, math.ceil(TIMEOUT - (GetTime() - pending.sent))) .. "s)" end
    if not db.settings.enabled or stoppedByError then return "collection is paused" end
    local wait = math.ceil(math.max(nextSend, externalUntil, scan and 0 or nextScan) - GetTime())
    if wait > 0 then return "next query allowed in " .. wait .. "s" end
    return windowHooked and "ready; click in the world outside combat" or "ready; press Next query"
end

local function raceSummary()
    if #races == 0 then return "none yet" end
    local text = table.concat(races, ", ")
    if not crossFaction and #otherRaces > 0 then
        text = text .. " (the other faction's are skipped: /who here has only ever answered with your own)"
    end
    return text
end

local function statusText()
    local last = db.scans[#db.scans]
    local new, updated = sinceLogin()
    local carried = ""
    if scan and (scan.sessions or 1) > 1 then
        carried = string.format(" (carried over from %d earlier session%s)", scan.sessions - 1, scan.sessions > 2 and "s" or "")
    end
    local parts = {
        "Client: " .. context.version .. " (" .. context.build .. ") | " .. context.region .. " (code " .. context.regionCode .. ") | " .. context.realm,
        "Collector faction: " .. context.faction,
        "Collection: " .. (db.settings.enabled and "ON" or "PAUSED") .. " | World clicks: " .. (db.settings.worldClicks and "ON" or "OFF"),
        "Stored unique characters: " .. countRecords(),
        "This pass: " .. (scan and scan.queries or 0) .. " responses; " .. #queue .. " queued" .. carried,
        "Status: " .. lastMessage,
        "Right now: " .. waitText(),
        "Who UI listeners silenced: " .. lastListeners,
        "Server honours these filters: " .. Core.FilterReport(db.filters or {}),
        "Server reports totals beyond the 50-row page: " .. (db.reportsTotals and "yes" or "not seen yet (searches are not skipped without it)"),
        "Races searched: " .. raceSummary(),
        "Queries: at most every " .. Core.Interval(db.settings) .. "s; pause during combat or while Who/Friends is open.",
        "If world clicks do not work, turn them off and use Next query.",
        "Counts are observed characters, not people or an exact online population.",

        "",
        "Loaded from disk at login: " .. loadedCount .. (db.lastSaved and ("  (written " .. date("%Y-%m-%d %H:%M", db.lastSaved) .. ")") or "  (nothing saved yet)"),
        "Gathered since login: " .. new .. " new and " .. updated .. " seen again or updated, held in memory until /reload, logout or a clean exit",
        "WoW writes addon data at those three moments only and no addon can force it; a crash or a killed client loses the session.",
    }
    if last then parts[#parts + 1] = "Last pass: " .. last.unique .. " characters, " .. last.capped .. " capped groups, " .. last.failed .. " failed queries." end
    if lostCount then
        parts[#parts + 1] = "|cffff7f7fThe last save kept only " .. loadedCount .. " of " .. db.expectedCount
            .. " characters. Export regularly; saving on this client is unreliable. Your next sync asks each partner for everything, to fill the gap.|r"
    end
    return table.concat(parts, "\n")
end

local function button(parent, label, x, y, width, callback)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 26)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", callback)
    return b
end

local function makeWindow(name, title, width, height)
    local w = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    w:SetSize(width, height)
    w:SetPoint("CENTER")
    w:SetMovable(true)
    w:EnableMouse(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", w.StopMovingOrSizing)
    w:SetClampedToScreen(true)
    w:SetFrameStrata("DIALOG")
    w.TitleText:SetText(title)
    UISpecialFrames[#UISpecialFrames + 1] = name
    return w
end

-- The version in the window title comes from the .toc, so it cannot fall out of step.
local function addonVersion()
    local getter = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not getter then return nil end
    local ok, value = pcall(getter, addonName, "Version")
    return ok and type(value) == "string" and value ~= "" and value or nil
end

local function uiText(value)
    return tostring(value or ""):gsub("|", "||")
end

local function classColored(record)
    return "|c" .. NS.Charts.ClassHex(record.class) .. uiText(record.fullName) .. "|r"
end

local function plural(name)
    return name:sub(-1) == "s" and name or name .. "s"
end

local function toggleEnabled()
    if not supported then say("Required who APIs are missing on this client"); return end
    db.settings.enabled = not db.settings.enabled
    stoppedByError = false
    if not db.settings.enabled then
        retryPending("Paused")
        lastMessage = "Paused"
    else
        lastMessage = "Waiting for a world click or Next query"
    end
end

local function makeSlider(parent, name, x, y, caption, low, high, value, onChange, width)
    local slider
    for _, template in ipairs({"OptionsSliderTemplate", "UISliderTemplateWithLabels"}) do
        local ok, created = pcall(CreateFrame, "Slider", name, parent, template)
        if ok and created then slider = created; break end
    end
    slider = slider or CreateFrame("Slider", name, parent)
    slider:SetSize(width or 150, 16)
    slider:SetPoint("TOPLEFT", x, y)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetValue(value)
    local label = _G[name .. "Text"] or slider.Text
    local lowLabel = _G[name .. "Low"] or slider.Low
    local highLabel = _G[name .. "High"] or slider.High
    if lowLabel then lowLabel:SetText(low) end
    if highLabel then highLabel:SetText(high) end
    local function describe(v) if label then label:SetText(caption .. ": " .. v) end end
    describe(value)
    -- Attached after SetValue so building the window does not trigger a refresh.
    slider:SetScript("OnValueChanged", function(_, raw)
        local level = math.floor(raw + 0.5)
        describe(level)
        onChange(level)
    end)
    slider.describe = describe
    return slider
end

local TABS = {"Overview", "Characters", "Guilds", "Trends", "Passes", "Sync", "Export", "Import", "Status"}
-- The tabs whose contents the filter bar narrows down.
local FILTERED = {Overview = true, Characters = true, Guilds = true, Trends = true, Passes = true}

local function seenText(days)
    return days and ("Seen: " .. days .. " days") or "Seen: any time"
end

local function label(parent, text, x, y, width, font)
    local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    f:SetPoint("TOPLEFT", x, y)
    f:SetWidth(width)
    f:SetJustifyH("LEFT")
    f:SetText(text)
    return f
end

local function buildFilters(w)
    local function invalidate() w.page = 1; w.dirty = true end
    w.metrics = label(w, "", 18, -36, 970, "GameFontNormal")
    label(w, "Search", 18, -76, 52)
    w.search = CreateFrame("EditBox", nil, w, "InputBoxTemplate")
    w.search:SetSize(150, 24)
    w.search:SetPoint("TOPLEFT", 76, -70)
    w.search:SetAutoFocus(false)
    w.search:SetMaxLetters(100)
    w.search:SetScript("OnTextChanged", invalidate)
    w.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    w.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    w.minSlider = makeSlider(w, "ForeverCensusMinLevel", 244, -82, "Min level", 1, Core.MAX_LEVEL, 1, function(level)
        w.minLevel = level
        if level > w.maxLevel then w.maxSlider:SetValue(level) end
        invalidate()
    end, 128)
    w.maxSlider = makeSlider(w, "ForeverCensusMaxLevel", 388, -82, "Max level", 1, Core.MAX_LEVEL, Core.MAX_LEVEL, function(level)
        w.maxLevel = level
        if level < w.minLevel then w.minSlider:SetValue(level) end
        invalidate()
    end, 128)
    w.factionButton = button(w, "Faction: All", 532, -76, 112, function()
        w.faction = (w.faction == nil and "Alliance") or (w.faction == "Alliance" and "Horde") or nil
        w.factionButton:SetText("Faction: " .. (w.faction or "All"))
        invalidate()
    end)
    -- Characters collected on two realms are two populations; this pulls them apart.
    w.realmButton = button(w, "All realms", 650, -76, 136, function()
        local realms = Core.Realms(db.records)
        local following = nil
        if w.realm == nil then
            following = realms[1]
        else
            for i, name in ipairs(realms) do
                if name == w.realm then following = realms[i + 1] end
            end
        end
        w.realm = following
        w.realmButton:SetText(following and uiText(following) or "All realms")
        invalidate()
    end)
    -- Beta characters get deleted and remade all the time, and a record stays stored
    -- for ever, so this keeps to the characters seen lately: who is actually playing.
    w.seenButton = button(w, seenText(nil), 792, -76, 104, function()
        w.seenDays = (w.seenDays == nil and 7) or (w.seenDays == 7 and 30) or nil
        w.seenButton:SetText(seenText(w.seenDays))
        invalidate()
    end)
    w.clearButton = button(w, "Clear filters", 902, -76, 92, function()
        w.search:SetText("")
        w.minSlider:SetValue(1)
        w.maxSlider:SetValue(Core.MAX_LEVEL)
        w.faction = nil
        w.factionButton:SetText("Faction: All")
        w.realm = nil
        w.realmButton:SetText("All realms")
        w.seenDays = nil
        w.seenButton:SetText(seenText(nil))
        w.drillClass, w.drillRace, w.drillGuild = nil, nil, nil
        invalidate()
    end)
end

local function buildOverview(w)
    local Charts = NS.Charts
    w.overview = CreateFrame("Frame", nil, w)
    w.overview:SetAllPoints(w)
    -- Room for more groups than the eight races and nine classes we know about, so a
    -- name this client does not recognise gets its own bar instead of disappearing.
    w.raceChart = Charts.BarChart(w.overview, 16, -146, 330, 260, "Races", 14)
    w.classChart = Charts.BarChart(w.overview, 354, -146, 356, 260, "Classes", 14)
    w.guildPanel = Charts.List(w.overview, 718, -146, 276, 260, "Largest guilds", 7)
    w.levelChart = Charts.Histogram(w.overview, 16, -414, 694, 236, "Characters at each level")
    w.zonePanel = Charts.List(w.overview, 718, -414, 276, 236, "Busiest zones", 6)
    -- Clicking a bar breaks the other chart down by it: a class shows which races play
    -- it, a race shows which classes it plays, and the level chart, guilds and zones
    -- follow. Clicking it again goes back to everyone. It is all worked out from the
    -- characters already stored, so nothing is searched again.
    w.classChart.onSelect = function(key)
        w.drillClass = w.drillClass ~= key and key or nil
        w:Refresh()
    end
    w.raceChart.onSelect = function(key)
        w.drillRace = w.drillRace ~= key and key or nil
        w:Refresh()
    end
    w.classChart.hint = function(key, selected)
        return selected and "Click again to show every class" or ("Click to see which races play " .. uiText(plural(key)))
    end
    w.raceChart.hint = function(key, selected)
        return selected and "Click again to show every race" or ("Click to see which classes " .. uiText(key) .. " characters play")
    end
    -- A guild narrows every chart to its members, and a class or race can then be
    -- picked inside it: which classes a guild is short of, how far along it is.
    w.guildPanel.onSelect = function(name)
        w.drillGuild = w.drillGuild ~= name and name or nil
        w:Refresh()
    end
    w.guildPanel.hint = function(_, selected)
        return selected and "Click again to show every guild" or "Click to see this guild's races, classes and levels"
    end
    w.drillClear = button(w.overview, "Clear selection", 812, -112, 182, function()
        w.drillClass, w.drillRace, w.drillGuild = nil, nil, nil
        w:Refresh()
    end)
    w.drillClear:Hide()
end

local function buildTrends(w)
    local Charts = NS.Charts
    w.trends = CreateFrame("Frame", nil, w)
    w.trends:SetAllPoints(w)
    w.dayChart = Charts.Timeline(w.trends, 16, -146, 978, 250, "New characters each day, last 30 days", 30)
    w.mixTable = Charts.Table(w.trends, 16, -404, 978, 246, "What each census pass found, newest first", 7, 16)
end

local function buildCharacters(w)
    local Charts = NS.Charts
    w.list = CreateFrame("Frame", nil, w)
    w.list:SetAllPoints(w)
    button(w.list, "Name / realm", 18, -146, 262, function() w.sortKey = "name"; w:Refresh() end)
    button(w.list, "Level", 286, -146, 56, function() w.sortKey = "level"; w:Refresh() end)
    label(w.list, "Class / race", 350, -153, 148, "GameFontNormal")
    label(w.list, "Guild", 502, -153, 214, "GameFontNormal")
    label(w.list, "Zone", 722, -153, 128, "GameFontNormal")
    button(w.list, "Last seen", 856, -146, 138, function() w.sortKey = "lastSeen"; w:Refresh() end)
    for i = 1, 16 do
        local row = CreateFrame("Button", nil, w.list)
        row:SetPoint("TOPLEFT", 18, -180 - (i - 1) * 26)
        row:SetSize(976, 25)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("TOPLEFT", 0, -2)
        row.name = label(row, "", 22, 0, 244)
        row.level = label(row, "", 268, 0, 56)
        row.class = label(row, "", 332, 0, 148)
        row.guild = label(row, "", 484, 0, 214)
        row.zone = label(row, "", 704, 0, 128)
        row.seen = label(row, "", 838, 0, 138)
        for _, column in ipairs({row.name, row.level, row.class, row.guild, row.zone, row.seen}) do column:SetMaxLines(1) end
        row:SetScript("OnEnter", function(self)
            local r = self.record
            if not r then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine(uiText(r.fullName), 1, 0.82, 0)
            for _, text in ipairs({
                "Level " .. r.level .. " " .. r.race .. " " .. r.class,
                "Faction: " .. Core.Faction(r),
                "Guild: " .. (r.guild ~= "" and r.guild or "None"),
                "Zone: " .. r.zone, "Region: " .. r.region,
                "First seen: " .. date("%Y-%m-%d %H:%M", r.firstSeen),
                "Last seen: " .. date("%Y-%m-%d %H:%M", r.lastSeen),
                "Collector: " .. r.observerRealm .. " / " .. r.observerFaction,
            }) do GameTooltip:AddLine(uiText(text), 1, 1, 1) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        w.rows[i] = row
    end
    w.pageLabel = label(w.list, "", 350, -612, 310, "GameFontNormal")
    button(w.list, "Previous", 18, -606, 130, function() w.page = math.max(1, w.page - 1); w:Refresh() end)
    button(w.list, "Next", 864, -606, 130, function() w.page = w.page + 1; w:Refresh() end)
end

local function buildExport(w)
    w.export = CreateFrame("Frame", nil, w)
    w.export:SetAllPoints(w)
    label(w.export, "Ctrl+A then Ctrl+C in the box, and paste each page into the offline viewer (ForeverCensus-Viewer.html, in this addon's folder). Repeat for every page.\nSyncing in game (Sync tab) is easier for a friend who also runs this addon; CSV is for sharing outside it.",
        18, -150, 960)
    local scroll = CreateFrame("ScrollFrame", nil, w.export, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 18, -196)
    scroll:SetSize(928, 400)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(910)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    w.exportEdit = edit
    w.exportLabel = label(w.export, "", 350, -612, 310, "GameFontNormal")
    button(w.export, "Previous", 18, -606, 130, function() w:ShowExport(w.exportPage - 1) end)
    button(w.export, "New snapshot", 690, -606, 160, function() w:ShowExport(1, true) end)
    button(w.export, "Next", 864, -606, 130, function() w:ShowExport(w.exportPage + 1) end)
    function w:ShowExport(page, refresh)
        if refresh or not self.exportSnapshot then
            self.exportSnapshot = {}
            for key, record in pairs(db.records) do self.exportSnapshot[key] = record end
        end
        local text, current, pages, total = Core.Export(self.exportSnapshot, page)
        self.exportPage = current
        self.exportLabel:SetText(string.format("Page %d / %d  |  %d characters", current, pages, total))
        self.exportEdit:SetText(text)
        self.exportEdit:SetFocus()
        self.exportEdit:HighlightText()
    end
end

local function buildImport(w)
    w.import = CreateFrame("Frame", nil, w)
    w.import:SetAllPoints(w)
    label(w.import, "Paste a Forever Census CSV here and choose Import. Use this for a file a friend sent you, or one saved from the offline viewer; for someone playing right now the Sync tab is easier. The same character read twice is merged, never counted twice, so importing a file again is safe.",
        18, -150, 960)
    local scroll = CreateFrame("ScrollFrame", nil, w.import, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 18, -206)
    scroll:SetSize(928, 380)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(910)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    w.importEdit = edit
    w.importResult = label(w.import, "", 18, -600, 700, "GameFontNormal")
    button(w.import, "Import pasted text", 18, -630, 170, function() w:RunImport() end)
    button(w.import, "Clear box", 196, -630, 130, function()
        w.importEdit:SetText("")
        w.importResult:SetText("")
    end)
    label(w.import, "One page at a time if the export had several; import them in any order.",
        340, -636, 620, "GameFontDisableSmall")
    function w:RunImport()
        local text = self.importEdit:GetText() or ""
        local result, problem = Core.ImportCSV(text, db.records, touch, GetServerTime())
        if problem then
            self.importResult:SetText("|cffff7f7f" .. uiText(problem) .. "|r")
            return
        end
        self.importResult:SetText(string.format(
            "Read %d rows: %d new, %d updated, %d already current%s",
            result.rows, result.new, result.updated, result.unchanged,
            result.rejected > 0 and string.format(", %d unreadable and discarded", result.rejected) or ""))
        if result.new + result.updated > 0 then
            say(string.format("Imported %d new and %d updated characters", result.new, result.updated))
        end
        self.dirty = true
        self:Refresh()
    end
end

local function buildStatus(w)
    w.status = CreateFrame("Frame", nil, w)
    w.status:SetAllPoints(w)
    w.statusText = label(w.status, "", 18, -150, 700)
    w.statusText:SetSpacing(5)
    button(w.status, "Pause / resume", 18, -560, 145, function() toggleEnabled(); w:RefreshStatus() end)
    button(w.status, "Next query", 172, -560, 120, function() sendNext(true); w:RefreshStatus() end)
    button(w.status, "World clicks on/off", 289, -560, 166, function()
        db.settings.worldClicks = not db.settings.worldClicks
        w:RefreshStatus()
    end)
    -- Reloading the interface is the only way an addon can make WoW write its data now.
    button(w.status, "Save to disk now", 463, -560, 150, function()
        local new, updated = sinceLogin()
        if new == 0 and updated == 0 then
            say("Nothing new to write since login")
            return
        end
        if not pcall(ReloadUI) then
            say("This client would not let the addon reload. Type /reload yourself to write the data.")
        end
    end)
    w.intervalSlider = makeSlider(w.status, "ForeverCensusInterval", 640, -566, "Seconds between searches",
        Core.MIN_INTERVAL, Core.MAX_INTERVAL, Core.Interval(db.settings), function(seconds)
            db.settings.interval = seconds
            w:RefreshStatus()
        end)
    label(w.status, "Searches only ever follow one of your own clicks. Lower the interval to finish a pass sooner; raise it if the server starts dropping searches. Nothing is sent anywhere except a sync partner you name yourself."
        .. "\n\n" .. "Save to disk now reloads your interface, which is what makes WoW write the data out. An ordinary /reload, logging out to character select, or quitting cleanly all do the same thing, and an unfinished pass carries on where it left off. Only a crash or a killed client loses the session.",
        18, -604, 960, "GameFontDisableSmall"):SetSpacing(3)
    function w:RefreshStatus()
        self.statusText:SetText(statusText())
        local seconds = Core.Interval(db.settings)
        if self.intervalSlider:GetValue() ~= seconds then self.intervalSlider:SetValue(seconds) end
    end
end

local function buildSync(w)
    local Sync = NS.Sync
    w.sync = CreateFrame("Frame", nil, w)
    w.sync:SetAllPoints(w)
    label(w.sync, "Swap census data in game with someone else running Forever Census. Both of you end up with the combined data; the same character seen twice is merged, never counted twice.",
        18, -150, 960, "GameFontNormal")
    label(w.sync, "Their character name", 18, -196, 170)
    w.syncName = CreateFrame("EditBox", nil, w.sync, "InputBoxTemplate")
    w.syncName:SetSize(220, 24)
    w.syncName:SetPoint("TOPLEFT", 196, -190)
    w.syncName:SetAutoFocus(false)
    w.syncName:SetMaxLetters(48)
    w.syncName:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    w.syncName:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Sync.Start(self:GetText()) end)
    w.syncStart = button(w.sync, "Share with them", 430, -196, 150, function() Sync.Start(w.syncName:GetText()) end)
    w.syncAccept = button(w.sync, "Accept request", 588, -196, 150, function() Sync.Accept() end)
    w.syncIgnore = button(w.sync, "Ignore", 746, -196, 90, function() Sync.Ignore() end)
    w.syncCancel = button(w.sync, "Cancel", 844, -196, 90, function() Sync.Cancel() end)
    w.syncAuto = button(w.sync, "Automatic sync: On", 18, -232, 200, function()
        Sync.SetAuto(not Sync.AutoEnabled())
        w:RefreshSync()
    end)
    w.syncAutoText = label(w.sync, "", 230, -239, 750)
    w.syncStatus = label(w.sync, "", 18, -276, 960, "GameFontNormal")
    w.syncPeers = label(w.sync, "", 18, -304, 960)
    label(w.sync, [[How it works
1. Your friend installs Forever Census and logs in on the same realm.
2. Type their character name above and choose Share with them, or use /fc sync Name.
3. They see one line in chat and choose Accept request (or /fc accept). You are then remembered as partners, and from then on your addons swap by themselves: shortly after either of you logs in, and every 20 minutes while you are both online. Automatic swaps stay out of chat.
4. The first swap sends everything both of you have. After that, each side only sends what is new or changed since your last swap, so a regular sync takes moments rather than half an hour. A swap cut short carries on from where it stopped. Leave the window open or closed; it keeps going either way.
5. Partners are people, not characters. Once you have swapped, both addons (0.7.1 or later) recognise each other on any character, new ones included. If you are Battle.net friends, it can also find which character they are on (/fc bnet shows what it sees).

Limits worth knowing: you both have to be online at the same time, transfer runs at about four characters a second (about sixteen when you are both on 0.8.0 or later), and a name you have never accepted cannot push data to you. /fc sync Name all swaps everything again; /fc autosync turns automatic swaps on or off; /fc forget Name removes a partner and all of their characters.]],
        18, -336, 960, "GameFontDisableSmall"):SetSpacing(3)
    function w:RefreshSync()
        local status, peers = Sync.StatusText()
        self.syncAuto:SetText("Automatic sync: " .. (Sync.AutoEnabled() and "On" or "Off"))
        self.syncAuto:SetEnabled(Sync.available)
        self.syncAutoText:SetText(Sync.AutoText())
        self.syncStatus:SetText(uiText(status))
        self.syncPeers:SetText("Sync partners: " .. uiText(peers))
        self.syncAccept:SetEnabled(Sync.request ~= nil)
        self.syncIgnore:SetEnabled(Sync.request ~= nil)
        self.syncCancel:SetEnabled(Sync.Busy())
        self.syncStart:SetEnabled(Sync.available and not Sync.Busy())
    end
end

local function guildItems(list, shown)
    local items = {}
    for i, guild in ipairs(list) do
        items[i] = {
            key = guild.name, left = uiText(guild.name), right = guild.members,
            sub = string.format("average level %.1f  |  %d at %d", guild.totalLevel / guild.members, guild.maxLevel, Core.MAX_LEVEL),
            lines = {uiText(guild.name), guild.members .. " observed members",
                string.format("Average level %.1f", guild.totalLevel / guild.members),
                guild.maxLevel .. " at level " .. Core.MAX_LEVEL,
                string.format("%.1f%% of the current selection", shown > 0 and guild.members * 100 / shown or 0)},
        }
    end
    return items
end

local function zoneItems(stats)
    local names = {}
    for zone in pairs(stats.zones) do names[#names + 1] = zone end
    table.sort(names, function(a, b)
        if stats.zones[a] ~= stats.zones[b] then return stats.zones[a] > stats.zones[b] end
        return a < b
    end)
    local items = {}
    for i, zone in ipairs(names) do
        items[i] = {left = uiText(zone), right = stats.zones[zone],
            sub = string.format("%.1f%% of the selection", stats.shown > 0 and stats.zones[zone] * 100 / stats.shown or 0),
            lines = {uiText(zone), stats.zones[zone] .. " characters last seen here"}}
    end
    return items
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function share(part, whole)
    return whole > 0 and part * 100 / whole or 0
end

-- The daily chart: each day's newcomers, with a date under every seventh day back from
-- today.
local function dayEntries(days)
    local entries = {}
    for i, day in ipairs(days) do
        entries[i] = {count = day.count,
            tick = (#days - i) % 7 == 0 and date("%d %b", day.stamp) or nil,
            lines = {date("%A %d %B", day.stamp), day.count .. " characters first seen that day",
                day.total .. " seen by the end of it"}}
    end
    return entries
end

local MIX_COLUMNS = {
    {text = "Pass", width = 118}, {text = "Realm", width = 128},
    {text = "Found", width = 56, justify = "RIGHT"}, {text = "Avg level", width = 66, justify = "RIGHT"},
    {text = "At " .. Core.MAX_LEVEL, width = 52, justify = "RIGHT"},
}

-- One row per pass, newest first: the share of what it found that was each class, so
-- a class catching on shows as its column climbing. The tooltip adds races and the
-- change since the pass before on the same realm.
local function mixTable(entries, room, maxColumns)
    local present = {}
    for _, entry in ipairs(entries) do
        for class in pairs(entry.mix.classes) do present[class] = true end
    end
    local classKeys = {}
    for _, class in ipairs(Core.ChartKeys(NS.Charts.classOrder, present)) do
        if present[class] and #MIX_COLUMNS + #classKeys < maxColumns then classKeys[#classKeys + 1] = class end
    end
    local columns, used = {}, 0
    for i, column in ipairs(MIX_COLUMNS) do
        columns[i] = column
        used = used + column.width
    end
    local width = math.min(80, math.floor((room - used) / math.max(1, #classKeys)))
    for _, class in ipairs(classKeys) do
        columns[#columns + 1] = {text = "|c" .. NS.Charts.ClassHex(class) .. uiText(class) .. "|r", width = width, justify = "RIGHT"}
    end
    local items = {}
    for i, entry in ipairs(entries) do
        local pass, mix = entry.pass, entry.mix
        local before
        for j = i + 1, #entries do
            local older = entries[j].pass
            if older.realm == pass.realm and older.faction == pass.faction then before = entries[j].mix; break end
        end
        local when = entry.live and "In progress" or date("%m-%d %H:%M", pass.finished or pass.started)
        local cells = {when, uiText(pass.realm or "?"), tostring(mix.n),
            string.format("%.1f", mix.levels / math.max(1, mix.n)), tostring(mix.atCap)}
        for _, class in ipairs(classKeys) do
            cells[#cells + 1] = string.format("%.1f%%", share(mix.classes[class] or 0, mix.n))
        end
        local lines = {entry.live and "Pass in progress, so far" or ("Pass finished " .. date("%Y-%m-%d %H:%M", pass.finished or pass.started)),
            "Started " .. date("%Y-%m-%d %H:%M", pass.started) .. " on " .. uiText(pass.realm or "?"),
            string.format("%d characters, average level %.1f, %d at level %d", mix.n, mix.levels / math.max(1, mix.n), mix.atCap, Core.MAX_LEVEL)}
        local function describe(counts, earlier)
            local names = {}
            for name in pairs(counts) do names[#names + 1] = name end
            table.sort(names, function(a, b)
                if counts[a] ~= counts[b] then return counts[a] > counts[b] end
                return a < b
            end)
            for _, name in ipairs(names) do
                local now = share(counts[name], mix.n)
                local change = ""
                if earlier then
                    change = string.format(", %+.1f since the pass before", now - share(earlier.counts[name] or 0, earlier.n))
                end
                lines[#lines + 1] = string.format("%s: %d (%.1f%%%s)", uiText(name), counts[name], now, change)
            end
        end
        describe(mix.classes, before and {counts = before.classes, n = before.n})
        describe(mix.races, before and {counts = before.races, n = before.n})
        items[i] = {cells = cells, lines = lines}
    end
    return columns, items
end

function NS.ShowData(tab)
    local Charts = NS.Charts
    if not dataPanel then
        local version = addonVersion()
        dataPanel = makeWindow("ForeverCensusData",
            version and ("Forever Census " .. version .. " - realm census") or "Forever Census - realm census", 1010, 700)
        local w = dataPanel
        w.page, w.sortKey, w.dirty, w.tab = 1, "lastSeen", true, "Overview"
        w.rows, w.tabs, w.faction, w.realm, w.seenDays = {}, {}, nil, nil, nil
        w.drillClass, w.drillRace, w.drillGuild = nil, nil, nil
        w.minLevel, w.maxLevel = 1, Core.MAX_LEVEL
        w.exportPage = 1

        buildFilters(w)
        for i, name in ipairs(TABS) do
            w.tabs[name] = button(w, name, 18 + (i - 1) * 88, -112, 84, function()
                w.tab = name
                w:Refresh()
            end)
        end
        buildOverview(w)
        buildCharacters(w)

        w.guilds = CreateFrame("Frame", nil, w)
        w.guilds:SetAllPoints(w)
        w.guildTable = Charts.List(w.guilds, 16, -146, 978, 494, "Guilds in the current selection", 16)
        -- A guild picked here opens the Overview broken down by it.
        w.guildTable.onSelect = function(name)
            w.drillGuild = name
            w.tab = "Overview"
            w:Refresh()
        end
        w.guildTable.hint = function()
            return "Click to see its races, classes and levels on the Overview"
        end

        buildTrends(w)

        w.passes = CreateFrame("Frame", nil, w)
        w.passes:SetAllPoints(w)
        w.passTable = Charts.List(w.passes, 16, -146, 978, 494, "Census passes (newest first)", 16)

        buildSync(w)
        buildExport(w)
        buildImport(w)
        buildStatus(w)

        w.footnote = label(w, "", 18, -658, 970, "GameFontDisableSmall")

        function w:Filters()
            -- The top of the slider means "no upper limit", so nothing already stored
            -- above the current cap is ever hidden by default.
            return {search = self.search:GetText(), minLevel = self.minLevel,
                maxLevel = self.maxLevel < Core.MAX_LEVEL and self.maxLevel or nil,
                faction = self.faction, realm = self.realm,
                seenSince = self.seenDays and (GetServerTime() - self.seenDays * Core.DAY) or nil}
        end

        function w:RefreshOverview(rows, stats, guilds)
            -- The bars each chart draws are fixed by the filters, not by a click, so a
            -- breakdown never makes a bar vanish; a race nobody of that class plays
            -- simply drops to zero.
            local raceKeys = Core.ChartKeys(Charts.raceOrder, stats.races, stats.factions)
            local classKeys = Core.ChartKeys(Charts.classOrder, stats.classes)
            if self.drillClass and not contains(classKeys, self.drillClass) then self.drillClass = nil end
            if self.drillRace and not contains(raceKeys, self.drillRace) then self.drillRace = nil end
            if self.drillGuild and not stats.guilds[self.drillGuild] then self.drillGuild = nil end
            -- A chosen guild narrows every chart; a class or race then works inside it.
            local base, baseStats = rows, stats
            if self.drillGuild then
                base = Core.Subset(rows, nil, nil, self.drillGuild)
                baseStats = Core.Summarize(base)
            end
            local ofClass = self.drillClass and Core.Summarize(Core.Subset(base, self.drillClass, nil)) or baseStats
            local ofRace = self.drillRace and Core.Summarize(Core.Subset(base, nil, self.drillRace)) or baseStats
            local picked = baseStats
            if self.drillClass and self.drillRace then
                picked = Core.Summarize(Core.Subset(base, self.drillClass, self.drillRace))
            elseif self.drillClass then
                picked = ofClass
            elseif self.drillRace then
                picked = ofRace
            end
            local classPlural = self.drillClass and uiText(plural(self.drillClass))
            local raceGroup = self.drillRace and (uiText(self.drillRace) .. " characters")
            local both = self.drillClass and self.drillRace and (uiText(self.drillRace) .. " " .. classPlural)
            local who = both or classPlural or raceGroup
            local guild = self.drillGuild and uiText(self.drillGuild)
            local inGuild = guild and (" in " .. guild) or ""

            if classPlural then self.raceChart.title:SetText("Races of " .. classPlural .. inGuild)
            else self.raceChart.title:SetText(guild and ("Races in " .. guild) or "Races") end
            self.raceChart:Update(Core.Distribution(ofClass.races, raceKeys, ofClass.shown),
                Charts.RaceStyle, ofClass.shown, self.drillRace, classPlural and (classPlural .. inGuild) or guild)
            if raceGroup then self.classChart.title:SetText("Classes of " .. raceGroup .. inGuild)
            else self.classChart.title:SetText(guild and ("Classes in " .. guild) or "Classes") end
            self.classChart:Update(Core.Distribution(ofRace.classes, classKeys, ofRace.shown),
                Charts.ClassStyle, ofRace.shown, self.drillClass, raceGroup and (raceGroup .. inGuild) or guild)
            if who then self.levelChart.title:SetText(who .. inGuild .. " at each level")
            else self.levelChart.title:SetText(guild and ("Members of " .. guild .. " at each level") or "Characters at each level") end
            self.levelChart:Update(picked)

            -- The guild list is not narrowed by the chosen guild, so another can be picked
            -- straight from it; it follows the class and race instead.
            local guildScope = picked
            if self.drillGuild then
                guildScope = (self.drillClass or self.drillRace)
                    and Core.Summarize(Core.Subset(rows, self.drillClass, self.drillRace)) or stats
            end
            local pickedGuilds = guildScope == stats and guilds or Core.GuildList(guildScope)
            self.guildPanel.title:SetText(who and ("Largest guilds: " .. who) or "Largest guilds")
            self.guildPanel:Update(guildItems(pickedGuilds, guildScope.shown),
                guildScope.shown > 0 and "No guilds among the matching characters" or "No matching characters",
                self.drillGuild)
            if #pickedGuilds > 0 then
                self.guildPanel.footer:SetText(string.format("%d guilds  |  %d unguilded%s", #pickedGuilds, guildScope.guildless,
                    #pickedGuilds > 7 and "  |  scroll for more" or ""))
            end
            local whose = who and (who .. inGuild) or guild
            self.zonePanel.title:SetText(whose and ("Busiest zones: " .. whose) or "Busiest zones")
            self.zonePanel:Update(zoneItems(picked), "No zones recorded yet")
            self.drillClear:SetShown(self.drillClass ~= nil or self.drillRace ~= nil or self.drillGuild ~= nil)
        end

        function w:RefreshTrends(rows)
            local days, earliest = Core.NewPerDay(rows, 30, GetServerTime())
            local week, month = 0, 0
            for i, day in ipairs(days) do
                month = month + day.count
                if i > #days - 7 then week = week + day.count end
            end
            self.dayChart:Update(dayEntries(days), string.format(
                "%d first seen in the last 7 days  |  %d in the last 30  |  first sighting on record: %s",
                week, month, earliest and date("%Y-%m-%d", earliest) or "none yet"))
            -- Passes on the realm and faction chosen above, the one under way on top.
            local entries = {}
            local function add(pass, mix, live)
                if (not self.realm or pass.realm == self.realm) and (not self.faction or pass.faction == self.faction) then
                    entries[#entries + 1] = {pass = pass, mix = mix, live = live}
                end
            end
            if scan and next(scan.seen) then add(scan, Core.Mix(db.records, scan.seen), true) end
            for i = #db.scans, 1, -1 do
                local pass = db.scans[i]
                if type(pass.mix) == "table" and type(pass.mix.classes) == "table" and type(pass.mix.races) == "table" then
                    add(pass, pass.mix, false)
                end
            end
            local columns, items = mixTable(entries, 958, 16)
            self.mixTable:Update(columns, items,
                "Nothing to compare yet. Every pass finished from 0.7.0 on keeps a note of what it found, and the pass under way shows here once it has found anyone.",
                "Share of each pass's own characters by class. Hover over a row for races and the change since the pass before.")
        end

        function w:Refresh()
            -- Only the Characters list shows the order; switching to it redraws it sorted.
            local rows, total, stats = Core.View(db.records, self:Filters(), self.tab == "Characters" and self.sortKey)
            local guilds = Core.GuildList(stats)
            self.metrics:SetText(string.format(
                "%d shown of %d stored  |  average level %.1f  |  %d at level %d  |  %d Alliance / %d Horde  |  %d guilds",
                #rows, total, #rows > 0 and stats.totalLevel / #rows or 0, stats.maxLevel, Core.MAX_LEVEL,
                stats.factions.Alliance or 0, stats.factions.Horde or 0, #guilds))

            self:RefreshOverview(rows, stats, guilds)
            self.guildTable:Update(guildItems(guilds, #rows),
                #rows > 0 and "No guilds among the matching characters" or "No matching characters", self.drillGuild)
            -- Only drawn while it is being looked at; switching to it redraws it.
            if self.tab == "Trends" then self:RefreshTrends(rows) end

            local passItems = {}
            if scan then
                local seen = 0
                for _ in pairs(scan.seen) do seen = seen + 1 end
                passItems[1] = {
                    left = "In progress, started " .. date("%Y-%m-%d %H:%M", scan.started), right = seen,
                    sub = string.format("%s  |  %d responses, %d capped, %d failed  |  %d searches still to do",
                        uiText(scan.realm or "?"), scan.queries, scan.capped, scan.failed, #queue),
                    lines = {"Pass in progress", seen .. " characters observed so far", scan.queries .. " who responses",
                        #queue .. " searches still to do",
                        (scan.sessions or 1) > 1 and ("Carried across " .. scan.sessions .. " sessions") or "Started this session"},
                }
            end
            for i = #db.scans, 1, -1 do
                local pass = db.scans[i]
                passItems[#passItems + 1] = {
                    left = date("%Y-%m-%d %H:%M", pass.started), right = pass.unique or 0,
                    sub = string.format("%s  |  %d responses, %d capped, %d failed", pass.realm or "?", pass.queries or 0, pass.capped or 0, pass.failed or 0),
                    lines = {date("%Y-%m-%d %H:%M", pass.started),
                        (pass.unique or 0) .. " characters observed", (pass.queries or 0) .. " who responses",
                        (pass.capped or 0) .. " capped groups (incomplete)", (pass.failed or 0) .. " failed queries",
                        (pass.strays or 0) .. " rows outside the requested filter, kept anyway",
                        "Collector: " .. (pass.realm or "?") .. " / " .. (pass.faction or "?") .. " / " .. (pass.region or "?"),
                        (pass.sessions or 1) > 1 and ("Carried across " .. pass.sessions .. " sessions") or "Finished in one session"},
                }
            end
            self.passTable:Update(passItems, "No passes yet. A pass starts with your first search.")

            local pages = math.max(1, math.ceil(#rows / 16))
            self.page = math.min(math.max(1, self.page), pages)
            self.pageLabel:SetText(string.format("Page %d / %d - sort: %s", self.page, pages, self.sortKey))
            for i, row in ipairs(self.rows) do
                local record = rows[(self.page - 1) * 16 + i]
                row.record = record
                if record then
                    local _, texture, coords = Charts.ClassStyle(record.class)
                    if texture then
                        row.icon:SetTexture(texture)
                        if coords then row.icon:SetTexCoord(unpack(coords)) end
                        row.icon:Show()
                    else row.icon:Hide() end
                    row.name:SetText(classColored(record))
                    row.level:SetText(record.level)
                    row.class:SetText(uiText(record.class .. " / " .. record.race))
                    row.guild:SetText(uiText(record.guild))
                    row.zone:SetText(uiText(record.zone))
                    row.seen:SetText(date("%m-%d %H:%M", record.lastSeen))
                    row:Show()
                else row:Hide() end
            end

            self:RefreshStatus()
            self:RefreshSync()
            for name, tabButton in pairs(self.tabs) do
                if name == self.tab then tabButton:LockHighlight() else tabButton:UnlockHighlight() end
            end
            self.overview:SetShown(self.tab == "Overview")
            self.list:SetShown(self.tab == "Characters")
            self.guilds:SetShown(self.tab == "Guilds")
            self.trends:SetShown(self.tab == "Trends")
            self.passes:SetShown(self.tab == "Passes")
            self.sync:SetShown(self.tab == "Sync")
            self.export:SetShown(self.tab == "Export")
            self.import:SetShown(self.tab == "Import")
            self.status:SetShown(self.tab == "Status")
            -- The filter bar only means anything where something is being filtered.
            local filtered = FILTERED[self.tab] == true
            for _, control in ipairs({self.search, self.minSlider, self.maxSlider, self.factionButton,
                self.realmButton, self.seenButton, self.clearButton}) do
                control:SetShown(filtered)
            end
            if self.tab == "Overview" then
                self.footnote:SetText("Click a race or class bar, or a guild, to break the charts down by it; click it again to go back. Observed characters, not an exact online count.")
            elseif self.tab == "Guilds" then
                self.footnote:SetText("Click a guild to see its races, classes and levels on the Overview. Observed characters, not an exact online count.")
            elseif self.tab == "Trends" then
                self.footnote:SetText("A character counts as new on the day you or a sync partner first saw it, so the first days of collecting include everyone who was already playing.")
            elseif filtered then
                self.footnote:SetText("Observed characters, not an exact online count. Capped searches are recorded as incomplete. Filters apply to every data tab.")
            else
                self.footnote:SetText("Forever Census keeps everything on this computer. /fc reopens this window.")
            end
            self.dirty = false
            self.drawnAt = GetTime()
        end
    end
    if tab then dataPanel.tab = tab end
    dataPanel:Show()
    dataPanel:Refresh()
    if dataPanel.tab == "Export" then dataPanel:ShowExport(dataPanel.exportPage or 1, true) end
end

function NS.Touch()
    if dataPanel then dataPanel.dirty = true end
end

-- Opening the window without typing /fc: the minimap's addon menu where the client has
-- one (the .toc puts us in it), and a button on the edge of the minimap that can be
-- dragged round it or hidden with /fc minimap. Addons that tidy minimap buttons away
-- gather this one with the rest. Neither ever searches; only the window opens.
local ICON = "Interface\\AddOns\\ForeverCensus\\Icon.tga"
local launcher

local function toggleWindow()
    if not db then return end
    if dataPanel and dataPanel:IsShown() then dataPanel:Hide() else NS.ShowData() end
end

local function describeLauncher(owner, extra)
    if type(owner) == "table" then GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    else GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR") end
    GameTooltip:AddLine("Forever Census", 1, 0.82, 0)
    if db then
        GameTooltip:AddLine(countRecords() .. " characters stored", 1, 1, 1)
        if scan then
            GameTooltip:AddLine(string.format("This pass: %d searches answered, %d still to do", scan.queries, #queue), 1, 1, 1)
        end
    end
    GameTooltip:AddLine("Click to open or close the census", 0.5, 0.85, 0.5)
    if extra then GameTooltip:AddLine(extra, 0.5, 0.85, 0.5) end
    GameTooltip:Show()
end

function ForeverCensus_OnAddonCompartmentClick()
    toggleWindow()
end

function ForeverCensus_OnAddonCompartmentEnter(_, menuButton)
    describeLauncher(menuButton)
end

function ForeverCensus_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

local function placeLauncher()
    local angle = math.rad(tonumber(db.settings.minimapAngle) or 200)
    local radius = (Minimap:GetWidth() or 140) / 2 + 5
    launcher:ClearAllPoints()
    launcher:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function buildLauncher()
    if launcher or not Minimap then return end
    local b = CreateFrame("Button", "ForeverCensusMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")
    b:SetScript("OnClick", function(_, which)
        if which == "RightButton" then NS.ShowData("Status") else toggleWindow() end
    end)
    b:SetScript("OnEnter", function(self) describeLauncher(self, "Right-click for the Status tab; drag to move") end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            if not (mx and my and px and py and scale and scale > 0) then return end
            local angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
            db.settings.minimapAngle = math.floor(angle % 360 + 0.5)
            placeLauncher()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    launcher = b
    placeLauncher()
    b:SetShown(not db.settings.minimapHidden)
end

local function initialize()
    if ForeverCensusDB and ForeverCensusDB.schema ~= 1 then
        say("Unsupported saved-data version. Existing data left untouched; addon disabled.")
        frame:UnregisterAllEvents()
        return
    end
    ForeverCensusDB = ForeverCensusDB or {schema = 1, records = {}, scans = {}, settings = {enabled = true, worldClicks = true}}
    db = ForeverCensusDB
    loadedCount = countRecords()
    touched, touchedCount = {}, 0
    -- Coming back short means the client saved partially, not that we crashed: a crash
    -- writes nothing at all and leaves disk and expectation agreeing with each other.
    lostCount = nil
    if db.expectedCount and loadedCount < db.expectedCount then
        lostCount = db.expectedCount - loadedCount
        -- The sync marks say what we already hold from each partner, and some of it has
        -- just gone. Dropping them makes the next swap with each one a full one.
        db.syncThrough = nil
    end
    -- Earlier versions kept these two in the saved file, though they only ever
    -- described the session that wrote them.
    db.loadedCount, db.lostCount = nil, nil
    local version, build = GetBuildInfo()
    local regionNames = {[1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN"}
    local regionCode = GetCurrentRegion()
    context = {version = version, build = tostring(build), region = regionNames[regionCode] or "Unknown", regionCode = tostring(regionCode),
        client = "forever", realm = GetRealmName() or "Unknown", faction = UnitFactionGroup("player") or "Unknown"}
    -- Chart labels and icons come from the client, so they stay correct if collection
    -- is unsupported and the window is only used to read data gathered earlier.
    NS.Charts.LoadTaxonomy()
    supported = API and type(API.SendWho) == "function" and type(API.GetNumWhoResults) == "function"
        and type(API.GetWhoInfo) == "function" and type(API.SetWhoToUi) == "function"
        and version:match("^1%.60%.") ~= nil
    if not supported then
        db.settings.enabled = false
        lastMessage = "Requires Forever 1.60.x and C_FriendList who APIs"
    else
        prepareSplits()
        hooksecurefunc(API, "SetWhoToUi", function(value) routeKnown = value end)
        hooksecurefunc(API, "SendWho", function()
            if sending then return end
            -- The API supplies no request ID. Yield to manual Who and other addons.
            local externalRoute = routeKnown
            retryPending("Another who request took priority; waiting 60 seconds")
            restoreWhoWindow()
            API.SetWhoToUi(externalRoute)
            externalUntil = GetTime() + 60
        end)
        if WorldFrame and WorldFrame.HookScript then
            local ok = pcall(WorldFrame.HookScript, WorldFrame, "OnMouseDown", function()
                if db.settings.worldClicks then sendNext(false) end
            end)
            windowHooked = ok
        end
        lastMessage = windowHooked and "Ready; waiting for world clicks outside combat" or "Use Next query; world click hook unavailable"
        restorePass()
        nextSend = GetTime() + Core.Interval(db.settings)
    end
    NS.Sync.Init(db, say, NS.Touch, touch)
    SLASH_FOREVERCENSUS1, SLASH_FOREVERCENSUS2 = "/fc", "/forevercensus"
    SlashCmdList.FOREVERCENSUS = function(input)
        local command, arg = input:match("^(%S*)%s*(.-)$")
        command = command:lower()
        if command == "export" then
            NS.ShowData("Export")
            dataPanel:ShowExport(tonumber(arg) or 1, true)
        elseif command == "import" then NS.ShowData("Import")
        elseif command == "status" then say(statusText())
        elseif command == "data" then NS.ShowData("Characters")
        elseif command == "stats" or command == "charts" then NS.ShowData("Overview")
        elseif command == "guilds" then NS.ShowData("Guilds")
        elseif command == "passes" then NS.ShowData("Passes")
        elseif command == "sync" then
            -- "/fc sync Name all" swaps everything, not just what changed since last time.
            local everyone = arg:match("^(.-)%s+[Aa][Ll][Ll]$")
            if arg:lower() == "cancel" then NS.Sync.Cancel()
            elseif everyone and everyone ~= "" then NS.Sync.Start(everyone, true)
            else NS.Sync.Start(arg) end
            NS.ShowData("Sync")
        elseif command == "autosync" then
            local wanted = arg:lower()
            local on = (wanted == "on") or (wanted ~= "off" and not NS.Sync.AutoEnabled())
            NS.Sync.SetAuto(on)
            say("Automatic sync " .. (on and "on" or "off"))
            NS.ShowData("Sync")
        elseif command == "accept" then NS.Sync.Accept(arg); NS.ShowData("Sync")
        elseif command == "ignore" then NS.Sync.Ignore(); NS.ShowData("Sync")
        elseif command == "forget" then NS.Sync.Forget(arg); NS.ShowData("Sync")
        elseif command == "bnet" then say(NS.Sync.BnetText())
        elseif command == "pause" then
            if db.settings.enabled then toggleEnabled() end
        elseif command == "resume" then
            if not db.settings.enabled then toggleEnabled() end
        elseif command == "interval" then
            db.settings.interval = tonumber(arg) or Core.INTERVAL
            say("Searches now at most every " .. Core.Interval(db.settings) .. " seconds")
            NS.ShowData("Status")
        elseif command == "next" then sendNext(true)
        elseif command == "trends" then NS.ShowData("Trends")
        elseif command == "minimap" then
            db.settings.minimapHidden = not db.settings.minimapHidden or nil
            if launcher then launcher:SetShown(not db.settings.minimapHidden) end
            say(db.settings.minimapHidden and "Minimap button hidden; /fc minimap brings it back" or "Minimap button shown")
        else NS.ShowData("Status") end
    end
    -- A launcher that fails to build must never cost the rest of the addon.
    if not pcall(buildLauncher) then launcher = nil end
    C_Timer.NewTicker(1, function()
        if pending and GetTime() - pending.sent > TIMEOUT then
            scan.consecutiveTimeouts = (scan.consecutiveTimeouts or 0) + 1
            if scan.consecutiveTimeouts >= 3 then
                failClosed("Three who requests timed out; try manual queries")
            else
                retryPending("Who request timed out; waiting 60 seconds before retry")
            end
        end
        if dataPanel and dataPanel:IsShown() then
            -- Redrawing the charts reads every stored character, a noticeable moment on a
            -- big realm (about 70 ms at 17,000). While a sync is pouring characters in,
            -- charts being looked at catch up every 15 seconds, other tabs when it ends;
            -- the Sync tab's own progress stays live either way.
            local waiting = NS.Sync.Busy() and (not FILTERED[dataPanel.tab] or GetTime() - (dataPanel.drawnAt or 0) < 15)
            if dataPanel.dirty and not waiting then dataPanel:Refresh() else dataPanel:RefreshStatus(); dataPanel:RefreshSync() end
        end
    end)
    -- Only the first install announces itself; ordinary gameplay stays quiet.
    if not db.welcomed then
        say("Ready for testing. /fc opens the window. World clicks collect outside combat; /fc sync Name shares with a friend.")
        db.welcomed = true
    end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("WHO_LIST_UPDATE")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, arg, detail, channel, sender)
    if event == "PLAYER_LOGIN" then initialize()
    elseif event == "WHO_LIST_UPDATE" and db then onWho()
    elseif event == "CHAT_MSG_ADDON" and db then NS.Sync.OnMessage(arg, detail, channel, sender)
    elseif event == "ADDON_LOADED" and pending then suppressWhoWindow()
    elseif (event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN") and arg == addonName and db and not stoppedByError then
        failClosed("Client blocked " .. tostring(detail))
    elseif event == "PLAYER_LOGOUT" and db then
        -- WoW writes saved variables here, on /reload and on a clean exit, and at no
        -- other time. An unfinished pass is written out to carry on next login, and
        -- noting the count we hand over lets the next login tell whether the write took.
        pcall(storePass)
        db.lastSaved = GetServerTime()
        db.expectedCount = countRecords()
    end
end)
