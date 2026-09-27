local _, NS = ...
local Sync = {}
NS.Sync = Sync

local PREFIX = "ForeverCensus"
-- WoW disconnects clients that flood the addon channel. ChatThrottleLib, which most
-- addons send through, keeps to 800 bytes a second, counting about 40 for each
-- message's envelope. We send at most one message a tick and stay a little under
-- that: about what four one-character messages a second always came to.
local RATE, MAX_INBOUND = 0.25, 50000
local BYTES, BURST, ENVELOPE = 720, 720, 40
-- The game can also refuse a message outright when it thinks we are sending too fast.
-- A refused message is tried again; if nothing gets through for this long, we stop.
local REFUSED_FOR = 60
-- From 0.8.0 characters travel several to a message (see ROWS below), and whatever
-- repeats from one to the next, like zones, guilds and realms, is only sent once.
local LIMIT, ROW_FIELDS, MAX_WORDS, MAX_CONTEXTS = 250, 9, 8000, 200
-- How long an answer to our own request is still welcome. Accepting takes a person
-- reading chat and clicking, which can easily take longer than the addon's own reply.
-- A request we were sent expires a little sooner, so accepting one always reaches the
-- other side while it is still listening.
local ASK_WINDOW, REQUEST_WINDOW = 900, 840
-- Automatic sync: shortly after login, then every twenty minutes, each partner is
-- offered a swap. Only changes travel, so when nothing is new it is six short
-- messages. The partner's addon does the same at its own login, so whichever of you
-- comes online second, the two of you catch up within a minute.
local AUTO_FIRST, AUTO_GAP, AUTO_EVERY, AUTO_JITTER = 30, 45, 1200, 120
-- A partner who logs out partway through sending says nothing; after this long without
-- a message the transfer is given up, so sync is not stuck for the rest of the session.
local QUIET = 60
-- How many of one partner's characters are offered a swap at once when we cannot tell
-- which one they are on, and how many of their characters are remembered.
local MAX_TRIES, MAX_ALTS = 6, 24
-- A partner on 0.7.1 or later is told every so many characters how far a transfer has
-- got, so one cut short is picked up from there rather than started over.
local CHECKPOINT = 100

local Core, db, say, onChange, onAbsorb
local outbox, sending = {}, nil
local allowance, refusedSince = BURST, nil
local inbound = nil
local asked = {}
-- When each partner is next offered a swap, and names whose "not playing" error the
-- server is about to send back and nobody needs to read.
local autoDue, autoChecked, muted = {}, 0, {}
local notFound

Sync.available, Sync.status, Sync.request = false, "Idle", nil

local function short(name)
    return (name or ""):match("^([^-]+)") or name or "?"
end

-- The same character whether or not the realm was typed or sent with the name.
local function person(name)
    return short(name):lower()
end

local function secret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

local function realmTag()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if type(realm) ~= "string" or realm == "" then realm = ((GetRealmName and GetRealmName()) or ""):gsub("%s+", "") end
    return realm
end

-- A name as we whisper it: our own realm left off, like the names the server hands us.
local function reach(name, realm)
    realm = realm and realm:gsub("%s+", "") or name:match("%-(.+)$")
    local base = short(name)
    if not realm or realm == "" or realm:lower() == realmTag():lower() then return base end
    return base .. "-" .. realm
end

-- Partners are people, not characters. A partner is filed under an id: the lower-case
-- name of the first of their characters we swapped with.
--   db.settings.peers[name]  every character allowed to swap with us, as before 0.7.1
--   db.settings.people[id]   mine: the key we gave them, which any of their characters
--                            shows to be recognised; theirs: the key they gave us; alts:
--                            their other characters; tag: their BattleTag, if they are
--                            one of our Battle.net friends; seen: when we last heard
--                            from the character the id is named after
--   db.syncThrough[id], db.syncVersion[id]
-- A partner from before 0.7.1 has no entry in people and is simply their one
-- character, which is also how 0.7.0 still reads all of this.
local function people()
    db.settings.people = db.settings.people or {}
    return db.settings.people
end

local function owner(name)
    local p = person(name)
    local list = db.settings.people
    if list and not list[p] then
        for id, entry in pairs(list) do
            if entry.alts and entry.alts[p] then return id end
        end
    end
    return p
end

local function entry(id)
    local list = people()
    list[id] = list[id] or {}
    return list[id]
end

-- Somebody we already swap with, rather than just a name.
local function isPartner(id)
    if db.settings.people and db.settings.people[id] then return true end
    for peer in pairs(db.settings.peers or {}) do
        if owner(peer) == id then return true end
    end
    return false
end

-- Every lower-case name one partner is known by.
local function members(id)
    local set = {[id] = true}
    local info = db.settings.people and db.settings.people[id]
    for p in pairs(info and info.alts or {}) do set[p] = true end
    for peer in pairs(db.settings.peers or {}) do
        if owner(peer) == id then set[person(peer)] = true end
    end
    return set
end

local function mine(name)
    return db.myCharacters ~= nil and db.myCharacters[person(name)] ~= nil
end

local function askedFor(sender)
    local when = asked[person(sender)]
    return when ~= nil and GetTime() - when <= ASK_WINDOW
end

-- Incremental sync. After a transfer from someone arrives whole, we keep the moment
-- (by their clock) that they began sending it; next time we tell them, and they send
-- only what changed after it. A transfer cut short keeps the old mark, so whatever
-- went missing is simply asked for again. No mark means send everything. All of a
-- partner's characters share one saved file, so they share one mark: switching
-- character never starts the swap over.
local function mark(name)
    return db.syncThrough and db.syncThrough[owner(name)] or 0
end

local function fields(payload)
    local out = {}
    for value in ((payload or "") .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = value end
    return out
end

local function numbers(payload)
    local out = {}
    for i, value in ipairs(fields(payload)) do out[i] = tonumber(value) end
    return out
end

local function reset()
    outbox, sending, inbound, refusedSince = {}, nil, nil, nil
end

-- Numbers in packed rows are written in base 36: a timestamp takes six characters
-- instead of ten, and the gap between two sightings usually one or two.
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function b36(n)
    if n < 0 then return "-" .. b36(-n) end
    local out = ""
    repeat
        local digit = n % 36
        out = DIGITS:sub(digit + 1, digit + 1) .. out
        n = (n - digit) / 36
    until n == 0
    return out
end

local function unb36(text)
    if type(text) ~= "string" or #text > 12 or not text:find("^%-?[0-9a-z]+$") then return nil end
    if text:sub(1, 1) == "-" then
        local value = tonumber(text:sub(2), 36)
        return value and -value
    end
    return tonumber(text, 36)
end

local function integral(n)
    return type(n) == "number" and n == math.floor(n) and n > -2 ^ 50 and n < 2 ^ 50
end

local function push(target, kind, payload)
    outbox[#outbox + 1] = {target = target, body = payload and (kind .. "\t" .. payload) or kind}
end

local function trusted(name)
    return db.settings.peers and db.settings.peers[name] ~= nil
end

-- The Sync tab reads this every second. It is not a change to the data, so it must not
-- make the window redraw its charts: on a big realm that redraw is a visible hitch.
local function note(text)
    Sync.status = text
end

function Sync.AutoEnabled()
    return db.settings.autoSync ~= false
end

-- A swap with someone has just begun, so their next automatic one waits its turn.
local function postpone(id)
    autoDue[id] = GetTime() + AUTO_EVERY + math.random(0, AUTO_JITTER)
end

-- The sync version a partner's addon last told us. Before 0.6.1 it cannot say what it
-- already has, so every swap with it is a full one both ways; offered every twenty
-- minutes, that would be forty minutes of traffic on a loop. Such a partner is only
-- swapped with when one of you asks. From version 3 (0.7.1) it knows its partners
-- as people, so it is told our key and our characters.
local function versionOf(id)
    return db.syncVersion and db.syncVersion[id]
end

local function tooOld(id)
    local version = versionOf(id)
    return version ~= nil and version < 2
end

local function heard(sender, version)
    if not version then return end
    db.syncVersion = db.syncVersion or {}
    db.syncVersion[owner(sender)] = version
end

-- Keys. When two partners swap, each gives the other a random key. Any of their
-- characters that shows ours is them, however new the character; the key only ever
-- travels by whisper between the two of you.
local KEY_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

local function newKey()
    local out = {}
    for i = 1, 20 do
        local n = math.random(1, #KEY_CHARS)
        out[i] = KEY_CHARS:sub(n, n)
    end
    return table.concat(out)
end

local function validKey(key)
    return type(key) == "string" and #key >= 12 and #key <= 32 and key:match("^%w+$") ~= nil
end

local function holder(key)
    for id, info in pairs(db.settings.people or {}) do
        if info.mine == key or info.also == key then return id end
    end
end

local function keep(list, cap)
    local order = {}
    for p, alt in pairs(list) do order[#order + 1] = {p = p, seen = alt.seen or 0} end
    if #order <= cap then return end
    table.sort(order, function(a, b) return a.seen > b.seen end)
    for i = cap + 1, #order do list[order[i].p] = nil end
end

-- One partner turns out to be another one's character: two ids for the same person,
-- from characters swapped with one at a time before 0.7.1, or both of you meeting on
-- characters the other had never seen. Everything of `from` is filed under `into`.
local function merge(from, into)
    if from == into then return end
    local list = people()
    local names = {}
    for peer in pairs(db.settings.peers or {}) do
        if owner(peer) == from then names[#names + 1] = peer end
    end
    local target, old = entry(into), list[from]
    target.alts = target.alts or {}
    for _, peer in ipairs(names) do
        local p = person(peer)
        if p ~= into then
            local seen = (p == from and old and old.seen) or (old and old.alts and old.alts[p] and old.alts[p].seen) or 0
            target.alts[p] = {name = peer, seen = seen}
        end
    end
    if old then
        for p, alt in pairs(old.alts or {}) do
            if p ~= into and not target.alts[p] then target.alts[p] = alt end
        end
        if old.mine and old.mine ~= target.mine then
            if target.mine then target.also = old.mine else target.mine = old.mine end
        end
        target.theirs = target.theirs or old.theirs
        target.tag = target.tag or old.tag
    end
    list[from] = nil
    keep(target.alts, MAX_ALTS)
    -- Both chains of swaps came out of the same saved file, and each one holds
    -- everything up to its own mark, so the later mark holds for the partner.
    for _, map in ipairs({db.syncThrough or {}, db.syncVersion or {}}) do
        if map[from] then
            map[into] = math.max(map[into] or 0, map[from])
            map[from] = nil
        end
    end
    autoDue[from] = nil
end

-- When we first accepted any of a partner's characters.
local function firstAccepted(id)
    local first
    for peer, at in pairs(db.settings.peers or {}) do
        if owner(peer) == id and (not first or at < first) then first = at end
    end
    return first or math.huge
end

-- Two ids for one partner become one, under whichever we accepted first, so the name
-- you know them by stays the same. Returns the one that is left.
local function join(a, b)
    if firstAccepted(b) < firstAccepted(a) then a, b = b, a end
    merge(b, a)
    return a
end

-- A character proved to be partner `id`: by showing our key, or by Battle.net.
local function adopt(name, id)
    local was, p = owner(name), person(name)
    if was ~= id and isPartner(was) then
        if was == p then
            id = join(was, id)
        else
            -- Listed as someone else's character, but the key says otherwise.
            local other = db.settings.people[was]
            if other and other.alts then other.alts[p] = nil end
        end
    end
    db.settings.peers[name] = db.settings.peers[name] or GetServerTime()
    local info = entry(id)
    if p == id then
        info.seen = GetServerTime()
    else
        info.alts = info.alts or {}
        info.alts[p] = {name = name, seen = GetServerTime()}
        keep(info.alts, MAX_ALTS)
    end
    return id
end

-- Heard from a partner's character: it is the one they are playing now.
local function touched(name)
    local info, p = db.settings.people and db.settings.people[owner(name)], person(name)
    if not info then return end
    if p == owner(name) then info.seen = GetServerTime()
    elseif info.alts and info.alts[p] then info.alts[p].seen = GetServerTime() end
end

-- The characters this saved file has been played on, so partners know which of them to
-- look for. WoW Forever hands the surname back as UnitName's second value.
local function noteSelf()
    if not UnitName then return end
    local first, surname = (UnitNameUnmodified or UnitName)("player")
    if type(first) ~= "string" or first == "" or secret(first) then return end
    local name = first
    if type(surname) == "string" and surname ~= "" and not secret(surname) then
        local separator = Constants and Constants.CharacterNameSeparatorConsts
            and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR or " "
        local tail = separator .. surname
        if first:sub(-#tail) ~= tail then name = first .. tail end
    end
    db.myCharacters = db.myCharacters or {}
    db.myCharacters[person(name)] = {name = name, realm = realmTag(), seen = GetServerTime()}
    keep(db.myCharacters, MAX_ALTS)
end

local function ownNames()
    local list = {}
    for _, char in pairs(db.myCharacters or {}) do list[#list + 1] = char end
    table.sort(list, function(a, b) return (a.seen or 0) > (b.seen or 0) end)
    local names = {}
    for i, char in ipairs(list) do
        names[i] = short(char.name) .. ((char.realm and char.realm ~= "") and ("-" .. char.realm) or "")
    end
    return names
end

-- Battle.net. A partner who is also a Battle.net friend can be found on whatever
-- character they are playing, even one neither addon has seen. Their BattleTag is
-- noted, on this computer only, the first time a swap shows which friend they are.
-- Returns the friends playing this game in this region, as {tag, name, realm}.
local function bnetPlaying()
    local out = {}
    local api = C_BattleNet
    if not (api and type(api.GetFriendAccountInfo) == "function" and type(BNGetNumFriends) == "function") then
        return out, false
    end
    local ok, total = pcall(BNGetNumFriends)
    if not ok or type(total) ~= "number" then return out, false end
    for i = 1, math.min(total, 200) do
        local okInfo, info = pcall(api.GetFriendAccountInfo, i)
        local tag = okInfo and type(info) == "table" and info.battleTag
        if type(tag) == "string" and not secret(tag) then
            local games = {}
            local okCount, count = false, nil
            if type(api.GetFriendNumGameAccounts) == "function" then okCount, count = pcall(api.GetFriendNumGameAccounts, i) end
            if okCount and type(count) == "number" and count > 0 and type(api.GetFriendGameAccountInfo) == "function" then
                for j = 1, math.min(count, 8) do
                    local okGame, game = pcall(api.GetFriendGameAccountInfo, i, j)
                    if okGame and type(game) == "table" then games[#games + 1] = game end
                end
            elseif type(info.gameAccountInfo) == "table" then
                games[1] = info.gameAccountInfo
            end
            for _, game in ipairs(games) do
                local name, realm = game.characterName, game.realmName or game.realmDisplayName
                local sameGame = (game.clientProgram == nil or BNET_CLIENT_WOW == nil or game.clientProgram == BNET_CLIENT_WOW)
                    and (game.wowProjectID == nil or WOW_PROJECT_ID == nil or game.wowProjectID == WOW_PROJECT_ID)
                if game.isOnline ~= false and game.isInCurrentRegion ~= false and sameGame
                    and type(name) == "string" and name ~= "" and not secret(name)
                    and type(realm) == "string" and realm ~= "" and not secret(realm) then
                    out[#out + 1] = {tag = tag, name = short(name), realm = realm:gsub("%s+", "")}
                end
            end
        end
    end
    return out, true
end

-- Battle.net may give a character's first name only. That is enough to pick one of a
-- partner's known characters, never enough to whisper someone new: first names repeat.
local function firstName(name)
    return person(name):match("^(%S+)")
end

local function learnTag(name, id)
    local info = db.settings.people and db.settings.people[id]
    if info and info.tag then return end
    local friends, usable = bnetPlaying()
    if not usable or #friends == 0 then return end
    local want, hits = person(name), {}
    for _, friend in ipairs(friends) do
        local got = person(friend.name)
        if got == want or (not got:find(" ", 1, true) and got == firstName(want)) then hits[#hits + 1] = friend end
    end
    if #hits == 1 then entry(id).tag = hits[1].tag end
end

local function bnetFind(peer)
    if not peer.tag then return nil end
    for _, friend in ipairs((bnetPlaying())) do
        if friend.tag == peer.tag then
            if friend.name:find(" ", 1, true) then return reach(friend.name, friend.realm), true end
            local match
            for _, known in ipairs(peer.all) do
                if firstName(known) == person(friend.name) then
                    if match then return nil end
                    match = known
                end
            end
            return match
        end
    end
end

-- True or false when the friends list knows; nil when they are not on it.
local function online(name)
    local api = C_FriendList
    if not (api and api.GetFriendInfo) then return nil end
    local ok, info = pcall(api.GetFriendInfo, name)
    if ok and type(info) == "table" and info.connected ~= nil then return info.connected and true or false end
    return nil
end

-- Which of a partner's characters to offer a swap: the one Battle.net says they are
-- on, or else the ones most recently played, all at once, since only the one online
-- can answer.
local function targets(peer)
    local found, verified = bnetFind(peer)
    if found then
        if verified then adopt(found, peer.id) end
        return {found}
    end
    local info = db.settings.people and db.settings.people[peer.id]
    local list, seen = {}, {}
    local function add(name, when)
        local p = person(name)
        if seen[p] or mine(name) then return end
        seen[p] = true
        if online(name) == false then return end
        list[#list + 1] = {name = name, when = when or 0}
    end
    for _, name in ipairs(peer.names) do
        local p = person(name)
        local alt = info and info.alts and info.alts[p]
        add(name, (p == peer.id and info and info.seen) or (alt and alt.seen) or db.settings.peers[name])
    end
    for _, alt in pairs(info and info.alts or {}) do add(alt.name, alt.seen) end
    table.sort(list, function(a, b)
        if a.when ~= b.when then return a.when > b.when end
        return a.name < b.name
    end)
    local out = {}
    for i = 1, math.min(#list, MAX_TRIES) do out[i] = list[i].name end
    return out
end

local start

local function autoTick()
    local now = GetTime()
    if now - autoChecked < 1 then return end
    autoChecked = now
    if not Sync.available or not Sync.AutoEnabled() then return end
    -- A request waiting for your answer holds automatic offers back, but only while it
    -- can still be accepted; one left unanswered must not hold them up for ever.
    local waiting = Sync.request and now - (Sync.requestAt or 0) <= REQUEST_WINDOW
    if sending or inbound or Sync.pending or waiting then return end
    for index, peer in ipairs(Sync.Peers()) do
        autoDue[peer.id] = autoDue[peer.id] or now + AUTO_FIRST + (index - 1) * AUTO_GAP
        if now >= autoDue[peer.id] and not tooOld(peer.id) then
            postpone(peer.id)
            -- A friend the game shows as offline is not asked at all.
            local names = targets(peer)
            if #names > 0 then
                start(names, false, true, short(peer.name), peer.id)
                return
            end
        end
    end
end

-- The server answers a whisper to someone offline with "No player named X is currently
-- playing". After an automatic offer that line is expected and says nothing useful, so
-- it is hidden, for that name and for a few seconds only. The same line in the middle
-- of sending means they have gone: sending stops, instead of the rest of the transfer
-- putting one of those lines in chat four times a second.
local function gone(message)
    if not notFound or type(message) ~= "string" or secret(message) then return nil end
    local who = message:match(notFound)
    if who and sending and person(sending.target) == person(who) then
        local target = sending.target
        reset()
        muted[person(who)] = GetTime() + 15
        note(short(target) .. " went offline partway through; the next swap carries on from where this one stopped")
    end
    return who
end

local function hideOffline(_, _, message)
    local who = gone(message)
    if not who then return false end
    local until_ = muted[person(who)]
    return until_ ~= nil and GetTime() <= until_
end

-- Packed rows, for a partner on 0.8.0 or later. A row is nine tab separated fields:
--   context, name, level, race, class, guild, zone, days seen, last seen
-- context stands for region, client, the name's realm, the realm and faction it was
-- seen from, and the build, defined once by a CTX message. race, class, guild and zone
-- are words, defined once by DEF messages. The numbers are base 36: level stays
-- decimal, "days seen" is lastSeen - firstSeen, and last seen is the gap from the row
-- before it in the same message, or the timestamp itself for the first row. Anything
-- that cannot be packed this way goes as an ordinary REC instead.
local function word(value)
    value = tostring(value or "")
    local index = sending.words[value]
    if not index then
        sending.wordList[#sending.wordList + 1] = value
        index = #sending.wordList
        sending.words[value] = index
    end
    return index
end

local function packed(item)
    if item.cells ~= nil then return item.cells end
    item.cells = false
    local record = db.records[item.key]
    if not record or not Core.Encode(record) then return false end
    local name, realm = tostring(record.fullName):match("^(.+)%-([^-]+)$")
    local level, first, last = tonumber(record.level), tonumber(record.firstSeen), tonumber(record.lastSeen)
    if not name or not (integral(level) and integral(first) and integral(last)) then return false end
    local context = table.concat({tostring(record.region), tostring(record.client), realm,
        tostring(record.observerRealm), tostring(record.observerFaction), tostring(record.build or "")}, "\t")
    if #context + 12 > LIMIT then return false end
    local ctx = sending.contexts[context]
    if not ctx then
        sending.contextList[#sending.contextList + 1] = context
        ctx = #sending.contextList
        sending.contexts[context] = ctx
    end
    if ctx > MAX_CONTEXTS or #sending.wordList + 4 > MAX_WORDS then return false end
    local refs = {word(record.race), word(record.class), word(record.guild), word(record.zone)}
    local cells = table.concat({b36(ctx), name, tostring(level), b36(refs[1]), b36(refs[2]),
        b36(refs[3]), b36(refs[4]), b36(last - first)}, "\t")
    if #cells + 16 > LIMIT - 5 then return false end
    item.cells, item.ctx, item.refs, item.last = cells, ctx, refs, last
    return cells
end

-- What goes next when the head of the outbox is a row for a packing partner: as many
-- rows as fit one message, once everything they refer to has been defined; until then
-- the definitions they need. Returns the message, how many outbox entries it uses up,
-- how many rows it carries, and what to note down once it has gone. Nothing, when the
-- first row cannot be packed.
local function nextPacked()
    local target = outbox[1].target
    local rows, size, previous = {}, 4, nil
    local needContext, needWords, listed = nil, {}, {}
    for _, item in ipairs(outbox) do
        if not item.key or item.target ~= target or not packed(item) then break end
        local row = item.cells .. "\t" .. b36(previous and item.last - previous or item.last)
        if size + 1 + #row > LIMIT then break end
        if not sending.contextSent[item.ctx] then needContext = needContext or item.ctx end
        for _, ref in ipairs(item.refs) do
            if not sending.wordSent[ref] and not listed[ref] then
                listed[ref] = true
                needWords[#needWords + 1] = ref
            end
        end
        rows[#rows + 1] = row
        size, previous = size + 1 + #row, item.last
    end
    if #rows == 0 then return nil end
    if needContext then
        return "CTX\t" .. b36(needContext) .. "\t" .. sending.contextList[needContext], 0, 0,
            function() sending.contextSent[needContext] = true end
    end
    if #needWords > 0 then
        table.sort(needWords)
        local parts, length, defined = {"DEF"}, 3, {}
        for _, ref in ipairs(needWords) do
            local pair = b36(ref) .. "\t" .. sending.wordList[ref]
            if #defined > 0 and length + 1 + #pair > LIMIT then break end
            parts[#parts + 1] = pair
            length = length + 1 + #pair
            defined[#defined + 1] = ref
        end
        return table.concat(parts, "\t"), 0, 0,
            function() for _, ref in ipairs(defined) do sending.wordSent[ref] = true end end
    end
    return "ROWS\t" .. table.concat(rows, "\t"), #rows, #rows
end

-- The game answers a send with a result: nothing or true on older clients, a code on
-- newer ones. Being told we are going too fast is not the same as the message going.
local function refused(result)
    if result == false then return true end
    if type(result) ~= "number" or result == 0 then return false end
    local codes = Enum and Enum.SendAddonMessageResult or {}
    return result == (codes.AddonMessageThrottle or 3) or result == (codes.ChannelThrottle or 8)
        or result == (codes.GeneralError or 9)
end

-- At most one message per tick, and only while the byte allowance covers it.
local function drain()
    autoTick()
    -- An offline name, a typo or a friend without the addon would otherwise leave the
    -- tab saying "waiting" forever, which is indistinguishable from a broken sync.
    if Sync.pending and GetTime() > (Sync.pendingUntil or 0) then
        local name = short(Sync.pending)
        local automatic = Sync.pendingAuto
        Sync.pending, Sync.pendingFor, Sync.pendingId, Sync.pendingAuto = nil, nil, nil, false
        if automatic then
            note(name .. " is not online right now; automatic sync will try again later")
        else
            note("No answer from " .. name .. " yet. If they accept within fifteen minutes the swap still starts; otherwise check they are online on this realm with Forever Census running.")
        end
    end
    if inbound and GetTime() - (inbound.last or 0) > QUIET then
        local from = inbound.from
        inbound = nil
        Sync.loud = false
        note(short(from) .. " stopped sending partway through; the next swap carries on from where this one stopped")
    end
    allowance = math.min(BURST, allowance + BYTES * RATE)
    local message = outbox[1]
    if not message then
        if sending and sending.finished then
            local text
            if sending.total == 0 and sending.known > 0 then
                text = "Nothing new for " .. short(sending.target) .. " since your last swap"
            else
                text = string.format("Sent %d characters to %s", sending.total, short(sending.target))
                if sending.known > 0 then
                    text = text .. string.format(" (%d they already had were not sent again)", sending.known)
                end
            end
            if sending.skipped > 0 then
                local left = string.format("%d characters are too long to send over the addon channel and were left out; CSV export still includes them", sending.skipped)
                text = text .. ". " .. left
                if Sync.loud then say(left) end
            end
            if sending.held > 0 then
                text = text .. string.format(". The game asked for a slower pace %d times; those messages were sent again, so nothing is missing", sending.held)
            end
            note(text)
            sending = nil
        end
        return
    end
    local body, uses, rows, sent
    if message.key and sending and sending.packs then body, uses, rows, sent = nextPacked() end
    if not body then
        body, uses, rows = message.body, 1, 0
        if message.key then
            -- A record too long for one 255 byte message is reported rather than dropped
            -- in silence (a long first and last name plus a long guild can reach it). An
            -- empty row goes in its place, so the count still adds up at the other end
            -- and the swap still counts as whole.
            local record = db.records[message.key]
            local line = record and Core.Encode(record)
            if not line and sending then
                sent = function() sending.skipped = sending.skipped + 1 end
            end
            body, rows = "REC\t" .. (line or ""), 1
        end
    end
    local cost = #body + ENVELOPE
    if allowance < cost then return end
    if refused(C_ChatInfo.SendAddonMessage(PREFIX, body, "WHISPER", message.target)) then
        -- It stays at the front of the queue for the next tick, and the pace drops back.
        allowance = 0
        if sending then sending.held = sending.held + 1 end
        refusedSince = refusedSince or GetTime()
        if GetTime() - refusedSince >= REFUSED_FOR then
            local target = message.target
            if sending then
                reset()
                note("The game would not send anything to " .. short(target) .. " for a minute, so the swap stopped; the next one carries on from where it got to")
            else
                table.remove(outbox, 1)
                refusedSince = nil
            end
        end
        return
    end
    refusedSince = nil
    allowance = allowance - cost
    for _ = 1, uses do table.remove(outbox, 1) end
    if sent then sent() end
    if sending and rows > 0 then
        local before = sending.sent
        sending.sent = sending.sent + rows
        if math.floor(sending.sent / 20) > math.floor(before / 20) or sending.sent == sending.total then
            note(string.format("Sending to %s: %d / %d", short(sending.target), sending.sent, sending.total))
        end
    end
end

-- A partner on 0.7.1 or later is given our key and told our characters, at the start
-- of every swap, which keeps both up to date for a few short messages.
local function introduce(target)
    local id = owner(target)
    if (versionOf(id) or 0) < 3 then return end
    local info = entry(id)
    info.mine = info.mine or newKey()
    push(target, "KEY", info.mine)
    local line, size = {}, 0
    for _, name in ipairs(ownNames()) do
        if #line > 0 and size + #name + 1 > Core.MAX_MESSAGE - 5 then
            push(target, "ALTS", table.concat(line, "\t"))
            line, size = {}, 0
        end
        line[#line + 1] = name
        size = size + #name + 1
    end
    if #line > 0 then push(target, "ALTS", table.concat(line, "\t")) end
end

-- since is the other side's mark for us: 0 (or a version 1 partner, which sends none)
-- means they want everything. Otherwise only what changed here from that moment on is
-- sent, less anything that came from them in the first place, on any character.
local function beginSend(target, since)
    since = tonumber(since) or 0
    local from = members(owner(target))
    local started = GetServerTime()
    -- Rows are gathered by the moment they last changed, oldest first, and each is only
    -- encoded as it is sent. Encoding a whole realm up front froze the game for a fifth
    -- of a second at seventeen thousand characters, and kept megabytes of text waiting.
    local moments, byMoment, total, known = {}, {}, 0, 0
    for key, record in pairs(db.records) do
        local changed = Core.ChangedAt(record)
        if since <= 0 or (changed >= since and not from[record.via or ""]) then
            local bucket = byMoment[changed]
            if not bucket then
                bucket = {}
                byMoment[changed] = bucket
                moments[#moments + 1] = changed
            end
            bucket[#bucket + 1] = key
            total = total + 1
        else
            known = known + 1
        end
    end
    table.sort(moments)
    postpone(owner(target))
    introduce(target)
    sending = {target = target, sent = 0, total = total, skipped = 0, known = known, held = 0, finished = false,
        packs = (versionOf(owner(target)) or 0) >= 4,
        words = {}, wordList = {}, wordSent = {}, contexts = {}, contextList = {}, contextSent = {}}
    push(target, "START", total)
    local checkpoints = (versionOf(owner(target)) or 0) >= 3
    local queued, unmarked = 0, 0
    for i, moment in ipairs(moments) do
        local bucket = byMoment[moment]
        table.sort(bucket)
        for _, key in ipairs(bucket) do outbox[#outbox + 1] = {target = target, key = key} end
        queued, unmarked = queued + #bucket, unmarked + #bucket
        -- "The rows so far are everything changed before the next moment": if all of
        -- them arrive, it is a mark they can keep. It can only go between two moments,
        -- and one search stamps up to fifty characters with the same second, so it goes
        -- at the first change after every hundred rows.
        local following = moments[i + 1]
        if checkpoints and unmarked >= CHECKPOINT and following then
            push(target, "MARK", following .. "\t" .. queued)
            unmarked = 0
        end
    end
    -- The moment we started is what they keep as their mark for us, but only if all
    -- of it arrives.
    push(target, "END", total .. "\t" .. started)
    sending.finished = true
    if total == 0 then
        note("Nothing new for " .. short(target) .. " since your last swap")
    else
        note(string.format("Sending to %s: 0 / %d", short(target), total))
    end
end

-- HELLO: version, our mark for them, 1 when automatic, and the key they gave us.
-- Before 0.7.1 there was no key, and the automatic flag was left off when not set;
-- older addons read the numbers they know and ignore the rest.
local function hello(name, everything, automatic)
    local info = db.settings.people and db.settings.people[owner(name)]
    local key = info and info.theirs
    local body = Core.SYNC_VERSION .. "\t" .. (everything and 0 or mark(name))
    if automatic or key then body = body .. "\t" .. (automatic and 1 or 0) end
    if key then body = body .. "\t" .. key end
    return body
end

local function yes(name)
    local info = db.settings.people and db.settings.people[owner(name)]
    local key = info and info.theirs
    return Core.SYNC_VERSION .. "\t" .. mark(name) .. (key and ("\t" .. key) or "")
end

-- everything: ask them for all they have, and send them all we have, whatever was
-- swapped before. automatic: offered by the timer rather than by you, which keeps it
-- out of chat and tells an addon that has not accepted us to decline without asking.
-- names: one character, or several of one partner's when we cannot tell which of them
-- is online; label is what the Sync tab calls them meanwhile.
start = function(names, everything, automatic, label, id)
    if not Sync.available then say("This client has no addon messaging; sync is unavailable"); return end
    if type(names) ~= "table" then
        local name = type(names) == "string" and names:match("^%s*(.-)%s*$") or ""
        if name == "" then say("Use /fc sync CharacterName"); return end
        names = {name}
    end
    if sending or inbound then say("A sync is already running. /fc sync cancel stops it"); return end
    reset()
    Sync.pending = label or names[1]
    Sync.pendingFor, Sync.pendingId = {}, id or owner(names[1])
    Sync.pendingUntil = GetTime() + 30
    Sync.pendingAuto = automatic and true or false
    Sync.everything = everything and true or false
    Sync.loud = not automatic
    for _, name in ipairs(names) do
        Sync.pendingFor[person(name)] = true
        asked[person(name)] = GetTime()
        -- Offers to characters we only guessed at stay out of chat when they are offline.
        if automatic or #names > 1 then muted[person(name)] = GetTime() + 15 end
        push(name, "HELLO", hello(name, everything, automatic))
    end
    if automatic then
        note("Automatic sync: checking with " .. short(Sync.pending) .. " for anything new")
    else
        note("Asked " .. short(Sync.pending) .. " to share. Waiting for their addon to answer.")
    end
end

-- Asking a partner by any of their names reaches them on whichever character they are
-- playing; the name you typed goes first.
function Sync.Start(name, everything)
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    local id = name ~= "" and owner(name)
    if id and isPartner(id) then
        for _, peer in ipairs(Sync.Peers()) do
            if peer.id == id then
                local names = {name}
                for _, other in ipairs(targets(peer)) do
                    if person(other) ~= person(name) then names[#names + 1] = other end
                end
                start(names, everything, false, name, id)
                return
            end
        end
    end
    start(name, everything, false)
end

function Sync.SetAuto(on)
    db.settings.autoSync = on and true or false
    note(on and "Automatic sync is on" or "Automatic sync is off")
end

function Sync.AutoText()
    if not Sync.available then return "Unavailable on this client" end
    if not Sync.AutoEnabled() then return "Off. Swaps only happen when you or a partner starts one." end
    local text = "On: with every partner, on whichever of your characters you are both playing, shortly after either of you logs in, then every 20 minutes while you are both online."
    local soonest, old, behind, slower = nil, {}, {}, {}
    for _, peer in ipairs(Sync.Peers()) do
        local due = autoDue[peer.id]
        local version = versionOf(peer.id)
        if tooOld(peer.id) then
            old[#old + 1] = short(peer.name)
        elseif due and (not soonest or due < soonest) then
            soonest = due
        end
        if version == 2 then behind[#behind + 1] = short(peer.name) end
        if version == 3 then slower[#slower + 1] = short(peer.name) end
    end
    if soonest then
        text = text .. string.format(" Next in about %d min.", math.max(0, math.ceil((soonest - GetTime()) / 60)))
    end
    if #old > 0 then
        text = text .. " " .. table.concat(old, ", ") .. " should update Forever Census first; until then, only swaps one of you starts."
    end
    if #behind > 0 then
        text = text .. " " .. table.concat(behind, ", ") .. " needs Forever Census 0.7.1 for swaps on other characters to happen by themselves."
    end
    if #slower > 0 then
        text = text .. " " .. table.concat(slower, ", ") .. " is on an older Forever Census, which takes characters one per message; from 0.8.0 a big swap is about four times as quick."
    end
    return text
end

function Sync.Accept(name)
    if not Sync.request then say("Nobody has asked to share"); return end
    if name and name ~= "" and short(name):lower() ~= short(Sync.request):lower() then
        say(short(Sync.request) .. " is the one waiting; /fc accept confirms them")
        return
    end
    local peer = Sync.request
    Sync.request = nil
    if GetTime() - (Sync.requestAt or 0) > REQUEST_WINDOW then
        say(short(peer) .. " asked too long ago for the answer to reach them. Use Share with them to ask them instead.")
        note("Idle")
        return
    end
    db.settings.peers = db.settings.peers or {}
    db.settings.peers[peer] = GetServerTime()
    heard(peer, Sync.requestVersion)
    learnTag(peer, owner(peer))
    touched(peer)
    Sync.loud = true
    push(peer, "YES", yes(peer))
    beginSend(peer, Sync.requestSince)
end

function Sync.Ignore()
    if not Sync.request then return end
    push(Sync.request, "NO")
    say("Ignoring " .. short(Sync.request) .. ". They stay untrusted until you accept them.")
    Sync.request = nil
    note("Idle")
end

function Sync.Cancel()
    local target = (sending and sending.target) or (inbound and inbound.from) or Sync.pending
    reset()
    Sync.pending, Sync.pendingFor, Sync.pendingId, Sync.request, Sync.everything = nil, nil, nil, nil, false
    Sync.pendingAuto, Sync.loud = false, false
    asked = {}
    if target then push(target, "BYE") end
    note("Cancelled")
end

-- Forgetting a partner forgets all of their characters.
function Sync.Forget(name)
    if not db.settings.peers or type(name) ~= "string" or name:match("^%s*$") then return end
    local id = owner(name:match("^%s*(.-)%s*$"))
    local gone = {}
    for peer in pairs(db.settings.peers) do
        if owner(peer) == id then gone[#gone + 1] = peer end
    end
    local info = db.settings.people and db.settings.people[id]
    if #gone == 0 and not info then return end
    local shown, others = nil, {}
    for _, peer in ipairs(gone) do
        if person(peer) == id then shown = short(peer) else others[#others + 1] = short(peer) end
    end
    for p, alt in pairs(info and info.alts or {}) do
        if not shown or p ~= person(shown) then
            local listed = false
            for _, other in ipairs(others) do if person(other) == p then listed = true end end
            if not listed then others[#others + 1] = short(alt.name) end
        end
    end
    for _, peer in ipairs(gone) do
        db.settings.peers[peer] = nil
        if db.syncThrough then db.syncThrough[person(peer)] = nil end
        if db.syncVersion then db.syncVersion[person(peer)] = nil end
    end
    if db.syncThrough then db.syncThrough[id] = nil end
    if db.syncVersion then db.syncVersion[id] = nil end
    if db.settings.people then db.settings.people[id] = nil end
    autoDue[id] = nil
    table.sort(others)
    shown = shown or table.remove(others, 1) or short(name)
    say("Removed " .. shown .. " from your sync partners"
        .. (#others > 0 and (", with their other characters " .. table.concat(others, ", ")) or ""))
end

-- One entry per partner, however many characters they have: id, name (the character
-- they are filed under), names (their characters allowed to swap), all (every one of
-- their characters we know of), since, through and tag.
function Sync.Peers()
    local byId, list = {}, {}
    for name, since in pairs(db.settings.peers or {}) do
        local id = owner(name)
        local peer = byId[id]
        if not peer then
            peer = {id = id, names = {}, since = since, through = db.syncThrough and db.syncThrough[id] or 0}
            byId[id] = peer
            list[#list + 1] = peer
        end
        peer.names[#peer.names + 1] = name
        peer.since = math.min(peer.since, since)
        if person(name) == id then peer.name = name end
    end
    for _, peer in ipairs(list) do
        table.sort(peer.names)
        peer.name = peer.name or peer.names[1]
        local info = db.settings.people and db.settings.people[peer.id]
        peer.tag = info and info.tag
        peer.all = {}
        local seen = {}
        for _, name in ipairs(peer.names) do
            seen[person(name)] = true
            peer.all[#peer.all + 1] = name
        end
        for p, alt in pairs(info and info.alts or {}) do
            if not seen[p] then peer.all[#peer.all + 1] = alt.name end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local handlers = {}

function handlers.HELLO(sender, payload)
    if sending or inbound then push(sender, "NO", "busy"); return end
    local values = fields(payload)
    local version, since = tonumber(values[1]), tonumber(values[2]) or 0
    local automatic, key = values[3] == "1", validKey(values[4]) and values[4] or nil
    -- Our key: one of a partner's characters, however new to us.
    local id = key and holder(key)
    if id then adopt(sender, id) end
    if trusted(sender) then
        heard(sender, version)
        learnTag(sender, owner(sender))
        touched(sender)
        -- Their swap, not ours: nothing about it needs to reach our chat.
        if not Sync.pending then Sync.loud = false end
        -- The partner we were waiting on got to us first, perhaps on another character.
        if Sync.pendingId and Sync.pendingId == owner(sender) then
            Sync.pending, Sync.pendingFor, Sync.pendingId, Sync.pendingAuto = nil, nil, nil, false
        end
        push(sender, "YES", yes(sender))
        beginSend(sender, since)
        return
    end
    -- An automatic offer from someone we have not accepted is declined without a word.
    -- Only a person asking in person gets a line in chat.
    if automatic then push(sender, "NO", "new"); return end
    -- Asking again and again only puts the line in chat once a minute.
    local repeated = Sync.request == sender and GetTime() - (Sync.requestAt or 0) < 60
    Sync.request, Sync.requestAt, Sync.requestSince, Sync.requestVersion = sender, GetTime(), since, version
    note(short(sender) .. " wants to share census data")
    if not repeated then
        say(short(sender) .. " wants to share census data. |cffffd100/fc accept|r to swap, |cffffd100/fc ignore|r to refuse.")
    end
end

-- YES is only ever an answer to a request we made. Taking one from anyone else would
-- make them a trusted partner and start sending them everything.
function handlers.YES(sender, payload)
    if not askedFor(sender) then return end
    asked[person(sender)] = nil
    if Sync.pendingFor and Sync.pendingFor[person(sender)] then
        Sync.pending, Sync.pendingFor, Sync.pendingId, Sync.pendingAuto = nil, nil, nil, false
    end
    local values = fields(payload)
    local key = validKey(values[3]) and values[3] or nil
    local id = key and holder(key)
    if id then adopt(sender, id) end
    db.settings.peers = db.settings.peers or {}
    db.settings.peers[sender] = db.settings.peers[sender] or GetServerTime()
    heard(sender, tonumber(values[1]))
    learnTag(sender, owner(sender))
    touched(sender)
    local since = Sync.everything and 0 or (tonumber(values[2]) or 0)
    Sync.everything = false
    if not sending then beginSend(sender, since) end
end

-- NO says why, from 0.7.1: busy with another swap, or a character not accepted yet.
function handlers.NO(sender, payload)
    local ours = sending ~= nil and sending.target == sender
    if not ours and not askedFor(sender) then return end
    if ours then reset() end
    asked[person(sender)] = nil
    local automatic = Sync.pendingAuto
    if Sync.pendingFor and Sync.pendingFor[person(sender)] then
        Sync.pending, Sync.pendingFor, Sync.pendingId, Sync.pendingAuto = nil, nil, nil, false
    end
    if payload == "busy" then
        note(short(sender) .. " is busy with another swap; " .. (automatic and "automatic sync will try again later" or "try again in a minute"))
    elseif payload == "new" then
        note(short(sender) .. " has not accepted this character yet. Share with them once from here and it is remembered.")
    else
        note(short(sender) .. " declined or is busy")
    end
end

-- The key a partner gave us, to show whichever of our characters we are on.
function handlers.KEY(sender, payload)
    if not trusted(sender) or not validKey(payload) then return end
    entry(owner(sender)).theirs = payload
end

-- A partner's characters, newest first, so we know whom to look for. Characters of
-- theirs we had filed as a partner of their own are brought together with them.
function handlers.ALTS(sender, payload)
    if not trusted(sender) then return end
    local id = owner(sender)
    local now = GetServerTime()
    local count = 0
    for i, raw in ipairs(fields(payload)) do
        if count >= MAX_ALTS then break end
        if raw ~= "" and #raw <= 64 and not raw:find("[%c|]") then
            count = count + 1
            local name, p = reach(raw), person(raw)
            if not mine(name) then
                -- A character we had filed as a partner of its own is brought in whole;
                -- one already listed as someone else's is left where it is.
                local other = owner(name)
                if other ~= id and other == p and isPartner(other) then id = join(other, id) end
                other = owner(name)
                if p ~= id and (other == id or not isPartner(other)) then
                    local info = entry(id)
                    info.alts = info.alts or {}
                    local old = info.alts[p]
                    info.alts[p] = {name = old and old.name or name, seen = math.max(old and old.seen or 0, now - i)}
                end
            end
        end
    end
    local info = db.settings.people and db.settings.people[id]
    if info and info.alts then keep(info.alts, MAX_ALTS) end
end

function handlers.START(sender, payload)
    if not trusted(sender) then return end
    -- One transfer at a time: someone else starting mid-way would scramble both.
    if inbound and inbound.from ~= sender then push(sender, "NO", "busy"); return end
    local expected = numbers(payload)[1] or 0
    if expected > MAX_INBOUND then
        push(sender, "BYE")
        note("Refused " .. short(sender) .. ": " .. expected .. " characters is more than this addon accepts")
        return
    end
    inbound = {from = sender, via = owner(sender), expected = expected, received = 0, new = 0, updated = 0, rejected = 0,
        last = GetTime(), words = {}, contexts = {}}
    note(string.format("Receiving from %s: 0 / %d", short(sender), expected))
end

-- One row of a transfer, whatever form it came in. A row that cannot be read still
-- counts, so the transfer is only whole if every row the sender counted arrived.
local function take(record)
    inbound.received = inbound.received + 1
    if not record then
        inbound.rejected = inbound.rejected + 1
        return
    end
    local result, key = Core.Absorb(db.records, record, GetServerTime(), inbound.via)
    if result == "new" then inbound.new = inbound.new + 1
    elseif result == "updated" then inbound.updated = inbound.updated + 1 end
    if result and onAbsorb then onAbsorb(key) end
end

local function received(sender, before)
    inbound.last = GetTime()
    if math.floor(inbound.received / 20) > math.floor(before / 20) then
        note(string.format("Receiving from %s: %d / %d", short(sender), inbound.received, inbound.expected))
    end
    if onChange then onChange() end
end

function handlers.REC(sender, payload)
    if not inbound or inbound.from ~= sender then return end
    if inbound.received >= MAX_INBOUND then return end
    local before = inbound.received
    take(Core.Decode(payload))
    received(sender, before)
end

-- Definitions for packed rows: words (DEF: index, value, index, value, ...) and
-- contexts (CTX: index, then region, client, name realm, realm, faction, build).
-- They only last for the transfer they came with.
function handlers.DEF(sender, payload)
    if not inbound or inbound.from ~= sender then return end
    local values = fields(payload)
    for i = 1, #values, 2 do
        local index = unb36(values[i])
        if index and index >= 1 and index <= MAX_WORDS then inbound.words[index] = values[i + 1] or "" end
    end
    inbound.last = GetTime()
end

function handlers.CTX(sender, payload)
    if not inbound or inbound.from ~= sender then return end
    local values = fields(payload)
    local index = unb36(values[1])
    if not index or index < 1 or index > MAX_CONTEXTS then return end
    inbound.contexts[index] = {values[2] or "", values[3] or "", values[4] or "", values[5] or "", values[6] or "", values[7] or ""}
    inbound.last = GetTime()
end

-- Several characters in one message, as packed above. A row that refers to something
-- never defined, or whose numbers do not read, is counted and discarded; once one
-- row's timestamp is unreadable, the ones after it in the message are too.
function handlers.ROWS(sender, payload)
    if not inbound or inbound.from ~= sender then return end
    local values = fields(payload)
    local before, previous = inbound.received, nil
    for start = 1, #values - ROW_FIELDS + 1, ROW_FIELDS do
        if inbound.received >= MAX_INBOUND then break end
        local context = inbound.contexts[unb36(values[start]) or 0]
        local name, level = values[start + 1], values[start + 2]
        local race, class = inbound.words[unb36(values[start + 3]) or 0], inbound.words[unb36(values[start + 4]) or 0]
        local guild, zone = inbound.words[unb36(values[start + 5]) or 0], inbound.words[unb36(values[start + 6]) or 0]
        local span, gap = unb36(values[start + 7]), unb36(values[start + 8])
        local last
        if gap and previous == nil then last = gap elseif gap and previous then last = previous + gap end
        previous = last or false
        local record
        if context and last and span and race and class and guild and zone and name ~= "" and level:find("^%d+$") then
            record = Core.Adopt({region = context[1], client = context[2], fullName = name .. "-" .. context[3],
                observerRealm = context[4], observerFaction = context[5], build = context[6], level = level,
                race = race, class = class, guild = guild, zone = zone, firstSeen = last - span, lastSeen = last})
        end
        take(record)
    end
    -- A message that is not a whole number of rows has lost some, and nobody can say
    -- how many: this transfer can no longer pass as whole, nor leave a checkpoint.
    if #values % ROW_FIELDS ~= 0 then inbound.damaged = true end
    received(sender, before)
end

function handlers.END(sender, payload)
    if not inbound or inbound.from ~= sender then return end
    local done = inbound
    inbound = nil
    local values = numbers(payload)
    local whole = done.received == done.expected and values[1] == done.expected and not done.damaged
    -- Only a transfer that arrived whole moves the mark. Anything short of that and
    -- the next swap asks from the old mark, which covers whatever went missing.
    if whole and values[2] and values[2] > 0 then
        db.syncThrough = db.syncThrough or {}
        db.syncThrough[owner(sender)] = values[2]
    end
    local summary = string.format("%s sent %d characters: %d new, %d updated%s%s",
        short(sender), done.received, done.new, done.updated,
        done.rejected > 0 and string.format(", %d unreadable and discarded", done.rejected) or "",
        whole and "" or string.format(". %d of %d arrived; the next swap asks again for the rest", done.received, done.expected))
    note(summary)
    -- A swap you started or accepted reports in chat; an automatic one only on the tab.
    if Sync.loud then say(summary) end
    Sync.loud = false
    if onChange then onChange() end
end

-- A checkpoint partway through a transfer: kept as the mark if every row before it
-- arrived, so a transfer cut short is picked up from there. Never moved backwards.
function handlers.MARK(sender, payload)
    if not inbound or inbound.from ~= sender then return end
    local values = numbers(payload)
    local at, count = values[1], values[2]
    if not (at and at > 0 and count and inbound.received == count) or inbound.damaged then return end
    db.syncThrough = db.syncThrough or {}
    if at > (db.syncThrough[inbound.via] or 0) then db.syncThrough[inbound.via] = at end
end

-- Only a sync with this person can be ended by them; anyone else's BYE is noise.
function handlers.BYE(sender)
    local involved = false
    if inbound and inbound.from == sender then inbound = nil; involved = true end
    if sending and sending.target == sender then reset(); involved = true end
    if involved then note(short(sender) .. " ended the sync") end
end

function Sync.OnMessage(prefix, message, _, sender)
    if prefix ~= PREFIX or type(message) ~= "string" then return end
    if sender == nil or sender == "" then return end
    local kind, payload = message:match("^(%u+)\t?(.*)$")
    local handler = kind and handlers[kind]
    if handler then handler(sender, payload) end
end

function Sync.StatusText()
    local peers = Sync.Peers()
    local names = {}
    for _, peer in ipairs(peers) do
        local notes = {}
        if peer.through > 0 then notes[#notes + 1] = "last swap " .. date("%m-%d %H:%M", peer.through) end
        local others = {}
        for _, name in ipairs(peer.all) do
            if person(name) ~= person(peer.name) then others[#others + 1] = short(name) end
        end
        table.sort(others)
        if #others > 3 then
            local more = #others - 2
            others = {others[1], others[2], more .. " more"}
        end
        if #others > 0 then notes[#notes + 1] = "also " .. table.concat(others, ", ") end
        if peer.tag then notes[#notes + 1] = "Battle.net friend" end
        names[#names + 1] = short(peer.name) .. (#notes > 0 and (" (" .. table.concat(notes, "; ") .. ")") or "")
    end
    return Sync.status, #names > 0 and table.concat(names, ", ") or "nobody yet"
end

-- What the addon can see of Battle.net, for /fc bnet: whether the client lets addons
-- read the friends list at all, and which partners it has recognised there.
function Sync.BnetText()
    local friends, usable = bnetPlaying()
    if not usable then return "This client does not let addons read your Battle.net friends, so partners are found by the characters you have swapped with." end
    local surnames = 0
    for _, friend in ipairs(friends) do
        if friend.name:find(" ", 1, true) then surnames = surnames + 1 end
    end
    local text = string.format("Battle.net: %d of your friends are playing WoW Forever%s.", #friends,
        #friends == 0 and "" or (surnames == #friends and ", and the client gives their full names"
            or surnames == 0 and ", but the client gives first names only, so only characters you have swapped with before can be picked out"
            or ""))
    local lines = {}
    for _, peer in ipairs(Sync.Peers()) do
        if peer.tag then
            local found = bnetFind(peer)
            lines[#lines + 1] = short(peer.name) .. ": linked" .. (found and (", playing " .. short(found) .. " now") or ", not on a character we can reach right now")
        else
            lines[#lines + 1] = short(peer.name) .. ": not linked yet (it happens by itself during a swap, if you are Battle.net friends)"
        end
    end
    if #lines > 0 then text = text .. " " .. table.concat(lines, ". ") .. "." end
    return text
end

function Sync.Busy()
    return sending ~= nil or inbound ~= nil
end

-- changed hears that there is something new to draw; absorbed hears the key of every
-- character a partner added or updated.
function Sync.Init(database, sayFn, changed, absorbed)
    Core, db, say, onChange, onAbsorb = NS.Core, database, sayFn, changed, absorbed
    db.settings.peers = db.settings.peers or {}
    pcall(noteSelf)
    Sync.available = C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function"
        and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function"
    if not Sync.available then
        Sync.status = "Addon messaging is unavailable on this client"
        return
    end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    if type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" then
        local escaped = ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
        notFound = "^" .. escaped:gsub("%%s", "(.+)") .. "$"
    end
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if notFound and addFilter then pcall(addFilter, "CHAT_MSG_SYSTEM", hideOffline) end
    -- Stopping must not depend on the chat filter being run, so the event is watched
    -- too; the filter only decides what reaches the chat frame.
    if notFound and CreateFrame then
        local watcher = CreateFrame("Frame")
        watcher:RegisterEvent("CHAT_MSG_SYSTEM")
        watcher:SetScript("OnEvent", function(_, _, message) gone(message) end)
    end
    C_Timer.NewTicker(RATE, drain)
end
