# Client quirks — where OUR build diverges from the reference docs

The reference material (1.12.1 FrameXML dumps, era addon sources, wiki
mirrors) is mostly right for build 5875 — but "mostly" fails silently.
This file records every place we have PROVEN our specific client (stock
1.12.1/5875 under wine, `local_classic`) behaves differently from what
the docs or stock-UI conventions imply. Add an entry the moment a live
probe contradicts the paper; each entry says how we proved it and what
the working pattern is.

## GameTooltip:SetAction returns no populate flag (proven 2026-08-15)

Stock `ActionButton_SetTooltip` branches on `GameTooltip:SetAction`'s
return value as an "I populated the tooltip" signal, so it is a
documented-by-convention API. On this build the call returns nothing:
a scan guarded by `local ok, filled = pcall(tip.SetAction, tip, slot);
if not (ok and filled) then skip end` classified all 120 action slots
unreadable — the r44 bar sweep shipped as a silent no-op
(`swept removed=0`), while PickupSpell/PlaceAction on the same slots
worked fine.

Working pattern: explicitly blank the tooltip's `<name>TextLeft1`
FontString (`SetText(nil)`) in addition to `ClearLines()`, call
`SetAction`, then treat non-empty text as the populate proof. The blank
makes a stale read impossible; the return value is never consulted.

## ReloadUI is gated outside hardware events (long known)

`ReloadUI()` / `ConsoleExec("reloadui")` from timer or chat-event
context often no-op on this wine build. The addon's reload ladder
(free paths → lit Reload! button arming the next out-of-combat
action-bar press) exists because of this. Never design a flow that
assumes programmatic reload succeeds; always confirm via the
`<SA> loaded rev=…` event.

## Buff textures must be captured, never guessed (ongoing)

`UnitBuff` texture paths on this build do not reliably match the icon
names one would guess from spell names: the Demon Skin autocast watch
never detected its own buff after a successful cast
(`captured=none`, 2026-08-15 live event) because the guessed texture
was wrong. Working pattern: capture the real texture from `UnitBuff`
immediately after a confirmed cast and persist that, or verify against
a live buff before trusting a hardcoded path. `WATCHED_BUFFS` carries
this warning in-code.

## Bulk looting is blocked even for hardware-driven panel clicks

`LootSlot` failed in the probe even from a button press — see
`docs/advisor-sandbox-gates.md`. Addon-driven looting is off the table
on this build; the r44 advisor removed its loot machinery accordingly.
