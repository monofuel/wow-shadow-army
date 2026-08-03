# Auto-promote Murist to party leader

> **STALE — written against upstream pin `ec5bd2f9d`.** The pin moved to
> `93730fb97` on 2026-08-03 after a 1661-commit upstream restructure
> (`client/` + `player/` → `environment/` + `bots/`), and the
> `lua-external-policy` fork branch this describes was dropped. Nothing below
> is verified against the new tree. See `docs/work-2026-08-03.md`.

When a bot seat is party leader and Murist is in the group, `army_host`
selects factorized `promote_party` (fork: CMSG_GROUP_SET_LEADER) for Murist.

Requires bot clients rebuilt with `bakPromoteParty` (restart seats after fork
change). Pure decide: `tools/party_promote.nim`. Rate limit 5s.

Run: `make escort-army` (or army_host on the current leader seat) with `--leader=Murist`.
