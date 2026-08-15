# Bot roster

This is the canonical persistent-home roster. Murist is the human party
leader; the other four characters are embedded Lua bot seats.

| Character | Account | Race / class | Party role | Foreground target |
|---|---|---|---|---|
| Murist | `monofuel` | undead / warlock | human leader | `make play-classic` |
| Shadowfel | `shadow1` | undead / warlock | caster DPS | `make warlock-bot` |
| Igris | `shadow2` | undead / warlock | caster DPS | `make igris-bot` |
| Tusk | `shadow3` | undead / warrior | tank | `make tusk-bot` |
| Beru | `shadow4` | undead / priest | healer | `make beru-bot` |

Persona notes: [Tusk](personas/tusk.md) and [Beru](personas/beru.md).

## Lifecycle

Realm and bot lifecycle are separate on purpose. Start the persistent realm
with `make start-server`; start the bot clients only when wanted:

```sh
make home-army-start
make home-army-status
make home-army-stop
make home-army-restart
```

`make party-army` remains an alias for `home-army-start`. Individual detached
lifecycle targets are `shadowfel-start`/`shadowfel-stop`, `igris-*`, `tusk-*`,
and `beru-*`. The foreground targets in the table are useful for debugging.
None of these targets creates accounts, rewrites characters, or starts the
realm.

Each seat has isolated runtime files under
`local_data/home-army/<Character>/`:

- `launcher.pid` and `launcher.log`
- `status/status.json`, updated each frame by the embedded policy
- `observer/`, the rendered-client observation evidence

The System uses the launcher PID plus a status heartbeat no older than 30
seconds. The retired `nim_control` ports are not part of the current runtime.

## Home policy

All four clients launch `lua/entry/home.lua` through the generic `lua-bot`
interface in `../monofuel-vanilla-wow`.

- Accept party invitations only from Murist.
- If the bot is leader and Murist is in the party, promote Murist.
- Follow Murist with a hard leash and assist his observed hostile target.
- Apply class roles: warlock damage, Tusk tank/threat, Beru healing,
  protection, resurrection, and damage when healing is not needed.
- On death, accept resurrection; briefly wait for a living nearby Beru;
  otherwise release, navigate to the corpse, and reclaim.
- If Murist is offline, absent from the party, or not observable, run the
  solo `accelerated` policy instead of standing idle.
- Do not issue `pet_attack`; the pet's normal combat behavior owns that.

The policy can only act on the current character's typed Observation. Party
membership, leader, targets, positions, health, auras, spells, and casts are
mirrored by the generic fork interface; there is no shared bot process or
out-of-band party state.

## Rules

- Fair play: no GM progress, DB edits, or out-of-band seat collusion.
- Bot policy belongs here; only generic Observation/intent plumbing belongs
  in `../monofuel-vanilla-wow`.
- Build, test, and run through each repository's `nix develop` environment.
