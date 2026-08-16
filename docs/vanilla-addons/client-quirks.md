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

## UISpecialFrames membership = the WORLD MAP closes your window (proven 2026-08-16)

Stock `UIParent.lua` walks `UISpecialFrames` in `CloseWindows()` and hides
**every visible entry**, and `CloseAllWindows()` is called from far more than
Escape:

| Caller | Where |
|---|---|
| `ShowUIPanel` for any `area == "full"` panel | `UIParent.lua:693` |
| **`UIPanelWindows["WorldMapFrame"] = { area = "full" }`** | `UIParent.lua:30` |
| `PLAYER_DEAD` | `UIParent.lua:239` |
| `PLAYER_CONTROL_LOST` (fear, charm, MC) | `UIParent.lua:478` |
| `ToggleGameMenu` / Escape | `UIParent.lua:1476, 1491` |

So **opening the world map closes every addon window in `UISpecialFrames`**.
This is what ate the combat coach for three revisions (r53, r54, r55 each
re-asserted "open" at load and at login — before any of these callers had
fired). Proven by reading the extracted 1.12 FrameXML at
`~/Code/coworld-local-data/player-cache/client_assets/Interface/FrameXML/`.

Working pattern (r56): do not assert the open state, KEEP it. An `OnHide`
that the addon did not initiate arms a restore flag; a 4 Hz guard re-shows the
window once nothing fullscreen is up. Deliberate closes (close button, slash
command) set a sticky "closed" flag first. Cost: Escape can no longer close
such a window, because Escape and the world map are the same call.

## No player facing on 5875; 8-arg SetTexCoord IS supported (proven 2026-08-16)

Read out of `WoW.exe`'s method tables and the extracted FrameXML, for the r56
guidance arrow:

- **`GetPlayerFacing` does not exist** in the 5875 binary. Neither does any
  minimap rotation: the `Minimap` widget's methods are exactly
  `GetPingPosition, PingLocation, SetZoom, GetZoom, GetZoomLevels,
  SetPlayerModel, SetArrowModel, SetBlipTexture, SetIconTexture,
  SetMaskTexture`, the string `rotateMinimap` appears nowhere in the client,
  and **`MiniMapCompassRing` is post-1.12** (absent from the binary, from
  Minimap.xml and from disk) — so the era trick of reading a facing off the
  compass ring does not apply here. Any on-screen direction indicator on this
  build is NORTH-UP or it is lying.
- **`Texture:SetRotation` does not exist** either (the `SetRotation` in the
  binary belongs to DressUpModel/CharacterModel).
- **8-argument `SetTexCoord` works.** The engine's own usage string is
  `SetTexCoord(minX, maxX, minY, maxY) or SetTexCoord(ULx, ULy, LLx, LLy,
  URx, URy, LRx, LRy)`, and stock `TaxiFrame.lua:223` (`DrawRouteLine`)
  rotates flight-path lines with it. That is the only texture-rotation route
  on 1.12, and it is enough for a smoothly rotating arrow.
- Usable stock arrow art: `Interface\Minimap\ROTATING-MINIMAPARROW` — 32x32,
  a triangle pointing up whose ink stops around radius 12 of 16, so a
  full-range rotated quad only ever samples transparent border outside the
  art. (`MinimapArrow`, `ROTATING-MINIMAPGUIDEARROW`,
  `ROTATING-MINIMAPCORPSEARROW`, `Rotating-MinimapGroupArrow` and
  `Interface\Buttons\UI-SortArrow` also exist.)

The addon reports the same facts from the RUNNING client once per session:
`<SA> hud arrow src=… getPlayerFacing=… setRotation=… texcoord8=…`.

## Bulk looting is blocked even for hardware-driven panel clicks

`LootSlot` failed in the probe even from a button press — see
`docs/advisor-sandbox-gates.md`. Addon-driven looting is off the table
on this build; the r44 advisor removed its loot machinery accordingly.
