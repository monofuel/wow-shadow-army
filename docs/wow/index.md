# Vanilla WoW 1.12 primer — for an FFXIV endgame player

Written for monofuel: 10+ years FFXIV endgame, essentially zero WoW. Target
outcomes are (a) play vanilla competently on our private realm, (b) design
bots for the Ragefire Chasm speedrun and leveling leagues.

**Coming from FFXIV, the one-paragraph version.** Vanilla WoW is FFXIV with
every convenience removed and every number exposed. There is no GCD — the
weapon swing timer and the spell cast bar are independent clocks you interleave
by hand. There is no duty finder, no teleport network, no job gauge, no
role-neutral "any healer works", and no automatic mount at level 20. Enmity is
called **threat**, it has no UI, and the tank's whole job is arithmetic you
can't see. Sprouts don't get a duty support NPC; they get a level-60 stranger
in /1 general chat or they don't get a group. What you *do* get: an economy with
real depth, character sheets where every stat matters, and dungeon runs where
one bad pull is a five-minute corpse walk. That last part is why bots are
interesting here.

## Reading order

| # | Doc | One line |
|---|---|---|
| 1 | combat-basics.md (archived privately) | No GCD; swing timer, cast bars, resources, stats, hit/dodge/parry/glancing, downranking |
| 2 | threat-and-tanking.md (archived privately) | The core dungeon mechanic: threat numbers, 110/130% overtake, taunts, CC |
| 3 | party-and-roles.md (archived privately) | 5-man party, 1/1/3 trinity, manual invites, loot rules, XP split, rez options |
| 4 | classes-1.12.md (archived privately) | All 9 classes: roles at 19 and 60, lowbie toolkit, talent trees, RFC profile ids |
| 5 | leveling-1-20.md (archived privately) | The Horde 1-20 you will actually play; trainers, talents at 10, no mount until 40 |
| 6 | world-and-travel.md (archived privately) | Kalimdor/EK, Orgrimmar districts, flight paths, zeppelins, hearthstone, zone bands |
| 7 | dungeons-and-rfc.md (archived privately) | Dungeon etiquette, then RFC: layout, four bosses, route, wipe causes, tournament contract |
| 8 | death-and-recovery.md (archived privately) | Corpse runs, rez sickness, durability, permadeath interaction, bot recovery rules |
| 9 | professions-economy.md (archived privately) | 2+3 professions, gathering/crafting chains, skill colors, AH, mail, Industry Empire substrate |

Read 1→2→3 before your first dungeon. Read 5→6 before your first play session.
Read 4→7 before designing an RFC bot. 9 is the Industry Empire stretch goal.

## FFXIV → WoW glossary

| FFXIV | Vanilla WoW 1.12 | Notes |
|---|---|---|
| GCD (2.5s, everything shares it) | **none** | Swing timer + per-spell cast times + per-spell cooldowns. Instants are free-flowing |
| Enmity | **Threat** | Same idea, no UI at all. Melee overtake at 110%, ranged at 130% |
| Tank stance (multiplier toggle) | **Defensive Stance** (warrior) / **Bear Form** (druid) | Stance changes your ability set and damage taken, *not* a flat threat multiplier |
| Provoke / Shirk | **Taunt** / **Growl** / **Mocking Blow** | Taunt sets your threat to top-of-list, doesn't add a big flat chunk |
| Job | **Class + talent spec** | 9 classes; specs come from 3 talent trees, respec costs gold and is slow |
| Job gauge | **nothing** | Track your own combo points, rage, cooldowns, debuff timers |
| Duty Finder / Trusts | **nothing** | Manual `/who`, general chat, and typed invites. No cross-realm anything |
| Light party (4-man) | **Party of 5** (1 tank / 1 healer / 3 DPS) | Raids are 10/15/20/40 |
| Sprout / duty support | **nothing** | You ask a stranger or you don't go |
| Aetheryte teleport | **Flight paths** (must be discovered on foot first) + **Hearthstone** (1h CD) | Travel time is a real cost. See world-and-travel.md |
| Chocobo / Sprint | **Mount at level 40** (~100g all-in on our realm: 90g skill + 10g wolf) | Level 1-39 you walk. There is no sprint |
| Return (15 min) | **Hearthstone** (1 hour, rebindable at any innkeeper) | One bind point at a time |
| Marketboard (universal, per-DC) | **Auction House** (Orgrimmar, faction-locked) | No cross-faction, no cross-city listing view |
| Retainer ventures | **nothing** | Mail with a 1h cross-account delay is your only async logistics |
| Materia / melding | **Enchanting** (+ item suffixes "of the Bear" etc.) | No overmeld gambling |
| Gear "i-level" | **Item level** exists but stats are what matter | +hit and +crit are the twink currency |
| Direct Hit / crit / det | **+hit % / +crit % / stat weights** | No DH, no tenacity. Weapon skill replaces some of the hit budget |
| Vuln stacks / debuff windows | **Sunder Armor / Curse of Recklessness / Faerie Fire** | Manual, stacking, and tank-applied |
| Sastasha "kill order" markers | **Skull / X / raid target icons** (leader sets), or typed `/p` calls | Marking is a leader skill, not automatic |
| Weakness (rez penalty) | **Resurrection Sickness** — only from a **spirit healer**, 10 min, -75% stats | Player rezzes have *no* sickness. Big deal (see death-and-recovery.md) |
| Repair NPC / gear breaking | **Durability** — 100% loss at 0, repair costs gold | Spirit-healer rez takes 25% durability |
| Fantasia / job change | **nothing** — new class = new character | Alts are the norm |
| Materials mostly untradeable | **BoP vs BoE** matters everywhere | Gathered mats are almost all BoE and AH-able |

## Conventions in these docs

- Values are 1.12.1 as **our realm** implements them. The realm is VMaNGOS
  with `WowPatch = 10` (`/vmangos-etc/mangosd.conf:436` in the running
  container) — i.e. 1.12 content tables.
- `(verify in-game)` marks anything I could not confirm from VMaNGOS data or
  source and am asserting from knowledge.
- **bot notes** callouts tie a mechanic to `docs/control-plane.md` observation
  fields and `PolicyActionKind` actions, so the mechanic is actionable at the
  `vanilla_wow.nim_control.v1` boundary rather than just true.
- Tournament rules are never duplicated here. The contract lives in
  `coworld-playbook/games/vanilla-wow.md` and upstream
  `docs/coworld-rfc-roles.md`; these docs cite it.
