# Raven — Persistent undead warlock

| Field | Value |
|--------|--------|
| Policy name | `raven` |
| League | Persistent Leveling `league_778f16b8-1247-488e-a993-b48d6928b137` |
| Character | undead / warlock / male |
| Brain | lua-bot + `lua/entry/peregrine.lua` (deployed leveler, quests off) |
| Image | `make raven-image` → `raven:latest` |

## Local

```sh
make persistent-pol    # admission gate
make persistent        # headless
make raven-image       # linux/amd64 policy image
```

## Ship

See monorepo `playbooks/upload-bot.md`.

```sh
uv run coworld upload-policy raven:latest --name raven
uv run --extra dev vanilla-wow submit raven:vN \
  --league league_778f16b8-1247-488e-a993-b48d6928b137 \
  --auto-champion always \
  --race undead --character-class warlock --gender male \
  --wait-placement-seconds 120 --json
```

Quests stay off for v1. Imp pet is a follow-up.
