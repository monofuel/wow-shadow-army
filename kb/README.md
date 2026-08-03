# Knowledgebase — reserved, currently empty

This folder is the **bot memory** layer: durable facts the LLM planner reads
at play time. It is **not built yet**, and it is deliberately empty.

## What belongs here (once the planner exists)

Facts a bot can act on in-game, written small and one per file:

- map and route facts ("the Barrens road bends east at the crossroads")
- quest data the bots discovered (giver, items, mob ids, reward spell)
- tool reliability learned from play ("accept_quest fails on vendors with
  empty gossip rows")
- per-shadow ledgers (professions, standing) once we keep them

## What does NOT belong here

Anything about **our code**: file paths, Nim flags, Makefile targets, packet
names, upstream pins, build steps, postmortems of our own bugs. A bot playing
the game cannot use those. They go in `docs/`.

Until 2026-08-03 this folder held nine such engineering documents — written
for the deleted Python `brain/`, which was their only claimed reader. They now
live in `docs/` (see `docs/postmortems/` for the debugging writeups).

## Why it is empty rather than deleted

`docs/v2.md` and `AGENTS.md` describe a three-layer architecture —
knowledgebase / Lua tools / LLM planner. Two of the three exist. This folder
holds the name for the third so we do not re-invent it under a worse one, but
an empty folder is an honest description of the current state: the bots have
no memory yet.

Do not park engineering notes here to give it something to hold.
