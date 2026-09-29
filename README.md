<p align="center"><img src="media/logo.png" width="128" alt="Forever Census icon"></p>

# Forever Census

A quiet /who census of your WoW Forever realm, with click-through charts, trends and in-game sync with friends.

Forever Census counts the characters on your realm while you play, and turns them into charts you can dig into. Built for WoW Forever 1.60.1 (interface 16001).

## Install

Download `ForeverCensus-x.y.z.zip` from [Releases](../../releases) and extract it into your Forever client's `Interface/AddOns` folder, so the layout is `Interface/AddOns/ForeverCensus/ForeverCensus.toc`. Restart the game fully after installing it for the first time, then type `/fc` or click the minimap button.

## How it collects

Each search is an ordinary /who, sent only when you click in the world (or press **Next query**). It never runs on a timer, and sends at most one search every 10 seconds by default (`/fc interval N`, 5 to 60). It works down from the highest level anyone has been seen at, splitting crowded levels by race, class and name until each search fits under the server's 50-result cap. It pauses in combat and while your Who or Friends window is open, your own searches always come first, and the Who window never pops up. A pass that doesn't finish in one session carries on at your next login. `/fc newpass`, or **Start a new pass** on the Passes tab, abandons it and starts again; nothing it found is lost.

## What you get

- Race, class and level charts for your realm, with the game's own icons. Click a class to see which races play it, a race to see its classes, or a guild to see its make-up.
- The largest guilds and busiest zones.
- Filters for search, level, faction, realm, and **Seen**, which keeps to characters seen in the last 7 or 30 days.
- **Trends**: new characters each day, and what each full census pass found, side by side.
- A searchable, sortable character list.
- **Sync with friends in game** (below).
- CSV export and import, and a standalone offline viewer for sharing with anyone.
- A minimap button, and an entry in the minimap's addon menu.

## Sync with a friend

The Sync tab swaps census data with someone else running Forever Census, and both of you end up with the combined data.

1. Your friend installs the addon and logs in on the same realm.
2. Type their character name in the Sync tab and choose **Share with them**, or `/fc sync Name`.
3. They choose **Accept request**, or `/fc accept`. From then on your addons swap by themselves, shortly after either of you logs in and every 20 minutes while you are both online, on whichever characters you are playing. Automatic swaps stay out of chat.

The first swap sends everything both of you have; after that only what is new or changed travels. A swap cut short, by a logout or a disconnect, carries on from where it stopped. Someone you have not accepted cannot send you anything, and every row that arrives is checked field by field before it is stored. The same character arriving twice is merged, never counted twice: the newest sighting supplies the details and the earliest sighting is kept.

## Share with anyone else

Open `ForeverCensus-Viewer.html` (in the addon folder) in a browser. In game, `/fc export`, copy the page, and paste it into the viewer; repeat for each page. The viewer shows the same breakdowns and filters as the addon, combines CSVs from several people, and saves a merged CSV. It needs no install, works offline and uploads nothing.

## Commands

| Command | Action |
| --- | --- |
| `/fc` | Open the window |
| `/fc stats` | Races, classes, levels, guilds and zones |
| `/fc data` | Browse, search and sort the characters |
| `/fc guilds` | Guilds by observed members |
| `/fc trends` | New characters per day, and passes compared |
| `/fc passes` | Completed census passes |
| `/fc newpass` | Abandon the pass under way and start a new one |
| `/fc sync Name` | Offer to swap data with that character (`/fc sync Name all` swaps everything again) |
| `/fc accept` / `/fc ignore` | Answer a sharing request |
| `/fc autosync` | Turn automatic swaps on or off |
| `/fc forget Name` | Remove a sync partner, with all of their characters |
| `/fc bnet` | Show which partners were found through Battle.net |
| `/fc sync cancel` | Stop a transfer in progress |
| `/fc export` / `/fc import` | CSV out, CSV in |
| `/fc pause` / `/fc resume` | Pause or resume collecting |
| `/fc interval N` | Seconds between searches, 5 to 60 |
| `/fc minimap` | Hide or show the minimap button |
| `/fc status` | Diagnostics |

## Good to know

- The counts are characters seen through /who, not an exact online population. /who only shows your own faction.
- WoW writes addon data on a /reload, a logout or a clean exit, and at no other time, so a crash loses what was gathered since the last one. The Status tab shows how much is still only in memory, and **Save to disk now** reloads to write it. Because this client's saving has been unreliable, the addon also checks at login that everything it handed over at logout came back.

## Privacy

Everything stays on your computer in the addon's saved variables (`ForeverCensus.lua`). Data only leaves your computer when you export it or sync with a partner you have accepted. A partner also receives the names of your characters, so their addon can recognise you on any of them; if a partner is one of your Battle.net friends, their BattleTag is kept in your saved variables to find them. Neither goes anywhere else. Exports contain in-game character names, guilds, zones and sighting times, so choose who you share them with.

## Licence

MIT; see [LICENSE.txt](LICENSE.txt).
