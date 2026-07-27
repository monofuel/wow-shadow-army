# Advisor sandbox gates (vanilla 1.12 human client)

**Product decision (2026-07-27):** vanilla ShadowArmy is **L0 only**.
Levels 1–4 wait for the Nim client’s Lua addon system. Do not grow
actuation on stock `WoW.exe`. See `docs/advisor-autopilot.md`.

Probe facts below explain *why* we stopped climbing on this client.

Instrument: advisor panel **Probe** (Click / Frame / Delay).

## Cast armor — 2026-07-27

`CastSpellByName` Demon Skin / Armor:

| Context | Result |
|---------|--------|
| Click | **works** |
| Frame | **does not** |
| Delay | **does not** |

## ReloadUI — 2026-07-27

| Context | Result |
|---------|--------|
| Click | **works** |
| Frame | **does not** |
| Delay | **does not** |

## Loot all (`LootSlot`) — 2026-07-27

Loot window open:

| Context | Result |
|---------|--------|
| Click | **does not** |
| Frame | **does not** |
| Delay | **does not** |

## Not pursuing

Client unlock / inject / third-party unlockers for freer Lua on vanilla.
Too much pain for L1–L4 product goals. Reference only:
`docs/advisor-unlock.md`, local clone `../zebra` (1.12 path is thin).
