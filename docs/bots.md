# Bot roster

The shadow army cast: who exists, which account/slot drives them, and how to
bring each seat up. This is the canonical list for this repo.

**Scope:** only the seats below are ours. The coworld framework ships its own
foundation characters (`BOT1`–`BOT5`, `COWORLD`, `COWCAM` accounts) for
framework testing — they are not part of the army and are not documented
here. monofuel also keeps his own manual-testing characters; those are his
list, not this one.

## The cast

Control socket is `41114 + slot`. Runtime dir is
`local_data/nim-runtime-slot<N>/`.

| Character | Account | Race / class | Role | Slot | Bring-up |
|-----------|---------|--------------|------|------|----------|
| Murist | `monofuel` | undead / warlock | human-played leader | — | `make play-classic` (real client) |
| Shadowfel | `shadow1` | undead / warlock | caster DPS | 2 | `make warlock-account` → `make warlock-bot` |
| Igris | `shadow2` | undead / warlock | caster DPS | 3 | `make igris-account` → `make igris-bot` |
| Tusk | `shadow3` | undead / warrior | tank | 4 | `make tusk-account` → `make tusk-bot` |
| Beru | `shadow4` | undead / priest | healer | 5 | `make beru-account` → `make beru-bot` |

Persona theses: [personas/tusk.md](personas/tusk.md),
[personas/beru.md](personas/beru.md). Shadowfel and Igris don't have persona
docs yet — they run the warlock seat described in
[warlock-seat.md](warlock-seat.md).

Standing army: `make escort-army` drives slots 2–5 through
`tools/army_host` + `lua/tools/escort_leader`, party
`Murist,Shadowfel,Igris,Tusk,Beru`, invites accepted from Murist only.

## Milestones

- **2026-07-25** — Murist grinds 1→6 solo (Deathknell); later 7 in party.
- **2026-07-27** — Shadowfel, Igris, Tusk, Beru all reach level 6 by
  overnight party grinding in Tirisfal. Verified legit against the realm's
  `LevelUp.log` (every intermediate ding, hours apart, moving grind
  positions) and a GM-command sweep of `Server.log`/`Ra.log`/`Chat.log`
  (no level/xp/modify commands). Shadowfel's larger banked XP (2314) is
  from grinding ~6 extra hours at 6 while dragging the others over the line.
- Next: Summon Imp via quest 1470 for the warlock seats (docs/v2.md).

Live levels/XP come from the realm DB, not this doc:

```
docker exec coworld-vmangos-coworld-game-1 mariadb -umangos -pmangos characters \
  -e "SELECT name, level, xp, played_time_total FROM characters WHERE account >= 100008"
```

## Rules that apply to every seat

- Fair play: no GM progress, no DB pokes, no out-of-band seat collusion
  (`AGENTS.md`). Local GM is observation/ops only (revive, tele for tests).
- Policy lives in `lua/tools/`; the Nim host is glue (docs/v2.md).
- Realm-side evidence for milestone claims:
  `../coworld-vanilla-wow/local_data/coworld-run/logs/LevelUp.log` plus the
  fair-play audit JSONL (`local_data/audit/fair-play.jsonl`, once wired).
