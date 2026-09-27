# Changelog

## 0.8.0

- A first swap is about four times as quick: between two 0.8.0 addons, characters go several to a message, with zones, guilds and realms sent once per swap. The pace on the wire is unchanged. Swapping with 0.7.x works as before.
- A message the game holds back for going too fast is now sent again instead of being lost, and the Sync tab says how often it happened.

## 0.7.2

- Smoother while syncing: the window no longer redraws its charts on every progress update, a big swap no longer freezes the game for a moment as it starts, and redrawing the window is twice as fast.

## 0.7.1

- Sync partners are recognised on any of their characters, new ones included, and so are yours: alts swap by themselves, and switching character never starts a swap over. Both sides need 0.7.1.
- Partners who are Battle.net friends are found on whatever character they are playing. `/fc bnet` shows what the addon can see.
- A partner logging off mid-swap no longer fills chat with "No player named … is currently playing".
- A swap cut short carries on from where it stopped next time.
- Characters linked one at a time with earlier versions are brought together as one partner.

## 0.7.0

- New **Seen** filter: keep to characters seen in the last 7 or 30 days.
- Click a guild on the Overview or the Guilds tab to see its races, classes, levels and zones. Pick a class or race inside it as well.
- New **Trends** tab: new characters each day, and census passes compared class by class.
- Minimap button, plus an entry in the minimap's addon menu. `/fc minimap` hides the button.
- The offline viewer gets the same breakdowns and filters, and a copy now ships in the addon folder.
- An icon and an MIT licence.

## 0.6.2

- Accepted partners swap by themselves, shortly after either logs in and every 20 minutes while both are online, without lines in chat. `/fc autosync` turns it off.
- Searches stop at level 30, the beta's cap.

## 0.6.1

- After the first swap, sync only sends what is new or changed, and never sends back what came from the partner. `/fc sync Name all` swaps everything again.

## 0.6.0

- Click a class or race bar to break the other chart down by it.
- A realm filter.
- A census pass carries on after a reload or logout instead of starting over, and searches go breadth first.
- Races the client does not list, such as WoW Forever's own, are learned from replies and searched for.
- Sync only accepts a yes from someone you asked, and long names in three-byte scripts sync and import.
