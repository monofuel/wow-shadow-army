# Interfaces

This is the current map of the persistent realm, the human advisor, the four
home bots, and The System. Historical external-host and `nim_control` designs
are not the runtime described here.

## Clients

There are two client implementations:

| | Headless Nim clients | Vanilla 1.12 client |
|---|---|---|
| Characters | Shadowfel, Igris, Tusk, Beru | Murist |
| Launch | embedded `lua-bot` targets in the Makefile | `make play-classic` |
| Our code | `lua/entry/home.lua` inside an embedded Lua 5.3 VM | `addons/ShadowArmy` Lua 5.0 addon |
| Connection | direct realmd/world WebSocket bridges on `:8080` | WoW protocol to the realm |

The advisor addon and bot policy are unrelated Lua programs. The addon runs
only in Murist's vanilla client. It neither controls the bots nor shares their
embedded VM.

## Bot path

```text
VMaNGOS observations
        │
        ▼
Nim rendered client / typed Observation
        │  generic projection in ../monofuel-vanilla-wow/bots/lua_bot
        ▼
lua/entry/home.lua: decide(view)
        │  declarative typed intent
        ▼
lua-bot intent parser and pilot lowering
        │
        ▼
typed client Action → VMaNGOS
```

`home.lua` sees only the current client's Observation. The fork projection now
includes the party roster and leader, invite state, each member's observed
target/health/power/death/auras/location/line of sight, the local spell facts,
active casts/channels, and richer visible-unit facts. Its new intents are:

- `accept_party`
- `promote_party` with a party-member GUID
- `follow` and `assist` with an observed party-player GUID
- `cast_spell` with an optional self/party `target_guid`

The pilot validates membership and visibility before lowering social actions.
Targeted casts are limited to self or a current party member. Navigation still
uses the existing RealPlayerBot route engine; its strategy is not invoked.

The old `tools/army_host.nim`, Lua subprocess, external frame protocol, and
`41114+slot` control sockets are not used. There is one OS/client process and
one Lua VM per character, so bots share no private state.

## Lifecycle and liveness

`make home-army-start` explicitly starts the four clients. It is separate from
`make start-server`. Each seat records:

```text
local_data/home-army/<Character>/launcher.pid
local_data/home-army/<Character>/launcher.log
local_data/home-army/<Character>/status/status.json
local_data/home-army/<Character>/observer/
```

The System's `control_up` compatibility field means the PID exists and the Lua
heartbeat is at most 30 seconds old; `control_port` is always zero. Dashboard
and MCP Start/Stop operations call the same per-seat Make lifecycle targets as
the command line.

## Advisor and admin path

The System (`system/system_server.nim`, `:7777`) uses server/admin surfaces:

- VMaNGOS SOAP `:7878` for announce, revive, and operational teleport actions
- MariaDB through `docker exec` for SELECT-only roster data
- `tools/realm_op.sh` for explicit realm up/down
- `Chat.log` for advisor events sent through in-game chat
- per-seat PID/status files for bot liveness and lifecycle

Vanilla WoW has no addon HTTP client. Advisor auto-update therefore travels
through the realm:

```text
advisor -- SendChatMessage/SAY --> VMaNGOS Chat.log --> The System
The System -- SOAP announce --> VMaNGOS chat --> advisor reload handler
```

See `docs/vanilla-addons/lua-api.md` for the local vanilla Lua/API references
used by the addon.

## Ports

| Port | Owner | Purpose |
|---|---|---|
| `3724` | VMaNGOS realmd | native game login |
| `8085` | VMaNGOS mangosd | native game world |
| `7878` | VMaNGOS SOAP | The System admin operations |
| `8080` | coworld HTTP/WS bridge | bot realmd/world WebSocket routes and health |
| `7777` | The System | dashboard and MCP |

## Ownership

- Persistent-home behavior belongs in this repository's `lua/` tree.
- Generic Observation projection, intent validation, and action lowering
  belong in `../monofuel-vanilla-wow/bots/lua_bot/` only when the interface
  needs them.
- Advisor behavior belongs in `addons/ShadowArmy/` and uses the checked-in Lua
  documentation referenced by `AGENTS.md`.
- Every build, test, and run uses the relevant repository's `nix develop`.
